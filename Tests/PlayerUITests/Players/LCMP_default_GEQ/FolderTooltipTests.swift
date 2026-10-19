#if os(macOS)
import AppKit
import SwiftUI
import Testing
import LibraryCore
@testable import PlayerUI

@Suite(.serialized) @MainActor struct FolderTooltipTests {
    @Test func onlyTruncatedTitlesEnableHelpAndResizingUpdatesEligibility() async throws {
        let root = OverflowTitle(name: "Long Artist — 長い曲名の末尾まで表示できる幅と省略が必要な幅を切り替えて確認する曲")
            .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        let host = NSHostingView(rootView: root); host.frame = NSRect(x: 0, y: 0, width: 100, height: 32)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let marker = try #require(allViews(host).compactMap { $0 as? QuickTooltip.Marker }.first)
        #expect(marker.isTooltipEnabled)
        window.setContentSize(NSSize(width: 1000, height: 32)); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!marker.isTooltipEnabled)
        marker.beginHover()
        try await Task.sleep(for: .milliseconds(400))
        #expect(marker.panel == nil)
        window.setContentSize(NSSize(width: 100, height: 32)); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(marker.isTooltipEnabled)
    }
    private func track(_ path: String) -> LibraryTrack {
        LibraryTrack(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                     reference: TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: path)), registration: .folder)
    }
    @Test func groupingUsesFullParentPathWithoutLosingTracksOrTheirOrder() {
        let a = track("/Music/Artist A/Album/first.wav")
        let b = track("/Music/Artist B/Album/second.wav")
        let c = track("/Music/Artist A/Album/third.wav")
        let d = track("/Music/Artist A/Album/Disc 2/fourth.wav")
        let groups = SourceFolderGroup.groups([a, b, c, d])
        #expect(groups.count == 3)
        #expect(groups.filter { $0.name == "Album" }.count == 2)
        #expect(Set(groups.map(\.id)).count == 3)
        #expect(groups.first { $0.directory?.path == "/Music/Artist A/Album" }?.tracks.map(\.id) == [a.id, c.id])
        #expect(Set(groups.flatMap(\.tracks).map(\.id)) == Set([a.id, b.id, c.id, d.id]))
        #expect(SourceFolderGroup.groups([]).isEmpty)
    }
    @Test func individualAndLegacySourcesShareDefaultGroup() {
        var file = track("/Music/Elsewhere/file.wav"); file.registration = .file
        var legacy = track("/Old/another.wav"); legacy.registration = nil
        let folder = track("/Music/Album/folder.wav")
        let groups = SourceFolderGroup.groups([file, folder, legacy])
        #expect(groups.count == 2)
        #expect(groups.first?.name == "デフォルト")
        #expect(groups.first?.tracks.map(\.id) == [file.id, legacy.id])
    }
    @Test func tooltipDelayCancellationAndNonactivatingPresentation() async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 210),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 210))
        let marker = QuickTooltip.Marker(frame: NSRect(x: 12, y: 120, width: 240, height: 44))
        marker.text = "Long Artist — とても長い曲名の末尾まで省略せずに確認できるツールチップの確認用タイトル"
        container.addSubview(marker); window.contentView = container; window.orderFront(nil)
        defer { marker.detach(); window.orderOut(nil); window.contentView = nil }
        marker.beginHover()
        try await Task.sleep(for: .milliseconds(100))
        #expect(marker.panel == nil)
        try await Task.sleep(for: .milliseconds(320))
        let panel = try #require(marker.panel)
        #expect(panel.isVisible && !panel.isKeyWindow && panel.ignoresMouseEvents)
        #expect(panel.parent === window)
        let label = try #require(panel.contentView?.subviews.first as? NSTextField)
        #expect(label.stringValue == marker.text)
        #expect(label.frame.height >= label.fittingSize.height)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"], let view = panel.contentView {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("quick-tooltip.png"))
        }
        marker.dismiss()
        #expect(marker.panel == nil && panel.parent == nil && !panel.isVisible)
        marker.beginHover(); marker.dismiss()
        try await Task.sleep(for: .milliseconds(400))
        #expect(marker.panel == nil)
        marker.beginHover()
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        try await Task.sleep(for: .milliseconds(400))
        #expect(marker.panel == nil)
    }
    @Test func folderListRendersNamesAndCounts() throws {
        let tracks = [track("/Music/Artist A/Album/長い曲名のサンプルでフォルダ内の曲も省略できる.wav"),
                      track("/Music/Artist A/Album/凪.wav"), track("/Music/Artist B/Album/夜の曲.mp3")]
        let root = SourceFolderList(tracks: tracks, unavailable: [tracks[1].id: "ファイルが見つかりません"], select: { _ in })
            .font(.system(size: 12)).padding(12).frame(width: 360, height: 300, alignment: .topLeading)
            .background(PlayerGlassBackground()).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root); host.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 360)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("source-folders.png"))
        }
        window.contentView = nil
    }
}
#endif
