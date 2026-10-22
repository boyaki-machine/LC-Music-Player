import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

/// References whose availability check waits for the test to let each batch through,
/// as a slow check on another thread would.
@MainActor private final class GatedReferences: FileReferenceProvider {
    let base = TestReferences()
    private(set) var batches: [Int] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiting.count }
    func beginAccess(_ url: URL) -> FileLease { base.beginAccess(url) }
    func makeReference(_ url: URL) throws -> TrackReference { try base.makeReference(url) }
    func resolve(_ reference: TrackReference) throws -> ResolvedTrack { try base.resolve(reference) }
    func availability(of references: [TrackReference]) async -> [TrackReference?] {
        batches.append(references.count)
        await withCheckedContinuation { waiting.append($0) }
        return references.map { try? base.resolve($0).reference }
    }
    /// Lets the batch that is waiting through.
    func pass() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
}

@Suite(.serialized) @MainActor struct AvailabilityTests {
    private func model(_ fixture: Fixture, count: Int) async throws -> (LibraryController, GatedReferences, MemoryStore, [URL]) {
        let refs = GatedReferences(), store = MemoryStore()
        let model = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: refs)
        let urls = try (0..<count).map { try fixture.file(String(format: "%03d.wav", $0)) }
        await model.importFiles(urls, into: try #require(model.document.currentPlaylistID))
        #expect(model.document.tracks.count == count)
        return (model, refs, store, urls)
    }
    private func waitForBatch(_ refs: GatedReferences, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while refs.waitingCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(refs.waitingCount == 1, sourceLocation: sourceLocation)
    }

    @Test func checkRunsInBatchesWithoutHoldingTheCallerAndMarksAsItGoes() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let size = LibraryController.availabilityBatchSize
        let (model, refs, store, urls) = try await model(f, count: size * 2 + 3)
        defer { model.shutdown() }
        let first = model.document.tracks[2], second = model.document.tracks[size + 5], moved = model.document.tracks[size * 2 + 1]
        try FileManager.default.removeItem(at: urls[2]); try FileManager.default.removeItem(at: urls[size + 5])
        let destination = try f.file("moved.wav")
        refs.base.moved[urls[size * 2 + 1]] = destination
        // The call returns at once; nothing is marked before the first batch has been checked.
        let task = try #require(model.refreshAvailability())
        #expect(model.unavailable.isEmpty)
        // A second request keeps the check that is running.
        #expect(model.refreshAvailability() == task)
        try await waitForBatch(refs)
        refs.pass()
        try await waitForBatch(refs)
        #expect(model.unavailable[first.id] != nil && model.unavailable[second.id] == nil)
        refs.pass()
        try await waitForBatch(refs)
        #expect(model.unavailable[second.id] != nil)
        #expect(model.track(moved.id)?.reference.lastKnownURL == urls[size * 2 + 1])
        refs.pass()
        await task.value
        #expect(refs.batches == [size, size, 3])
        // The refreshed bookmark is saved once the whole library has been checked.
        #expect(model.track(moved.id)?.reference.lastKnownURL == destination)
        #expect(store.document.tracks.first { $0.id == moved.id }?.reference.lastKnownURL == destination)
        #expect(model.unavailable.count == 2)
    }

    @Test func tracksRepairedDuringTheCheckKeepTheirRepair() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (model, refs, store, urls) = try await model(f, count: 3)
        defer { model.shutdown() }
        // The check sees the old references: one missing, one found elsewhere.
        let missing = model.document.tracks[0], relocated = model.document.tracks[1]
        try FileManager.default.removeItem(at: urls[0])
        refs.base.moved[urls[1]] = try f.file("elsewhere.wav")
        let task = try #require(model.refreshAvailability())
        try await waitForBatch(refs)
        let first = try f.file("first-replacement.wav"), second = try f.file("second-replacement.wav")
        model.repairTrack(missing.id, using: first)
        model.repairTrack(relocated.id, using: second)
        refs.pass()
        await task.value
        // Results for the old references neither mark the repaired track nor replace its bookmark.
        #expect(model.unavailable[missing.id] == nil)
        #expect(model.track(missing.id)?.reference.lastKnownURL == first)
        #expect(model.track(relocated.id)?.reference.lastKnownURL == second)
        #expect(store.document.tracks.first { $0.id == relocated.id }?.reference.lastKnownURL == second)
    }

    @Test func aTrackRepairedAfterItsBatchKeepsItsRepairWhenTheCheckSaves() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (model, refs, store, urls) = try await model(f, count: LibraryController.availabilityBatchSize + 1)
        defer { model.shutdown() }
        let relocated = model.document.tracks[1]
        refs.base.moved[urls[1]] = try f.file("elsewhere.wav")
        let task = try #require(model.refreshAvailability())
        try await waitForBatch(refs)
        refs.pass()
        // Its batch is done; the check now waits on the next one when the track is repaired.
        try await waitForBatch(refs)
        let replacement = try f.file("replacement.wav")
        model.repairTrack(relocated.id, using: replacement)
        refs.pass()
        await task.value
        #expect(model.track(relocated.id)?.reference.lastKnownURL == replacement)
        #expect(store.document.tracks.first { $0.id == relocated.id }?.reference.lastKnownURL == replacement)
    }

    @Test func shutdownEndsTheCheck() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (model, refs, _, urls) = try await model(f, count: 3)
        try FileManager.default.removeItem(at: urls[0])
        let task = try #require(model.refreshAvailability())
        try await waitForBatch(refs)
        model.shutdown()
        refs.pass()
        await task.value
        #expect(model.unavailable.isEmpty && refs.batches.count == 1)
        #expect(model.refreshAvailability() == nil)
    }

    /// The real provider resolves security-scoped bookmarks, the slow part, on another thread.
    @Test func bookmarkReferencesCheckRealFiles() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let refs = BookmarkFileReferences()
        let kept = try f.file("kept.wav"), gone = try f.file("gone.wav")
        let references = [try refs.makeReference(kept), try refs.makeReference(gone)]
        try FileManager.default.removeItem(at: gone)
        let results = await refs.availability(of: references)
        #expect(results.count == 2)
        #expect(results[0]?.lastKnownURL.standardizedFileURL.resolvingSymlinksInPath() == kept.standardizedFileURL.resolvingSymlinksInPath())
        #expect(results[1] == nil)
    }
}
