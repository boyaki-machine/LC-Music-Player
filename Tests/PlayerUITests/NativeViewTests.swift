import AppKit
import SwiftUI
import Testing
import PlaybackCore
@testable import PlayerUI

@Suite(.serialized) @MainActor
struct NativeViewTests {
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
}
