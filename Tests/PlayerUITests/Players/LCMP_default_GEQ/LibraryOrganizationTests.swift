import AppKit
import Testing
import LibraryCore
@testable import PlayerUI

@MainActor struct LibraryOrganizationTests {
    private func track(_ path: String, _ registration: TrackRegistration? = .file) -> LibraryTrack {
        LibraryTrack(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     reference: TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: path)), registration: registration)
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
