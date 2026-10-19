#if os(macOS)
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

    @Test func dragDistanceSnapsToRowsWithinTheList() {
        let pitch = PlaylistReorder.pitch
        #expect(PlaylistReorder.target(from: 2, offset: 0, count: 5) == 2)
        #expect(PlaylistReorder.target(from: 2, offset: pitch * 0.49, count: 5) == 2)
        #expect(PlaylistReorder.target(from: 2, offset: pitch * 0.51, count: 5) == 3)
        #expect(PlaylistReorder.target(from: 2, offset: -pitch * 1.6, count: 5) == 0)
        #expect(PlaylistReorder.target(from: 2, offset: pitch * 30, count: 5) == 4)
        #expect(PlaylistReorder.target(from: 0, offset: -pitch * 30, count: 5) == 0)
        #expect(PlaylistReorder.target(from: 0, offset: 10, count: 0) == 0)
        #expect(PlaylistReorder.destination(from: 2, target: 4) == 5)
        #expect(PlaylistReorder.destination(from: 2, target: 0) == 0)
    }

    @Test func clickSurfaceDragNeverClicksAndReportsDistance() throws {
        let view = PlaylistClickSurface.ClickView(frame: CGRect(x: 0, y: 0, width: 220, height: 44))
        view.tracksDragInLoop = false
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 220, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        var clicks: [Int] = [], phases: [PlaylistRowDrag] = []
        view.click = { clicks.append($0) }; view.drag = { phases.append($0) }
        func event(_ type: NSEvent.EventType, y: Double) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 10, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, y: 20))
        view.mouseDragged(with: try event(.leftMouseDragged, y: 17))
        #expect(phases.isEmpty)
        view.mouseDragged(with: try event(.leftMouseDragged, y: 0))
        view.mouseUp(with: try event(.leftMouseUp, y: -30))
        #expect(phases == [.moved(20), .ended(50)] && clicks.isEmpty)
        phases = []
        view.mouseDown(with: try event(.leftMouseDown, y: 20))
        view.mouseDragged(with: try event(.leftMouseDragged, y: 40))
        view.cancelOperation(nil)
        view.mouseUp(with: try event(.leftMouseUp, y: 40))
        #expect(phases == [.moved(-20), .cancelled] && clicks.isEmpty)
        view.mouseDown(with: try event(.leftMouseDown, y: 20))
        view.mouseUp(with: try event(.leftMouseUp, y: 21))
        #expect(clicks == [1])
    }
}
#endif
