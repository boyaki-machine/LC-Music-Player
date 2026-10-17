import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

@MainActor final class CountingStore: LibraryPersistence {
    var document = LibraryDocument()
    var saves = 0
    var recoveryMessage: String? { nil }
    func load() throws -> LibraryDocument { document }
    func save(_ document: LibraryDocument) throws { saves += 1; self.document = document }
}

@MainActor struct LibraryEditingTests {
    private func model(_ store: CountingStore) -> LibraryController {
        LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: TestReferences())
    }

    @Test func excludingAFolderRemovesItsTracksEverywhereInOneSave() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = CountingStore(), library = model(store)
        let list = try #require(library.document.currentPlaylistID)
        let album = try ["Album/1.wav", "Album/2.wav", "Album/3.wav"].map { try f.file($0) }
        let other = try f.file("Other/keep.wav")
        await library.importFiles([album[0].deletingLastPathComponent(), other], into: list)
        let second = try #require(library.createPlaylist("別のリスト"))
        library.addTracks(library.document.tracks.map(\.id), to: second)
        let albumIDs = library.document.tracks.filter { $0.reference.lastKnownURL.path.contains("/Album/") }.map(\.id)
        #expect(albumIDs.count == 3)
        let current = try #require(library.playlist(list)?.entries.first { $0.trackID == albumIDs[1] })
        library.selectEntry(current.id, in: list)
        let saves = store.saves
        library.excludeTracks(albumIDs)
        #expect(store.saves == saves + 1)
        #expect(library.document.tracks.map(\.reference.lastKnownURL) == [other])
        #expect(library.document.playlists.allSatisfy { $0.entries.count == 1 })
        #expect(library.document.currentEntryID == nil && library.playback.state == .empty)
        #expect(library.message == "3曲をライブラリから除外しました。")
        #expect(album.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        library.excludeTracks([])
        library.excludeTracks([UUID()])
        #expect(library.document.tracks.count == 1 && library.error == nil)
    }
}
