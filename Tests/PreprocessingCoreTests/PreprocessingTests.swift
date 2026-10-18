import AVFAudio
import Foundation
import Testing
@testable import PreprocessingCore

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PlaybackCoreTests/Fixtures/\(name)")
}
private func bytes(_ decoder: any PCMDecoding, chunk: UInt32 = 1237) throws -> [Data] {
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: chunk))
    var result = Array(repeating: Data(), count: decoder.processingFormat.isInterleaved ? 1 : Int(decoder.processingFormat.channelCount))
    repeat {
        do { try decoder.decode(into: buffer, length: chunk) }
        catch { print("decode failed position=\(decoder.position) length=\(decoder.length) format=\(decoder.processingFormat): \(error)"); throw error }
        if decoder.position < decoder.length { #expect(buffer.frameLength == chunk) }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for i in list.indices {
            if let ptr = list[i].mData {
                result[i].append(ptr.assumingMemoryBound(to: UInt8.self), count: Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame))
            }
        }
    } while buffer.frameLength != 0
    return result
}
private func wave(_ samples: [[Float]], rate: Double = 48000) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-preprocess-\(UUID()).wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: UInt32(samples.count)))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(samples[0].count)))
    buffer.frameLength = buffer.frameCapacity
    for ch in samples.indices { for n in samples[ch].indices { buffer.floatChannelData![ch][n] = samples[ch][n] } }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

@Suite(.serialized) struct PreprocessingTests {
    @Test(arguments: ["tone.wav", "tone.aiff", "tone-aac.m4a", "tone-alac.m4a", "tone.mp3", "tone.flac", "tone-96k-24bit.wav", "tone-96k-24bit.flac"])
    func prefixContinuesWithoutChangingAnyPCM(_ filename: String) async throws {
        let url = fixture(filename), original = try Data(contentsOf: fixture(filename))
        let baseline = try AudioDecoderFactory.open(url)
        defer { try? baseline.close() }
        let expected = try bytes(baseline)
        print("Baseline completed: \(filename)")
        let prepared = try await AudioPreprocessor.shared.prepare(url, seconds: 0.013, byteLimit: 8192)
        #expect(prepared.bufferedBytes <= 8192 && prepared.bufferedFrames > 0)
        let decoder = try prepared.takeDecoder()
        defer { try? decoder.close() }
        #expect(decoder.position == 0)
        #expect(try bytes(decoder) == expected)
        #expect(decoder.position > 0)
        #expect(try Data(contentsOf: url) == original)
        #expect(throws: (any Error).self) { try prepared.takeDecoder() }
        let peak = try await AudioPreprocessor.shared.measure(url)
        #expect(peak.frameCount == decoder.position)
        #expect(peak.samplePeak > 0 && peak.samplePeak < 0.2)
        #expect(peak.channelCount == (filename.contains("96k") ? 2 : 1))
    }
    @Test func seekInsideAndBeyondPrefixUsesCorrectPosition() async throws {
        let url = try wave([Array(repeating: 0.1, count: 20000) + Array(repeating: 0.7, count: 20000)])
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await AudioPreprocessor.shared.prepare(url, seconds: 0.1)
        let decoder = try prepared.takeDecoder(); defer { try? decoder.close() }
        for frame: Int64 in [123, 25000, 0, 39999] {
            try decoder.seek(to: frame)
            let reference = try AudioDecoderFactory.open(url); defer { try? reference.close() }
            try reference.seek(to: frame)
            #expect(decoder.position == frame)
            #expect(try bytes(decoder) == bytes(reference))
        }
    }
    @Test(arguments: ["tone.wav", "tone.flac", "tone.mp3", "tone-aac.m4a", "tone-alac.m4a"])
    func seekWithinCompletelyCachedShortTrack(_ name: String) async throws {
        let url = fixture(name)
        let prepared = try await AudioPreprocessor.shared.prepare(url)
        let decoder = try prepared.takeDecoder(); defer { try? decoder.close() }
        try decoder.seek(to: 100)
        #expect(decoder.position == 100)
        let remainder = try bytes(decoder)
        #expect(!remainder[0].isEmpty)
    }

    @Test func wholeTrackPeakIncludesLastChannelLastFrameAndSilence() async throws {
        var left = Array(repeating: Float(0.125), count: 19001)
        var right = Array(repeating: Float(-0.25), count: 19001)
        right[right.count - 1] = -0.875
        left[0] = 0.5
        let url = try wave([left, right]); defer { try? FileManager.default.removeItem(at: url) }
        let result = try await AudioPreprocessor.shared.measure(url)
        #expect(result.samplePeak == 0.875 && result.frameCount == 19001)
        #expect(abs(result.peakDBFS - 20 * log10(0.875)) < 1e-9)
        let silent = try wave([Array(repeating: 0, count: 9)]); defer { try? FileManager.default.removeItem(at: silent) }
        let silence = try await AudioPreprocessor.shared.measure(silent)
        #expect(silence.samplePeak == 0 && silence.peakDBFS == -.infinity)
    }
    @Test func sourceMutationAndCancellationInvalidateResults() async throws {
        let url = try wave([Array(repeating: 0.1, count: 16000)])
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await AudioPreprocessor.shared.prepare(url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 90)], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try prepared.takeDecoder() }
        let token = PreparationCancellation(); token.cancel()
        do { _ = try await AudioPreprocessor.shared.prepare(url, cancellation: token); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        do { _ = try await AudioPreprocessor.shared.measure(url, cancellation: token); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }
    @Test func invalidInputsNeverProduceCompletedResults() async throws {
        for name in ["broken.wav", "absent.wav"] {
            do { _ = try await AudioPreprocessor.shared.prepare(fixture(name)); Issue.record("Expected failure") } catch {}
            do { _ = try await AudioPreprocessor.shared.measure(fixture(name)); Issue.record("Expected failure") } catch {}
        }
        let url = try wave([[.nan, 0, 1]])
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await AudioPreprocessor.shared.measure(url); Issue.record("Expected invalid sample failure") } catch {}
        for seconds in [0.0, -1, .infinity, .nan, 3] {
            do { _ = try await AudioPreprocessor.shared.prepare(fixture("tone.wav"), seconds: seconds); Issue.record("Expected invalid limit failure") } catch {}
        }
    }
    @Test func cancelledInFlightScanAndInt32Precision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-int32-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for channel in 0..<2 { for frame in 0..<48000 { buffer.int32ChannelData![channel][frame] = 0 } }
        buffer.int32ChannelData![1][47999] = .max
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt32, interleaved: false)
             for _ in 0..<20 { try file.write(from: buffer) } }
        let result = try await AudioPreprocessor.shared.measure(url)
        // Decoders return Float32, so 32-bit integer PCM keeps 24 bits of precision.
        #expect(abs(result.samplePeak - Double(Int32.max) / 2147483648) <= 0x1p-24, "Measured peak \(result.samplePeak)")
        let token = PreparationCancellation()
        let task = Task { try await AudioPreprocessor.shared.measure(url, cancellation: token) }
        try await Task.sleep(for: .milliseconds(1)); token.cancel()
        do { _ = try await task.value; Issue.record("Expected interrupted scan") }
        catch { #expect(error is CancellationError) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_PREPROCESS_PROFILE"] == "1"))
    func startupPreparationProfile() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["LCMP_PREPROCESS_FIXTURES"])
        var reports: [[String: Any]] = []
        for name in ["tone.wav", "tone.flac", "tone.mp3"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            for run in 0..<6 {
                let begin = ContinuousClock.now
                for _ in 0..<2 { let decoder = try AudioDecoderFactory.open(url); try decoder.close() }
                let original = seconds(begin.duration(to: .now))
                let preparationStart = ContinuousClock.now
                let prepared = try await AudioPreprocessor.shared.prepare(url)
                let preparation = seconds(preparationStart.duration(to: .now))
                let handoffStart = ContinuousClock.now
                let decoder = try prepared.takeDecoder()
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096))
                try decoder.decode(into: buffer, length: 4096)
                let handoff = seconds(handoffStart.duration(to: .now))
                try decoder.close()
                #expect(buffer.frameLength > 0)
                reports.append(["file": name, "run": run, "twoOpensSeconds": original, "preparationSeconds": preparation,
                                "handoffAndFirstPCMSeconds": handoff, "bufferedBytes": prepared.bufferedBytes])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("startup.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
