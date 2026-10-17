import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

@MainActor final class MemoryStore: LibraryPersistence {
    var document = LibraryDocument()
    var fail = false
    var recoveryMessage: String? { nil }
    func load() throws -> LibraryDocument { document }
    func save(_ document: LibraryDocument) throws { if fail { throw LibraryFailure.inaccessible }; self.document = document }
}
@MainActor final class TestReferences: FileReferenceProvider {
    let scopes = ScopeCounter()
    var moved: [URL: URL] = [:]
    var denied: Set<URL> = []
    func beginAccess(_ url: URL) -> FileLease { FileLease() }
    func makeReference(_ url: URL) throws -> TrackReference {
        guard !denied.contains(url), FileManager.default.fileExists(atPath: url.path) else { throw LibraryFailure.inaccessible }
        return TrackReference(bookmark: Data(url.absoluteString.utf8), lastKnownURL: url)
    }
    func resolve(_ reference: TrackReference) throws -> ResolvedTrack {
        guard reference.bookmark != nil else { throw LibraryFailure.unavailable }
        let url = moved[reference.lastKnownURL] ?? reference.lastKnownURL
        let updated = try makeReference(url)
        scopes.acquire()
        return ResolvedTrack(url: url, reference: updated, lease: FileLease { [scopes] in scopes.release() })
    }
}
final class ScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var highWater = 0
    var active: Int { lock.withLock { count } }
    var maximum: Int { lock.withLock { highWater } }
    func acquire() { lock.withLock { count += 1; highWater = max(highWater, count) } }
    func release() { lock.withLock { count -= 1 } }
}
@MainActor final class CountingRealReferences: FileReferenceProvider {
    let scopes = ScopeCounter()
    private let base = BookmarkFileReferences()
    func beginAccess(_ url: URL) -> FileLease { base.beginAccess(url) }
    func makeReference(_ url: URL) throws -> TrackReference { try base.makeReference(url) }
    func resolve(_ reference: TrackReference) throws -> ResolvedTrack {
        let resolved = try base.resolve(reference)
        scopes.acquire()
        return ResolvedTrack(url: resolved.url, reference: resolved.reference,
            lease: FileLease { [scopes, underlying = resolved.lease] in
                withExtendedLifetime(underlying) {}; scopes.release()
            })
    }
}
@MainActor final class TestBackend: PlaybackBackend {
    var duration: TimeInterval = 10
    var supportsSeeking = true
    var currentTime: TimeInterval = 0
    var volume: Float = 0.25
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playCount = 0
    func play() throws { playCount += 1 }
    func pause() throws {}
    func resume() throws {}
    func seek(to seconds: TimeInterval) throws { currentTime = seconds }
    func stop() {}
}
struct Fixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-library-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original fixture".utf8).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) @MainActor struct LibraryTests {
    @Test func bookmarkAccessHasOneOwnerAndIsReleasedBetweenRuns() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let refs = TestReferences(); var backends: [TestBackend] = []
        let store = MemoryStore()
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); backends.append(b); return b })
        let model = LibraryController(playback: playback, store: store, references: refs)
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([try f.file("a.wav"), try f.file("b.wav")], into: list)
        #expect(refs.scopes.active == 0)
        model.selectEntry(try #require(model.playlist(list)?.entries.first?.id), in: list)
        #expect(refs.scopes.active == 0)
        model.togglePlayPause()
        #expect(refs.scopes.active == 1)
        let playingBackend = try #require(backends.last)
        store.fail = true; model.next()
        #expect(playback.state == .playing && model.currentIndex == 0 && refs.scopes.active == 1)
        store.fail = false
        playingBackend.onEvent?(.finished)
        #expect(model.currentIndex == 1 && playback.state == .playing && refs.scopes.active == 1)
        backends.last?.onEvent?(.finished)
        #expect(playback.state == .finished && refs.scopes.active == 0)
        for _ in 0..<3 {
            model.togglePlayPause(); #expect(refs.scopes.active == 1)
            playback.stop(); #expect(refs.scopes.active == 0)
            playback.seek(to: 3); #expect(refs.scopes.active == 0)
        }
        model.togglePlayPause(); model.togglePlayPause()
        #expect(playback.state == .paused && refs.scopes.active == 1)
        model.shutdown(); #expect(refs.scopes.active == 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"), arguments: ["wav", "mp3"])
    func twoRealTracksFinishIdleThenShutdown(format: String) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        func wav(_ name: String) throws -> URL {
            let url = f.root.appendingPathComponent(name)
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
            func number<T: FixedWidthInteger>(_ n: T) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            let frames = 8820
            ascii("RIFF"); number(UInt32(36 + frames * 2)); ascii("WAVEfmt "); number(UInt32(16))
            number(UInt16(1)); number(UInt16(1)); number(UInt32(44100)); number(UInt32(88200)); number(UInt16(2)); number(UInt16(16))
            ascii("data"); number(UInt32(frames * 2))
            for i in 0..<frames { number(Int16(sin(Double(i) * 2 * .pi * 440 / 44100) * 100)) }
            try data.write(to: url); return url
        }
        let playback = PlaybackController(); playback.setVolume(0.005)
        let refs = CountingRealReferences()
        let model = LibraryController(playback: playback, store: MemoryStore(), references: refs)
        let list = try #require(model.document.currentPlaylistID)
        if format == "mp3" {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("PlaybackCoreTests/Fixtures/tone.mp3")
            let a = f.root.appendingPathComponent("a.mp3"), b = f.root.appendingPathComponent("b.mp3")
            let bytes = try Data(contentsOf: fixture); try bytes.write(to: a); try bytes.write(to: b)
            await model.importFiles([a, b], into: list)
        } else { await model.importFiles([try wav("a.wav"), try wav("b.wav")], into: list) }
        model.playPlaylist(list)
        let deadline = ContinuousClock.now + .seconds(8)
        while !(model.currentIndex == 1 && playback.state == .finished), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.currentIndex == 1 && playback.state == .finished)
        #expect(refs.scopes.active == 0)
        playback.seek(to: playback.duration / 2)
        #expect(playback.state == .stopped && refs.scopes.active == 0)
        model.togglePlayPause()
        let replayDeadline = ContinuousClock.now + .seconds(5)
        while playback.state == .playing, ContinuousClock.now < replayDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(playback.state == .finished && refs.scopes.active == 0)
        model.togglePlayPause(); playback.stop()
        #expect(playback.state == .stopped && refs.scopes.active == 0)
        model.togglePlayPause()
        let finalDeadline = ContinuousClock.now + .seconds(5)
        while playback.state == .playing, ContinuousClock.now < finalDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(playback.state == .finished && refs.scopes.active == 0)
        try await Task.sleep(for: .seconds(2))
        model.shutdown()
        #expect(playback.state == .empty && !model.canEdit)
    }
    @Test func registrationOriginSurvivesRestartAndFolderRegistrationPromotesExistingFile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = try f.file("Album/song.wav"), store = MemoryStore()
        let model = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: TestReferences())
        await model.importFiles([file])
        #expect(model.document.tracks.first?.registration == .file)
        await model.importFiles([file.deletingLastPathComponent()])
        #expect(model.document.tracks.count == 1 && model.document.tracks.first?.registration == .folder)
        let restored = try JSONDecoder().decode(LibraryDocument.self, from: JSONEncoder().encode(model.document))
        #expect(restored.tracks.first?.registration == .folder)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        tracks[0].removeValue(forKey: "registration"); json["tracks"] = tracks
        let legacy = try JSONDecoder().decode(LibraryDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.tracks.first?.registration == nil)
        model.shutdown()
        #expect(model.playback.state == .empty && !model.canEdit && model.playback.onNaturalFinish == nil)
        let before = model.document
        model.removeEntry(UUID(), from: model.document.playlists[0].id)
        await model.importFiles([file])
        #expect(model.document == before)
    }
    @Test func atomicStoreRecoveryAndFutureVersionProtection() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let path = f.root.appendingPathComponent("state/library.json")
        let store = JSONLibraryStore(url: path)
        var doc = try store.load(); try store.save(doc)
        let original = doc
        doc.playlists[0].name = "更新"; try store.save(doc)
        try Data("broken".utf8).write(to: path)
        let recovered = JSONLibraryStore(url: path)
        #expect(try recovered.load() == original)
        #expect(recovered.recoveryMessage != nil)
        try recovered.save(original)
        #expect(try JSONLibraryStore(url: path).load() == original)
        let saved = try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
        #expect(saved.contains { $0.contains("damaged-") })
        // Paths and bookmarks are personal data: every library file is owner-only.
        let directory = try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for name in saved {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().appendingPathComponent(name).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "\(name)")
        }
        try Data("{\"schemaVersion\":999}".utf8).write(to: path)
        #expect(throws: (any Error).self) { try JSONLibraryStore(url: path).load() }
        #expect(try String(contentsOf: path, encoding: .utf8).contains("999"))
    }
    @Test func failedAtomicWriteKeepsLastDocumentAndInvalidReferencesAreRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let path = f.root.appendingPathComponent("library.json")
        let store = JSONLibraryStore(url: path); let doc = try store.load(); try store.save(doc)
        let before = try Data(contentsOf: path)
        let failing = JSONLibraryStore(url: path) { data, url in
            if url == path { throw LibraryFailure.inaccessible }
            try data.write(to: url, options: .atomic)
        }
        var next = try failing.load(); next.playlists[0].name = "失敗する編集"
        #expect(throws: (any Error).self) { try failing.save(next) }
        #expect(try Data(contentsOf: path) == before)
        next.playlists[0].entries = [PlaylistEntry(trackID: UUID())]
        #expect(throws: (any Error).self) { try next.validate() }
    }
    @Test func editsRestoreIDsOrderAndDuplicateEntriesWithoutCopyingAudio() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.wav"), b = try f.file("b.flac")
        let original = try Data(contentsOf: a)
        let store = JSONLibraryStore(url: f.root.appendingPathComponent("state/library.json"))
        let refs = TestReferences(), playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let model = LibraryController(playback: playback, store: store, references: refs)
        await model.importFiles([b, a])
        await model.importFiles([a])
        #expect(model.document.tracks.count == 2)
        let listID = try #require(model.createPlaylist("もうひとつ"))
        let ids = model.document.tracks.map(\.id)
        model.addTracks([ids[0], ids[1], ids[0]], to: listID)
        let entries = try #require(model.playlist(listID)).entries
        #expect(Set(entries.map(\.id)).count == 3)
        model.selectEntry(entries[0].id, in: listID)
        model.moveEntry(entries[0].id, in: listID, offset: 1)
        #expect(model.document.currentEntryID == entries[0].id)
        let reopened = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: JSONLibraryStore(url: store.url), references: refs)
        reopened.restore()
        #expect(reopened.document == model.document)
        #expect(reopened.playback.state == .ready)
        #expect(try Data(contentsOf: a) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted() == ["a.wav", "b.flac", "state"])
    }
    @Test func queueFinishesInOrderAndOldEventsCannotAdvanceIt() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.wav"), b = try f.file("b.wav")
        var backends: [TestBackend] = []
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); backends.append(b); return b })
        let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences())
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list)
        model.playPlaylist(list)
        let old = try #require(backends.last?.onEvent)
        old(.finished)
        let second = try #require(model.currentEntry?.id)
        #expect(model.currentIndex == 1 && playback.state == .playing)
        old(.finished)
        #expect(model.currentEntry?.id == second)
        backends.last?.onEvent?(.finished)
        #expect(playback.state == .finished && model.currentIndex == 1)
        model.previous(); #expect(playback.state == .ready && model.currentIndex == 0)
    }
    @Test func missingNextStopsAndSourceRepairKeepsEntryIDs() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.wav"), b = try f.file("b.wav")
        let refs = TestReferences(); var backends: [TestBackend] = []
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); backends.append(b); return b })
        let model = LibraryController(playback: playback, store: MemoryStore(), references: refs)
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list)
        let entryIDs = try #require(model.playlist(list)).entries.map(\.id)
        model.playPlaylist(list); try FileManager.default.removeItem(at: b)
        backends.last?.onEvent?(.finished)
        #expect(model.currentIndex == 0 && playback.state == .finished && model.error != nil)
        let missing = try #require(model.document.tracks.first { $0.reference.lastKnownURL == b })
        #expect(model.unavailable[missing.id] != nil)
        let replacement = try f.file("moved.wav")
        model.repairTrack(missing.id, using: replacement)
        #expect(model.unavailable[missing.id] == nil)
        #expect(model.playlist(list)?.entries.map(\.id) == entryIDs)
        model.next(); #expect(model.currentIndex == 1 && playback.state == .ready)
        model.excludeTrack(missing.id)
        #expect(playback.state == .empty && model.currentEntry == nil)
        #expect(FileManager.default.fileExists(atPath: replacement.path))
    }
    @Test func saveFailurePreservesAudioAndEditingState() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.file("a.wav"), b = try f.file("b.wav"), store = MemoryStore()
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let model = LibraryController(playback: playback, store: store, references: TestReferences())
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list); model.playPlaylist(list)
        let before = model.document, url = playback.selectedURL
        store.fail = true
        model.next()
        #expect(playback.state == .playing && playback.selectedURL == url && model.document == before)
        model.renamePlaylist(list, name: "保存不可"); #expect(model.document == before)
        model.removeEntry(try #require(model.currentEntry?.id), from: list)
        #expect(model.document == before && playback.state == .playing)
    }
    @Test func playingFromPreparedSeekKeepsPositionAndMovedFileCanBeReopened() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = try f.file("original.wav"), replacement = try f.file("renamed.wav")
        let refs = TestReferences()
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let model = LibraryController(playback: playback, store: MemoryStore(), references: refs)
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([original], into: list)
        model.selectEntry(try #require(model.playlist(list)?.entries.first?.id), in: list)
        playback.seek(to: 4)
        model.togglePlayPause()
        #expect(playback.state == .playing && playback.currentTime == 4)
        playback.stop()
        refs.moved[original] = replacement
        model.togglePlayPause()
        #expect(playback.state == .playing && playback.selectedURL == replacement)
    }
    @Test func folderDiscoverySkipsHiddenPackagesLinksAndPreservesFiles() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let good = try f.file("album/song.wav")
        _ = try f.file(".hidden.wav"); _ = try f.file("ignore.txt"); _ = try f.file("Ignored.app/inside.wav")
        let outside = try Fixture(); defer { outside.cleanup() }; _ = try outside.file("outside.wav")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("linked"), withDestinationURL: outside.root)
        let found = try AudioDiscovery.files(in: [f.root])
        #expect(found.map(\.path) == [good.path])
    }
    @Test func repairingMissingRestoredCurrentTrackMakesPlayAvailable() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = try f.file("missing.wav"), replacement = try f.file("replacement.wav")
        let store = MemoryStore(), refs = TestReferences()
        let first = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: refs)
        let list = try #require(first.document.currentPlaylistID)
        await first.importFiles([original], into: list)
        let entry = try #require(first.playlist(list)?.entries.first)
        first.selectEntry(entry.id, in: list)
        try FileManager.default.removeItem(at: original)
        let restored = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: refs)
        restored.restore()
        #expect(restored.playback.state == .empty)
        restored.repairTrack(entry.trackID, using: replacement)
        #expect(restored.playback.state == .ready && restored.playback.canPlay)
        #expect(restored.currentEntry?.id == entry.id)
        restored.togglePlayPause()
        #expect(restored.playback.state == .playing && restored.playback.selectedURL == replacement)
    }
    @Test func m3u8UnicodeRelativeDuplicatesMissingAndHostileLists() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let song = try f.file("音楽/凪.wav"), playlist = f.root.appendingPathComponent("list.m3u8")
        let data = M3U8.encode([M3U8Item(url: song, title: "凪"), M3U8Item(url: song)], relativeTo: playlist)
        #expect(String(decoding: data, as: UTF8.self).contains("./音楽/凪.wav"))
        #expect(try M3U8.decode(data, relativeTo: playlist).map(\.url) == [song, song])
        #expect(throws: (any Error).self) { try M3U8.decode(Data("#EXTM3U\n#EXT-X-VERSION:3\nsegment.ts".utf8), relativeTo: playlist) }
        #expect(throws: (any Error).self) { try M3U8.decode(Data("https://example.invalid/song.mp3".utf8), relativeTo: playlist) }
        #expect(throws: (any Error).self) { try M3U8.decode(Data([0xff]), relativeTo: playlist) }
        let many = Data(String(repeating: "a.mp3\n", count: M3U8.maximumItems + 1).utf8)
        #expect(throws: (any Error).self) { try M3U8.decode(many, relativeTo: playlist) }
        #expect(try M3U8.decode(Data(String(repeating: "a.mp3\n", count: M3U8.maximumItems).utf8), relativeTo: playlist).count == M3U8.maximumItems)
        let oversized = f.root.appendingPathComponent("oversized.m3u8")
        try Data(count: M3U8.maximumBytes + 1).write(to: oversized)
        #expect(throws: (any Error).self) { try M3U8.read(oversized) }
        try (String(decoding: data, as: UTF8.self) + "./missing.flac\n").write(to: playlist, atomically: true, encoding: .utf8)
        let model = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: MemoryStore(), references: TestReferences())
        await model.importM3U8(playlist)
        #expect(model.document.tracks.count == 2 && model.document.playlists.last?.entries.count == 3)
        #expect(model.unavailable.count == 1)
        let out = f.root.appendingPathComponent("export.m3u8")
        model.exportM3U8(try #require(model.document.playlists.last?.id), to: out)
        #expect(try M3U8.decode(Data(contentsOf: out), relativeTo: out).map(\.url) == [song, song, f.root.appendingPathComponent("missing.flac")])
    }
    @Test func corruptUnrecoverableStoreIsReadOnly() throws {
        let f = try Fixture(); defer { f.cleanup() }; let url = try f.file("library.json")
        let model = LibraryController(playback: PlaybackController(), store: JSONLibraryStore(url: url), references: TestReferences())
        #expect(!model.editsEnabled && model.createPlaylist("上書きしない") == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "original fixture")
    }
}

@Suite(.serialized) @MainActor struct ReferenceAndStoreTests {
    @Test func realReadOnlyBookmarksFollowRenameRefreshAndDetectDeletion() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = try f.file("original.wav"), renamed = f.root.appendingPathComponent("renamed.wav")
        let bytes = try Data(contentsOf: original), refs = BookmarkFileReferences()
        let reference = try refs.makeReference(original)
        try FileManager.default.moveItem(at: original, to: renamed)
        let resolved = try refs.resolve(reference)
        #expect(resolved.url.lastPathComponent == "renamed.wav")
        #expect(try Data(contentsOf: resolved.url) == bytes)
        #expect(try refs.resolve(resolved.reference).reference == resolved.reference)
        try FileManager.default.removeItem(at: renamed)
        #expect(throws: (any Error).self) { try refs.resolve(resolved.reference) }
    }
    @Test func anotherWriterNeverGetsOverwritten() throws {
        let f = try Fixture(); defer { f.cleanup() }; let path = f.root.appendingPathComponent("library.json")
        let first = JSONLibraryStore(url: path); var doc = try first.load(); try first.save(doc)
        let second = JSONLibraryStore(url: path); _ = try second.load()
        doc.playlists[0].name = "別の保存"; try first.save(doc)
        #expect(throws: (any Error).self) { try second.save(LibraryDocument()) }
        #expect(try JSONLibraryStore(url: path).load() == doc)
    }
    @Test func minusRemovesOneDuplicateWithoutChangingPlayingEntry() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let url = try f.file("same.wav")
        let model = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: MemoryStore(), references: TestReferences())
        let listID = try #require(model.document.currentPlaylistID)
        await model.importFiles([url], into: listID)
        model.addTracks([try #require(model.document.tracks.first?.id)], to: listID)
        let entries = try #require(model.playlist(listID)).entries
        model.selectEntry(entries[1].id, in: listID, autoPlay: true)
        model.removeEntry(entries[0].id, from: listID)
        #expect(model.currentEntry?.id == entries[1].id && model.playback.state == .playing)
        model.removeEntry(entries[1].id, from: listID)
        #expect(model.playback.state == .empty && model.document.tracks.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test func m3u8ControlCharactersUseEncodedFileURLs() throws {
        let file = URL(fileURLWithPath: "/music/line\nbreak.wav"), list = URL(fileURLWithPath: "/music/list.m3u8")
        let encoded = M3U8.encode([M3U8Item(url: file, title: "one\ntwo")], relativeTo: list)
        #expect(try M3U8.decode(encoded, relativeTo: list) == [M3U8Item(url: file, title: "one two")])
    }
}
