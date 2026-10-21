import AVFAudio
import Foundation
import Testing
import AudioProcessingCore
@testable import PlaybackCore

/// A volume change while audio flows must not step the waveform: a step is heard as a click.
/// Offline rendering through the playback graph, so no output device is needed.
@Suite @MainActor struct VolumeChangeTests {
    private static let rate = 48000.0
    /// One period of the 1kHz test tone.
    private static let period = 48

    @Test func appVolumeChangeRampsInsteadOfStepping() throws {
        let envelope = try render(changeAt: 24000) { $0.setVolume(0.1) }
        let before = envelope[24000 / Self.period - 2], after = envelope.last!
        #expect(abs(before - 0.5) < 0.01 && abs(after - 0.05) < 0.01)
        // A step would change the envelope by 0.45 within one period; the ramp spreads it over
        // many. The largest change per period stays a small part of the whole.
        let largest = zip(envelope, envelope.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(largest < 0.1, "largest change in one period \(largest)")
        let moving = zip(envelope, envelope.dropFirst()).filter { abs($1 - $0) > 0.001 }.count
        #expect(moving >= 5, "the change spread over \(moving) periods")
    }

    @Test func levelGainIsInPlaceFromTheFirstSample() throws {
        // -6dB from the plan: the gain stage is set when the graph is built, before audio flows.
        let metrics = AudioLevelMetrics(loudness: .measured(-17), samplePeak: 0.5, truePeak: 0.5, frameCount: 48000, blockCount: 10)
        let plan = try NormalizationPlan(metrics: metrics, profile: MeasurementProfile(sampleRate: Self.rate, channels: 2))
        #expect(abs(plan.gainDB + 6) < 1e-9)
        let envelope = try render(plan: plan)
        let expected = Float(0.5 * plan.linearGain)
        #expect(envelope.allSatisfy { abs($0 - expected) < 0.005 }, "\(envelope.prefix(4))")
    }

    /// Renders one second of a 0.5 peak 1kHz tone at app volume 1 and returns its peak per period.
    private func render(plan: NormalizationPlan? = nil, changeAt: Int? = nil,
                        change: (PlaybackGraph) -> Void = { _ in }) throws -> [Float] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let frames = Int(Self.rate)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        input.frameLength = input.frameCapacity
        for channel in 0..<2 { for n in 0..<frames {
            input.floatChannelData![channel][n] = Float(0.5 * sin(2 * .pi * 1000 * Double(n) / Self.rate))
        } }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let graph = PlaybackGraph(engine: engine, player: player, sourceFormat: format, observationFormat: format, plan: plan)
        graph.setVolume(1)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        player.scheduleBuffer(input)
        try engine.start(); defer { engine.stop() }
        player.play()
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var samples: [Float] = []
        var changed = false
        while samples.count < frames {
            if let changeAt, !changed, samples.count >= changeAt { change(graph); changed = true }
            #expect(try engine.renderOffline(512, to: chunk) == .success)
            samples += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
        }
        return stride(from: 0, to: frames - Self.period, by: Self.period).map { start in
            samples[start..<(start + Self.period)].map(abs).max()!
        }
    }
}
