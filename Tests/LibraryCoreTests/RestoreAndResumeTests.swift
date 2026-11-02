import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
@testable import LibraryCore

/// References whose resolving (the selection's) and checking (the library's) each wait for the test
/// while held, and whose resolved references are refreshed ones, as a stale bookmark resolves.
@MainActor final class HeldReferences: FileReferenceProvider {
    let base = TestReferences()
    var holdsResolve = false
    var holdsCheck = false
    private var resolveWaiters: [CheckedContinuation<Void, Never>] = []
    private var checkWaiters: [CheckedContinuation<Void, Never>] = []
    var waitingResolves: Int { resolveWaiters.count }
    var waitingChecks: Int { checkWaiters.count }
    func beginAccess(_ url: URL) -> FileLease { base.beginAccess(url) }
    func makeReference(_ url: URL) throws -> TrackReference { try base.makeReference(url) }
    func resolve(_ reference: TrackReference) throws -> ResolvedTrack {
        var resolved = try base.resolve(reference)
        resolved.reference.bookmark = Self.refreshedBookmark(resolved.url)
        return resolved
    }
    static func refreshedBookmark(_ url: URL) -> Data { Data((url.absoluteString + "#refreshed").utf8) }
    /// Every resolve of a selection, held or not.
    private(set) var resolveCount = 0
    func resolved(_ reference: TrackReference) async throws -> ResolvedTrack {
        resolveCount += 1
        if holdsResolve { await withCheckedContinuation { resolveWaiters.append($0) } }
        return try resolve(reference)
    }
    func availability(of references: [TrackReference]) async -> [TrackReference?] {
        if holdsCheck { await withCheckedContinuation { checkWaiters.append($0) } }
        return references.map { try? resolve($0).reference }
    }
    func located(_ references: [TrackReference]) async -> [TrackReference?] { references.map { try? resolve($0).reference } }
    func releaseResolves() { holdsResolve = false; resolveWaiters.forEach { $0.resume() }; resolveWaiters = [] }
    func releaseChecks() { holdsCheck = false; checkWaiters.forEach { $0.resume() }; checkWaiters = [] }
}

/// The player cannot open files on its own, as on the iPhone: only the library's references can.
@MainActor struct NoFileAccess: FileAccess {
    func acquire(_ url: URL) throws -> FileLease { throw PlaybackError.inaccessibleFile }
}

@MainActor func waitUntil(_ predicate: () -> Bool, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    #expect(predicate(), sourceLocation: sourceLocation)
}

/// The last track is read ahead at launch, but play never depends on it: neither on the order of the
/// read-ahead and the library's check, nor on a read-ahead that was cancelled or failed.
@Suite(.serialized) @MainActor struct RestoreSelectionTests {
    /// A library saved with its second track current, opened again as at launch.
    private func launch(_ f: Fixture, store: MemoryStore = MemoryStore(), refs: HeldReferences = HeldReferences(),
                        playback: PlaybackController = PlaybackController(fileAccess: NoFileAccess())) async throws -> (LibraryController, [URL]) {
        let files = try ["a.wav", "b.wav"].map { try audioFile(f.root, name: $0, duration: 2) }
        if store.document.tracks.isEmpty {
            let setup = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: TestReferences())
            let list = try #require(setup.document.currentPlaylistID)
            await setup.importFiles(files, into: list)
            setup.selectEntry(try #require(setup.playlist(list)?.entries.last).id, in: list)
            setup.shutdown()
        }
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true,
                                      preferences: MemoryPreferences(), preprocessor: AudioPreprocessor())
        return (model, files)
    }

    @Test(arguments: ["check just before", "check first", "read-ahead first"])
    func aReferenceRefreshedByTheCheckKeepsTheReadAhead(order: String) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let refs = HeldReferences()
        let (model, files) = try await launch(f, refs: refs)
        defer { model.shutdown() }
        #expect(model.canPlay && model.playback.selectedURL == nil)
        if order == "check just before" {
            // The check's save runs before the read-ahead's work begins.
            refs.holdsCheck = true
            model.refreshAvailability()
            try await waitUntil { refs.waitingChecks == 1 }
            refs.releaseChecks()
            model.restore()
        } else if order == "check first" {
            refs.holdsResolve = true
            model.restore()
            try await waitUntil { model.document.tracks[1].reference.bookmark == HeldReferences.refreshedBookmark(files[1]) }
            refs.releaseResolves()
        } else {
            refs.holdsCheck = true
            model.restore()
            try await waitUntil { !model.isPreparing }
            refs.releaseChecks()
            await model.refreshAvailability()?.value
        }
        try await waitUntil { !model.isPreparing }
        #expect(model.playback.state == .ready && model.playback.selectedURL?.lastPathComponent == "b.wav")
        #expect(model.document.tracks[1].reference.bookmark == HeldReferences.refreshedBookmark(files[1]))
        #expect(model.error == nil && model.canPlay)
    }

    /// A changed setting cancels the work on its way; the last track is read ahead again.
    @Test func aChangedSettingDuringTheReadAheadReadsItAgain() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let refs = HeldReferences()
        let (model, _) = try await launch(f, refs: refs)
        defer { model.shutdown() }
        refs.holdsResolve = true
        model.restore()
        try await waitUntil { refs.waitingResolves == 1 }
        model.setNormalizesVolume(true)
        #expect(model.isPreparing)
        refs.releaseResolves()
        try await waitUntil { !model.isPreparing && model.playback.state == .ready }
        #expect(model.playback.selectedURL?.lastPathComponent == "b.wav" && model.error == nil)
    }

    /// A repair points the track to another file: the read-ahead of the old one never commits.
    @Test func aRepairDuringTheReadAheadReadsTheNewFile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let refs = HeldReferences()
        let (model, _) = try await launch(f, refs: refs)
        defer { model.shutdown() }
        let replacement = try audioFile(f.root, name: "c.wav", duration: 1)
        refs.holdsResolve = true
        model.restore()
        try await waitUntil { refs.waitingResolves == 1 }
        model.repairTrack(model.document.tracks[1].id, using: replacement)
        refs.releaseResolves()
        try await waitUntil { !model.isPreparing && model.playback.state == .ready }
        #expect(model.playback.selectedURL?.lastPathComponent == "c.wav")
    }

    /// An unreadable last track shows its error and leaves play working, to try it again.
    @Test func anUnreadableLastTrackShowsAnErrorAndKeepsPlay() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let refs = HeldReferences()
        let (model, files) = try await launch(f, refs: refs)
        defer { model.shutdown() }
        refs.base.denied.insert(files[1])
        model.restore()
        try await waitUntil { !model.isPreparing && model.error != nil }
        // The library's check, saving the other track's refreshed reference, keeps the error shown.
        await model.refreshAvailability()?.value
        #expect(model.error != nil)
        #expect(model.playback.state == .empty && model.canPlay && model.unavailable[model.document.tracks[1].id] != nil)
    }

    /// Moving on the seek bar before playing uses the library's access to the file (the player has none).
    @Test func movingBeforePlayingNeedsNoAccessOfThePlayer() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (model, _) = try await launch(f)
        defer { model.shutdown() }
        model.restore()
        try await waitUntil { !model.isPreparing && model.playback.state == .ready }
        model.seek(to: 1.25)
        #expect(model.playback.error == nil && model.error == nil)
        #expect(abs(model.playback.currentTime - 1.25) < 0.001)
    }
}

/// Where the current track was left is saved apart from the library and resumed at launch.
@Suite(.serialized) @MainActor struct ResumePositionTests {
    private struct Model {
        let model: LibraryController
        let store: MemoryStore
        var backends: () -> [TestBackend]
        var backend: TestBackend { backends().last! }
    }
    /// Without preparation, so that the player plays test backends and nothing reaches the output.
    private func model(_ f: Fixture, store: MemoryStore = MemoryStore()) async throws -> Model {
        var made: [TestBackend] = []
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); made.append(b); return b })
        let model = LibraryController(playback: playback, store: store, references: TestReferences(), positionSaveInterval: .milliseconds(20))
        if model.document.tracks.isEmpty {
            await model.importFiles([try f.file("a.wav"), try f.file("b.wav")], into: try #require(model.document.currentPlaylistID))
        }
        return Model(model: model, store: store, backends: { made })
    }

    @Test func pausingPlayingMovingAndStoppingSaveOrForgetThePosition() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let m = try await model(f)
        defer { m.model.shutdown() }
        let list = try #require(m.model.document.currentPlaylistID)
        let entries = try #require(m.model.playlist(list)?.entries)
        m.model.selectEntry(entries[0].id, in: list)
        #expect(m.store.position?.entryID == entries[0].id && m.store.position?.seconds == 0)
        // Playing saves every interval.
        m.model.togglePlayPause()
        m.backend.currentTime = 3
        try await waitUntil { m.store.position?.seconds == 3 }
        m.backend.currentTime = 4
        try await waitUntil { m.store.position?.seconds == 4 }
        // Pausing saves where it paused, and the clock stops.
        m.backend.currentTime = 4.5
        m.model.togglePlayPause()
        #expect(m.store.position?.seconds == 4.5)
        m.backend.currentTime = 6
        try await Task.sleep(for: .milliseconds(80))
        #expect(m.store.position?.seconds == 4.5)
        // Moving while paused saves the new place.
        m.model.seek(to: 7)
        #expect(m.store.position?.seconds == 7)
        // Going to the background and quitting save it too.
        m.model.togglePlayPause(); m.backend.currentTime = 7.5
        m.model.isInBackground = true
        #expect(m.store.position?.seconds == 7.5)
        m.model.isInBackground = false
        // Stopping forgets it.
        m.model.stop()
        #expect(m.store.position == nil)
        // Another track starts from its top; its natural end forgets it.
        m.model.selectEntry(entries[1].id, in: list, autoPlay: true)
        #expect(m.store.position?.entryID == entries[1].id && m.store.position?.seconds == 0)
        m.backend.onEvent?(.finished)
        #expect(m.store.position == nil)
        m.model.togglePlayPause(); m.backend.currentTime = 2
        m.model.shutdown()
        #expect(m.store.position?.seconds == 2)
    }

    @Test func launchResumesTheSavedPositionWithoutPlaying() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = MemoryStore()
        do {
            let m = try await model(f, store: store)
            let list = try #require(m.model.document.currentPlaylistID)
            m.model.selectEntry(try #require(m.model.playlist(list)?.entries.last).id, in: list, autoPlay: true)
            m.backend.currentTime = 6.5
            m.model.togglePlayPause()
            m.model.shutdown()
        }
        let m = try await model(f, store: store)
        defer { m.model.shutdown() }
        m.model.restore()
        #expect(m.model.playback.state == .ready && m.model.currentIndex == 1 && m.backend.currentTime == 6.5)
    }

    /// The read-ahead at launch starts where the track was left, when it is the same file.
    @Test(arguments: ["same", "changed", "beyond"])
    func theReadAheadResumesOnlyInTheSameFile(_ file: String) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = MemoryStore()
        let url = try audioFile(f.root, name: "a.wav", duration: 2)
        do {
            let setup = LibraryController(playback: PlaybackController(fileAccess: NoFileAccess()), store: store, references: TestReferences(),
                                          preprocessingEnabled: true, preferences: MemoryPreferences(), preprocessor: AudioPreprocessor())
            let list = try #require(setup.document.currentPlaylistID)
            await setup.importFiles([url], into: list)
            setup.selectEntry(try #require(setup.playlist(list)?.entries.first).id, in: list)
            try await waitUntil { !setup.isPreparing && setup.playback.state == .ready }
            setup.seek(to: 1.5)
            #expect(store.position?.seconds == 1.5)
            setup.shutdown()
        }
        if file == "changed" { _ = try audioFile(f.root, name: "a.wav", duration: 1.8) }
        if file == "beyond" { store.position?.seconds = 2.5 }
        let model = LibraryController(playback: PlaybackController(fileAccess: NoFileAccess()), store: store, references: TestReferences(),
                                      preprocessingEnabled: true, preferences: MemoryPreferences(), preprocessor: AudioPreprocessor())
        defer { model.shutdown() }
        model.restore()
        try await waitUntil { !model.isPreparing && model.playback.state == .ready }
        #expect(abs(model.playback.currentTime - (file == "same" ? 1.5 : 0)) < 0.001)
        #expect(model.savedPosition?.seconds == (file == "same" ? 1.5 : 0))
    }
}

/// Play on the last track at launch, whatever became of its read-ahead.
/// Opt-in because it plays to the default output (at volume 0).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
@MainActor struct RestorePlaybackOutputTests {
    /// `saved` runs before the launch, as the previous run of the app.
    private func launch(_ f: Fixture, refs: HeldReferences, store: MemoryStore = MemoryStore(),
                        saved: (LibraryController, [URL]) async throws -> Void = { _, _ in }) async throws -> (LibraryController, [URL]) {
        let files = try ["a.wav", "b.wav"].map { try audioFile(f.root, name: $0, duration: 4) }
        let setup = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: TestReferences())
        let list = try #require(setup.document.currentPlaylistID)
        await setup.importFiles(files, into: list)
        setup.selectEntry(try #require(setup.playlist(list)?.entries.last).id, in: list)
        try await saved(setup, files)
        setup.shutdown()
        let playback = PlaybackController(fileAccess: NoFileAccess()); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true,
                                      preferences: MemoryPreferences(), preprocessor: AudioPreprocessor())
        return (model, files)
    }

    /// Play pressed while the last track is read ahead plays it when it is ready; pressing again changes nothing.
    @Test func playDuringTheReadAheadPlaysWhenReady() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let refs = HeldReferences()
        let (model, _) = try await launch(f, refs: refs)
        defer { model.shutdown() }
        refs.holdsResolve = true
        model.restore()
        try await waitUntil { refs.waitingResolves == 1 }
        #expect(model.canPlay && model.playback.selectedURL == nil)
        model.togglePlayPause(); model.togglePlayPause()
        refs.releaseResolves()
        try await waitUntil { model.playback.state == .playing }
        // Taken over, not prepared again.
        #expect(refs.resolveCount == 1)
        #expect(model.playback.selectedURL?.lastPathComponent == "b.wav" && model.error == nil)
        model.stop()
    }

    /// A last track that could not be read at launch plays from where it was left once it can be read.
    @Test func playAfterAFailedReadAheadStartsAtTheSavedPosition() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let refs = HeldReferences(), store = MemoryStore()
        let (reopened, files) = try await launch(f, refs: refs, store: store) { previous, files in
            // The position saved last time, in this very file.
            let list = try #require(previous.document.currentPlaylistID), entry = try #require(previous.currentEntry)
            let prepared = try await AudioPreprocessor().preparePrefix(files[1], cancellation: PreparationCancellation())
            store.position = ResumePosition(playlistID: list, entryID: entry.id, trackID: entry.trackID, seconds: 2, source: ResumeSource(prepared))
        }
        defer { reopened.shutdown() }
        #expect(store.position?.seconds == 2)
        refs.base.denied.insert(files[1])
        reopened.restore()
        try await waitUntil { !reopened.isPreparing && reopened.error != nil }
        #expect(reopened.canPlay && reopened.playback.state == .empty)
        refs.base.denied.remove(files[1])
        reopened.togglePlayPause()
        try await waitUntil { reopened.playback.state == .playing }
        #expect(reopened.error == nil && reopened.playback.currentTime >= 2 && reopened.playback.currentTime < 3)
        reopened.stop()
        #expect(store.position == nil)
    }
}
