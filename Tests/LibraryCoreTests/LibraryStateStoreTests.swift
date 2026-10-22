import Foundation
import Testing
@testable import LibraryCore

/// The state that changes with every song is saved apart from the library and applied only to the
/// library file it was written for.
@Suite(.serialized) @MainActor struct LibraryStateStoreTests {
    private func document(tracks: Int = 3) -> LibraryDocument {
        var doc = LibraryDocument()
        for n in 0..<tracks {
            doc.tracks.append(LibraryTrack(name: "\(n)", reference: TrackReference(bookmark: Data([UInt8(n)]), lastKnownURL: URL(fileURLWithPath: "/music/\(n).wav"))))
        }
        doc.playlists[0].entries = doc.tracks.map { PlaylistEntry(trackID: $0.id) }
        return doc
    }
    private func files(_ store: JSONLibraryStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path).sorted()
    }

    @Test func songChangesWriteOnlyTheStateAndEditsWriteTheLibrary() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = JSONLibraryStore(url: f.root.appendingPathComponent("library.json"))
        _ = try store.load()
        var doc = document()
        try store.save(doc)
        let library = try Data(contentsOf: store.url), stamp = FileStamp(store.url)
        for entry in doc.playlists[0].entries {
            doc.currentEntryID = entry.id
            doc.shuffleCycles = [ShuffleCycle(playlistID: doc.playlists[0].id, first: entry.id)]
            try store.save(doc)
            #expect(FileStamp(store.url) == stamp)
            #expect(try Data(contentsOf: store.url) == library)
            #expect(try JSONLibraryStore(url: store.url).load() == doc)
        }
        #expect(try files(store) == ["library-state.json", "library.json", "library.json.backup"])
        // An edit writes the library with the state, keeps the previous library as the backup
        // and leaves no state file behind.
        doc.playlists[0].name = "編集"
        try store.save(doc)
        #expect(try files(store) == ["library.json", "library.json.backup"])
        #expect(try JSONLibraryStore(url: store.url).load() == doc)
        let backup = try JSONDecoder().decode(LibraryDocument.self, from: Data(contentsOf: store.backupURL))
        #expect(backup.playlists[0].name != "編集" && backup.currentEntryID == nil)
        for name in try files(store) {
            let attributes = try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent(name).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "\(name)")
        }
    }

    @Test func aStateThatDoesNotBelongToTheLibraryIsIgnored() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = JSONLibraryStore(url: f.root.appendingPathComponent("library.json"))
        _ = try store.load()
        var doc = document()
        try store.save(doc)
        let saved = doc
        doc.currentEntryID = doc.playlists[0].entries[1].id
        try store.save(doc)
        // Another version of the app rewrote the library: the state was for the old file.
        try Data(contentsOf: store.url).write(to: store.url, options: .atomic)
        #expect(try JSONLibraryStore(url: store.url).load() == saved)
        // A broken state, or one naming an entry the library lacks, is ignored too.
        let fresh = JSONLibraryStore(url: store.url); _ = try fresh.load()
        try fresh.save(doc); var other = doc; other.currentEntryID = doc.playlists[0].entries[2].id; try fresh.save(other)
        #expect(try JSONLibraryStore(url: store.url).load() == other)
        try Data("broken".utf8).write(to: fresh.stateURL)
        #expect(try JSONLibraryStore(url: store.url).load() == saved)
        var state = LibraryState(other); state.library = FileStamp(store.url); state.currentEntryID = UUID()
        try JSONEncoder().encode(state).write(to: fresh.stateURL)
        #expect(try JSONLibraryStore(url: store.url).load() == saved)
    }

    @Test func anotherWriterOfTheStateIsDetected() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let path = f.root.appendingPathComponent("library.json")
        let first = JSONLibraryStore(url: path); _ = try first.load()
        var doc = document(); try first.save(doc)
        let second = JSONLibraryStore(url: path); _ = try second.load()
        doc.currentEntryID = doc.playlists[0].entries[0].id
        try second.save(doc)
        doc.currentEntryID = doc.playlists[0].entries[1].id
        #expect(throws: LibraryFailure.self) { try first.save(doc) }
    }

    @Test func onlyTheNewestDamagedLibrariesAreKept() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let path = f.root.appendingPathComponent("library.json")
        let store = JSONLibraryStore(url: path); _ = try store.load()
        let doc = document(); try store.save(doc); try store.save(doc)
        for n in 0..<5 {
            try Data("broken \(n)".utf8).write(to: path)
            let recovering = JSONLibraryStore(url: path)
            #expect(try recovering.load() == doc)
            #expect(recovering.recoveryMessage != nil)
            try recovering.save(doc)
            let fine = JSONLibraryStore(url: path); #expect(try fine.load() == doc); try fine.save(doc)
        }
        let damaged = try files(store).filter { $0.hasPrefix("library.json.damaged-") }
        #expect(damaged.count == JSONLibraryStore.damagedLimit)
        let kept = try damaged.map { try String(contentsOf: f.root.appendingPathComponent($0), encoding: .utf8) }.sorted()
        #expect(kept == ["broken 2", "broken 3", "broken 4"])
    }
}
