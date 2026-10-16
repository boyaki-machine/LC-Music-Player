import AnalysisCore
import AVFAudio
import Foundation
import Testing
@testable import PlaybackCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
@MainActor struct AnalysisLifetimeTests {
    @Test func replacesAnalysisQueuesWhileEngineRenders() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-render-lifetime-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for channel in 0..<2 {
            for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = sin(Float(frame) * 2 * .pi * 1000 / 48000) * 0.05 }
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings)
             for _ in 0..<6 { try file.write(from: buffer) } }
        let controller = PlaybackController(); defer { controller.close() }
        controller.setVolume(0); controller.select(url); controller.togglePlayPause()
        let configuration = try AnalysisConfiguration(bandCount: 16, framesPerSecond: 30)
        for _ in 0..<200 {
            controller.configureAnalysis(nil)
            try await Task.sleep(for: .milliseconds(1))
            controller.configureAnalysis(configuration)
            try await Task.sleep(for: .milliseconds(2))
            #expect(controller.state == .playing && controller.error == nil)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while controller.analysisFrame == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.analysisFrame != nil)
        controller.stop()
        #expect(controller.analysisFrame == nil && controller.activeFileLease == nil)
    }
}
