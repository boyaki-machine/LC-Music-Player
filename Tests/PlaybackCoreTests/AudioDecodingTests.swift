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
