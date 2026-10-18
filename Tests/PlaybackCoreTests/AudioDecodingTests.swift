import AVFAudio
import Foundation
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
        let backend = try AudioEngineBackend(url: url)
        #expect(backend.duration > 0.2)
        #expect(backend.currentTime == 0)
    }

    /// Lossless containers decode to exactly the PCM they were made from.
    @Test(arguments: [("tone.aiff", "tone.wav"), ("tone-alac.m4a", "tone.wav"), ("tone.flac", "tone.wav"),
                      ("tone-96k-24bit.flac", "tone-96k-24bit.wav")])
    func losslessFormatsMatchTheirSourcePCM(_ pair: (String, String)) throws {
        let decoded = try AudioDecoderFactory.open(Self.fixture(pair.0))
        defer { try? decoded.close() }
        let reference = try AudioDecoderFactory.open(Self.fixture(pair.1))
        defer { try? reference.close() }
        #expect(decoded.length == reference.length)
        #expect(try Self.samples(decoded) == Self.samples(reference))
    }

    /// Very short PCM files (an eofErr case of the previous decoder) keep every frame.
    @Test(arguments: ["wav", "aiff"], [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32])
    func shortPCMFilesKeepEveryFrame(_ fileExtension: String, common: AVAudioCommonFormat) throws {
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
        let decoder = try AudioDecoderFactory.open(url)
        defer { try? decoder.close() }
        #expect(decoder.length == 9)
        let expected = (0..<9).map { Double($0) / 16 } + Array(repeating: -0.5, count: 9)
        #expect(try Self.samples(decoder) == expected)
    }

    @Test func renamedContentDoesNotReachAnotherParser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (source, renamed) in [("tone.flac", "tone.wav"), ("tone.mp3", "tone.flac"), ("tone-aac.m4a", "tone.mp3"), ("tone.wav", "tone.m4a")] {
            let url = directory.appendingPathComponent(renamed)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: Self.fixture(source), to: url)
            #expect(throws: (any Error).self, "\(source) as \(renamed)") { try AudioDecoderFactory.open(url) }
        }
        #expect(throws: (any Error).self) { try AudioDecoderFactory.open(directory.appendingPathComponent("tone.ogg")) }
    }

    /// LAME/Xing headers carry the encoder delay and padding: the decoded track has exactly
    /// the original frame count and starts on the original first sample (no gap between tracks).
    @Test(arguments: ["gapless-vbr-44k-stereo", "gapless-cbr-48k-mono"])
    func mp3EncoderDelayAndPaddingAreRemoved(_ name: String) throws {
        let mp3 = try AudioDecoderFactory.open(Self.fixture(name + ".mp3"))
        defer { try? mp3.close() }
        let original = try AudioDecoderFactory.open(Self.fixture(name + ".wav"))
        defer { try? original.close() }
        #expect(mp3.length == original.length)
        let channels = Int(original.processingFormat.channelCount), frames = Int(original.length)
        let decoded = try Self.samples(mp3), reference = try Self.samples(original)
        #expect(decoded.count == reference.count)
        // The squared error near the start is smallest without a shift. A remaining decoder (529)
        // or encoder (576) delay would move the minimum; ±1 frame confirms the exact start.
        func error(lag: Int) -> Double {
            let window = frames / 15
            return (0..<channels).reduce(0) { sum, channel in
                sum + (1000..<(1000 + window)).reduce(0) { total, frame in
                    let difference = decoded[channel * frames + frame + lag] - reference[channel * frames + frame]
                    return total + difference * difference
                }
            }
        }
        let aligned = error(lag: 0)
        for lag in [-576, -529, -1, 1, 529, 576] { #expect(aligned * 2 < error(lag: lag), "lag \(lag)") }
    }

    /// Seeking returns the same PCM as decoding from the start, including in VBR files.
    @Test(arguments: ["gapless-vbr-44k-stereo.mp3", "gapless-cbr-48k-mono.mp3", "tone.flac", "tone-96k-24bit.flac",
                      "tone-aac.m4a", "tone-alac.m4a", "tone.wav"])
    func seekingMatchesSequentialDecoding(_ name: String) throws {
        let full = try AudioDecoderFactory.open(Self.fixture(name))
        defer { try? full.close() }
        let channels = Int(full.processingFormat.channelCount), frames = Int(full.length)
        let all = try Self.samples(full)
        for position in [frames / 7, frames / 2, frames * 5 / 6] {
            let decoder = try AudioDecoderFactory.open(Self.fixture(name))
            defer { try? decoder.close() }
            try decoder.seek(to: AVAudioFramePosition(position))
            #expect(decoder.position == AVAudioFramePosition(position))
            let count = min(1024, frames - position)
            let read = try Self.samples(decoder, maximumFrames: count)
            for channel in 0..<channels {
                let expected = Array(all[(channel * frames + position)..<(channel * frames + position + count)])
                #expect(Array(read[(channel * count)..<((channel + 1) * count)]) == expected, "\(name) at \(position)")
            }
        }
    }

    private static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    /// PCM as Float64, channel after channel. Exact for every integer and Float32 source format.
    private static func samples(_ decoder: any PCMDecoding, maximumFrames: Int = .max) throws -> [Double] {
        let input = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(min(4096, maximumFrames))))
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: input.format.sampleRate,
                                                channels: input.format.channelCount, interleaved: false))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        let converter = try #require(AVAudioConverter(from: input.format, to: format))
        var channels = Array(repeating: [Double](), count: Int(format.channelCount))
        while channels[0].count < maximumFrames {
            try decoder.decode(into: input, length: AVAudioFrameCount(min(Int(input.frameCapacity), maximumFrames - channels[0].count)))
            if input.frameLength == 0 { break }
            try converter.convert(to: output, from: input)
            let list = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            for (index, buffer) in list.enumerated() {
                let values = try #require(buffer.mData).assumingMemoryBound(to: Double.self)
                channels[index].append(contentsOf: UnsafeBufferPointer(start: values, count: Int(output.frameLength)))
            }
        }
        return channels.flatMap { $0 }
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
