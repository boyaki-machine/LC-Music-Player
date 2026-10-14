import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import PlaybackCore

/// Opt-in because these tests intentionally send a quiet tone to the current output.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
@MainActor
struct AudioOutputTests {
    @Test(arguments: ["tone.wav", "tone.aiff", "tone-aac.m4a", "tone-alac.m4a", "tone.mp3",
                      "tone.flac", "tone-96k-24bit.wav", "tone-96k-24bit.flac"])
    func rendersToDefaultOutput(_ filename: String) async throws {
        let url = try #require(Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures"))
        let controller = PlaybackController()
        defer { controller.close() }
        controller.setVolume(0.1)
        controller.select(url)
        #expect(controller.error == nil)
        controller.togglePlayPause()
        #expect(controller.state == .playing)
        for _ in 0..<150 {
            if controller.state != .playing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.error == nil)
        #expect(controller.state == .finished)
    }

    @Test func actualPauseResumeStopAndRestartPreserveSystemVolume() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-output-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = 0.05 * sin(Float(frame) * 2 * .pi * 440 / 44100)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let before = systemOutputVolume()
        let controller = PlaybackController()
        defer { controller.close() }
        controller.setVolume(0.1)
        controller.select(url)
        #expect(controller.error == nil)
        controller.togglePlayPause()
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.state == .playing)
        #expect(controller.currentTime > 0)
        controller.togglePlayPause()
        #expect(controller.state == .paused)
        let paused = controller.currentTime
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(controller.currentTime - paused) < 0.03)
        controller.togglePlayPause()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.state == .playing)
        #expect(controller.currentTime > paused)
        controller.stop()
        #expect(controller.state == .stopped)
        #expect(controller.currentTime == 0)
        controller.togglePlayPause()
        for _ in 0..<175 {
            if controller.state != .playing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.error == nil)
        #expect(controller.state == .finished)
        if let before, let after = systemOutputVolume() {
            #expect(before.device == after.device)
            #expect(before.volume == after.volume)
            print("System output volume: unchanged")
        } else {
            print("System output volume: device does not expose a readable scalar; comparison not performed")
        }
    }

    // Read only: the app must never set macOS's device volume.
    private func systemOutputVolume() -> (device: AudioDeviceID, volume: Float32)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            var volume: Float32 = 0
            size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
                return (device, volume)
            }
        }
        return nil
    }
}
