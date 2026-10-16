import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

@Suite(.serialized) @MainActor struct PlaylistClickTests {
    @Test(arguments: ["ready", "stopped", "finished", "paused"])
    func doubleClickStartsInactiveSelectionAndSingleClickSwitchesPlaying(_ state: String) async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var backends: [TestBackend] = []
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); backends.append(b); return b })
        let store = MemoryStore(), refs = TestReferences()
        let model = LibraryController(playback: playback, store: store, references: refs)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([try fixture.file("a.wav"), try fixture.file("b.wav")], into: list)
        let entries = try #require(model.playlist(list)?.entries)
        model.clickEntry(entries[0].id, in: list, clickCount: 1)
        #expect(playback.state == .ready)
        if state != "ready" {
            model.togglePlayPause()
            if state == "stopped" { model.stop() }
            if state == "paused" { model.togglePlayPause() }
            if state == "finished" {
                // Last entry avoids natural progression to another row.
                model.clickEntry(entries[1].id, in: list, clickCount: 1)
                backends.last?.onEvent?(.finished)
            }
        }
        let selected = try #require(model.currentEntry?.id)
        model.clickEntry(selected, in: list, clickCount: 2)
        #expect(playback.state == .playing)
        let count = backends.count
        model.clickEntry(selected, in: list, clickCount: 1)
        model.clickEntry(selected, in: list, clickCount: 2)
        #expect(playback.state == .playing && backends.count == count)
        let other = try #require(entries.first { $0.id != selected })
        model.clickEntry(other.id, in: list, clickCount: 1)
        #expect(model.currentEntry?.id == other.id && playback.state == .playing)
        model.addTracks([other.trackID], to: list)
        let duplicate = try #require(model.playlist(list)?.entries.last)
        model.clickEntry(duplicate.id, in: list, clickCount: 1)
        #expect(model.currentEntry?.id == duplicate.id && playback.state == .playing)
        let another = try #require(model.createPlaylist("別リスト"))
        model.addTracks([other.trackID], to: another)
        let cross = try #require(model.playlist(another)?.entries.first)
        model.clickEntry(cross.id, in: another, clickCount: 1)
        #expect(model.document.currentPlaylistID == another && model.currentEntry?.id == cross.id && playback.state == .playing)
        store.fail = true
        model.clickEntry(entries[0].id, in: list, clickCount: 1)
        #expect(model.currentEntry?.id == cross.id && playback.state == .playing && model.error != nil)
        store.fail = false; refs.denied.insert(model.track(entries[0].trackID)!.reference.lastKnownURL)
        model.clickEntry(entries[0].id, in: list, clickCount: 1)
        #expect(model.currentEntry?.id == cross.id && playback.state == .playing)
    }
}
