import AppKit
import SwiftUI

/// UI position only. PlaybackCore continues to own the actual linear gain.
enum VolumeCurve {
    static func gain(at position: Double) -> Double {
        let x = position.isFinite ? min(1, max(0, position)) : 0
        return x < 0.5 ? 4 * x * x * (1 - x) : x
    }
    static func position(for gain: Double) -> Double {
        let gain = gain.isFinite ? min(1, max(0, gain)) : 0
        if gain == 0 || gain >= 0.5 { return gain }
        var low = 0.0, high = 0.5
        for _ in 0..<48 {
            let middle = (low + high) / 2
            if self.gain(at: middle) < gain { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}

/// A separate hosting subtree makes focus ownership include the slider and mute button.
struct VolumeFocusScope<Content: View>: NSViewRepresentable {
    let content: Content
    let dismiss: () -> Void
    func makeNSView(context: Context) -> VolumeFocusView {
        let view = VolumeFocusView()
        let host = NSHostingView(rootView: content)
        host.frame = view.bounds; host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        view.dismiss = dismiss
        return view
    }
    func updateNSView(_ view: VolumeFocusView, context: Context) {
        (view.subviews.first as? NSHostingView<Content>)?.rootView = content
        view.dismiss = dismiss
    }
    static func dismantleNSView(_ view: VolumeFocusView, coordinator: ()) { view.stop() }
}

@MainActor final class VolumeFocusView: NSView {
    var dismiss: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var hadFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop(); hadFocus = false
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFocus() }
        }
        DispatchQueue.main.async { [weak self] in self?.checkFocus() }
    }
    func checkFocus() {
        guard let window else { return }
        if let view = window.firstResponder as? NSView, view === self || view.isDescendant(of: self) {
            hadFocus = true
        } else if hadFocus { hadFocus = false; dismiss?() }
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    isolated deinit { stop() }
}
