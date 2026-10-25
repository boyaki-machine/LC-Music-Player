// Reads the macOS default output device through Core Audio HAL.
#if os(macOS)
import AVFAudio
import AnalysisCore
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
        var observedAnalysis = false
        var ages: [Double] = []
        var computations: [Double] = []
        var lastSequence: UInt64 = 0
        for _ in 0..<150 {
            if let frame = controller.analysisFrame {
                observedAnalysis = true
                #expect(frame.bandDBFS.count == 32)
                #expect(frame.timing.sampleRate > 0)
                #expect(frame.timing.appliedAudioDelay == 0)
                if frame.sequence != lastSequence {
                    lastSequence = frame.sequence
                    if let center = frame.timing.windowCenterHostTime { ages.append(frame.timing.producedHostTime - center) }
                    computations.append(frame.computationSeconds)
                }
            }
            if controller.state != .playing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.error == nil)
        #expect(controller.state == .finished)
        #expect(observedAnalysis)
        #expect(controller.analysisFrame == nil)
        print("Analysis \(filename): observed=\(computations.count), maxCompute=\(computations.max() ?? 0)s, maxWindowAge=\(ages.max() ?? 0)s")
    }

    /// The end is reported after the whole track has played, not when decoding finishes,
    /// and the reported position runs up to the duration without passing it.
    @Test(arguments: ["gapless-vbr-44k-stereo.mp3", "gapless-cbr-48k-mono.mp3"])
    func finishesAfterTheWholeTrackHasPlayed(_ filename: String) async throws {
        let url = try #require(Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures"))
        let backend = try AudioEngineBackend(url: url)
        defer { backend.stop() }
        backend.volume = 0
        var finishedAt: ContinuousClock.Instant?
        backend.onEvent = { if case .finished = $0 { finishedAt = .now } }
        let started = ContinuousClock.now
        try backend.play()
        var last = 0.0
        while finishedAt == nil, started.duration(to: .now) < .seconds(backend.duration + 3) {
            let time = backend.currentTime
            #expect(time >= last && time <= backend.duration)
            last = time
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = started.duration(to: try #require(finishedAt))
        #expect(elapsed >= .seconds(backend.duration))
        #expect(elapsed < .seconds(backend.duration + 1))
        #expect(last > backend.duration - 0.1)
    }

    /// Frames say where in the track their window is: just behind the rendered position, through
    /// pausing and seeking.
    @Test func analysisFramesCarryTheTrackPosition() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-position-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0.05 * sin(Float(frame) * 2 * .pi * 440 / 44100) }
        do { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
        let controller = PlaybackController()
        defer { controller.close() }
        controller.setVolume(0.05)
        controller.select(url)
        controller.togglePlayPause()
        /// Frames for a while: each position against the rendered position when it arrived.
        func observe(_ seconds: Double) async throws -> [(track: Double, rendered: Double)] {
            var seen: [(Double, Double)] = []
            var last: UInt64?
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                if let frame = controller.analysisFrame, frame.sequence != last {
                    last = frame.sequence
                    seen.append((try #require(frame.trackSeconds), controller.currentTime))
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            return seen
        }
        let playing = try await observe(0.6)
        #expect(playing.count >= 5)
        // The rendered position is read from the player's last render, which can trail the newest
        // rendered buffer the window came from by an I/O buffer or two.
        for (track, rendered) in playing {
            #expect(track <= rendered + 0.05 && rendered - track < 0.3, "track \(track) rendered \(rendered)")
        }
        #expect(zip(playing.dropFirst(), playing).allSatisfy { $0.track > $1.track })
        controller.togglePlayPause()
        let paused = controller.currentTime
        controller.togglePlayPause()
        let resumed = try await observe(0.3)
        #expect(resumed.first.map { $0.track >= paused - 0.1 && $0.track < paused + 0.3 } == true, "\(paused) \(resumed.first.map { $0.track } ?? -1)")
        controller.seek(to: 2.5)
        let sought = try await observe(0.3)
        #expect(sought.first.map { $0.track >= 2.45 && $0.track < 2.8 } == true, "\(sought.first.map { $0.track } ?? -1)")
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
        // Wait for observed progress: a loaded parallel run can delay the MainActor well past a fixed sleep.
        try await waitUntil { controller.currentTime > 0 && controller.analysisFrame != nil }
        #expect(controller.state == .playing)
        #expect(controller.currentTime > 0)
        let firstGeneration = try #require(controller.analysisFrame?.generation)
        controller.togglePlayPause()
        #expect(controller.state == .paused)
        #expect(controller.analysisFrame == nil)
        let paused = controller.currentTime
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(controller.currentTime - paused) < 0.03)
        controller.togglePlayPause()
        try await waitUntil { controller.currentTime > paused && controller.analysisFrame != nil }
        #expect(controller.state == .playing)
        #expect(controller.currentTime > paused)
        #expect(controller.analysisFrame != nil && controller.analysisFrame?.generation != firstGeneration)
        let beforeSeekGeneration = controller.analysisFrame?.generation
        controller.seek(to: 1.2)
        // The position moves to the target at once; checking before any wait keeps this independent of load.
        #expect(controller.currentTime >= 1.2 && controller.currentTime < 1.3)
        try await waitUntil { controller.currentTime > 1.2 && controller.analysisFrame != nil }
        #expect(controller.state == .playing && controller.currentTime >= 1.2)
        #expect(controller.analysisFrame != nil && controller.analysisFrame?.generation != beforeSeekGeneration)
        controller.togglePlayPause()
        controller.seek(to: 0.7)
        #expect(controller.state == .paused)
        #expect(abs(controller.currentTime - 0.7) < 0.001)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(controller.currentTime - 0.7) < 0.001)
        controller.togglePlayPause()
        // Resuming a paused seek starts a new output run. Wait for observed
        // progress rather than assuming every device starts rendering in 100ms.
        let resumeDeadline = ContinuousClock.now + .seconds(2)
        while controller.currentTime <= 0.7, controller.state == .playing, ContinuousClock.now < resumeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.currentTime > 0.7)
        controller.toggleMute()
        #expect(controller.volume == 0)
        controller.toggleMute()
        #expect(controller.volume == 0.1)
        controller.stop()
        #expect(controller.state == .stopped)
        #expect(controller.currentTime == 0)
        #expect(controller.analysisFrame == nil)
        controller.togglePlayPause()
        try await waitUntil(seconds: 10) { controller.state != .playing }
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

    @Test(arguments: ["tone.wav", "tone.aiff", "tone-aac.m4a", "tone-alac.m4a", "tone.mp3",
                      "tone.flac", "tone-96k-24bit.wav", "tone-96k-24bit.flac"])
    func preparedSeekRendersFromPosition(_ filename: String) async throws {
        let url = try #require(Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures"))
        let controller = PlaybackController()
        defer { controller.close() }
        controller.setVolume(0.05)
        controller.select(url)
        #expect(controller.canSeek)
        controller.seek(to: 0.1)
        #expect(controller.state == .ready)
        #expect(abs(controller.currentTime - 0.1) < 0.001)
        controller.togglePlayPause()
        for _ in 0..<150 {
            if controller.state != .playing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.state == .finished)
        #expect(controller.error == nil)
        controller.seek(to: 0.05)
        #expect(controller.state == .stopped)
        #expect(abs(controller.currentTime - 0.05) < 0.001)
    }

    @Test func analysisReconfigurationKeepsPlaybackAndInvalidatesOldFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-analysis-config-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let samples = try #require(buffer.floatChannelData)[0]
        for i in 0..<48000 { samples[i] = Float(0.05 * sin(2 * .pi * 1000 * Double(i) / 48000)) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<10 { try file.write(from: buffer) }
        }
        let controller = PlaybackController()
        defer { controller.close() }
        controller.setVolume(0)
        controller.select(url)
        controller.togglePlayPause()
        let initial = try await analysisFrame(controller, bands: 32)
        let position = controller.currentTime
        controller.configureAnalysis(try AnalysisConfiguration(bandCount: 64, framesPerSecond: 60))
        #expect(controller.analysisFrame == nil)
        let changed = try await analysisFrame(controller, bands: 64)
        #expect(changed.generation != initial.generation)
        #expect(controller.state == .playing && controller.currentTime >= position)
        #expect(changed.leftRMS > 0.01) // observed before app volume, which is zero
        controller.configureAnalysis(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.analysisFrame == nil && controller.state == .playing)
        controller.configureAnalysis(try AnalysisConfiguration(bandCount: 8, framesPerSecond: 15))
        let restored = try await analysisFrame(controller, bands: 8)
        #expect(restored.generation != changed.generation)
        controller.togglePlayPause()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.analysisFrame == nil && controller.state == .paused)
        controller.togglePlayPause()
        let resumed = try await analysisFrame(controller, bands: 8)
        #expect(resumed.generation != restored.generation)
        controller.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.analysisFrame == nil && controller.state == .stopped)
    }

    private func waitUntil(seconds: Double = 2, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func analysisFrame(_ controller: PlaybackController, bands: Int) async throws -> AnalysisFrame {
        for _ in 0..<100 {
            if let frame = controller.analysisFrame, frame.bandDBFS.count == bands { return frame }
            try await Task.sleep(for: .milliseconds(10))
        }
        let frame = try #require(controller.analysisFrame, "Analysis did not arrive within one second")
        #expect(frame.bandDBFS.count == bands)
        return frame
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
#endif
