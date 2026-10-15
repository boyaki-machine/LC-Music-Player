import AppKit
import SwiftUI

extension View {
    func quickHelp(_ text: String, when enabled: Bool = true) -> some View { background(QuickTooltip(text: text, enabled: enabled)) }
}

/// Compare the actual rendered width with an uncompressed copy in the same font.
struct OverflowTitle: View {
    let name: String
    var help: String? = nil
    @State private var fullWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    var body: some View {
        Text(verbatim: name).lineLimit(1)
            .background {
                GeometryReader { geometry in Color.clear.preference(key: VisibleTitleWidth.self, value: geometry.size.width) }
            }
            .background {
                Text(verbatim: name).lineLimit(1).fixedSize(horizontal: true, vertical: false).hidden().accessibilityHidden(true)
                    .background { GeometryReader { geometry in Color.clear.preference(key: FullTitleWidth.self, value: geometry.size.width) } }
            }
            .onPreferenceChange(FullTitleWidth.self) { fullWidth = $0 }
            .onPreferenceChange(VisibleTitleWidth.self) { visibleWidth = $0 }
            .quickHelp(help ?? name, when: visibleWidth > 0 && fullWidth > visibleWidth + 0.5)
    }
    private struct FullTitleWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
    private struct VisibleTitleWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
}

/// Track-title help with an app-local delay; the panel never takes clicks or focus.
struct QuickTooltip: NSViewRepresentable {
    var text: String
    var enabled = true
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        if view.text != text { view.dismiss(); view.text = text }
        if view.isTooltipEnabled != enabled { view.dismiss(); view.isTooltipEnabled = enabled }
    }
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.detach() }

    final class Marker: NSView {
        static let delay: Duration = .milliseconds(350)
        var text = ""
        var isTooltipEnabled = true
        private var pending: Task<Void, Never>?
        private(set) var panel: NSPanel?
        private var tracking: NSTrackingArea?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); detach()
            guard let window else { return }
            for name in [NSWindow.willCloseNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        override func mouseEntered(with event: NSEvent) { beginHover() }
        override func mouseExited(with event: NSEvent) { dismiss() }
        func beginHover() {
            dismiss()
            guard isTooltipEnabled else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.dismiss() }
                return event
            }
            pending = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: Self.delay) } catch { return }
                guard !Task.isCancelled else { return }
                self?.show()
            }
        }
        private func show() {
            guard isTooltipEnabled, let window, window.isVisible, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty, !text.isEmpty else { return }
            let screen = window.screen ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            let width = min(320, max(120, visible.width - 16))
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12); label.textColor = .labelColor
            label.preferredMaxLayoutWidth = width - 16
            let height = min(visible.height - 16, ceil(label.fittingSize.height) + 16)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true; panel.level = .popUpMenu
            panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .darkAqua)
            let surface = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            surface.material = .popover; surface.state = .active
            surface.wantsLayer = true; surface.layer?.cornerRadius = 6; surface.layer?.masksToBounds = true
            label.frame = NSRect(x: 8, y: 8, width: width - 16, height: height - 16)
            surface.addSubview(label); panel.contentView = surface
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let y = anchor.minY - height - 4 >= visible.minY ? anchor.minY - height - 4 : anchor.maxY + 4
            panel.setFrameOrigin(NSPoint(x: min(max(anchor.minX, visible.minX + 8), visible.maxX - width - 8),
                                         y: min(max(y, visible.minY + 8), visible.maxY - height - 8)))
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil); self.panel = panel
        }
        func dismiss() {
            pending?.cancel(); pending = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); self.panel = nil }
        }
        func detach() {
            dismiss()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
        }
    }
}
