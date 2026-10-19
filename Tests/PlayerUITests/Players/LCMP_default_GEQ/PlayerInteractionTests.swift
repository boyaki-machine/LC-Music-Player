#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PlayerUI

@Suite(.serialized) @MainActor struct PlayerInteractionTests {
    @Test func volumeCurveHasContinuousJoinAndRoundTripsExistingGain() {
        #expect(VolumeCurve.gain(at: 0) == 0)
        #expect(abs(VolumeCurve.gain(at: 0.1) - 0.036) < 1e-12)
        #expect(VolumeCurve.gain(at: 0.25) == 0.1875)
        var previous = -1.0
        for n in 0...1000 {
            let position = Double(n) / 1000
            let gain = VolumeCurve.gain(at: position)
            #expect(gain > previous)
            #expect(abs(VolumeCurve.position(for: gain) - position) < 1e-10)
            if position >= 0.5 { #expect(gain == position) }
            previous = gain
        }
        let epsilon = 1e-6
        #expect(abs((0.5 - VolumeCurve.gain(at: 0.5 - epsilon)) / epsilon - 1) < 1e-5)
        #expect(VolumeCurve.gain(at: .nan) == 0 && VolumeCurve.position(for: .infinity) == 0)
        #expect(VolumeCurve.gain(at: -1) == 0 && VolumeCurve.position(for: 2) == 1)
    }

    @Test func nonlinearKeysAndAccessibilityUseActualVolume() throws {
        var gain = 0.036
        let control = NativeSlider(value: Binding(get: { gain }, set: { gain = $0 }), range: 0...1,
                                   vertical: true, label: "音量", volumeCurve: true)
        let coordinator = control.makeCoordinator()
        let slider = NativeSlider.CommitSlider(value: 0.1, minValue: 0, maxValue: 1,
            target: coordinator, action: #selector(NativeSlider.Coordinator.changed(_:)))
        slider.volumeCurve = true; slider.isVertical = true
        #expect(slider.accessibilityPerformIncrement())
        #expect(abs(gain - 0.0765) < 1e-10)
        slider.setAccessibilityValue(0.1875)
        #expect(abs(slider.doubleValue - 0.25) < 1e-10)
        #expect(abs(gain - 0.1875) < 1e-10)
        #expect(abs((slider.accessibilityValue() as? NSNumber)!.doubleValue - gain) < 1e-10)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        slider.keyDown(with: event)
        #expect(abs(gain - 0.128) < 1e-10)
        slider.isEnabled = false
        slider.setAccessibilityValue(1)
        #expect(!slider.accessibilityPerformIncrement() && abs(gain - 0.128) < 1e-10)
    }

    @Test func volumeInactivityResetsAndNeverInterruptsTracking() async throws {
        let model = PlayerPresentation(volumeHideDelay: .milliseconds(80))
        model.volumeVisible = true
        try await Task.sleep(for: .milliseconds(40))
        model.volumeInteraction()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.volumeVisible)
        model.trackVolume(true)
        try await Task.sleep(for: .milliseconds(120))
        model.volumeInteraction()
        #expect(model.volumeVisible)
        model.trackVolume(false)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!model.volumeVisible)
        model.volumeVisible = true; model.closeOverlays()
        model.volumeVisible = true; model.trackVolume(true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.volumeVisible)
        model.closeOverlays()
    }

    @Test func focusScopeIncludesInternalButtonButDismissesExternalFocus() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 210),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 210))
        let scope = VolumeFocusView(frame: CGRect(x: 200, y: 60, width: 54, height: 132))
        let slider = NativeSlider.CommitSlider(frame: CGRect(x: 10, y: 50, width: 28, height: 64))
        let mute = NSButton(title: "ミュート", target: nil, action: nil)
        let outside = NativeSlider.CommitSlider(frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        mute.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        scope.addSubview(slider); scope.addSubview(mute)
        root.addSubview(scope); root.addSubview(outside); window.contentView = root
        var dismissals = 0; scope.dismiss = { dismissals += 1 }
        #expect(window.makeFirstResponder(slider)); scope.checkFocus()
        #expect(window.makeFirstResponder(mute)); scope.checkFocus()
        #expect(dismissals == 0)
        #expect(window.makeFirstResponder(outside))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(dismissals == 1)
        scope.stop(); window.contentView = nil
    }

    @Test func mouseSurfaceSeparatesDoubleClickFromDragAndOutsideRelease() throws {
        let view = PlaylistClickSurface.ClickView(frame: CGRect(x: 0, y: 0, width: 220, height: 44))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        var counts: [Int] = []; view.click = { counts.append($0) }
        func event(_ type: NSEvent.EventType, count: Int, x: Double = 10) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 20), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        for count in [1, 2, 3] {
            view.mouseDown(with: try event(.leftMouseDown, count: count))
            view.mouseUp(with: try event(.leftMouseUp, count: count))
        }
        view.mouseDown(with: try event(.leftMouseDown, count: 1))
        view.mouseDragged(with: try event(.leftMouseDragged, count: 1, x: 80))
        view.mouseUp(with: try event(.leftMouseUp, count: 1, x: 80))
        view.mouseDown(with: try event(.leftMouseDown, count: 2))
        view.mouseUp(with: try event(.leftMouseUp, count: 2, x: 230))
        #expect(counts == [1, 2])
        window.contentView = nil
    }
}
#endif
