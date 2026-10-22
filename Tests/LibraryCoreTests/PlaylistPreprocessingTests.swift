import AVFAudio
import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
import AudioProcessingCore
@testable import LibraryCore

private actor PlaylistWorker: AudioPreprocessing {
    let real: AudioPreprocessor
    var blocked: Set<URL> = []
    var failed: Set<URL> = []
    var starts: [URL] = []
    var prefixes: [URL] = []
    var cancelled: [URL] = []
    init(cache: MeasurementCacheConfiguration? = nil) { real = AudioPreprocessor(cache: cache) }
    func block(_ url: URL) { blocked.insert(url) }
    func release(_ url: URL) { blocked.remove(url) }
    func fail(_ url: URL) { failed.insert(url) }
    func prepare(_ url: URL, cancellation: PreparationCancellation, seconds: Double, byteLimit: Int) async throws -> PreparedAudio {
        prefixes.append(url)
        return try await real.prepare(url, cancellation: cancellation, seconds: seconds, byteLimit: byteLimit)
    }
    func measureLevels(_ url: URL, profile: MeasurementProfile, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackAudioMetrics {
        starts.append(url)
        do {
            while blocked.contains(url) { try cancellation.check(); try await Task.sleep(for: .milliseconds(2)) }
            try cancellation.check()
            if failed.contains(url) { throw PreprocessingFailure.invalidAudio }
            return try await real.measureLevels(url, profile: profile, cancellation: cancellation, ownerID: ownerID)
        } catch { if error is CancellationError { cancelled.append(url) }; throw error }
    }
    func measure(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackPeak {
        try await real.measure(url, cancellation: cancellation, ownerID: ownerID)
    }
    func reconcileCacheOwners(_ owners: Set<UUID>) async { await real.reconcileCacheOwners(owners) }
}

@MainActor private func playlistFixture(_ root: URL, count: Int = 5) throws -> LibraryDocument {
    let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PlaybackCoreTests/Fixtures/tone.wav")
    var doc = LibraryDocument()
    for n in 0..<count {
        let url = root.appendingPathComponent("\(n).wav")
        try FileManager.default.copyItem(at: original, to: url)
        let track = LibraryTrack(name: "\(n)", reference: TrackReference(bookmark: Data(url.absoluteString.utf8), lastKnownURL: url))
        doc.tracks.append(track); doc.playlists[0].entries.append(PlaylistEntry(trackID: track.id))
    }
    return doc
}
/// Waits for a condition. The limit only ends a failing wait; a slow, loaded simulator can need far longer than usual.
@MainActor private func sweepWait(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await condition())
}

@MainActor private final class OutputProfileBox { var rate = 48000.0; var unsupported = false }

@Suite(.serialized) @MainActor struct PlaylistPreprocessingTests {
    @Test(arguments: [0, 2, 4]) func ranksCurrentThenNeighborsWithoutWrappingOrDuplicateTracks(_ index: Int) throws {
        let f = try Fixture(); defer { f.cleanup() }
        var doc = try playlistFixture(f.root)
        doc.currentEntryID = doc.playlists[0].entries[index].id
        doc.playlists[0].entries.append(PlaylistEntry(trackID: doc.tracks[index].id))
        let other = MusicPlaylist(name: "other", entries: [PlaylistEntry(trackID: doc.tracks[1].id)])
        doc.playlists.append(other)
        let order = PlaylistPreprocessing.ordered(doc, playing: true).map(\.track.id)
        var expected = [index]
        if index < 4 { expected.append(index + 1) }
        if index > 0 { expected.append(index - 1) }
        expected += (0..<5).filter { !expected.contains($0) }
        #expect(order == expected.map { doc.tracks[$0].id })
        #expect(PlaylistPreprocessing.ordered(doc, playing: false).map(\.track.id) == doc.tracks.map(\.id))
    }

    @Test func serialSweepSkipsFailuresAndFillsOtherPlaylistsOnce() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        var doc = try playlistFixture(f.root)
        let extra = doc.playlists[0].entries.removeLast()
        doc.playlists.append(MusicPlaylist(name: "other", entries: [extra, doc.playlists[0].entries[0]]))
        let refs = TestReferences(), worker = PlaylistWorker(), playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let broken = doc.tracks[1].reference.lastKnownURL
        await worker.fail(broken)
        let queue = PlaylistPreprocessing(references: refs, worker: worker, profile: { try MeasurementProfile(sampleRate: 48000, channels: 2) })
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 5 && queue.active == nil }
        await queue.retirement?.value
        #expect(await worker.starts == doc.tracks.map { $0.reference.lastKnownURL })
        #expect(refs.scopes.active == 0 && refs.scopes.maximum == 1)
        queue.update(doc, playback: playback, after: nil)
        // Nothing starts again: the queue stays idle even after its retirement chain has run.
        #expect(queue.active == nil)
        await queue.retirement?.value
        #expect(queue.active == nil)
        #expect(await worker.starts.count == 5)
        queue.suspend()
    }

    @Test func sharesCurrentScopeReleasesNextPrefixDuringSweepThenRestoresIt() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        var doc = try playlistFixture(f.root)
        doc.currentEntryID = doc.playlists[0].entries[2].id
        let refs = TestReferences(), worker = PlaylistWorker(), playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let current = try refs.resolve(doc.tracks[2].reference)
        #expect(playback.select(current.url, using: current.lease))
        playback.togglePlayPause(using: current.lease)
        await worker.block(doc.tracks[1].reference.lastKnownURL)
        let queue = PlaylistPreprocessing(references: refs, worker: worker, profile: { try MeasurementProfile(sampleRate: 48000, channels: 2) })
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 3 }
        #expect(queue.active?.trackID == doc.tracks[1].id && queue.active?.audio == nil)
        #expect(refs.scopes.maximum <= 2)
        await worker.release(doc.tracks[1].reference.lastKnownURL)
        try await sweepWait { await worker.starts.count == 5 && queue.active?.audio != nil && queue.active?.trackID == doc.tracks[3].id }
        #expect(await worker.starts == [2, 3, 1, 0, 4].map { doc.tracks[$0].reference.lastKnownURL })
        #expect(await worker.prefixes == [doc.tracks[3].reference.lastKnownURL, doc.tracks[3].reference.lastKnownURL])
        queue.suspend(); await queue.retirement?.value
        playback.stop()
        #expect(refs.scopes.maximum <= 2)
        // The explicit test-owned current scope remains alive until this scope returns.
        #expect(refs.scopes.active == 1)
    }

    @Test func transfersPendingMeasurementWithoutCancellingOrResolvingAgain() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let doc = try playlistFixture(f.root, count: 2), refs = TestReferences(), worker = PlaylistWorker()
        let playback = PlaybackController(makeBackend: { _ in TestBackend() }), url = doc.tracks[0].reference.lastKnownURL
        await worker.block(url)
        let queue = PlaylistPreprocessing(references: refs, worker: worker, profile: { try MeasurementProfile(sampleRate: 48000, channels: 2) })
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 1 }
        let (request, work) = try #require(queue.take(doc.tracks[0]))
        queue.suspend()
        #expect(request.audio == nil && request.resolved != nil)
        await worker.release(url); await work?.value
        #expect(request.levels != nil && request.failure == nil)
        #expect(await worker.cancelled.isEmpty)
        #expect(await worker.starts == [url])
        #expect(refs.scopes.maximum == 1)
        request.resolved = nil
        #expect(refs.scopes.active == 0)
    }

    @Test func interruptionRemovalRepairAndProfileChangesRetireBeforeReopening() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        var doc = try playlistFixture(f.root, count: 3)
        let refs = TestReferences(), worker = PlaylistWorker(), playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let output = OutputProfileBox()
        let queue = PlaylistPreprocessing(references: refs, worker: worker, profile: { try MeasurementProfile(sampleRate: output.rate, channels: 2) })
        let first = doc.tracks[0].reference.lastKnownURL
        await worker.block(first)
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 1 }
        queue.suspend()
        doc.playlists[0].entries.removeFirst(); doc.tracks.removeFirst()
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 3 && queue.active == nil }
        #expect(await worker.cancelled == [first])
        #expect(refs.scopes.maximum == 1)
        let revised = doc.tracks[1].reference.lastKnownURL
        let handle = try FileHandle(forWritingTo: revised); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 4 && queue.active == nil }
        output.rate = 44100
        queue.outputChanged()
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 6 && queue.active == nil }
        queue.suspend(); await queue.retirement?.value
        #expect(refs.scopes.active == 0)
    }

    @Test func fillsPersistentCacheAndReconstructionDoesNotScanAgain() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let doc = try playlistFixture(f.root, count: 3), refs = TestReferences()
        let config = MeasurementCacheConfiguration(url: f.root.appendingPathComponent("cache/measurements.sqlite"),
            platform: .init(system: "test"))
        let worker = PlaylistWorker(cache: config), playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let profile = try MeasurementProfile(sampleRate: 48000, channels: 2)
        await worker.reconcileCacheOwners(Set(doc.tracks.map(\.id)))
        let queue = PlaylistPreprocessing(references: refs, worker: worker, profile: { profile })
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 3 && queue.active == nil }
        await queue.retirement?.value
        #expect(await worker.real.statistics().levelScans == 3)
        let second = PlaylistWorker(cache: config)
        let restored = PlaylistPreprocessing(references: refs, worker: second, profile: { profile })
        restored.update(doc, playback: playback, after: nil)
        try await sweepWait { await second.starts.count == 3 && restored.active == nil }
        #expect(await second.real.statistics().levelScans == 0)
        #expect(await second.real.statistics().cacheHits == 3)
        queue.suspend(); restored.suspend(); await restored.retirement?.value
        #expect(refs.scopes.active == 0)
    }

    @Test func outputChangesInvalidatePendingWorkAndUnsupportedOutputDoesNotLoop() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let doc = try playlistFixture(f.root, count: 2), refs = TestReferences(), worker = PlaylistWorker()
        let playback = PlaybackController(makeBackend: { _ in TestBackend() }), output = OutputProfileBox()
        let first = doc.tracks[0].reference.lastKnownURL
        await worker.block(first)
        let queue = PlaylistPreprocessing(references: refs, worker: worker, profile: {
            if output.unsupported { throw AudioProcessingFailure.unsupportedProfile }
            return try MeasurementProfile(sampleRate: output.rate, channels: 2)
        })
        queue.update(doc, playback: playback, after: nil)
        try await sweepWait { await worker.starts.count == 1 }
        output.unsupported = true; queue.outputChanged()
        await queue.retirement?.value
        #expect(queue.active == nil && !queue.supportsProfile && refs.scopes.active == 0)
        await worker.release(first)
        output.unsupported = false; output.rate = 44100; queue.outputChanged()
        try await sweepWait { await worker.starts.count == 3 && queue.active == nil }
        queue.suspend(); await queue.retirement?.value
        queue.outputChanged(); await Task.yield()
        #expect(queue.active == nil && refs.scopes.active == 0 && refs.scopes.maximum == 1)
    }

    @Test func controllerStartsOnSuccessfulAddWithProcessingOffAndStopPreventsRestart() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let doc = try playlistFixture(f.root, count: 2), refs = TestReferences(), store = MemoryStore(), worker = PlaylistWorker()
        let defaults = MemoryPreferences()
        await worker.block(doc.tracks[0].reference.lastKnownURL)
        let playback = PlaybackController(), model = LibraryController(playback: playback, store: store, references: refs,
            preprocessingEnabled: true, playlistPreprocessingEnabled: true, preferences: defaults, preprocessor: worker)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles(doc.tracks.map { $0.reference.lastKnownURL }, into: list)
        try await sweepWait { await worker.starts.count == 1 }
        #expect(!model.normalizesVolume && !playback.normalizationRequired && playback.state == .empty)
        model.stop(); try await sweepWait { refs.scopes.active == 0 }
        #expect(await worker.starts.count == 1)
        store.fail = true
        model.addTracks([model.document.tracks[1].id], to: list)
        await Task.yield(); #expect(await worker.starts.count == 1)
        store.fail = false; await worker.release(doc.tracks[0].reference.lastKnownURL)
        model.addTracks([model.document.tracks[1].id], to: list)
        try await sweepWait { await worker.starts.count == 3 && refs.scopes.active == 0 }
        #expect(await worker.real.statistics().levelScans == 2)
        #expect(refs.scopes.maximum <= 1 && !model.normalizesVolume)
        model.stop()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"), arguments: [false, true])
    func completedIdleMeasurementsAreDisplayedOnPlayWithoutAnotherScan(_ normalize: Bool) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let doc = try playlistFixture(f.root, count: 1), store = MemoryStore(), refs = TestReferences()
        // Replace the 0.25s fixture so playback is still running when the display toggles are checked.
        try FileManager.default.removeItem(at: doc.tracks[0].reference.lastKnownURL)
        _ = try audioFile(f.root, name: doc.tracks[0].reference.lastKnownURL.lastPathComponent, duration: 5)
        store.document = doc
        let processor = AudioPreprocessor(cache: .init(url: f.root.appendingPathComponent("cache/measurements.sqlite"),
            platform: .init(system: "test")))
        let defaults = MemoryPreferences()
        let playback = PlaybackController(); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true,
            playlistPreprocessingEnabled: true, preferences: defaults, preprocessor: processor)
        defer { model.shutdown() }
        try await sweepWait { let scans = await processor.statistics().levelScans; return scans == 1 && refs.scopes.active == 0 }
        #expect(model.peakMeasurement == .disabled)
        model.setNormalizesVolume(normalize); model.setMeasuresMaximumVolume(true)
        model.playPlaylist(try #require(model.document.currentPlaylistID))
        try await sweepWait { model.currentTrackPeak != nil && playback.state == .playing }
        #expect(await processor.statistics().levelScans == 1)
        #expect(await processor.statistics().peakScans == 0)
        #expect(playback.normalizationRequired == normalize)
        model.setMeasuresMaximumVolume(false); #expect(model.currentTrackPeak == nil)
        model.setMeasuresMaximumVolume(true); #expect(model.currentTrackPeak != nil)
        model.stop(); try await sweepWait { refs.scopes.active == 0 }
        #expect(refs.scopes.maximum <= 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"),
          arguments: ["play", "natural", "off", "stop", "pause", "saveFailure", "removed", "exclude", "repair", "settings", "other"])
    func playbackInterruptsOrTakesNonNextMeasurementAndRemainsBounded(_ action: String) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let doc = try playlistFixture(f.root, count: 3)
        // Keep the old track playing while the deliberately held third-track scan is selected.
        for track in doc.tracks {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 8))
            buffer.frameLength = buffer.frameCapacity
            for n in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][n] = sin(Float(n) * 2 * .pi * 440 / 48000) * 0.03
                buffer.floatChannelData![1][n] = buffer.floatChannelData![0][n]
            }
            let file = try AVAudioFile(forWriting: track.reference.lastKnownURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let store = MemoryStore(), refs = TestReferences(), worker = PlaylistWorker()
        store.document = doc
        let targetURL = doc.tracks[2].reference.lastKnownURL
        await worker.block(targetURL)
        let defaults = MemoryPreferences()
        if action != "off" { defaults.set(true, forKey: "normalizeVolume") }
        let playback = PlaybackController(); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true,
            playlistPreprocessingEnabled: true, preferences: defaults, preprocessor: worker)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID), entries = doc.playlists[0].entries
        model.playPlaylist(list)
        try await sweepWait { let started = await worker.starts; return playback.state == .playing && started.contains(targetURL) }
        #expect(model.currentIndex == 0 && refs.scopes.maximum <= 2)
        if action == "natural" {
            model.moveEntry(entries[2].id, in: list, offset: -1)
            playback.seek(to: playback.duration - 0.04)
            try await sweepWait { model.isPreparing }
        } else { model.selectEntry(entries[2].id, in: list, autoPlay: true) }
        #expect(model.isPreparing)
        if action == "off" {
            try await sweepWait { model.currentIndex == 2 && playback.state == .playing }
        } else {
            #expect(model.currentIndex == 0)
            #expect(playback.state == (action == "natural" ? .finished : .playing))
        }
        if action == "stop" { model.stop() }
        if action == "pause" { model.togglePlayPause() }
        if action == "saveFailure" { store.fail = true }
        if action == "removed" { model.removeEntry(entries[2].id, from: list) }
        if action == "exclude" { model.excludeTrack(doc.tracks[2].id) }
        if action == "repair" { model.repairTrack(doc.tracks[2].id, using: doc.tracks[1].reference.lastKnownURL) }
        if action == "settings" { model.setNormalizationTarget(-18) }
        if action == "other" { model.selectEntry(entries[1].id, in: list, autoPlay: true) }
        await worker.release(targetURL)
        try await sweepWait { !model.isPreparing }
        if action == "play" || action == "off" {
            #expect(model.currentIndex == 2 && playback.state == .playing)
        } else if action == "natural" {
            #expect(model.currentEntry?.id == entries[2].id && playback.state == .playing)
        } else if action == "other" {
            #expect(model.currentIndex == 1 && playback.state == .playing)
        } else {
            #expect(model.currentIndex == 0)
            if action == "saveFailure" { #expect(model.error != nil && playback.state == .playing) }
            if action == "settings" || action == "pause" { #expect(playback.state == .paused) }
        }
        if action == "play" || action == "natural" { #expect((await worker.starts).filter { $0 == targetURL }.count == 1) }
        model.stop(); try await sweepWait { refs.scopes.active == 0 }
        #expect(refs.scopes.maximum <= 2)
        #expect((playback.normalizationPlan == nil) || action != "off")
    }

}
