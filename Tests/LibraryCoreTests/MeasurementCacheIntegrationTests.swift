import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
import AudioProcessingCore
@testable import LibraryCore

/// Record completed cache-owner audits so a test can wait for LibraryController's background audit.
private actor AuditedPreprocessor: AudioPreprocessing {
    let worker: AudioPreprocessor
    private(set) var audits: [Set<UUID>] = []
    init(_ worker: AudioPreprocessor) { self.worker = worker }
    func prepare(_ url: URL, cancellation: PreparationCancellation, seconds: Double, byteLimit: Int) async throws -> PreparedAudio {
        try await worker.prepare(url, cancellation: cancellation, seconds: seconds, byteLimit: byteLimit)
    }
    func measure(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackPeak {
        try await worker.measure(url, cancellation: cancellation, ownerID: ownerID)
    }
    func measureLevels(_ url: URL, profile: MeasurementProfile, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackAudioMetrics {
        try await worker.measureLevels(url, profile: profile, cancellation: cancellation, ownerID: ownerID)
    }
    func reconcileCacheOwners(_ owners: Set<UUID>) async { await worker.reconcileCacheOwners(owners); audits.append(owners) }
    /// Wait for an audit of `owners` that completed after the first `after` audits.
    func waitForAudit(of owners: Set<UUID>, after: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !audits.dropFirst(after).contains(owners), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(audits.dropFirst(after).contains(owners))
    }
}

@Suite(.serialized) @MainActor struct MeasurementCacheIntegrationTests {
    @Test func playlistRemovalRetainsCacheLibraryExclusionAuditsAfterSuccessfulSave() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let config = MeasurementCacheConfiguration(url: f.root.appendingPathComponent("cache/measurements.sqlite"),
            platform: .init(system: "test"))
        let processor = AudioPreprocessor(cache: config), store = MemoryStore(), refs = TestReferences()
        let audited = AuditedPreprocessor(processor)
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true,
                                      preferences: MemoryPreferences(), preprocessor: audited)
        defer { model.shutdown() }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackCoreTests/Fixtures/tone.wav")
        let url = f.root.appendingPathComponent("tone.wav"); try FileManager.default.copyItem(at: source, to: url)
        let list = try #require(model.document.currentPlaylistID)
        let beforeImport = await audited.audits.count
        await model.importFiles([url], into: list)
        let track = try #require(model.document.tracks.first?.id), entry = try #require(model.playlist(list)?.entries.first?.id)
        // The cache saves only for audited owners; a loaded run may otherwise measure before the import's audit.
        try await audited.waitForAudit(of: [track], after: beforeImport)
        _ = try await processor.measure(url, ownerID: track)
        model.removeEntry(entry, from: list)
        _ = try await processor.measure(url, ownerID: track)
        #expect(await processor.statistics().peakScans == 1)
        store.fail = true; model.excludeTrack(track)
        #expect(model.track(track) != nil)
        _ = try await processor.measure(url, ownerID: track)
        #expect(await processor.statistics().peakScans == 1)
        let beforeExclusion = await audited.audits.count
        store.fail = false; model.excludeTrack(track)
        try await audited.waitForAudit(of: [], after: beforeExclusion)
        let reopened = AudioPreprocessor(cache: config)
        _ = try await reopened.measure(url)
        #expect(await reopened.statistics().peakScans == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func currentNextStopOtherTrackAndRestartUseCompletedCache() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let config = MeasurementCacheConfiguration(url: f.root.appendingPathComponent("cache/measurements.sqlite"),
            platform: .init(system: "test"))
        let defaults = MemoryPreferences()
        let store = MemoryStore(), refs = TestReferences(), playback = PlaybackController()
        playback.setVolume(0)
        let processor = AudioPreprocessor(cache: config)
        var model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true, preferences: defaults, preprocessor: processor)
        // Long enough that no natural finish advances playback while a loaded run waits.
        let urls = try (0..<2).map { try audioFile(f.root, name: "\($0).wav", duration: 5) }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles(urls, into: list)
        model.setNormalizesVolume(true)
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
