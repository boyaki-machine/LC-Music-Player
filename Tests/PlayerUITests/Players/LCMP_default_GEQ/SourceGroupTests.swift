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

    @Test func filesStillGroupByFolder() {
        let groups = SourceFolderGroup.groups([track("file:///Music/Album/a.mp3"), track("file:///Music/Album/b.mp3")])
        #expect(groups.map(\.name) == ["Album"])
    }
}
