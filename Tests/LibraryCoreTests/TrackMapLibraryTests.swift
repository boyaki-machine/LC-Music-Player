import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
import AudioProcessingCore
@testable import LibraryCore

/// Real preparation and measurement; track maps that name their file by their length (1s per letter after "a").
private actor MapWorker: AudioPreprocessing {
    let real = AudioPreprocessor()
    private(set) var mapRequests: [(file: String, owner: UUID?)] = []
    var failing: Set<String> = []
    func fail(_ name: String) { failing.insert(name) }
    func prepare(_ url: URL, cancellation: PreparationCancellation, seconds: Double, byteLimit: Int) async throws -> PreparedAudio {
        try await real.prepare(url, cancellation: cancellation, seconds: seconds, byteLimit: byteLimit)
    }
    func measure(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackPeak {
        try await real.measure(url, cancellation: cancellation, ownerID: ownerID)
    }
    func measureLevels(_ url: URL, profile: MeasurementProfile, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackAudioMetrics {
        try await real.measureLevels(url, profile: profile, cancellation: cancellation, ownerID: ownerID)
    }
    func trackMap(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackMap {
        let name = url.lastPathComponent
        mapRequests.append((name, ownerID))
        try cancellation.check()
        if failing.contains(name) { throw PreprocessingFailure.invalidAudio }
        let length = Self.length(of: name)
        return TrackMap(beats: BeatMap(algorithm: 77, durationMilliseconds: length, clarity: 1, tempos: [], beats: []),
                        vocals: VocalMap(algorithm: 78, durationMilliseconds: length, register: .unknown, medianNote: 0,
                                         frameMilliseconds: 40, mouth: [], notes: [], events: []))
    }
    static func length(of name: String) -> UInt32 { UInt32((name.unicodeScalars.first!.value - 96) * 1000) }
    func reconcileCacheOwners(_ owners: Set<UUID>) async {}
}

@Suite(.serialized) @MainActor struct TrackMapLibraryTests {
    @Test func theCurrentTracksMapFollowsTheTrackAndTheSweepMapsEveryTrack() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let files = try ["a.wav", "b.wav", "c.wav"].map { try audioFile(f.root, name: $0, duration: 1) }
        let worker = MapWorker(), refs = TestReferences()
        await worker.fail("c.wav")
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let model = LibraryController(playback: playback, store: MemoryStore(), references: refs, preprocessingEnabled: true,
                                      playlistPreprocessingEnabled: true, preferences: MemoryPreferences(), preprocessor: worker)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles(files, into: list)
        // The sweep asks for the map of every track it measures, for that track.
        try await waitAsync { Set(await worker.mapRequests.map(\.file)) == ["a.wav", "b.wav", "c.wav"] }
        let owners = await worker.mapRequests.map(\.owner)
        #expect(Set(owners.compactMap { $0 }) == Set(model.document.tracks.map(\.id)))
        #expect(model.currentTrackMap == nil)

        model.playPlaylist(list)
        try await wait { playback.state == .playing && model.currentTrackMap?.beats.durationMilliseconds == 1000 }
        model.next()
        try await wait { model.currentIndex == 1 && playback.state == .playing }
        // Never the previous track's map for this one.
        #expect(model.currentTrackMap == nil || model.currentTrackMap?.beats.durationMilliseconds == 2000)
        try await wait { model.currentTrackMap?.beats.durationMilliseconds == 2000 }
        // A pause keeps the map; a stop keeps it for the selected track.
        playback.togglePlayPause()
        try await wait { playback.state == .paused }
        #expect(model.currentTrackMap?.beats.durationMilliseconds == 2000)
        playback.togglePlayPause()
        try await wait { playback.state == .playing }
        model.stop()
        #expect(model.currentTrackMap?.beats.durationMilliseconds == 2000)

        // A track that cannot be mapped has no map, and is not asked again and again while it plays
        // (the player asks once, the sweep once more for the track it now measures around).
        model.selectEntry(try #require(model.playlist(list)?.entries[2].id), in: list, autoPlay: true)
        try await wait { model.currentIndex == 2 && playback.state == .playing }
        try await waitAsync { await worker.mapRequests.filter { $0.file == "c.wav" }.count >= 2 }
        try await Task.sleep(for: .milliseconds(300))
        let asked = await worker.mapRequests.filter { $0.file == "c.wav" }.count
        #expect(asked <= 4)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.currentTrackMap == nil)
        #expect(await worker.mapRequests.filter { $0.file == "c.wav" }.count == asked)
        model.stop()
    }

    private func wait(_ predicate: () -> Bool) async throws {
        try await waitAsync { predicate() }
    }
    private func waitAsync(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }
}
