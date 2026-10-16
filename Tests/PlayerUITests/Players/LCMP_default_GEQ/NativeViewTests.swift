import AppKit
import SwiftUI
import Testing
import PlaybackCore
import LibraryCore
@testable import PlayerUI

@Suite(.serialized) @MainActor
struct NativeViewTests {
    @Test func extensionGripResizesWithStableScreenCoordinatesAndKeyboard() throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 360, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        let grip = ExtensionResizeHandle.Grip(frame: CGRect(x: 0, y: 0, width: 360, height: 10))
        container.addSubview(grip); window.contentView = container
        grip.resize = { height in
            let top = window.frame.maxY
            window.setFrame(CGRect(x: window.frame.minX, y: top - height, width: 360, height: height), display: false)
        }
        func mouse(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: CGPoint(x: 200, y: y)), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        grip.mouseDown(with: try mouse(.leftMouseDown, y: 105))
        grip.mouseDragged(with: try mouse(.leftMouseDragged, y: 25))
        #expect(window.frame.height == 380 && window.frame.maxY == 400)
        grip.mouseDragged(with: try mouse(.leftMouseDragged, y: 5))
        #expect(window.frame.height == 400 && window.frame.width == 360 && window.frame.maxY == 400)
        grip.mouseUp(with: try mouse(.leftMouseUp, y: 5))
        grip.mouseDragged(with: try mouse(.leftMouseDragged, y: 0))
        #expect(window.frame.height == 400)
        grip.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126)))
        #expect(window.frame.height == 380)
        #expect(grip.accessibilityPerformIncrement())
        #expect(window.frame.height == 400)
        #expect(grip.accessibilityPerformDecrement())
        #expect((grip.accessibilityValue() as? NSNumber)?.doubleValue == 380)
        window.contentView = nil
    }

    @Test func nativeVolumeKeysCommitAndEscapeCancels() throws {
        var value = 0.4
        var commits = 0
        var cancels = 0
        let control = NativeSlider(value: Binding(get: { value }, set: { value = $0 }),
                                   range: 0...1, vertical: true, label: "アプリ内音量")
        let coordinator = control.makeCoordinator()
        let slider = NativeSlider.CommitSlider(value: value, minValue: 0, maxValue: 1,
                           target: coordinator, action: #selector(NativeSlider.Coordinator.changed(_:)))
        slider.isVertical = true
        slider.onCommit = { commits += 1 }
        slider.onCancel = { cancels += 1 }
        func key(_ code: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            slider.keyDown(with: event)
        }
        try key(126)
        #expect(abs(value - 0.45) < 0.001)
        try key(125)
        #expect(abs(value - 0.4) < 0.001)
        #expect(commits == 2)
        try key(53)
        #expect(cancels == 1 && commits == 2)
        slider.setAccessibilityValue("0.7")
        #expect(abs(value - 0.7) < 0.001 && commits == 3)
        #expect((slider.accessibilityValue() as? NSNumber)?.doubleValue == slider.doubleValue)
        slider.isEnabled = false
        try key(126)
        slider.setAccessibilityValue("0.9")
        #expect(value == 0.7 && commits == 3)
        #expect(!slider.acceptsFirstResponder)
    }

    @Test func animationDragMovesWindowWithoutTogglingSeek() throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 360, height: 210),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = AnimationDragSurface.DragView(frame: CGRect(x: 0, y: 0, width: 360, height: 144))
        window.contentView = view
        var toggles = 0
        view.toggleSeek = { toggles += 1 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 60, y: 80)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 80, y: 90)))
        #expect(window.frame.origin == CGPoint(x: 120, y: 110))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 60, y: 80)))
        #expect(toggles == 0)
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30, y: 30)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 30, y: 30)))
        #expect(toggles == 1)
        window.contentView = nil
    }

    @Test func nativeViewsRenderWithinCompactBounds() throws {
        let playback = PlaybackController()
        let model = PlayerPresentation()
        let root = PlayerView(playback: playback, presentation: model, chooseFile: {}, toggleExtension: { model.toggleExtension() })
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: WindowLayout.mainSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == WindowLayout.mainSize)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            func capture(_ name: String) throws {
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
            try capture("main")
            model.volumeVisible = true; model.seekVisible = true
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try capture("overlays")

        }
        window.contentView = nil
    }

    @Test func playlistMembershipChoicesRenderAtCompactWidth() throws {
        // A centered parent reproduced variable indentation for different title lengths.
        let root = VStack(spacing: 10) {
            PlaylistTrackChoice(name: "凪", added: true, selected: .constant(false))
            PlaylistTrackChoice(name: "これから追加する曲", added: false, selected: .constant(false))
            PlaylistTrackChoice(name: "長い曲名も追加済の表示を残して省略されることを確認する曲", added: true, selected: .constant(true))
        }.font(.system(size: 12)).padding(12).frame(width: 360, height: 110, alignment: .leading)
            .background(PlayerGlassBackground()).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 110)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 360)
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let titles = allViews(host).compactMap { $0 as? QuickTooltip.Marker }
        #expect(titles.count == 3)
        let starts = titles.map { $0.convert($0.bounds, to: host).minX }
        if let first = starts.first { #expect(starts.allSatisfy { abs($0 - first) < 1 }) }
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("playlist-membership.png"))
        }
        window.contentView = nil
    }
}

@MainActor private final class UIStore: LibraryPersistence {
    var document: LibraryDocument
    var recoveryMessage: String? { nil }
    init(_ document: LibraryDocument) { self.document = document }
    func load() throws -> LibraryDocument { document }
    func save(_ document: LibraryDocument) throws { self.document = document }
}
@MainActor private struct UIReferences: FileReferenceProvider {
    func beginAccess(_ url: URL) -> FileLease { FileLease() }
    func makeReference(_ url: URL) throws -> TrackReference { TrackReference(bookmark: Data([1]), lastKnownURL: url) }
    func resolve(_ reference: TrackReference) throws -> ResolvedTrack {
        guard reference.bookmark != nil else { throw LibraryFailure.unavailable }
        return ResolvedTrack(url: reference.lastKnownURL, reference: reference, lease: FileLease())
    }
}
@MainActor private final class UIBackend: PlaybackBackend {
    var duration: TimeInterval = 60
    var supportsSeeking = true
    var currentTime: TimeInterval = 0
    var volume: Float = 0.25
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    func play() throws {}
    func pause() throws {}
    func resume() throws {}
    func seek(to seconds: TimeInterval) throws { currentTime = seconds }
    func stop() {}
}

@Suite(.serialized) @MainActor struct LibraryNativeViewTests {
    @Test func minusClickRemovesEntryInHostedPlaylist() async throws {
        var doc = LibraryDocument()
        let track = LibraryTrack(name: "削除確認の曲", reference: TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: "/missing-test.wav")))
        doc.tracks = [track]; doc.playlists[0].entries = [PlaylistEntry(trackID: track.id)]
        let library = LibraryController(playback: PlaybackController(), store: UIStore(doc), references: UIReferences())
        let presentation = PlayerPresentation(); presentation.toggleExtension()
        let actions = LibraryActions(files: { _ in }, folder: {}, repair: { _ in }, importPlaylist: {}, exportPlaylist: { _ in })
        let host = NSHostingView(rootView: ExtensionView(playback: library.playback, presentation: presentation, library: library, actions: actions))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let minus = try #require(allViews(host).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "削除確認の曲をリストから外す" })
        #expect(minus.bounds.width == 24 && minus.bounds.height == 32)
        #expect(minus.hitTest(NSPoint(x: minus.frame.minX + 2, y: minus.frame.minY + 2)) != nil)
        let action = try #require(minus.action)
        #expect(minus.sendAction(action, to: minus.target))
        #expect(library.document.playlists[0].entries.isEmpty)
        #expect(library.document.tracks.count == 1)
    }
    @Test func adoptedExtensionRendersCurrentRowAndFineNativeScroller() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-native-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var doc = LibraryDocument()
        for index in 0..<12 {
            let url = root.appendingPathComponent("sample-\(index).wav"); try Data([1]).write(to: url)
            let track = LibraryTrack(name: index == 6 ? "凪" : "検証用の曲 \(index + 1)", reference: TrackReference(bookmark: index == 2 ? nil : Data([1]), lastKnownURL: url))
            doc.tracks.append(track); doc.playlists[0].entries.append(PlaylistEntry(trackID: track.id))
        }
        doc.currentEntryID = doc.playlists[0].entries[6].id
        let playback = PlaybackController(makeBackend: { _ in UIBackend() })
        let library = LibraryController(playback: playback, store: UIStore(doc), references: UIReferences())
        library.restore(); library.togglePlayPause()
        let presentation = PlayerPresentation(); presentation.toggleExtension()
        let actions = LibraryActions(files: { _ in }, folder: {}, repair: { _ in }, importPlaylist: {}, exportPlaylist: { _ in })
        let host = NSHostingView(rootView: ExtensionView(playback: playback, presentation: presentation, library: library, actions: actions))
        host.frame = CGRect(origin: .zero, size: WindowLayout.extensionSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.setFrameOrigin(CGPoint(x: -10000, y: -10000)); window.orderFront(nil); host.layoutSubtreeIfNeeded(); host.display()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded(); host.display()
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.fittingSize.width <= WindowLayout.extensionSize.width)

        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let scroll = try #require(allViews(host).compactMap { $0 as? NSScrollView }.first)
        #expect(RefinedScrollStyle.FineScroller.isCompatibleWithOverlayScrollers)
        #expect(scroll.verticalScroller is RefinedScrollStyle.FineScroller)
        #expect(scroll.contentView.bounds.origin.y > 0)
        let currentRowCenter = CGFloat(6 * 46 + 22)
        #expect(scroll.contentView.bounds.minY <= currentRowCenter && scroll.contentView.bounds.maxY >= currentRowCenter)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("library-extension.png"))
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        library.togglePlayPause()
        try await Task.sleep(for: .milliseconds(100))
        #expect(scroll.contentView.bounds.origin.y == 0)
        for height in [CGFloat(240), 540] {
            window.setContentSize(CGSize(width: 360, height: height))
            host.layoutSubtreeIfNeeded(); host.display()
            try await Task.sleep(for: .milliseconds(100))
            #expect(host.bounds.size == CGSize(width: 360, height: height))
            #expect(scroll.contentSize.height > 0 && scroll.contentSize.height < height)
            if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("library-extension-\(Int(height)).png"))
            }
        }
        window.orderOut(nil); window.contentView = nil; playback.close()
    }
}

extension LibraryNativeViewTests {
    @Test func hostedRowMouseClicksReachPlaybackAndMissingSourceDetail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-row-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var doc = LibraryDocument()
        for index in 0..<3 {
            let url = root.appendingPathComponent("sample-\(index).wav"); try Data([1]).write(to: url)
            let track = LibraryTrack(name: "クリック検証 \(index)", reference: TrackReference(bookmark: index == 2 ? nil : Data([1]), lastKnownURL: url))
            doc.tracks.append(track); doc.playlists[0].entries.append(PlaylistEntry(trackID: track.id))
        }
        let playback = PlaybackController(makeBackend: { _ in UIBackend() })
        let library = LibraryController(playback: playback, store: UIStore(doc), references: UIReferences())
        defer { library.shutdown() }
        library.refreshAvailability()
        let presentation = PlayerPresentation(); presentation.toggleExtension()
        let actions = LibraryActions(files: { _ in }, folder: {}, repair: { _ in }, importPlaylist: {}, exportPlaylist: { _ in })
        let host = NSHostingView(rootView: ExtensionView(playback: playback, presentation: presentation, library: library, actions: actions))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        func click(_ index: Int, count: Int) async throws {
            host.layoutSubtreeIfNeeded()
            let id = doc.playlists[0].entries[index].id.uuidString
            let surface = try #require(allViews(host).compactMap { $0 as? PlaylistClickSurface.ClickView }.first { $0.identifier?.rawValue == id })
            let local = NSPoint(x: surface.bounds.midX, y: surface.bounds.midY)
            let location = surface.convert(local, to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            }
            window.sendEvent(try event(.leftMouseDown)); window.sendEvent(try event(.leftMouseUp))
            try await Task.sleep(for: .milliseconds(40))
        }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        try await click(0, count: 1); #expect(playback.state == .ready)
        try await click(0, count: 2); #expect(playback.state == .playing)
        try await Task.sleep(for: .milliseconds(40))
        try await click(1, count: 1); #expect(library.currentIndex == 1 && playback.state == .playing)
        try await Task.sleep(for: .milliseconds(40))
        try await click(2, count: 1); #expect(presentation.section == .source && playback.state == .playing)
    }
}

extension LibraryNativeViewTests {
    @Test func mainVolumeReopensWithoutChangingGainAndClosesOnExternalFocus() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-volume-ui-\(UUID()).wav")
        try Data([1]).write(to: rootURL); defer { try? FileManager.default.removeItem(at: rootURL) }
        let playback = PlaybackController(makeBackend: { _ in UIBackend() })
        #expect(playback.select(rootURL)); defer { playback.close() }
        let model = PlayerPresentation()
        let host = NSHostingView(rootView: PlayerView(playback: playback, presentation: model, chooseFile: {}, toggleExtension: {}))
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 210)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 460, height: 210))
        let outside = NSTextField(frame: CGRect(x: 370, y: 20, width: 80, height: 30))
        container.addSubview(host); container.addSubview(outside)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        defer { model.closeOverlays(); window.orderOut(nil); window.contentView = nil }
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        func settle() async throws {
            host.layoutSubtreeIfNeeded(); window.update()
            try await Task.sleep(for: .milliseconds(60))
        }
        for gain: Float in [0.25, 0.036, 0.75] {
            model.volumeVisible = false; playback.setVolume(gain)
            try await settle()
            model.volumeVisible = true; try await settle()
            let slider = try #require(allViews(host).compactMap { $0 as? NativeSlider.CommitSlider }.first { $0.volumeCurve })
            #expect(window.firstResponder === slider)
            #expect(abs(VolumeCurve.gain(at: slider.doubleValue) - Double(gain)) < 1e-10)
            #expect(playback.volume == gain && model.volumeVisible)
            slider.setAccessibilityValue(0.1875); try await settle()
            #expect(abs(playback.volume - 0.1875) < 1e-6 && model.volumeVisible)
            #expect(window.makeFirstResponder(outside))
            try await settle()
            #expect(!model.volumeVisible)
        }
        for state in ["STOP", "PLAY", "PAUSE"] {
            if state != "STOP" { playback.togglePlayPause() }
            try await settle()
            if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("main-\(state).png"))
            }
        }
    }
}
