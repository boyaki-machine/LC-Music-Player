import AVFAudio
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
            program: MeasurementProgramIdentity(applicationVersion: "test", build: "1", executableDigest: "test-binary-1", environment: "test"))
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
    @Test func incompatibleProgramAlgorithmConversionAndOutputMiss() async throws {
        let f = try CacheFixture(); defer { f.cleanup() }; let url = try f.wave()
        _ = try await AudioPreprocessor(cache: f.configuration).measureLevels(url, profile: profile())
        for version in 0..<4 {
            var config = f.configuration
            if version == 0 { config.program = .init(applicationVersion: "test", build: "2", executableDigest: "test-binary-2", environment: "test") }
            if version == 1 { config.algorithmVersion = 2 }
            if version == 2 { config.conversionVersion = 2 }
            let processor = AudioPreprocessor(cache: config)
            _ = try await processor.measureLevels(url, profile: profile(version == 3 ? 44100 : 48000, version == 3 ? 1 : 2))
            #expect(await processor.statistics().levelScans == 1)
        }
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
        var unavailable = f.configuration; unavailable = .init(url: url.appendingPathComponent("blocked.sqlite"), program: unavailable.program)
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
