import Foundation
import Testing
import LibraryCore
@testable import PlayerUI

@Suite struct SourceGroupTests {
    private func track(_ url: String, registration: TrackRegistration = .file, tags: TrackTags? = nil) -> LibraryTrack {
        LibraryTrack(name: url, reference: TrackReference(bookmark: nil, lastKnownURL: URL(string: url)!), registration: registration, tags: tags)
    }
    private func album(_ title: String, artist: String = "Band", disc: Int? = nil, track: Int? = nil) -> TrackTags {
        TrackTags(album: title, albumArtist: artist, disc: disc, track: track)
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

    // MARK: Albums

    @Test func filesAndLibrarySongsOfOneAlbumShareAGroupInDiscAndTrackOrder() throws {
        let c = track("file:///Rips/Two/c.flac", tags: album("Night", disc: 2, track: 1))
        let a = track("file:///Rips/One/a.mp3", tags: album("night", disc: 1, track: 2))
        let b = track("ipod-library://item/item.m4a?id=1", tags: album("NIGHT", disc: 1, track: 1))
        let unnumbered = track("file:///Rips/One/z.mp3", tags: album("Night"))
        let groups = SourceFolderGroup.groups([c, unnumbered, a, b])
        #expect(groups.count == 1)
        let night = try #require(groups.first)
        #expect(night.isAlbum && night.isRemovable && night.directory == nil)
        #expect(night.name == "Night" && night.kindName == "アルバム")
        // Disc 1 track 1, disc 1 track 2, the unnumbered track (disc 1 assumed, after the numbered), then disc 2.
        #expect(night.tracks.map(\.id) == [b.id, a.id, unnumbered.id, c.id])
    }

    @Test func aSingleAlbumTrackFollowsTheFolderRules() throws {
        let alone = track("file:///Music/Single/a.mp3", tags: album("Only One"))
        let song = track("ipod-library://item/item.m4a?id=1", tags: album("Lonely"))
        let groups = SourceFolderGroup.groups([alone, song])
        #expect(!groups.contains { $0.isAlbum })
        #expect(groups.first { $0.kind == .unsorted }?.tracks.map(\.id) == [alone.id])
        #expect(groups.first { $0.name == "ミュージック" }?.tracks.map(\.id) == [song.id])
    }

    @Test func tracksLeftOutOfAnAlbumFormFoldersOnlyByThemselves() throws {
        // Two album tracks and one untagged file in the same folder: the untagged file stays alone,
        // so it goes to the default group unless it was registered with its folder.
        let one = track("file:///Music/Album/1.mp3", tags: album("Album")), two = track("file:///Music/Album/2.mp3", tags: album("Album"))
        let bonus = track("file:///Music/Album/bonus.mp3")
        var groups = SourceFolderGroup.groups([one, two, bonus])
        #expect(groups.map(\.name) == ["デフォルト", "Album"])
        #expect(groups.first { $0.isAlbum }?.tracks.count == 2)
        let registered = track("file:///Music/Album/bonus.mp3", registration: .folder)
        groups = SourceFolderGroup.groups([one, two, registered])
        #expect(groups.map(\.kind) == [.album(key: try #require(one.tags?.albumKey), title: "Album", artist: "Band"),
                                       .folder(URL(string: "file:///Music/Album/")!)])
    }

    @Test func albumsWithTheSameTitleShowTheirArtists() throws {
        let groups = SourceFolderGroup.groups([
            track("file:///A/1.mp3", tags: album("Greatest Hits", artist: "Alpha")), track("file:///A/2.mp3", tags: album("Greatest Hits", artist: "Alpha")),
            track("file:///B/1.mp3", tags: album("greatest hits", artist: "Beta")), track("file:///B/2.mp3", tags: album("greatest hits", artist: "Beta")),
            track("file:///C/1.mp3", tags: album("Other", artist: "Gamma")), track("file:///C/2.mp3", tags: album("Other", artist: "Gamma")),
        ])
        #expect(groups.map(\.name) == ["Greatest Hits — Alpha", "greatest hits — Beta", "Other"])
        #expect(Set(groups.map(\.id)).count == 3)
    }

    @Test func groupsAreOrderedDefaultLibraryAlbumsThenFolders() throws {
        let groups = SourceFolderGroup.groups([
            track("file:///Music/Zeta/1.mp3"), track("file:///Music/Zeta/2.mp3"),
            track("file:///Rips/z.mp3", tags: album("Blue")), track("file:///Rips/y.mp3", tags: album("Blue")),
            track("file:///Rips/x.mp3", tags: album("Amber")), track("file:///Other/w.mp3", tags: album("Amber")),
            track("ipod-library://item/item.m4a?id=1"), track("file:///Single/s.mp3"),
            track("file:///Music/Alpha/1.mp3"), track("file:///Music/Alpha/2.mp3"),
        ])
        #expect(groups.map(\.name) == ["デフォルト", "ミュージック", "Amber", "Blue", "Alpha", "Zeta"])
        #expect(groups.filter(\.isRemovable).count == 5)
    }

    @Test func hidingTracksKeepsAlbums() throws {
        let a = track("file:///Rips/a.mp3", tags: album("Album")), b = track("file:///Rips/b.mp3", tags: album("Album"))
        let groups = SourceFolderGroup.groups([a, b], hiding: [b.id])
        #expect(groups.count == 1 && groups.first?.isAlbum == true && groups.first?.tracks.map(\.id) == [a.id])
    }
}
