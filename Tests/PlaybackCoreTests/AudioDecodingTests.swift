import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import PlaybackCore

@Suite @MainActor
struct AudioDecodingTests {
    @Test(arguments: ["tone.wav", "tone.aiff", "tone-aac.m4a", "tone-alac.m4a", "tone.mp3",
                      "tone.flac", "tone-96k-24bit.wav", "tone-96k-24bit.flac"])
    func decodesOriginalFixtures(_ filename: String) throws {
        let url = try #require(Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures"))
        let before = try Data(contentsOf: url)
        let lease = try LocalFileAccess().acquire(url)
        defer { withExtendedLifetime(lease) {} }
        let decoder = try AudioDecoderFactory.open(url)
        defer { try? decoder.close() }
        let format = decoder.processingFormat
        #expect(format.sampleRate == (filename.contains("96k") ? 96000 : 44100))
        #expect(format.channelCount == (filename.contains("96k") ? 2 : 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        try decoder.decode(into: buffer, length: 4096)
        #expect(buffer.frameLength > 0)
        // Opening and decoding through the app must not modify the source.
        #expect(try Data(contentsOf: url) == before)
        let backend = try SFBAudioBackend(url: url)
        #expect(backend.duration > 0.2)
        #expect(backend.currentTime == 0)
    }

    /// Pinning decoders must not change the PCM that SFBAudioEngine's content
    /// detection produced before, including the libsndfile → Core Audio switch.
    @Test(arguments: ["tone.wav", "tone.aiff", "tone-aac.m4a", "tone-alac.m4a", "tone.mp3",
                      "tone.flac", "tone-96k-24bit.wav", "tone-96k-24bit.flac"])
    func pinnedDecoderMatchesDetectedPCM(_ filename: String) throws {
        let url = try #require(Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures"))
        let pinned = try AudioDecoderFactory.open(url)
        defer { try? pinned.close() }
        let detected = try AudioDecoder(url: url)
        // SFBAudioEngine 0.14.0 cannot open some short AAC files with either selection;
        // both paths then use the same AVAudioFile fallback.
        do { try detected.open() } catch where filename.hasSuffix(".m4a") { return }
        defer { try? detected.close() }
        #expect(pinned.length == detected.length)
        #expect(pinned.processingFormat.sampleRate == detected.processingFormat.sampleRate)
        #expect(pinned.processingFormat.channelCount == detected.processingFormat.channelCount)
        let expected = try Self.samples(detected), actual = try Self.samples(pinned)
        #expect(actual.count == expected.count)
        #expect(actual == expected)
    }

    /// Very short PCM files hit SFBAudioEngine's Core Audio eofErr; the fallback must
    /// still return what libsndfile, the previously detected decoder, produced.
    @Test(arguments: ["wav", "aiff"], [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32])
    func shortPCMFilesMatchPreviousDecoder(_ fileExtension: String, common: AVAudioCommonFormat) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("short.\(fileExtension)")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: common == .pcmFormatInt16 ? 16 : 32,
                                       AVLinearPCMIsFloatKey: common == .pcmFormatFloat32,
                                       AVLinearPCMIsBigEndianKey: fileExtension == "aiff", AVLinearPCMIsNonInterleaved: false]
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9))
        buffer.frameLength = 9
        for frame in 0..<9 { buffer.floatChannelData![0][frame] = Float(frame) / 16; buffer.floatChannelData![1][frame] = -0.5 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let previous = try AudioDecoder(url: url, decoderName: .libsndfile)
        try previous.open()
        defer { try? previous.close() }
        let pinned = try AudioDecoderFactory.open(url)
        defer { try? pinned.close() }
        #expect(pinned.length == previous.length)
        #expect(try Self.samples(pinned) == Self.samples(previous))
    }

    @Test func renamedContentDoesNotReachAnotherParser() throws {
        let flac = try #require(Bundle.module.url(forResource: "tone.flac", withExtension: nil, subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renamed = directory.appendingPathComponent("tone.wav")
        try FileManager.default.copyItem(at: flac, to: renamed)
        // Content detection routes this ".wav" to libFLAC; pinning keeps it on Core Audio.
        let detected = try AudioDecoder(url: renamed)
        #expect(Self.className(detected) == "SFBFLACDecoder")
        if let pinned = try? AudioDecoderFactory.open(renamed) {
            defer { try? pinned.close() }
            #expect(Self.className(pinned) == "SFBCoreAudioDecoder")
        }
        #expect(throws: (any Error).self) { try AudioDecoderFactory.open(directory.appendingPathComponent("tone.ogg")) }
    }

    private static func className(_ decoder: AnyObject) -> String { String(cString: object_getClassName(decoder)) }

    /// Full-track PCM as Float64, exact for every integer and Float32 source format.
    private static func samples(_ decoder: any PCMDecoding) throws -> [Double] {
        let input = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096))
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: input.format.sampleRate,
                                                channels: input.format.channelCount, interleaved: false))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        let converter = try #require(AVAudioConverter(from: input.format, to: format))
        var result: [Double] = []
        while true {
            try decoder.decode(into: input, length: input.frameCapacity)
            if input.frameLength == 0 { return result }
            try converter.convert(to: output, from: input)
            let list = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            for buffer in list {
                let values = try #require(buffer.mData).assumingMemoryBound(to: Double.self)
                result.append(contentsOf: UnsafeBufferPointer(start: values, count: Int(output.frameLength)))
            }
        }
    }

    @Test func corruptAudioIsARecoverableLoadingError() throws {
        let url = try #require(Bundle.module.url(forResource: "broken.wav", withExtension: nil, subdirectory: "Fixtures"))
        let controller = PlaybackController()
        controller.select(url)
        #expect(controller.state == .empty)
        #expect(!controller.canPlay)
        guard case .loadingFailed = controller.error else {
            Issue.record("Expected a loading failure for corrupt audio")
            return
        }
    }
}
