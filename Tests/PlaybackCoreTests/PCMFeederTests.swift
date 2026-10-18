import AVFAudio
import Foundation
import Testing
@testable import PlaybackCore

/// Offline rendering checks the feeder without an output device.
@Suite struct PCMFeederTests {
    @Test(arguments: ["gapless-vbr-44k-stereo.mp3", "tone-96k-24bit.flac", "gapless-vbr-44k-stereo.wav"])
    func everyFrameIsPlayedOnceInOrderAndTheEndIsReported(_ name: String) async throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        let reference = try AudioDecoderFactory.open(url)
        defer { try? reference.close() }
        let format = reference.processingFormat, frames = AVAudioFrameCount(reference.length)
        let expected = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        try reference.decode(into: expected, length: frames)

        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let ended = Signal()
        let feeder = PCMFeeder(decoder: try AudioDecoderFactory.open(url), player: player, endCallback: .dataRendered,
                               finished: { ended.set() }, failed: { Issue.record($0) })
        defer { feeder.cancel(); player.stop(); engine.stop(); feeder.close() }
        try feeder.prime()
        try engine.start()
        player.play()

        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames + 4096))
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var total: AVAudioFramePosition = 0
        while total < AVAudioFramePosition(frames) {
            let count = min(4096, AVAudioFramePosition(frames) - total)
            // Refills are asynchronous; render only frames that are already scheduled.
            let deadline = ContinuousClock.now + .seconds(5)
            while feeder.scheduledFrames < total + count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(!ended.value)
            #expect(try engine.renderOffline(AVAudioFrameCount(count), to: chunk) == .success)
            for channel in 0..<Int(format.channelCount) {
                memcpy(rendered.floatChannelData![channel].advanced(by: Int(total)), chunk.floatChannelData![channel], Int(chunk.frameLength) * 4)
            }
            total += AVAudioFramePosition(chunk.frameLength)
        }
        #expect(feeder.scheduledFrames == AVAudioFramePosition(frames))
        for channel in 0..<Int(format.channelCount) {
            let a = UnsafeBufferPointer(start: expected.floatChannelData![channel], count: Int(frames))
            let b = UnsafeBufferPointer(start: rendered.floatChannelData![channel], count: Int(frames))
            #expect(Array(a) == Array(b), "\(name) channel \(channel)")
        }
        // The end is reported once the last buffer has been rendered, never before.
        let deadline = ContinuousClock.now + .seconds(5)
        while !ended.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(ended.value)
    }
}

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
