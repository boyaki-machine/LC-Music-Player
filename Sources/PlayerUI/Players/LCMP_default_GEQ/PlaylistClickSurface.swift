#if os(macOS)
import AppKit
#endif
import SwiftUI

enum PlaylistRowDrag: Equatable {
    /// Vertical distance from the press, in list content points (down is positive).
    case moved(CGFloat)
    case ended(CGFloat)
    case cancelled
}

/// Row geometry of the playlist used to turn a drag distance into a position.
enum PlaylistReorder {
    /// Row height 44pt plus the 2pt spacing of the list.
    static let pitch: CGFloat = 46
    /// The position the dragged row takes when released.
    static func target(from index: Int, offset: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + Int((offset / pitch).rounded()), 0), count - 1)
    }
    /// The insertion index before the move, as `LibraryController.moveEntry(_:in:to:)` takes it.
    static func destination(from index: Int, target: Int) -> Int { target > index ? target + 1 : target }
}

#if os(macOS)
/// Mouse clicks use AppKit's click count; the underlying Button keeps keyboard and AX actions.
/// A press that moves 6pt or more is a drag, never a click; with `drag` set it reorders the row.
struct PlaylistClickSurface: NSViewRepresentable {
    let entryID: UUID
    var drag: ((PlaylistRowDrag) -> Void)? = nil
    let click: (Int) -> Void
    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) {
        view.click = click; view.drag = drag; view.identifier = NSUserInterfaceItemIdentifier(entryID.uuidString)
    }
    final class ClickView: NSView {
        var click: ((Int) -> Void)?
        var drag: ((PlaylistRowDrag) -> Void)?
        /// Tests drive the drag with direct event calls instead of the event queue.
        var tracksDragInLoop = true
        private var count: Int?
        private var origin = NSPoint.zero
        private var dragStart: CGFloat?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            count = event.clickCount
            origin = event.locationInWindow
            dragStart = nil
        }
        override func mouseDragged(with event: NSEvent) {
            if let dragStart { drag?(.moved(contentY(event) - dragStart)); return }
            guard hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 6 else { return }
            count = nil
            guard drag != nil, let window else { return }
            dragStart = contentY(origin)
            drag?(.moved(contentY(event) - contentY(origin)))
            if tracksDragInLoop { track(in: window, from: event) }
        }
        override func mouseUp(with event: NSEvent) {
            defer { count = nil }
            if let start = dragStart { dragStart = nil; drag?(.ended(contentY(event) - start)); return }
            guard let count, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // Triple clicks do not select or restart a track again.
            if count == 1 || count == 2 { click?(count) }
        }
        override func cancelOperation(_ sender: Any?) {
            if dragStart != nil { dragStart = nil; drag?(.cancelled) }
        }
        /// Follows the drag in a local loop. The lazy list may drop this row's view while the
        /// list scrolls, and the loop keeps receiving events regardless. Periodic events keep
        /// scrolling while the pointer rests beyond the list edge.
        private func track(in window: NSWindow, from first: NSEvent) {
            var last = first
            NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 1.0 / 30)
            defer { NSEvent.stopPeriodicEvents() }
            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .periodic, .keyDown], timeout: .infinity, mode: .eventTracking) { event, stop in
                guard let event, self.dragStart != nil else { stop.pointee = true; return }
                switch event.type {
                case .leftMouseUp: self.mouseUp(with: event); stop.pointee = true
                case .keyDown where event.keyCode == 53: self.cancelOperation(nil); stop.pointee = true
                case .keyDown: break
                case .periodic: if self.scrollList(last) { self.mouseDragged(with: last) }
                default: last = event; _ = self.scrollList(event); self.mouseDragged(with: event)
                }
            }
        }
        private func scrollList(_ event: NSEvent) -> Bool { enclosingScrollView?.contentView.autoscroll(with: event) ?? false }
        private func contentY(_ event: NSEvent) -> CGFloat { contentY(event.locationInWindow) }
        /// Measures in the scrolled content, so scrolling and the row's own offset do not shift it.
        private func contentY(_ point: NSPoint) -> CGFloat {
            guard let content = enclosingScrollView?.documentView else { return -point.y }
            let y = content.convert(point, from: nil).y
            return content.isFlipped ? y : -y
        }
    }
}
#endif
