import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

/// References that count the synchronous calls, which run on the main actor. The library must use
/// the asynchronous ones for work a listener waits for, so that a provider can move it elsewhere.
@MainActor private final class SyncCountingReferences: FileReferenceProvider {
    let base = TestReferences()
    private(set) var syncCalls: [String] = []
    func beginAccess(_ url: URL) -> FileLease { base.beginAccess(url) }
    func makeReference(_ url: URL) throws -> TrackReference { syncCalls.append("makeReference"); return try base.makeReference(url) }
    func resolve(_ reference: TrackReference) throws -> ResolvedTrack { syncCalls.append("resolve"); return try base.resolve(reference) }
    func resolved(_ reference: TrackReference) async throws -> ResolvedTrack { try base.resolve(reference) }
    func located(_ references: [TrackReference]) async -> [TrackReference?] { references.map { try? base.resolve($0).reference } }
    func makeReferences(_ urls: [URL]) async -> [TrackReference?] { urls.map { try? base.makeReference($0) } }
    func availability(of references: [TrackReference]) async -> [TrackReference?] { await located(references) }
}

private struct AlbumTags: TrackTagReading { func tags(for url: URL) async -> TrackTags? { TrackTags(album: "a") } }

/// A Music library whose lookups record whether they ran on the main thread.
private final class ThreadRecordingLibrary: MediaLibraryLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    var mainThreadCalls: Int { lock.withLock { threads.filter { $0 }.count } }
    var calls: Int { lock.withLock { threads.count } }
    func song(forPersistentID id: UInt64) -> MediaLibrarySong? {
        lock.withLock { threads.append(Thread.isMainThread) }
        return MediaLibrarySong(assetURL: URL(string: "ipod-library://item/item.m4a?id=\(id)")!, duration: 1, dateAdded: .distantPast)
    }
}

@Suite(.serialized) @MainActor struct OffMainReferencesTests {
    @Test func importTagsSelectionAndPlaylistsUseOnlyTheAsynchronousCalls() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try audioFile(f.root, name: "a.wav", duration: 0.5), b = try audioFile(f.root, name: "b.wav", duration: 0.5)
        let refs = SyncCountingReferences()
        let model = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: MemoryStore(),
                                      references: refs, preprocessingEnabled: true, preferences: MemoryPreferences(),
                                      preprocessor: AudioPreprocessor(), tagReader: AlbumTags())
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list)
        await model.importFiles([a, try f.file("c.wav")], into: list)
        await model.waitForTags()
        #expect(model.document.tracks.count == 3 && model.document.tracks.allSatisfy { $0.tags?.album == "a" })
        let entry = try #require(model.playlist(list)?.entries.first)
        model.selectEntry(entry.id, in: list)
        try await wait { !model.isPreparing && model.document.currentEntryID == entry.id }
        let out = f.root.appendingPathComponent("out.m3u8")
        await model.exportM3U8(list, to: out) { _ in Issue.record("every file is in the list's folder"); return nil }
        await model.importM3U8(out)
        #expect(model.document.playlists.last?.entries.count == 4 && model.document.tracks.count == 3)
        #expect(refs.syncCalls.isEmpty, "\(refs.syncCalls)")
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }

    @Test func bookmarkReferencesResolveLocateAndCreateOffTheMainThread() async throws {
        let library = ThreadRecordingLibrary()
        let refs = BookmarkFileReferences(mediaLibrary: library)
        let url = try #require(URL(string: "ipod-library://item/item.m4a?id=42"))
        let made = await refs.makeReferences([url])
        let reference = try #require(made.first ?? nil)
        _ = try await refs.resolved(reference)
        _ = await refs.located([reference, reference])
        #expect(library.calls == 4 && library.mainThreadCalls == 0)
    }
}
