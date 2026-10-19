import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

/// A Music library with the songs a test puts in it, keyed by persistent ID.
final class FakeMediaLibrary: MediaLibraryLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var songs: [UInt64: MediaLibrarySong] = [:]
    func add(_ id: UInt64, ext: String = "m4a", duration: TimeInterval = 180,
             dateAdded: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> URL {
        let url = URL(string: "ipod-library://item/item.\(ext)?id=\(id)")!
        lock.withLock { songs[id] = MediaLibrarySong(assetURL: url, duration: duration, dateAdded: dateAdded) }
        return url
    }
    func remove(_ id: UInt64) { _ = lock.withLock { songs.removeValue(forKey: id) } }
    func song(forPersistentID id: UInt64) -> MediaLibrarySong? { lock.withLock { songs[id] } }
}

@Suite @MainActor struct MediaLibraryTests {
    @Test func referenceReadsThePersistentIDFromTheAssetURL() {
        let song = TrackReference(bookmark: nil, lastKnownURL: URL(string: "ipod-library://item/item.m4a?id=1234567890123")!)
        #expect(song.mediaItemID == 1234567890123)
        #expect(TrackReference(bookmark: nil, lastKnownURL: URL(string: "ipod-library://item/item.m4a")!).mediaItemID == nil)
        #expect(TrackReference(bookmark: nil, lastKnownURL: URL(string: "ipod-library://item/item.m4a?id=x")!).mediaItemID == nil)
        #expect(TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: "/tmp/item.m4a?id=1")).mediaItemID == nil)
    }

    @Test func supportedAudioAcceptsLibrarySongsOfSupportedFormatsOnly() {
        #expect(SupportedAudio.accepts(URL(string: "ipod-library://item/item.m4a?id=1")!))
        #expect(SupportedAudio.accepts(URL(string: "ipod-library://item/item.mp3?id=1")!))
        #expect(!SupportedAudio.accepts(URL(string: "ipod-library://item/item.movpkg?id=1")!))
        #expect(!SupportedAudio.accepts(URL(string: "https://example.com/item.m4a")!))
    }

    @Test func documentAcceptsLibrarySongsButNotOtherRemoteURLs() throws {
        var document = LibraryDocument()
        document.tracks = [LibraryTrack(name: "Song", reference: TrackReference(bookmark: nil,
            lastKnownURL: URL(string: "ipod-library://item/item.m4a?id=7")!))]
        try document.validate()
        document.tracks = [LibraryTrack(name: "Song", reference: TrackReference(bookmark: nil,
            lastKnownURL: URL(string: "https://example.com/item.m4a")!))]
        #expect(throws: LibraryFailure.self) { try document.validate() }
    }

    @Test func referencesLookUpLibrarySongsEachTime() throws {
        let library = FakeMediaLibrary()
        let references = BookmarkFileReferences(mediaLibrary: library)
        let url = library.add(42)
        let reference = try references.makeReference(url)
        #expect(reference.bookmark == nil && reference.mediaItemID == 42)
        let resolved = try references.resolve(reference)
        #expect(resolved.url == url)
        library.remove(42)
        #expect(throws: LibraryFailure.self) { try references.resolve(reference) }
        #expect(throws: LibraryFailure.self) { try references.makeReference(url) }
    }

    @Test func importRegistersTitlesOnceAndPlaysTheAssetURL() async throws {
        let library = FakeMediaLibrary()
        let first = library.add(1), second = library.add(2, ext: "mp3")
        var selected: [URL] = []
        let playback = PlaybackController(makeBackend: { url in selected.append(url); return TestBackend() })
        let model = LibraryController(playback: playback, store: MemoryStore(), references: BookmarkFileReferences(mediaLibrary: library))
        let list = try #require(model.document.currentPlaylistID)
        await model.importMediaItems([M3U8Item(url: first, title: "夜の散歩"), M3U8Item(url: second, title: "Midnight Drive")], into: list)
        #expect(model.error == nil)
        #expect(model.document.tracks.map(\.name) == ["夜の散歩", "Midnight Drive"])
        #expect(model.unavailable.isEmpty)
        #expect(model.playlist(list)?.entries.count == 2)
        // The same songs again are the same tracks; the playlist gets new entries as with files.
        await model.importMediaItems([M3U8Item(url: first, title: "夜の散歩")])
        #expect(model.document.tracks.count == 2)
        model.playPlaylist(list)
        #expect(selected.last == first)
    }

    @Test func songsMissingFromTheLibraryAreNotRegistered() async throws {
        let library = FakeMediaLibrary()
        let model = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: MemoryStore(),
                                      references: BookmarkFileReferences(mediaLibrary: library))
        await model.importMediaItems([M3U8Item(url: URL(string: "ipod-library://item/item.m4a?id=9")!, title: "Gone")])
        #expect(model.document.tracks.isEmpty)
        #expect(model.error != nil)
    }

    /// The measurement cache identifies a library song by its ID, length and date added.
    @Test func measurementIdentityFollowsTheLibrarySong() throws {
        let library = FakeMediaLibrary()
        let identity = MediaLibraryMeasurementSourceIdentity(mediaLibrary: library)
        let url = library.add(7, duration: 234.666)
        let first = try #require(try identity.identity(for: url))
        #expect(try identity.identity(for: url) == first)
        #expect(first.locator == url.absoluteString && first.resource == "media-library/7" && first.size == 234_666)
        _ = library.add(7, duration: 234.667)
        #expect(try identity.identity(for: url) != first)
        _ = library.add(7, duration: 234.666, dateAdded: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try identity.identity(for: url) != first)
        _ = library.add(7, duration: 234.666)
        #expect(try identity.identity(for: url) == first)
        // Another song, an unknown or removed one, a changed asset URL and a song without length are not cached.
        #expect(try identity.identity(for: library.add(8, duration: 234.666)) != first)
        #expect(try identity.identity(for: URL(string: "ipod-library://item/item.m4a?id=9")!) == nil)
        #expect(try identity.identity(for: URL(string: "ipod-library://item/item.mp3?id=7")!) == nil)
        #expect(try identity.identity(for: URL(string: "ipod-library://item/item.m4a")!) == nil)
        #expect(try identity.identity(for: library.add(10, duration: 0)) == nil)
        library.remove(7)
        #expect(try identity.identity(for: url) == nil)
    }

    @Test func measurementIdentityLeavesFilesToTheLocalIdentity() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-identity-\(UUID()).m4a")
        try Data([1, 2, 3]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let identity = MediaLibraryMeasurementSourceIdentity(mediaLibrary: FakeMediaLibrary())
        let local = try #require(try LocalMeasurementSourceIdentity().identity(for: file))
        #expect(try identity.identity(for: file) == local)
    }

    @Test func playlistFilesKeepLibrarySongs() throws {
        let file = URL(fileURLWithPath: "/tmp/list.m3u8")
        let song = URL(string: "ipod-library://item/item.m4a?id=5")!
        let data = M3U8.encode([M3U8Item(url: song, title: "Song")], relativeTo: file)
        #expect(try M3U8.decode(data, relativeTo: file) == [M3U8Item(url: song, title: "Song")])
    }
}
