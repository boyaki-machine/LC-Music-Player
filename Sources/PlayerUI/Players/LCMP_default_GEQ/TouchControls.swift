#if os(iOS)
import SwiftUI
import UIKit

// iOS counterparts of the AppKit-backed controls. They keep the macOS names and parameters
// so the shared views compile unchanged; touch replaces the pointer, focus and hover behavior.

struct GlassSurface: View {
    let reducedTransparency: Bool
    var body: some View {
        if !reducedTransparency { Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark) }
    }
}

/// A tap toggles the seek bar. iOS presents the player full screen, so there is no window to drag.
struct AnimationDragSurface: View {
    let toggleSeek: () -> Void
    var body: some View {
        Color.clear.contentShape(Rectangle()).onTapGesture(perform: toggleSeek)
            .accessibilityElement()
            .accessibilityLabel("シークバーの表示切替")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, toggleSeek)
    }
}

/// A thin track with a round knob. The whole frame takes touches; a drag sets the value from
/// the touch position and commits on release.
struct NativeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let vertical: Bool
    let label: String
    var commit: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil
    var focusChanged: ((Bool) -> Void)? = nil
    var volumeCurve = false
    var trackingChanged: ((Bool) -> Void)? = nil
    @Environment(\.isEnabled) private var enabled
    @State private var tracking = false
    private static let inset: CGFloat = 6

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var fraction: Double {
        let position = volumeCurve ? VolumeCurve.position(for: value) : value
        return min(1, max(0, (position - range.lowerBound) / span))
    }
    private func setFraction(_ proposed: Double) {
        let position = range.lowerBound + min(1, max(0, proposed)) * span
        value = volumeCurve ? VolumeCurve.gain(at: position) : position
    }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let length = max(0, (vertical ? size.height : size.width) - 2 * Self.inset)
            let filled = length * fraction
            ZStack {
                Capsule().fill(.white.opacity(enabled ? 0.24 : 0.08))
                    .frame(width: vertical ? 3 : length, height: vertical ? length : 3)
                    .position(x: size.width / 2, y: size.height / 2)
                if enabled {
                    Capsule().fill(Color.green.opacity(0.8))
                        .frame(width: vertical ? 3 : filled, height: vertical ? filled : 3)
                        .position(x: vertical ? size.width / 2 : Self.inset + filled / 2,
                                  y: vertical ? size.height - Self.inset - filled / 2 : size.height / 2)
                }
                Circle().fill(.white.opacity(enabled ? 0.9 : 0.2)).frame(width: 12, height: 12)
                    .position(x: vertical ? size.width / 2 : Self.inset + filled,
                              y: vertical ? size.height - Self.inset - filled : size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard enabled, length > 0 else { return }
                if !tracking { tracking = true; trackingChanged?(true); focusChanged?(true) }
                setFraction(vertical ? (size.height - Self.inset - drag.location.y) / length
                                     : (drag.location.x - Self.inset) / length)
            }.onEnded { _ in
                guard tracking else { return }
                tracking = false; trackingChanged?(false); commit?(); focusChanged?(false)
            })
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(volumeCurve ? "\(Int((value * 100).rounded()))%" : timeText(value))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            let step = vertical ? 0.05 : min(5 / span, 0.05)
            setFraction(fraction + (direction == .increment ? step : -step))
            commit?()
        }
    }
}

/// Touch has no outside-click monitor; the player closes popups with its own tap target.
@MainActor final class VolumeOutsideClickHandler {}

struct VolumeClickRegion: View {
    let handler: VolumeOutsideClickHandler
    var isPopup = false
    var dismiss: (() -> Void)? = nil
    var body: some View { Color.clear.allowsHitTesting(false) }
}

struct VolumeFocusScope<Content: View>: View {
    let content: Content
    let dismiss: () -> Void
    var body: some View { content }
}

/// Touch has no hover, so titles show no delayed tooltip.
struct QuickTooltip: View {
    var text: String
    var enabled = true
    var body: some View { Color.clear.allowsHitTesting(false) }
}

/// The same three row actions as macOS, each with a 44pt-tall touch target.
struct PlaylistRowActions: View {
    let name: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            action("chevron.up", "を上へ", canMoveUp, moveUp)
            action("chevron.down", "を下へ", canMoveDown, moveDown)
            action("minus", "をリストから外す", canRemove, remove)
        }
    }
    private func action(_ symbol: String, _ suffix: String, _ enabled: Bool, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 30, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.white.opacity(enabled ? 0.55 : 0.2)).disabled(!enabled)
            .accessibilityLabel(name + suffix)
    }
}

/// The extension fills the screen below the player on iOS, so it has no resize grip.
struct ExtensionResizeHandle: View {
    var resize: (CGFloat) -> Void
    var body: some View { EmptyView() }
}

/// Reveals the current row once per opening, like macOS, by finding the enclosing UIScrollView.
struct RefinedScrollStyle: UIViewRepresentable {
    var revealID: UUID? = nil
    var rowIndex: Int? = nil
    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) {
        view.revealID = revealID; view.rowIndex = rowIndex; view.configureLater()
    }
    final class Marker: UIView {
        var revealID: UUID?
        var rowIndex: Int?
        private var revealed: UUID?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false; backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); configureLater() }
        override func layoutSubviews() { super.layoutSubviews(); configureLater() }
        func configureLater() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                scroll.indicatorStyle = .white
                guard let token = self.revealID, token != self.revealed, let index = self.rowIndex,
                      scroll.bounds.height > 0, scroll.contentSize.height > 0 else { return }
                let y = max(0, min(scroll.contentSize.height - scroll.bounds.height,
                                   CGFloat(index) * PlaylistReorder.pitch + 22 - scroll.bounds.height / 2))
                scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                self.revealed = token
            }
        }
        private var enclosingScrollView: UIScrollView? {
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView { return scroll }
                view = current.superview
            }
            return nil
        }
    }
}

/// A tap is click count 1 and a double tap is 2, matching the macOS row semantics.
/// A long press lifts the row; the following drag reorders it.
/// The gestures are UIKit recognizers on a plain view, as table cells have: a tap or a long press
/// fails when the finger moves first, so a flick that starts on a row scrolls the list. SwiftUI
/// gestures (a long press sequenced before a drag, also as a UIGestureRecognizerRepresentable)
/// kept the touch from the enclosing scroll view, and the list could not be scrolled from its rows.
struct PlaylistClickSurface: UIViewRepresentable {
    let entryID: UUID
    var drag: ((PlaylistRowDrag) -> Void)? = nil
    let click: (Int) -> Void
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.click = click; view.drag = drag; view.press.isEnabled = drag != nil
    }
    final class Surface: UIView {
        var click: (Int) -> Void = { _ in }
        var drag: ((PlaylistRowDrag) -> Void)?
        let press = UILongPressGestureRecognizer()
        private var start: CGFloat = 0
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
            double.numberOfTapsRequired = 2
            let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
            single.require(toFail: double)
            press.minimumPressDuration = 0.35
            press.addTarget(self, action: #selector(pressed(_:)))
            [double, single, press].forEach(addGestureRecognizer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func tapped() { click(1) }
        @objc private func doubleTapped() { click(2) }
        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            // Window coordinates: the lifted row moves with the finger, so its own space would not do.
            let y = recognizer.location(in: nil).y
            switch recognizer.state {
            case .began: start = y; drag?(.moved(0))
            case .changed: drag?(.moved(y - start))
            case .ended: drag?(.ended(y - start))
            case .cancelled, .failed: drag?(.cancelled)
            default: break
            }
        }
    }
}

struct LCMPCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? ShuffleToggle.litColor : .white.opacity(0.5))
                configuration.label
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
extension ToggleStyle where Self == LCMPCheckboxToggleStyle {
    static var checkbox: LCMPCheckboxToggleStyle { LCMPCheckboxToggleStyle() }
}
#endif
