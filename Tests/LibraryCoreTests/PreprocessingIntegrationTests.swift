import AVFAudio
import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

@MainActor private func waitFor(_ predicate: () -> Bool, seconds: Double = 4) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(predicate())
}
@MainActor private func audioFile(_ root: URL, name: String, duration: Double = 3, peak: Float = 0.3) throws -> URL {
    let url = root.appendingPathComponent(name)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(duration * 48000)))
    buffer.frameLength = buffer.frameCapacity
    for n in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![0][n] = sin(Float(n) * 2 * .pi * 1000 / 48000) * 0.05
        buffer.floatChannelData![1][n] = -buffer.floatChannelData![0][n]
    }
    buffer.floatChannelData![1][Int(buffer.frameLength) - 1] = peak
    let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
    return url
}

@Suite(.serialized) @MainActor struct PreprocessingIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"),
          arguments: ["tone.wav", "tone.aiff", "tone-aac.m4a", "tone-alac.m4a", "tone.mp3", "tone.flac", "tone-96k-24bit.wav", "tone-96k-24bit.flac"])
    func normalizedFormatsRenderToCompletion(_ name: String) async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackCoreTests/Fixtures/\(name)")
        let prepared = try await AudioPreprocessor.shared.prepare(url)
        let metrics = try await AudioPreprocessor.shared.measureLevels(url, profile: SFBAudioBackend.measurementProfile())
        let playback = PlaybackController(); playback.setVolume(0); playback.requireNormalization(true)
        #expect(playback.selectPrepared(prepared, using: FileLease {}, metrics: metrics))
        playback.togglePlayPause()
        try await waitFor { playback.state == .finished }
        #expect(playback.error == nil && playback.activeFileLease == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func normalizationGatesPlaybackPersistsAndKeepsManualVolumeIndependent() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let suite = "lcmp-normalization-\(UUID())", store = MemoryStore(), refs = TestReferences()
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "measureMaximumVolume") // never migrates into processing ON
        let playback = PlaybackController(); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true, preferences: defaults)
        defer { model.shutdown() }
        #expect(!model.normalizesVolume && !playback.normalizationRequired)
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([try audioFile(fixture.root, name: "n1.wav", duration: 6, peak: 0.8),
                                 try audioFile(fixture.root, name: "n2.wav", duration: 6, peak: 0.7)], into: list)
        model.setNormalizesVolume(true)
        #expect(defaults.bool(forKey: "normalizeVolume"))
        model.playPlaylist(list)
        #expect(model.isPreparing && playback.state != .playing)
        try await waitFor { playback.state == .playing && model.currentTrackMetrics != nil && playback.normalizationPlan != nil }
        let originalMetrics = try #require(model.currentTrackMetrics)
        let plan = try #require(playback.normalizationPlan)
        #expect(originalMetrics.levels.truePeakDBTP + plan.gainDB <= plan.settings.ceilingDBTP - plan.settings.marginDB + 1e-9)
        #expect(model.currentTrackPeak?.samplePeak == originalMetrics.sourcePeak.samplePeak)
        try await waitFor { playback.analysisFrame != nil }
        model.togglePlayPause()
        #expect(playback.state == .paused && model.currentTrackMetrics == originalMetrics)
        playback.seek(to: 0.5)
        model.togglePlayPause()
        #expect(playback.state == .playing && model.currentTrackMetrics == originalMetrics)
        model.setNormalizationTarget(-18)
        #expect(playback.state == .paused && playback.normalizationPlan == nil)
        model.togglePlayPause()
        try await waitFor { playback.state == .playing && playback.normalizationPlan?.settings.targetLUFS == -18 }
        #expect(model.currentTrackMetrics == originalMetrics)
        playback.toggleMute()
        #expect(playback.isMuted && playback.state == .playing)
        playback.toggleMute()
        #expect(!playback.isMuted && playback.volume == 0)
        let selected = model.currentEntry?.id
        store.fail = true; model.next()
        try await waitFor { !model.isPreparing }
        #expect(model.currentEntry?.id == selected && playback.state == .playing && model.error != nil)
        store.fail = false
        model.setNormalizesVolume(false)
        #expect(playback.state == .paused && playback.normalizationPlan == nil && playback.volume == 0)
        model.togglePlayPause()
        try await waitFor { playback.state == .playing && !model.isPreparing }
        #expect(playback.normalizationPlan == nil)
        for _ in 0..<8 {
            try await waitFor { model.preparedNextEntryID != nil }
            model.togglePlayPause(); model.togglePlayPause()
            await Task.yield()
        }
        for _ in 0..<4 {
            model.setNormalizesVolume(!model.normalizesVolume)
            model.togglePlayPause()
            try await waitFor { playback.state == .playing && !model.isPreparing }
        }
        #expect(refs.scopes.maximum <= 2)
        model.stop()
        try await waitFor { refs.scopes.active == 0 }
        #expect(model.currentTrackMetrics == nil)
        model.setNormalizesVolume(true); model.playPlaylist(list); model.stop()
        try await waitFor { refs.scopes.active == 0 && !model.isPreparing }
        #expect(playback.state == .stopped)
    }

    @Test func directPlaybackCannotBypassRequiredMeasurement() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let url = try audioFile(fixture.root, name: "guard.wav")
        let playback = PlaybackController()
        playback.requireNormalization(true)
        #expect(playback.select(url))
        playback.togglePlayPause()
        #expect(playback.state == .failed && playback.activeFileLease == nil)
        let prepared = try await AudioPreprocessor.shared.prepare(url)
        #expect(!playback.selectPrepared(prepared, using: FileLease {}))
    }

    @Test func backgroundSelectionRetainsOnlyMetadataAndHonorsCancelAndSaveFailure() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let suite = "lcmp-test-\(UUID())", store = MemoryStore(), refs = TestReferences()
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let playback = PlaybackController()
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true, preferences: defaults)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([try audioFile(fixture.root, name: "a.wav"), try audioFile(fixture.root, name: "b.wav")], into: list)
        let entries = try #require(model.playlist(list)?.entries)
        model.selectEntry(entries[0].id, in: list)
        #expect(model.isPreparing)
        await Task.yield()
        try await waitFor { !model.isPreparing }
        #expect(playback.state == .ready && model.currentIndex == 0)
        try await waitFor { refs.scopes.active == 0 }
        #expect(model.peakMeasurement == .disabled && model.currentTrackPeak == nil)
        model.selectEntry(entries[1].id, in: list)
        model.stop()
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.currentIndex == 0 && !model.isPreparing && playback.state == .stopped)
        #expect(refs.scopes.active == 0)
        store.fail = true
        model.selectEntry(entries[1].id, in: list)
        try await waitFor { !model.isPreparing }
        #expect(model.currentIndex == 0 && model.error != nil && playback.state == .stopped)
        #expect(refs.scopes.active == 0)
        store.fail = false
        model.selectEntry(entries[1].id, in: list)
        model.removeEntry(entries[1].id, from: list)
        try await waitFor { !model.isPreparing }
        #expect(model.currentIndex == 0 && refs.scopes.active == 0)
        model.setMeasuresMaximumVolume(true)
        #expect(defaults.bool(forKey: "measureMaximumVolume"))
        model.setMeasuresMaximumVolume(false)
        #expect(!defaults.bool(forKey: "measureMaximumVolume") && model.currentTrackPeak == nil)
    }

    @Test func preparedSelectionProtectsAccessUntilStop() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let url = try audioFile(fixture.root, name: "ready.wav")
        let prepared = try await AudioPreprocessor.shared.prepare(url)
        let counter = ScopeCounter()
        func access() -> FileLease { counter.acquire(); return FileLease { counter.release() } }
        let playback = PlaybackController()
        #expect(playback.selectPrepared(prepared, using: access()))
        #expect(playback.state == .ready && counter.active == 1)
        playback.stop()
        #expect(counter.active == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func preparedPlaybackMeasurementReorderPauseSeekAdvanceAndShutdown() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let suite = "lcmp-test-\(UUID())", store = MemoryStore(), refs = TestReferences()
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let playback = PlaybackController(); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true, preferences: defaults)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        let a = try audioFile(fixture.root, name: "a.wav", peak: 0.7)
        let b = try audioFile(fixture.root, name: "b.wav", peak: 0.8)
        let c = try audioFile(fixture.root, name: "c.wav", peak: 0.9)
        await model.importFiles([a, b, c], into: list)
        let entries = try #require(model.playlist(list)?.entries)
        model.setMeasuresMaximumVolume(true); model.playPlaylist(list)
        try await waitFor { playback.state == .playing && model.currentTrackPeak != nil && model.preparedNextEntryID == entries[1].id }
        #expect(abs((model.currentTrackPeak?.samplePeak ?? 0) - 0.7) < 1e-6)
        #expect(playback.volume == 0 && refs.scopes.active <= 2)
        #expect(model.preparedNextByteCount <= 32 * 1024 * 1024)
        try await waitFor { playback.analysisFrame != nil }
        model.moveEntry(entries[2].id, in: list, offset: -1)
        try await waitFor { model.preparedNextEntryID == entries[2].id }
        // Failed disk commit leaves current audio, current entry and access intact.
        store.fail = true; model.next()
        try await waitFor { !model.isPreparing }
        #expect(model.currentIndex == 0 && playback.state == .playing && model.error != nil)
        store.fail = false
        model.togglePlayPause()
        #expect(playback.state == .paused)
        try await waitFor { refs.scopes.active == 1 && model.preparedNextEntryID == nil }
        playback.seek(to: 0.5)
        model.togglePlayPause()
        try await waitFor { playback.state == .playing && model.preparedNextEntryID == entries[2].id }
        model.next()
        try await waitFor { model.currentEntry?.id == entries[2].id && playback.state == .playing && model.currentTrackPeak != nil }
        #expect(abs((model.currentTrackPeak?.samplePeak ?? 0) - 0.9) < 1e-6)
        model.setMeasuresMaximumVolume(false)
        #expect(model.currentTrackPeak == nil && model.peakMeasurement == .disabled)
        model.stop()
        try await waitFor { refs.scopes.active == 0 }
        #expect(model.preparedNextEntryID == nil && playback.state == .stopped)
        model.togglePlayPause()
        try await waitFor { playback.state == .playing }
        playback.seek(to: playback.duration - 0.06)
        try await waitFor { model.currentEntry?.id == entries[1].id && playback.state == .playing }
        model.shutdown()
        try await waitFor { refs.scopes.active == 0 }
        #expect(playback.state == .empty && !model.canEdit && !model.isPreparing)
    }
}
