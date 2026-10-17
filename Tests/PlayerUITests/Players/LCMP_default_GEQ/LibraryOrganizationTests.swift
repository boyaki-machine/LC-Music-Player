import AppKit
import Testing
import LibraryCore
@testable import PlayerUI

@MainActor struct LibraryOrganizationTests {
    private func track(_ path: String, _ registration: TrackRegistration? = .file) -> LibraryTrack {
        LibraryTrack(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     reference: TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: path)), registration: registration)
    }

    @Test func filesFromOneFolderFormAGroupOnceTwoArriveOrAFolderIsRegistered() {
        let single = track("/Music/Single/only.wav")
        let first = track("/Music/Album/1.wav"), later = track("/Music/Album/2.wav", nil)
        let joined = track("/Music/Folder/added later.wav"), folder = track("/Music/Folder/registered.wav", .folder)
        let groups = SourceFolderGroup.groups([first, single, joined, later, folder])
        #expect(groups.map(\.name) == ["デフォルト", "Album", "Folder"])
        #expect(groups[0].tracks.map(\.id) == [single.id])
        #expect(groups[1].tracks.map(\.id) == [first.id, later.id])
        #expect(groups[2].tracks.map(\.id) == [joined.id, folder.id])
        // Removing the second file returns the first to the default group.
        #expect(SourceFolderGroup.groups([first, single]).map(\.name) == ["デフォルト"])
        #expect(SourceFolderGroup.groups([first, single]).first?.tracks.count == 2)
    }

    @Test func versionComesFromTheBundleOrReadsAsDevelopment() {
        #expect(AppVersion.text(["CFBundleShortVersionString": "0.18.42", "CFBundleVersion": "0.18.42"]) == "0.18.42")
        #expect(AppVersion.text(["CFBundleShortVersionString": "0.18.42"]) == "0.18.42")
        #expect(AppVersion.text(["CFBundleShortVersionString": ""]) == "開発版")
        #expect(AppVersion.displayName == "LC Music Player (LCMP)")
        #expect(AppVersion.text(["CFBundleVersion": "3"]) == "開発版")
        #expect(AppVersion.text(nil) == "開発版")
    }
}
