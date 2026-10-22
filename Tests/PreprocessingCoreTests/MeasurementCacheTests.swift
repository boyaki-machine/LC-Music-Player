import AVFAudio
import CryptoKit
import Foundation
import Testing
import AudioProcessingCore
@testable import PreprocessingCore

private struct CacheFixture {
    let root: URL
    let configuration: MeasurementCacheConfiguration
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configuration = MeasurementCacheConfiguration(url: root.appendingPathComponent("cache/measurements.sqlite"),
            platform: MeasurementPlatformIdentity(system: "test"))
    }
    func wave(_ name: String = "tone.wav", seconds: Double = 0.6, amplitude: Float = 0.1) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for n in 0..<4800 { buffer.floatChannelData![0][n] = sin(Float(n) * 2 * .pi * 1000/48000) * amplitude }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<Int(seconds*10) { try file.write(from: buffer) }
        }
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
private func profile(_ rate: Double = 48000, _ channels: UInt32 = 2) throws -> MeasurementProfile { try .init(sampleRate: rate, channels: channels) }
private struct NoStableIdentity: MeasurementSourceIdentifying {
    func identity(for url: URL) throws -> MeasurementSourceIdentity? { nil }
}
/// A provider without file attributes, like the Music library: its revision is whatever it reports.
private final class ProviderIdentity: MeasurementSourceIdentifying, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = "180.0/1700000000"
    func replace(with revision: String) { lock.withLock { self.revision = revision } }
    func identity(for url: URL) throws -> MeasurementSourceIdentity? {
        lock.withLock { MeasurementSourceIdentity(locator: "provider://\(url.lastPathComponent)", resource: "provider/1", revision: revision, size: 180_000) }
    }
}

@Suite(.serialized) struct MeasurementCacheTests {
    @Test func survivesNewProcessorReusesNativePeakAndRecalculatesTarget() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }
        let url = try f.wave(), processor = AudioPreprocessor(cache: f.configuration)
        let original = try Data(contentsOf: url)
        #expect(try LocalMeasurementSourceIdentity().identity(for: url) != nil)
        _ = try SQLiteConnection(url: f.configuration.url, maximumBytes: f.configuration.maximumBytes)
        let probe = MeasurementCache(f.configuration)
        #expect(try probe.request(url, profile: profile()) != nil)
        let metrics = try await processor.measureLevels(url, profile: profile())
        #expect(await processor.statistics().levelScans == 1)
        let reopened = AudioPreprocessor(cache: f.configuration)
        let restored = try await reopened.measureLevels(url, profile: profile())
        #expect(restored == metrics)
        let peak = try await reopened.measure(url)
        #expect(peak == metrics.sourcePeak)
        let stats = await reopened.statistics()
        #expect(stats.levelScans == 0 && stats.peakScans == 0 && stats.cacheHits == 2)
        let before = try NormalizationPlan(metrics: restored.levels, profile: restored.profile, settings: .init(targetLUFS: -23))
        let after = try NormalizationPlan(metrics: restored.levels, profile: restored.profile, settings: .init(targetLUFS: -18))
        #expect(before.gainDB != after.gainDB)
        #expect(try Data(contentsOf: url) == original)
        let permissions = try FileManager.default.attributesOfItem(atPath: f.configuration.url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test func sourceIdentityReplacementRenameAndSymlinkRules() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }
        let url = try f.wave("one/tone.wav"), processor = AudioPreprocessor(cache: f.configuration)
        _ = try await processor.measure(url)
        let other = try f.wave("two/tone.wav", amplitude: 0.3)
        _ = try await processor.measure(other)
        let changed = try f.wave("replacement.wav", amplitude: 0.5)
        let oldDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: changed, to: url)
        try FileManager.default.setAttributes([.modificationDate: try #require(oldDate)], ofItemAtPath: url.path)
        #expect(abs(try await processor.measure(url).samplePeak - 0.5) < 1e-6)
        // In-place same-size mutation with restored mtime must fail the ctime check.
        let previous = try SourceFingerprint(url: url)
        let file = try FileHandle(forWritingTo: url); try file.seek(toOffset: 500)
        try file.write(contentsOf: Data([0,0,0,0])); try file.close()
        try FileManager.default.setAttributes([.modificationDate: try #require(oldDate)], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try previous.validate() }
        _ = try await processor.measure(url)
        let renamed = url.deletingLastPathComponent().appendingPathComponent("renamed.wav")
        try FileManager.default.moveItem(at: url, to: renamed)
        _ = try await processor.measure(renamed)
        let link = f.root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: renamed)
        _ = try await processor.measure(link)
        let stats = await processor.statistics()
        #expect(stats.peakScans == 5 && stats.cacheHits == 1)
    }
    /// A provider's identity keeps measurements across processors until the provider reports another revision.
    @Test func providerIdentitySurvivesNewProcessorUntilItsRevisionChanges() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }
        let url = try f.wave(), provider = ProviderIdentity()
        var config = f.configuration; config.sourceIdentity = provider
        let metrics = try await AudioPreprocessor(cache: config).measureLevels(url, profile: profile())
        let reopened = AudioPreprocessor(cache: config)
        #expect(try await reopened.measureLevels(url, profile: profile()) == metrics)
        var stats = await reopened.statistics()
        #expect(stats.levelScans == 0 && stats.cacheHits == 1)
        provider.replace(with: "181.0/1700000000")
        let replaced = AudioPreprocessor(cache: config)
        _ = try await replaced.measureLevels(url, profile: profile())
        stats = await replaced.statistics()
        #expect(stats.levelScans == 1 && stats.cacheHits == 0)
    }
    /// A new build of the app keeps measurements: only the OS major version, the algorithm, the
    /// conversion and the output profile take part in the key.
    @Test func incompatiblePlatformAlgorithmConversionAndOutputMiss() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }; let url = try f.wave()
        _ = try await AudioPreprocessor(cache: f.configuration).measureLevels(url, profile: profile())
        let rebuilt = AudioPreprocessor(cache: f.configuration)
        _ = try await rebuilt.measureLevels(url, profile: profile())
        #expect(await rebuilt.statistics().levelScans == 0)
        for version in 0..<4 {
            var config = f.configuration
            if version == 0 { config.platform = .init(system: "test 2") }
            if version == 1 { config.algorithmVersion = 2 }
            if version == 2 { config.conversionVersion = 2 }
            let processor = AudioPreprocessor(cache: config)
            _ = try await processor.measureLevels(url, profile: profile(version == 3 ? 44100 : 48000, version == 3 ? 1 : 2))
            #expect(await processor.statistics().levelScans == 1)
        }
    }
    @Test func currentPlatformNamesOnlyTheMajorVersion() {
        let system = MeasurementPlatformIdentity.current.system
        #expect(system.hasSuffix(" \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"))
        #expect(!system.contains("."))
        #expect(MeasurementRequest.legacyMajor("Version 26.0 (Build 25A354)/CoreAudio") == 26)
        #expect(MeasurementRequest.legacyMajor("Version 15.7.1 (Build 24G231)/CoreAudio") == 15)
        #expect(MeasurementRequest.legacyMajor("test") == nil)
    }
    /// Records of schema 1, keyed by an earlier build, are carried over when Core Audio decoded them
    /// on the same OS major version with the same algorithm and conversion; others are dropped.
    @Test func schemaOneRecordsCarryOverOnlyWhenCompatible() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        var config = f.configuration; config.platform = .current
        let owner = UUID()
        let cases: [(name: String, environment: String, algorithm: String, carried: Bool)] = [
            ("same.wav", "Version \(major).1 (Build 1A1)/CoreAudio", "1", true),
            ("older-os.wav", "Version \(major - 1).6 (Build 1A1)/CoreAudio", "1", false),
            ("other-decoder.wav", "Version \(major).1 (Build 1A1)", "1", false),
            ("other-algorithm.wav", "Version \(major).1 (Build 1A1)/CoreAudio", "2", false),
        ]
        var urls: [URL] = []
        for item in cases {
            let url = try f.wave(item.name); urls.append(url)
            _ = try await AudioPreprocessor(cache: config).measureLevels(url, profile: profile(), ownerID: owner)
        }
        // Rewrite every record as the first format would have stored it.
        do {
            let db = try SQLiteConnection(url: config.url, maximumBytes: config.maximumBytes)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            for row in try db.query("SELECT key, context FROM measurements") {
                let c = try PropertyListDecoder().decode([String].self, from: try #require(row[1].data))
                let item = try #require(cases.first { c[1].hasSuffix($0.name) })
                let legacy = ["LCMP-measurements-1", c[1], c[2], c[3], c[4], "1.15.106", "106", "digest", item.environment,
                              item.algorithm, "1", c[9], c[10], c[11]]
                let context = try encoder.encode(legacy)
                let key = Data(SHA256.hash(data: context))
                try db.execute("PRAGMA foreign_keys=OFF")
                try db.execute("UPDATE owners SET key=? WHERE key=?", [.blob(key), .blob(try #require(row[0].data))])
                try db.execute("UPDATE measurements SET key=?, context=?, epoch=? WHERE key=?",
                               [.blob(key), .blob(context), .blob(Data("legacy".utf8)), .blob(try #require(row[0].data))])
                try db.execute("PRAGMA foreign_keys=ON")
            }
            try db.execute("PRAGMA user_version=1")
        }
        let upgraded = AudioPreprocessor(cache: config)
        for (item, url) in zip(cases, urls) {
            let before = await upgraded.statistics().levelScans
            _ = try await upgraded.measureLevels(url, profile: profile(), ownerID: owner)
            #expect(await upgraded.statistics().levelScans - before == (item.carried ? 0 : 1), "\(item.name)")
        }
        let db = try SQLiteConnection(url: config.url, maximumBytes: config.maximumBytes)
        #expect(db.schemaVersion == SQLiteConnection.currentVersion)
        // The carried record keeps its owner, so an audit of the library keeps it.
        await upgraded.reconcileCacheOwners([owner])
        let reopened = AudioPreprocessor(cache: config)
        _ = try await reopened.measureLevels(urls[0], profile: profile())
        #expect(await reopened.statistics().levelScans == 0)
    }
    @Test func corruptMissingFutureAndUnwritableStoresFallBack() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }; let url = try f.wave()
        let processor = AudioPreprocessor(cache: f.configuration)
        let expected = try await processor.measureLevels(url, profile: profile())
        do {
            let db = try SQLiteConnection(url: f.configuration.url, maximumBytes: f.configuration.maximumBytes)
            try db.execute("UPDATE measurements SET payload=?", [.blob(Data("broken".utf8))])
        }
        let corrupted = AudioPreprocessor(cache: f.configuration)
        #expect(try await corrupted.measureLevels(url, profile: profile()) == expected)
        #expect(await corrupted.statistics().levelScans == 1)
        do {
            let db = try SQLiteConnection(url: f.configuration.url, maximumBytes: f.configuration.maximumBytes)
            try db.execute("PRAGMA user_version=999")
        }
        let future = AudioPreprocessor(cache: f.configuration)
        _ = try await future.measureLevels(url, profile: profile())
        #expect(await future.statistics().levelScans == 1)
        var unavailable = f.configuration; unavailable = .init(url: url.appendingPathComponent("blocked.sqlite"), platform: unavailable.platform)
        let failed = AudioPreprocessor(cache: unavailable)
        #expect(try await failed.measureLevels(url, profile: profile()) == expected)
        #expect(await failed.statistics().cacheWriteFailures > 0)
        // Unsupported identity disables persistence without preventing measurement.
        var uncertain = f.configuration; uncertain.sourceIdentity = NoStableIdentity()
        let bypass = AudioPreprocessor(cache: uncertain)
        _ = try await bypass.measure(url); _ = try await bypass.measure(url)
        #expect(await bypass.statistics().peakScans == 2)
    }
    @Test func canceledAndConcurrentRequestsShareOnlyCompletedResults() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }; let url = try f.wave(seconds: 30)
        let processor = AudioPreprocessor(cache: f.configuration), token = PreparationCancellation()
        let a = Task { try await processor.measureLevels(url, profile: profile(), cancellation: token) }
        let b = Task { try await processor.measureLevels(url, profile: profile()) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await processor.statistics().coalescedRequests == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await processor.statistics().coalescedRequests == 1)
        token.cancel()
        do { _ = try await a.value; Issue.record("Expected canceled waiter") } catch { #expect(error is CancellationError) }
        let result = try await b.value
        #expect(await processor.statistics().levelScans == 1)
        let restored = try await AudioPreprocessor(cache: f.configuration).measureLevels(url, profile: profile())
        #expect(restored == result)
        let allCanceled = try f.wave("cancel.wav", seconds: 30)
        let cancel = PreparationCancellation()
        let c = Task { try await processor.measureLevels(allCanceled, profile: profile(), cancellation: cancel) }
        try await Task.sleep(for: .milliseconds(5)); cancel.cancel()
        do { _ = try await c.value; Issue.record("Expected canceled scan") } catch { #expect(error is CancellationError) }
        let retry = AudioPreprocessor(cache: f.configuration)
        _ = try await retry.measureLevels(allCanceled, profile: profile())
        #expect(await retry.statistics().levelScans == 1)
    }
    @Test func auditKeepsSharedOwnersAndRejectsLateExcludedWrites() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }; let url = try f.wave(seconds: 10)
        let processor = AudioPreprocessor(cache: f.configuration), a = UUID(), b = UUID()
        await processor.reconcileCacheOwners([a,b])
        _ = try await processor.measureLevels(url, profile: profile(), ownerID: a)
        _ = try await processor.measureLevels(url, profile: profile(), ownerID: b)
        await processor.reconcileCacheOwners([b])
        _ = try await processor.measure(url, ownerID: b)
        #expect(await processor.statistics().peakScans == 0)
        _ = try await processor.measureLevels(url, profile: profile(), ownerID: b)
        #expect(await processor.statistics().levelScans == 1)
        await processor.reconcileCacheOwners([])
        let reopened = AudioPreprocessor(cache: f.configuration)
        _ = try await reopened.measureLevels(url, profile: profile())
        #expect(await reopened.statistics().levelScans == 1)
        let late = try f.wave("late.wav", seconds: 30)
        await processor.reconcileCacheOwners([a])
        let pending = Task { try await processor.measureLevels(late, profile: profile(), ownerID: a) }
        try await Task.sleep(for: .milliseconds(5)); await processor.reconcileCacheOwners([])
        _ = try await pending.value
        let retry = AudioPreprocessor(cache: f.configuration)
        _ = try await retry.measureLevels(late, profile: profile())
        #expect(await retry.statistics().levelScans == 1)
    }
    @Test func countAgeAndPageBudgetAreBounded() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }
        var config = f.configuration; config.maximumRecords = 2; config.maximumBytes = 65536
        let processor = AudioPreprocessor(cache: config)
        for n in 0..<6 { _ = try await processor.measure(f.wave("\(n).wav")) }
        let db = try SQLiteConnection(url: config.url, maximumBytes: config.maximumBytes)
        #expect(try db.query("SELECT COUNT(*) FROM measurements").first?.first?.integer ?? 99 <= 2)
        #expect((try config.url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= config.maximumBytes)
        try db.execute("UPDATE measurements SET used=0")
        let reopened = AudioPreprocessor(cache: config)
        _ = try await reopened.measure(f.root.appendingPathComponent("5.wav"))
        #expect(await reopened.statistics().peakScans == 1)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_CACHE_PROCESS"] != nil))
    func cacheSurvivesProcessRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["LCMP_CACHE_PROCESS_ROOT"]))
        let config = MeasurementCacheConfiguration(url: root.appendingPathComponent("process-cache/measurements.sqlite"))
        let processor = AudioPreprocessor(cache: config)
        _ = try await processor.measureLevels(root.appendingPathComponent("short.wav"), profile: profile())
        let stats = await processor.statistics()
        #expect(stats.levelScans == (env["LCMP_CACHE_PROCESS"] == "seed" ? 1 : 0))
        #expect(stats.cacheHits == (env["LCMP_CACHE_PROCESS"] == "seed" ? 0 : 1))
        print("PROCESS_CACHE \(env["LCMP_CACHE_PROCESS"]!) scans=\(stats.levelScans) hits=\(stats.cacheHits)")
    }
}
