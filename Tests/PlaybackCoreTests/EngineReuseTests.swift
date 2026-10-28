import AVFAudio
import Foundation
import Testing
import AudioProcessingCore
@testable import PlaybackCore

@Suite(.serialized) @MainActor struct EngineReuseTests {
    /// The output profile is read once per output: building an engine to read it costs milliseconds.
    @Test func outputProfileIsReadAgainOnlyWhenTheOutputChanges() throws {
        var reads = 0
        func read() throws -> MeasurementProfile { reads += 1; return try MeasurementProfile(sampleRate: 48000, channels: 2) }
        let speaker = OutputSignature(values: ["speaker", "48000"]), headphones = OutputSignature(values: ["headphones", "48000"])
        _ = try AudioEngineBackend.cachedProfile(for: speaker, read: read)
        _ = try AudioEngineBackend.cachedProfile(for: speaker, read: read)
        #expect(reads == 1)
        _ = try AudioEngineBackend.cachedProfile(for: headphones, read: read)
        _ = try AudioEngineBackend.cachedProfile(for: headphones, read: read)
        #expect(reads == 2)
        _ = try AudioEngineBackend.cachedProfile(for: nil, read: read)
        _ = try AudioEngineBackend.cachedProfile(for: nil, read: read)
        #expect(reads == 4)
        #expect(OutputSignature.current() == OutputSignature.current())
    }

    /// On iOS a route change pauses the track only when the outputs are other devices.
    @Test func onlyOtherOutputDevicesCountAsAnOutputChange() {
        #expect(AudioEngineBackend.outputsChanged(from: ["earphones"], to: ["speaker"]))
        #expect(AudioEngineBackend.outputsChanged(from: ["speaker"], to: ["speaker", "car"]))
        #expect(AudioEngineBackend.outputsChanged(from: ["speaker"], to: []))
        #expect(!AudioEngineBackend.outputsChanged(from: ["left", "right"], to: ["right", "left"]))
        #expect(!AudioEngineBackend.outputsChanged(from: nil, to: ["speaker"]))
    }

    /// The graph renders at the output device's rate, so a source at that rate is never converted.
    @Test func theGraphRendersAtTheDevicesRate() throws {
        let engine = AVAudioEngine()
        let device = engine.outputNode.outputFormat(forBus: 0)
        try #require(device.sampleRate > 0)
        let format = AudioEngineBackend.outputGraphFormat(of: engine)
        #expect(format.sampleRate == device.sampleRate && format.channelCount == min(2, device.channelCount))
        #expect(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate == device.sampleRate)
        let profile = try AudioEngineBackend.measurementProfile()
        #expect(profile.sampleRate == device.sampleRate && profile.channels == format.channelCount)
    }

    /// At the graph's rate, with no level gain and full volume, the samples pass unchanged.
    @Test func aSourceAtTheGraphsRatePassesUnchanged() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)); input.frameLength = 4096
        for channel in 0..<2 { for n in 0..<4096 { input.floatChannelData![channel][n] = Float((n * 7919 + channel * 104729) % 2001 - 1000) / 1250 } }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let graph = PlaybackGraph(engine: engine, player: player, sourceFormat: format, observationFormat: format, plan: nil)
        graph.setVolume(1)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        player.scheduleBuffer(input)
        try engine.start(); defer { engine.stop() }
        player.play()
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var output: [[Float]] = [[], []]
        while output[0].count < 4096 {
            #expect(try engine.renderOffline(512, to: chunk) == .success)
            for channel in 0..<2 { output[channel] += UnsafeBufferPointer(start: chunk.floatChannelData![channel], count: Int(chunk.frameLength)) }
        }
        for channel in 0..<2 {
            #expect(output[channel] == Array(UnsafeBufferPointer(start: input.floatChannelData![channel], count: 4096)))
        }
    }

    /// Outputs of external converters: a plan measured at the device's rate sets the level of what the graph renders.
    @Test(arguments: [88200.0, 176400, 192000])
    func aPlanAtTheDevicesRateSetsTheRenderedLevel(rate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let metrics = AudioLevelMetrics(loudness: .measured(-17), samplePeak: 0.5, truePeak: 0.5, frameCount: UInt64(rate), blockCount: 10)
        let plan = try NormalizationPlan(metrics: metrics, profile: MeasurementProfile(sampleRate: rate, channels: 2))
        let frames: AVAudioFrameCount = 16384
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)); input.frameLength = frames
        for channel in 0..<2 { for n in 0..<Int(frames) { input.floatChannelData![channel][n] = 0.5 } }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let graph = PlaybackGraph(engine: engine, player: player, sourceFormat: format, observationFormat: format, plan: plan)
        graph.setVolume(1)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        player.scheduleBuffer(input)
        try engine.start(); defer { engine.stop() }
        player.play()
        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var last: Float = 0
        for _ in 0..<Int(frames) / 512 {
            #expect(try engine.renderOffline(512, to: chunk) == .success)
            last = chunk.floatChannelData![0][Int(chunk.frameLength) - 1]
        }
        #expect(abs(last - 0.5 * Float(pow(10, plan.gainDB / 20))) < 1e-4, "\(rate)Hz: \(last)")
        #expect(plan.gainDB == -6)
    }

    /// A graph taken over by the next track gets that track's level gain, and a player for its format.
    @Test func aTakenGraphGetsTheNextTracksGainAndFormat() throws {
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let metrics = AudioLevelMetrics(loudness: .measured(-17), samplePeak: 0.5, truePeak: 0.5, frameCount: 48000, blockCount: 10)
        let plan = try NormalizationPlan(metrics: metrics, profile: MeasurementProfile(sampleRate: 48000, channels: 2))
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let graph = PlaybackGraph(engine: engine, player: player, sourceFormat: stereo, observationFormat: stereo, plan: plan)
        #expect(abs(graph.chain.levelNode.globalGain + 6) < 1e-6)
        let same = graph.taking(sourceFormat: stereo, plan: nil)
        #expect(same.player === player && same.chain.levelNode.globalGain == 0)
        let other = same.taking(sourceFormat: mono, plan: plan)
        #expect(other.player !== player && other.player.engine === engine && player.engine == nil)
        #expect(other.player.outputFormat(forBus: 0) == mono && abs(other.chain.levelNode.globalGain + 6) < 1e-6)
        #expect(other.format == stereo && other.converter === graph.converter)
    }

    /// Seeking while playing restarts only the player of the running engine, at the new position.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func seekingWhilePlayingKeepsTheEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-seek-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let second = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)); second.frameLength = 48000
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); for _ in 0..<12 { try file.write(from: second) } }
        let backend = try AudioEngineBackend(url: url); backend.volume = 0
        defer { backend.stop() }
        var finished = false
        backend.onEvent = { if case .finished = $0 { finished = true } }
        try backend.play()
        let engine = try #require(backend.currentEngine)
        try await Task.sleep(for: .milliseconds(150))
        for target in [8.0, 2.0, 11.6] {
            try backend.seek(to: target)
            #expect(backend.currentEngine === engine)
            let deadline = ContinuousClock.now + .seconds(5)
            while backend.currentTime <= target + 0.05, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(backend.currentTime > target && backend.currentTime < target + 1)
        }
        // The new run reports its own end.
        let deadline = ContinuousClock.now + .seconds(5)
        while !finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished)
    }
}

/// The next track takes over the running engine of the one before it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
@MainActor struct EngineHandoffTests {
    private func tone(_ root: URL, _ name: String, rate: Double, channels: UInt32, seconds: Int = 3) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let second = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))); second.frameLength = second.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<seconds { try file.write(from: second) }
        return url
    }
    private func playing(_ backend: AudioEngineBackend) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while backend.currentTime <= 0.01, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(backend.currentTime > 0.01)
    }

    @Test func aRetiredEngineIsTakenOverAndOtherwiseStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-handoff-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stereo = try tone(root, "a.wav", rate: 48000, channels: 2), mono = try tone(root, "b.wav", rate: 44100, channels: 1)
        let a = try AudioEngineBackend(url: stereo); a.volume = 0
        try a.play(); try await playing(a)
        let engine = try #require(a.currentEngine)
        a.retire()
        #expect(AudioEngineBackend.hasHandoff)
        // Same format: the same engine plays the next track.
        let b = try AudioEngineBackend(url: stereo); b.volume = 0
        try b.play(); try await playing(b)
        #expect(b.currentEngine === engine && !AudioEngineBackend.hasHandoff)
        // Another format: still the same engine, with a new player for the source.
        b.retire()
        let c = try AudioEngineBackend(url: mono); c.volume = 0
        try c.play(); try await playing(c)
        #expect(c.currentEngine === engine)
        // An explicit stop releases the output at once.
        c.retire()
        let d = try AudioEngineBackend(url: stereo)
        d.stop()
        #expect(!AudioEngineBackend.hasHandoff && !engine.isRunning)
        // An engine nobody takes stops after a moment.
        let e = try AudioEngineBackend(url: stereo); e.volume = 0
        try e.play(); try await playing(e)
        let left = try #require(e.currentEngine)
        e.retire()
        try await Task.sleep(for: AudioEngineBackend.handoffLifetime + .milliseconds(300))
        #expect(!AudioEngineBackend.hasHandoff && !left.isRunning)
    }

    /// A track that ends leaves its engine for the next one; a stop leaves nothing running.
    @Test func aFinishedTrackLeavesItsEngineAndAStopDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-finish-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try tone(root, "short.wav", rate: 48000, channels: 2, seconds: 1)
        let playback = PlaybackController(); playback.setVolume(0)
        #expect(playback.select(url))
        playback.togglePlayPause()
        let deadline = ContinuousClock.now + .seconds(5)
        while playback.state != .finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.state == .finished && AudioEngineBackend.hasHandoff)
        #expect(playback.select(url))
        playback.togglePlayPause()
        playback.stop()
        #expect(!AudioEngineBackend.hasHandoff)
    }
}
