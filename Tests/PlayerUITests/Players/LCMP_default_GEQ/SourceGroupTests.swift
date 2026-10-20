import Foundation
import Testing
import LibraryCore
@testable import PlayerUI

@Suite struct SourceGroupTests {
    private func track(_ url: String, registration: TrackRegistration = .file) -> LibraryTrack {
        LibraryTrack(name: url, reference: TrackReference(bookmark: nil, lastKnownURL: URL(string: url)!), registration: registration)
    }

    @Test func librarySongsFormTheirOwnGroupEvenAlone() throws {
        let groups = SourceFolderGroup.groups([track("ipod-library://item/item.m4a?id=1"), track("file:///Music/Single/a.mp3")])
        #expect(groups.count == 2)
        let music = try #require(groups.first { $0.directory != nil })
        #expect(music.name == "ミュージック" && music.tracks.count == 1)
        #expect(groups.contains { $0.directory == nil && $0.name == "デフォルト" })
    }

    @Test func allLibrarySongsShareOneGroup() throws {
        let groups = SourceFolderGroup.groups([track("ipod-library://item/item.m4a?id=1"), track("ipod-library://item/item.mp3?id=2"),
                                               track("ipod-library://item/item.m4a?id=3")])
        #expect(groups.count == 1)
        #expect(groups.first?.name == "ミュージック" && groups.first?.tracks.count == 3)
    }

    @Test func hidingTracksKeepsTheOtherTracksInTheirGroups() throws {
        let a = track("file:///Music/Album/a.mp3"), b = track("file:///Music/Album/b.mp3")
        let single = track("file:///Music/Single/c.mp3"), song = track("ipod-library://item/item.m4a?id=1")
        let all = [a, b, single, song]
        // Hiding b leaves a alone, but a stays in its folder group instead of moving to the default group.
        let groups = SourceFolderGroup.groups(all, hiding: [b.id])
        let album = try #require(groups.first { $0.name == "Album" })
        #expect(album.tracks.map(\.id) == [a.id])
        #expect(groups.first { $0.directory == nil }?.tracks.map(\.id) == [single.id])
        // A group whose tracks are all hidden is left out; nothing hidden keeps every group.
        #expect(SourceFolderGroup.groups(all, hiding: [song.id]).map(\.name).contains("ミュージック") == false)
        #expect(SourceFolderGroup.groups(all, hiding: []).map(\.id) == SourceFolderGroup.groups(all).map(\.id))
        #expect(SourceFolderGroup.groups(all, hiding: Set(all.map(\.id))).isEmpty)
    }

    @MainActor @Test func hidingAddedTracksIsOffByDefaultAndKept() {
        let preferences = MemoryPreferences()
        let presentation = PlayerPresentation(preferences: preferences)
        #expect(!presentation.hidesAddedTracks)
        presentation.setHidesAddedTracks(true)
        #expect(presentation.hidesAddedTracks)
        #expect(PlayerPresentation(preferences: preferences).hidesAddedTracks)
        presentation.setHidesAddedTracks(false)
        #expect(!PlayerPresentation(preferences: preferences).hidesAddedTracks)
    }

    @Test func filesStillGroupByFolder() {
        let groups = SourceFolderGroup.groups([track("file:///Music/Album/a.mp3"), track("file:///Music/Album/b.mp3")])
        #expect(groups.map(\.name) == ["Album"])
    }
}
