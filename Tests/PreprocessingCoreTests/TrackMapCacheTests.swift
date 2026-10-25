import AVFAudio
import CryptoKit
import Foundation
import Testing
import AudioProcessingCore
@testable import PreprocessingCore

/// A stand-in detector: another algorithm whose maps are easy to recognise.
private final class CountingDetector: BeatDetecting {
    static let algorithm: UInt16 = 900
    private var frames = 0
    private let rate: Double
    init(sampleRate: Double) throws { rate = sampleRate }
    func consume(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) throws { self.frames += frames }
    func finish() throws -> BeatMap {
        let ms = UInt32(Double(frames) / rate * 1000)
        return BeatMap(algorithm: Self.algorithm, durationMilliseconds: ms, clarity: 1, tempos: [],
                       beats: [.init(milliseconds: 0, strength: 1, isDownbeat: true), .init(milliseconds: ms / 2, strength: 1, isDownbeat: false)])
    }
}

private struct MapFixture {
    let root: URL
    let configuration: MeasurementCacheConfiguration
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-maps-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configuration = MeasurementCacheConfiguration(url: root.appendingPathComponent("cache/measurements.sqlite"),
            platform: MeasurementPlatformIdentity(system: "test"))
    }
    /// A decaying 60Hz kick every half second (120 BPM) from 0.5s, at 44.1kHz stereo.
    func kicks(_ name: String = "kicks.wav", seconds: Int = 12) throws -> URL {
        let url = root.appendingPathComponent(name), rate = 44100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let total = Int(rate) * seconds
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
        buffer.frameLength = AVAudioFrameCount(total)
        for n in 0..<total {
            let t = Double(n) / rate
            let since = t < 0.5 ? -1 : (t - 0.5).truncatingRemainder(dividingBy: 0.5)
            let v = since < 0 ? 0 : Float(0.5 * sin(2 * .pi * 60 * since) * exp(-since * 15))
            buffer.floatChannelData![0][n] = v; buffer.floatChannelData![1][n] = v
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct TrackMapCacheTests {
    private func profile() throws -> MeasurementProfile { try .init(sampleRate: 48000, channels: 2) }

    @Test func levelScanAlsoMapsTheBeats() async throws {
        let f = try MapFixture(); defer { f.cleanup() }
        let url = try f.kicks()
        let processor = AudioPreprocessor(cache: f.configuration)
        _ = try await processor.measureLevels(url, profile: profile())
        let reopened = AudioPreprocessor(cache: f.configuration)
        let map = try await reopened.trackMap(url)
        let stats = await reopened.statistics()
        #expect(stats.mapScans == 0 && stats.cacheHits == 1)
        #expect(map.beats.algorithm == OnsetBeatDetector.algorithm && map.vocals.algorithm == CentreVocalAnalyzer.algorithm)
        let beatsMap = map.beats
        #expect(abs((beatsMap.tempos.first?.bpm ?? 0) - 120) < 1, "\(beatsMap.tempos)")
        #expect(beatsMap.beats.count >= 20)
        #expect(beatsMap.durationMilliseconds == 12_000 && map.vocals.durationMilliseconds == 12_000)
    }

    /// Another detector maps the track again from a scan of its own, and keeps the measured levels.
    @Test func anotherDetectorScansOnlyTheBeats() async throws {
        let f = try MapFixture(); defer { f.cleanup() }
        let url = try f.kicks()
        _ = try await AudioPreprocessor(cache: f.configuration).measureLevels(url, profile: profile())
        var other = f.configuration; other.trackAnalyzers = TrackAnalyzers(beats: BeatDetector(CountingDetector.self))
        let processor = AudioPreprocessor(cache: other)
        let map = try await processor.trackMap(url)
        #expect(map.beats.algorithm == CountingDetector.algorithm && map.beats.durationMilliseconds == 12_000)
        _ = try await processor.measureLevels(url, profile: profile())
        var stats = await processor.statistics()
        #expect(stats.mapScans == 1 && stats.levelScans == 0)
        // Both maps stay: neither detector's record removes the other's.
        let again = AudioPreprocessor(cache: other)
        #expect(try await again.trackMap(url) == map)
        let standard = AudioPreprocessor(cache: f.configuration)
        #expect(try await standard.trackMap(url).beats.algorithm == OnsetBeatDetector.algorithm)
        stats = await standard.statistics()
        #expect(stats.mapScans == 0)
        #expect(await again.statistics().mapScans == 0)
    }

    @Test func beatRequestJoinsARunningLevelScan() async throws {
        let f = try MapFixture(); defer { f.cleanup() }
        let url = try f.kicks(seconds: 60)
        let processor = AudioPreprocessor(cache: f.configuration)
        async let levels = processor.measureLevels(url, profile: profile())
        try await Task.sleep(for: .milliseconds(20))
        async let beats = processor.trackMap(url)
        let (l, b) = try await (levels, beats)
        #expect(l.sourceFrameCount == 44100 * 60)
        #expect(b.beats.beats.count > 100)
        let stats = await processor.statistics()
        #expect(stats.levelScans == 1 && stats.mapScans == 0 && stats.coalescedRequests == 1)
    }

    /// The beat request alone keeps the joined scan going when the level request is cancelled.
    @Test func cancelledLevelRequestKeepsTheJoinedBeats() async throws {
        let f = try MapFixture(); defer { f.cleanup() }
        let url = try f.kicks(seconds: 60)
        let processor = AudioPreprocessor(cache: f.configuration), token = PreparationCancellation()
        let levels = Task { try await processor.measureLevels(url, profile: profile(), cancellation: token) }
        try await Task.sleep(for: .milliseconds(20))
        let beats = Task { try await processor.trackMap(url) }
        try await Task.sleep(for: .milliseconds(20))
        token.cancel()
        await #expect(throws: CancellationError.self) { try await levels.value }
        #expect(try await beats.value.beats.beats.count > 100)
        #expect(try await AudioPreprocessor(cache: f.configuration).trackMap(url).beats.beats.count > 100)
    }

    @Test func withoutCacheEveryRequestScans() async throws {
        let f = try MapFixture(); defer { f.cleanup() }
        let url = try f.kicks(seconds: 6)
        let processor = AudioPreprocessor()
        let first = try await processor.trackMap(url)
        let second = try await processor.trackMap(url)
        #expect(first == second)
        #expect(await processor.statistics().mapScans == 2)
        let token = PreparationCancellation(); token.cancel()
        await #expect(throws: CancellationError.self) { try await processor.trackMap(url, cancellation: token) }
    }

    /// A damaged record is a miss; the beats are found again.
    @Test func damagedRecordScansAgain() async throws {
        let f = try MapFixture(); defer { f.cleanup() }
        let url = try f.kicks(seconds: 6)
        let map = try await AudioPreprocessor(cache: f.configuration).trackMap(url)
        let cache = MeasurementCache(f.configuration)
        let request = try #require(try cache.mapRequest(url))
        let db = try SQLiteConnection(url: f.configuration.url, maximumBytes: f.configuration.maximumBytes)
        let broken = Data("LCTM".utf8) + Data([1, 1])
        try db.execute("UPDATE measurements SET payload=?, checksum=? WHERE key=?",
                       [.blob(broken), .blob(Data(SHA256.hash(data: broken))), .blob(request.key)])
        let reopened = AudioPreprocessor(cache: f.configuration)
        #expect(try await reopened.trackMap(url) == map)
        #expect(await reopened.statistics().mapScans == 1)
    }
}
