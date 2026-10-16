import AppKit
import AVFAudio
import Foundation
import SwiftUI
import Testing
import PlaybackCore
@testable import PlayerUI

@Suite(.serialized) @MainActor struct VisualizationIntegrationTests {
    @Test func hidingStopsVisualizationWithoutWaitingForHostingViewUpdates() {
        let presentation = PlayerPresentation()
        presentation.visualizationDriver.synchronize(activity: .playing, visible: true)
        #expect(presentation.visualizationDriver.isRunning)
        presentation.visualizationVisible = false
        #expect(!presentation.visualizationDriver.isRunning)
        #expect(presentation.visualizationDriver.presentation.pendingCount == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func realPCMDrivesNativePlayerAndLifecycleClearsOldDisplay() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-led-ui-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let data = try #require(buffer.floatChannelData)
        for i in 0..<48000 {
            data[0][i] = Float(0.1 * sin(2 * .pi * 440 * Double(i) / 48000))
            data[1][i] = Float(0.1 * sin(2 * .pi * 2000 * Double(i) / 48000))
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<5 { try file.write(from: buffer) }
        }
        let playback = PlaybackController(), presentation = PlayerPresentation()
        let driver = presentation.visualizationDriver
        // Output presentation includes device latency; a fixed 180/350ms sleep can
        // finish while valid frames are still waiting for their presentation time.
        func waitForLitFrame() async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while driver.snapshot.counts.allSatisfy({ $0 == 0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { presentation.visualizationVisible = false; playback.close() }
        playback.setVolume(0)
        let host = NSHostingView(rootView: PlayerView(playback: playback, presentation: presentation,
            chooseFile: {}, toggleExtension: { presentation.toggleExtension() }))
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 210)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "LCMP 可視化検証"
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        playback.select(url); playback.togglePlayPause()
        try await waitForLitFrame()
        host.layoutSubtreeIfNeeded()
        #expect(playback.analysisConfiguration?.bandCount == 16)
        #expect(playback.analysisFrame != nil && driver.snapshot.counts.contains(where: { $0 > 0 }))
        #expect(driver.presentation.adoptionCount > 0)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("real-pcm-player.png"))
        }
        playback.togglePlayPause()
        try await Task.sleep(for: .milliseconds(80))
        let frozen = driver.snapshot.counts
        #expect(driver.activity == .paused && frozen.contains(where: { $0 > 0 }))
        #expect(driver.presentation.pendingCount == 0)
        // OFF cells can still have their documented 200ms tail at pause time.
        // The clock stops after that tail drains, while lit cells stay frozen.
        try await Task.sleep(for: .milliseconds(220))
        #expect(!driver.isRunning && driver.snapshot.counts == frozen)
        playback.seek(to: 1)
        try await Task.sleep(for: .milliseconds(60))
        #expect(driver.snapshot.counts.allSatisfy { $0 == 0 })
        playback.togglePlayPause()
        try await waitForLitFrame()
        #expect(driver.snapshot.counts.contains(where: { $0 > 0 }))
        presentation.visualizationVisible = false
        #expect(!driver.isRunning)
        try await Task.sleep(for: .milliseconds(60))
        #expect(playback.analysisConfiguration == nil && playback.state == .playing)
        presentation.visualizationVisible = true
        try await waitForLitFrame()
        #expect(playback.state == .playing && driver.snapshot.counts.contains(where: { $0 > 0 }))
        playback.stop()
        try await Task.sleep(for: .milliseconds(80))
        #expect(driver.snapshot.counts.allSatisfy { $0 == 0 } && !driver.isRunning)
        playback.togglePlayPause()
        try await Task.sleep(for: .milliseconds(150))
        playback.seek(to: playback.duration - 0.1)
        try await Task.sleep(for: .milliseconds(500))
        #expect(playback.state == .finished && driver.snapshot.counts.allSatisfy { $0 == 0 } && !driver.isRunning)
    }
}
