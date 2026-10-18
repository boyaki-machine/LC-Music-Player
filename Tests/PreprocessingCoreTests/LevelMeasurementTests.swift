import AVFAudio
import Foundation
import Testing
import AudioProcessingCore
@testable import PreprocessingCore

@Suite(.serialized) struct LevelMeasurementTests {
    @Test(arguments: ["tone.wav", "tone.aiff", "tone-aac.m4a", "tone-alac.m4a", "tone.mp3", "tone.flac", "tone-96k-24bit.wav", "tone-96k-24bit.flac"])
    func allFormatsAreMeasuredToEOFWithoutChangingSource(_ name: String) async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackCoreTests/Fixtures/\(name)")
        let data = try Data(contentsOf: url)
        let result = try await AudioPreprocessor.shared.measureLevels(url, profile: MeasurementProfile(sampleRate: 48000, channels: 2))
        #expect(result.sourceFrameCount > 0 && result.levels.frameCount > 0)
        #expect(result.levels.samplePeak > 0 && result.levels.truePeak >= result.levels.samplePeak)
        #expect(result.profile.channels == 2)
        #expect(result.levels.loudness == .tooShort) // fixtures are 0.25 seconds
        let prepared = try await AudioPreprocessor.shared.prepare(url)
        let decoder = try ProfileDecoder(base: prepared.takeDecoder(), profile: result.profile, frameLength: result.levels.frameCount)
        defer { try? decoder.close() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: result.profile.format, frameCapacity: 1237))
        var frames: UInt64 = 0
        repeat {
            try decoder.decode(into: buffer, length: 1237)
            frames += UInt64(buffer.frameLength)
            if frames < result.levels.frameCount { #expect(buffer.frameLength == 1237) }
        } while buffer.frameLength > 0
        #expect(frames == result.levels.frameCount)
        try decoder.seek(to: Int64(frames/2))
        try decoder.decode(into: buffer, length: 1237)
        #expect(buffer.frameLength > 0)
        #expect(try Data(contentsOf: url) == data)
    }
    /// Reference values were measured with the previous MP3 decoder (mpg123). The accepted
    /// tolerance for a decoder change is ±0.05 LU and ±0.1 dB.
    @Test(arguments: [("gapless-vbr-44k-stereo.mp3", -14.463, -3.386, -3.456), ("gapless-cbr-48k-mono.mp3", -15.199, -4.139, -4.320)])
    func mp3MeasurementStaysWithinTolerance(_ reference: (String, Double, Double, Double)) async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackCoreTests/Fixtures/\(reference.0)")
        let result = try await AudioPreprocessor.shared.measureLevels(url, profile: MeasurementProfile(sampleRate: 48000, channels: 2))
        let loudness = try #require(result.levels.loudness.value)
        #expect(abs(loudness - reference.1) <= 0.05)
        #expect(abs(result.levels.truePeakDBTP - reference.2) <= 0.1)
        #expect(abs(result.sourcePeak.peakDBFS - reference.3) <= 0.1)
    }
    @Test func fullTrackMeasurementCancelsAndInvalidatesSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-level-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = buffer.frameCapacity
        for n in 0..<48000 { buffer.floatChannelData![0][n] = Float(sin(Double(n)*2 * .pi * 1000/48000)*0.1) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<30 { try file.write(from: buffer) }
        }
        let cancellation = PreparationCancellation()
        let profile = try MeasurementProfile(sampleRate: 48000, channels: 2)
        let scan = Task { try await AudioPreprocessor.shared.measureLevels(url, profile: profile, cancellation: cancellation) }
        try await Task.sleep(for: .milliseconds(10)); cancellation.cancel()
        do { _ = try await scan.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        let metrics = try await AudioPreprocessor.shared.measureLevels(url, profile: profile)
        #expect(abs(try #require(metrics.levels.loudness.value) + 20) < 0.1) // mono duplicated to stereo
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 90)], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try metrics.source.validate() }
    }
}
