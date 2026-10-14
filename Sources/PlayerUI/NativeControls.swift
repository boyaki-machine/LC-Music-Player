import AppKit
import SwiftUI

struct GlassSurface: NSViewRepresentable {
    let reducedTransparency: Bool
    func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.isHidden = reducedTransparency
    }
}

struct AnimationDragSurface: NSViewRepresentable {
    let toggleSeek: () -> Void
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.toggleSeek = toggleSeek }

    final class DragView: NSView {
        var toggleSeek: (() -> Void)?
        private var pointerOrigin = CGPoint.zero
        private var windowOrigin = CGPoint.zero
        private var dragging = false
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("シークバーの表示切替")
            setAccessibilityHelp("ドラッグでウィンドウを移動します。")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func mouseDown(with event: NSEvent) {
            pointerOrigin = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            windowOrigin = window?.frame.origin ?? .zero
            dragging = false
        }
        override func mouseDragged(with event: NSEvent) {
            let point = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            let dx = point.x - pointerOrigin.x, dy = point.y - pointerOrigin.y
            if hypot(dx, dy) >= 6 { dragging = true }
            if dragging { window?.setFrameOrigin(CGPoint(x: windowOrigin.x + dx, y: windowOrigin.y + dy)) }
        }
        override func mouseUp(with event: NSEvent) {
            let point = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            let moved = hypot(point.x - pointerOrigin.x, point.y - pointerOrigin.y) >= 6
            if !dragging && !moved && bounds.contains(convert(event.locationInWindow, from: nil)) { toggleSeek?() }
            dragging = false
        }
        override func accessibilityPerformPress() -> Bool { toggleSeek?(); return true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 || event.keyCode == 36 { toggleSeek?() }
            else if event.keyCode == 48 {
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
            } else { super.keyDown(with: event) }
        }
    }
}

/// AppKit provides native vertical direction, arrow keys, and AX increment/decrement.
struct NativeSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let vertical: Bool
    let label: String
    var commit: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = CommitSlider(frame: .zero)
        slider.cell = ThinSliderCell()
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound; slider.doubleValue = value
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.isVertical = vertical
        slider.focusOnAttach = true
        slider.isEnabled = context.environment.isEnabled
        slider.isContinuous = true
        slider.controlSize = .small
        slider.onCommit = { context.coordinator.parent.commit?() }
        slider.onCancel = { context.coordinator.parent.cancel?() }
        slider.setAccessibilityLabel(label)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isEnabled = context.environment.isEnabled
        if !slider.isEnabled, slider.window?.firstResponder === slider { slider.window?.makeFirstResponder(nil) }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: NativeSlider
        init(_ parent: NativeSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
    final class CommitSlider: NSSlider {
        var onCommit: (() -> Void)?
        var focusOnAttach = false
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { isEnabled }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if focusOnAttach { window?.makeFirstResponder(self) }
        }
        override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); onCommit?() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return }
            guard isEnabled else { return }
            let increase = isVertical ? event.keyCode == 126 : event.keyCode == 124
            let decrease = isVertical ? event.keyCode == 125 : event.keyCode == 123
            if increase || decrease {
                let step = isVertical ? (maxValue - minValue) / 20 : min(5, (maxValue - minValue) / 20)
                doubleValue = min(maxValue, max(minValue, doubleValue + (increase ? step : -step)))
                if let action { sendAction(action, to: target) }
                onCommit?()
            } else { super.keyDown(with: event) }
        }
        override func accessibilityValue() -> Any? { NSNumber(value: doubleValue) }
        override func setAccessibilityValue(_ value: Any?) {
            let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
            guard isEnabled, let number, number.isFinite else { return }
            doubleValue = min(maxValue, max(minValue, number))
            if let action { sendAction(action, to: target) }
            onCommit?()
        }
        override func accessibilityPerformIncrement() -> Bool { adjustAccessibility(1) }
        override func accessibilityPerformDecrement() -> Bool { adjustAccessibility(-1) }
        private func adjustAccessibility(_ direction: Double) -> Bool {
            guard isEnabled else { return false }
            let step = isVertical ? (maxValue - minValue) / 20 : min(5, (maxValue - minValue) / 20)
            setAccessibilityValue(doubleValue + step * direction)
            return true
        }
    }
}

/// Retain NSSlider tracking and AX behavior while matching the thin visual surface.
@MainActor
private final class ThinSliderCell: NSSliderCell {
    private var fraction: CGFloat { maxValue > minValue ? CGFloat((doubleValue - minValue) / (maxValue - minValue)) : 0 }
    override func barRect(flipped: Bool) -> NSRect {
        let bounds = controlView?.bounds ?? .zero
        return isVertical ? NSRect(x: bounds.midX - 1, y: bounds.minY + 4, width: 2, height: max(0, bounds.height - 8))
                          : NSRect(x: bounds.minX + 4, y: bounds.midY - 1, width: max(0, bounds.width - 8), height: 2)
    }
    override func knobRect(flipped: Bool) -> NSRect {
        let bar = barRect(flipped: flipped)
        let progress = isVertical && flipped ? 1 - fraction : fraction
        let center = isVertical ? CGPoint(x: bar.midX, y: bar.minY + bar.height * progress)
                                : CGPoint(x: bar.minX + bar.width * progress, y: bar.midY)
        return NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
    }
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        NSColor.white.withAlphaComponent(isEnabled ? 0.24 : 0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        guard isEnabled else { return }
        var fill = rect
        if isVertical {
            fill.size.height *= fraction
            if flipped { fill.origin.y = rect.maxY - fill.height }
        } else { fill.size.width *= fraction }
        NSColor.systemGreen.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        NSColor.white.withAlphaComponent(isEnabled ? 0.9 : 0.2).setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }
}

/// Observe clicks without consuming them; the volume toggle keeps its own action.
@MainActor
final class VolumeOutsideClickHandler {
    weak var popup: NSView?
    weak var toggle: NSView?
    var dismiss: (() -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let popup = self.popup else { return }
                func contains(_ view: NSView?) -> Bool {
                    guard let view, let window = view.window, event.window === window else { return false }
                    return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                }
                if !contains(popup) && !contains(self.toggle) { self.dismiss?() }
            }
            return event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; popup = nil; dismiss = nil
    }
}

struct VolumeClickRegion: NSViewRepresentable {
    let handler: VolumeOutsideClickHandler
    var isPopup = false
    var dismiss: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(handler: handler, isPopup: isPopup) }
    func makeNSView(context: Context) -> PassThroughView { PassThroughView() }
    func updateNSView(_ view: PassThroughView, context: Context) {
        if isPopup {
            handler.popup = view; handler.dismiss = dismiss; handler.start()
        } else { handler.toggle = view }
    }
    static func dismantleNSView(_ view: PassThroughView, coordinator: Coordinator) {
        if coordinator.isPopup { coordinator.handler.stop() }
    }
    @MainActor final class Coordinator {
        let handler: VolumeOutsideClickHandler
        let isPopup: Bool
        init(handler: VolumeOutsideClickHandler, isPopup: Bool) { self.handler = handler; self.isPopup = isPopup }
    }
    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
