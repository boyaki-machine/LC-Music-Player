#if os(macOS)
import AppKit
#endif
import SwiftUI

#if os(macOS)
/// Fixed native button rectangles keep thin glyphs easy to click.
struct PlaylistRowActions: NSViewRepresentable {
    let name: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ActionStrip {
        let stack = ActionStrip(frame: NSRect(x: 0, y: 0, width: 72, height: 32))
        for (index, symbol) in ["chevron.up", "chevron.down", "minus"].enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
            button.image = button.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
            button.isBordered = false; button.setButtonType(.momentaryPushIn); button.tag = index
            button.contentTintColor = NSColor.white.withAlphaComponent(0.55)
            button.frame = NSRect(x: index * 24, y: 0, width: 24, height: 32)
            stack.addSubview(button)
        }
        return stack
    }
    func updateNSView(_ view: ActionStrip, context: Context) {
        context.coordinator.parent = self
        for (index, button) in view.subviews.compactMap({ $0 as? NSButton }).enumerated() {
            button.isEnabled = [canMoveUp, canMoveDown, canRemove][index]
            let label = name + ["を上へ", "を下へ", "をリストから外す"][index]
            button.setAccessibilityLabel(label); button.toolTip = label
        }
    }
    final class ActionStrip: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 72, height: 32) }
        override func layout() {
            super.layout()
            for (index, button) in subviews.enumerated() { button.frame = NSRect(x: index * 24, y: 0, width: 24, height: 32) }
        }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: PlaylistRowActions
        init(_ parent: PlaylistRowActions) { self.parent = parent }
        @objc func clicked(_ sender: NSButton) {
            switch sender.tag {
            case 0: if parent.canMoveUp { parent.moveUp() }
            case 1: if parent.canMoveDown { parent.moveDown() }
            default: if parent.canRemove { parent.remove() }
            }
        }
    }
}

#endif

struct PlaylistTrackChoice: View {
    let name: String
    let added: Bool
    @Binding var selected: Bool
    var body: some View {
        Toggle(isOn: $selected) {
            HStack(spacing: 6) {
                OverflowTitle(name: name, help: name + "\n" + (added ? "このプレイリストに追加済みです。再度選ぶと重複して追加します。" : "このプレイリストに追加します。"))
                    .foregroundStyle(added ? Color.white.opacity(0.55) : Color.white.opacity(0.85))
                if added { Text("追加済").font(.ui(10)).foregroundStyle(Color(red: 0.65, green: 0.79, blue: 0.72)).fixedSize() }
            }
        }.toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(name)\(added ? "、このプレイリストに追加済" : "")")
    }
}

#if os(macOS)
/// A narrow bottom grip preserves the borderless glass window's shape.
struct ExtensionResizeHandle: NSViewRepresentable {
    var resize: (CGFloat) -> Void
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ view: Grip, context: Context) { view.resize = resize }

    final class Grip: NSView {
        var resize: (CGFloat) -> Void = { _ in }
        private var initialMouseY: CGFloat?
        private var initialHeight: CGFloat = 0
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.splitter)
            setAccessibilityLabel("拡張ウィンドウの高さ")
            setAccessibilityHelp("上下にドラッグ、または上下キーで高さを変更します。")
            toolTip = "上下にドラッグして高さを変更"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func draw(_ dirtyRect: NSRect) {
            (window?.firstResponder === self ? NSColor.white.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.2)).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 12, y: bounds.midY - 1, width: 24, height: 2), xRadius: 1, yRadius: 1).fill()
        }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            window.makeFirstResponder(self)
            initialHeight = window.frame.height
            initialMouseY = window.convertPoint(toScreen: event.locationInWindow).y
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let initialMouseY else { return }
            resize(initialHeight + initialMouseY - window.convertPoint(toScreen: event.locationInWindow).y)
        }
        override func mouseUp(with event: NSEvent) { initialMouseY = nil }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: changeHeight(-20)
            case 125: changeHeight(20)
            default: super.keyDown(with: event)
            }
        }
        private func changeHeight(_ delta: CGFloat) { if let window { resize(window.frame.height + delta) } }
        override func accessibilityValue() -> Any? { window.map { NSNumber(value: Double($0.frame.height)) } }
        override func accessibilityPerformIncrement() -> Bool { changeHeight(20); return window != nil }
        override func accessibilityPerformDecrement() -> Bool { changeHeight(-20); return window != nil }
    }
}

/// The hit area stays native; only the scroller's visible knob is reduced.
struct RefinedScrollStyle: NSViewRepresentable {
    var revealID: UUID? = nil
    var rowIndex: Int? = nil
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        view.revealID = revealID; view.rowIndex = rowIndex; view.configureLater()
    }
    final class Marker: NSView {
        var revealID: UUID?
        var rowIndex: Int?
        private var revealed: UUID?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureLater() }
        override func layout() { super.layout(); configureLater() }
        func configureLater() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else { return }
                scroll.drawsBackground = false
                scroll.autohidesScrollers = true
                if !(scroll.verticalScroller is FineScroller) {
                    let scroller = FineScroller(); scroller.scrollerStyle = .overlay
                    scroll.verticalScroller = scroller
                    scroll.scrollerStyle = .overlay
                }
                guard let self, let token = self.revealID, token != self.revealed,
                      let index = self.rowIndex, let document = scroll.documentView,
                      scroll.contentSize.height > 0, document.frame.height > 0 else { return }
                // Rows have a fixed 44pt height and 2pt spacing. Reveal once per opening,
                // after native layout, without competing with the user's scrolling.
                let y = max(0, min(document.frame.height - scroll.contentSize.height,
                                   CGFloat(index) * 46 + 22 - scroll.contentSize.height / 2))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                self.revealed = token
            }
        }
    }
    final class FineScroller: NSScroller {
        override class var isCompatibleWithOverlayScrollers: Bool { true }
        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
        override func drawKnob() {
            let slot = rect(for: .knob)
            let knob = NSRect(x: slot.midX - 1.5, y: slot.minY + 1, width: 3, height: max(0, slot.height - 2))
            NSColor.white.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: knob, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

#endif

struct PlayerGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            GlassSurface(reducedTransparency: reduceTransparency)
            Color(red: 0.12, green: 0.13, blue: 0.14).opacity(reduceTransparency ? 1 : 0.65)
        }
    }
}
struct SoftGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.ui(12)).padding(.horizontal, 9).padding(.vertical, 6)
            .foregroundStyle(Color(red: 0.79, green: 0.91, blue: 0.84).opacity(enabled ? 1 : 0.35))
            .background(.white.opacity(enabled ? (configuration.isPressed ? 0.13 : 0.07) : 0.03), in: RoundedRectangle(cornerRadius: 5))
    }
}
/// Shuffle mode toggle. The pictogram glows softly like an LED while shuffle is on and stays
/// near-dark while playback follows the playlist order.
struct ShuffleToggle: View {
    static let litColor = Color(red: 0.62, green: 0.91, blue: 0.74)
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "shuffle").font(.ui(13, weight: .medium))
                .foregroundStyle(isOn ? Self.litColor : .white.opacity(0.3))
                .shadow(color: isOn ? Self.litColor.opacity(0.6) : .clear, radius: 4)
                // A 32×28pt hit area that does not make the header row taller.
                .frame(width: 32, height: 28).contentShape(Rectangle()).padding(.vertical, -6)
        }.buttonStyle(.plain).help("ランダム再生").accessibilityLabel("ランダム再生")
            .accessibilityValue(isOn ? "オン" : "オフ").accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
