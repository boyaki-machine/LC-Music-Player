import Foundation
import Testing
import PlaybackCore
import AudioProcessingCore
@testable import LibraryCore

@Suite(.serialized) @MainActor struct MeasurementCacheIntegrationTests {
    @Test func playlistRemovalRetainsCacheLibraryExclusionAuditsAfterSuccessfulSave() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let config = MeasurementCacheConfiguration(url: f.root.appendingPathComponent("cache/measurements.sqlite"),
            program: .init(applicationVersion: "test", build: "1", executableDigest: "test", environment: "test"))
        let processor = AudioPreprocessor(cache: config), store = MemoryStore(), refs = TestReferences()
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true, preprocessor: processor)
        defer { model.shutdown() }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackCoreTests/Fixtures/tone.wav")
        let url = f.root.appendingPathComponent("tone.wav"); try FileManager.default.copyItem(at: source, to: url)
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([url], into: list)
        let track = try #require(model.document.tracks.first?.id), entry = try #require(model.playlist(list)?.entries.first?.id)
        _ = try await processor.measure(url, ownerID: track)
        model.removeEntry(entry, from: list)
        _ = try await processor.measure(url, ownerID: track)
        #expect(await processor.statistics().peakScans == 1)
        store.fail = true; model.excludeTrack(track)
        #expect(model.track(track) != nil)
        _ = try await processor.measure(url, ownerID: track)
        #expect(await processor.statistics().peakScans == 1)
        store.fail = false; model.excludeTrack(track)
        // Allow the successful-save audit Task to enqueue before the barrier.
        await Task.yield()
        await processor.reconcileCacheOwners(Set(model.document.tracks.map(\.id)))
        let reopened = AudioPreprocessor(cache: config)
        _ = try await reopened.measure(url)
        #expect(await reopened.statistics().peakScans == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func currentNextStopOtherTrackAndRestartUseCompletedCache() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let config = MeasurementCacheConfiguration(url: f.root.appendingPathComponent("cache/measurements.sqlite"),
            program: .init(applicationVersion: "test", build: "1", executableDigest: "test", environment: "test"))
        let defaults = MemoryPreferences()
        let store = MemoryStore(), refs = TestReferences(), playback = PlaybackController()
        playback.setVolume(0)
        let processor = AudioPreprocessor(cache: config)
        var model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true, preferences: defaults, preprocessor: processor)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackCoreTests/Fixtures/tone.wav")
        var urls: [URL] = []
        for n in 0..<2 {
            let url = f.root.appendingPathComponent("\(n).wav"); try FileManager.default.copyItem(at: fixture, to: url); urls.append(url)
        }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles(urls, into: list)
        model.setNormalizesVolume(true)
        // Pause promptly so a 0.25s original fixture doesn't finish before assertions.
        model.playPlaylist(list)
        try await cacheWait { model.currentTrackMetrics != nil && playback.state == .playing }
        let first = try #require(model.currentTrackMetrics)
        try await cacheWait { model.preparedNextHasLevels }
        model.next()
        try await cacheWait { model.currentIndex == 1 && playback.state == .playing }
        model.stop()
        try await cacheWait { refs.scopes.active == 0 }
        #expect(await processor.statistics().levelScans == 2)
        model.playPlaylist(list)
        try await cacheWait { model.currentIndex == 0 && model.currentTrackMetrics != nil && playback.state == .playing }
        #expect(model.currentTrackMetrics == first)
        #expect(await processor.statistics().levelScans == 2)
        model.shutdown()
        try await cacheWait { refs.scopes.active == 0 }
        let secondProcessor = AudioPreprocessor(cache: config)
        model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true, preferences: defaults, preprocessor: secondProcessor)
        defer { model.shutdown() }
        model.playPlaylist(list)
        try await cacheWait { playback.state == .playing && model.currentTrackMetrics != nil }
        #expect(await secondProcessor.statistics().levelScans == 0)
        #expect(await secondProcessor.statistics().cacheHits >= 1)
        model.setNormalizationTarget(-18); model.togglePlayPause()
        try await cacheWait { playback.state == .playing && playback.normalizationPlan?.settings.targetLUFS == -18 }
        #expect(model.currentTrackMetrics == first && playback.volume == 0)
        #expect(refs.scopes.maximum <= 2)
        model.stop(); try await cacheWait { refs.scopes.active == 0 }
    }
}
@MainActor private func cacheWait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(predicate())
}
