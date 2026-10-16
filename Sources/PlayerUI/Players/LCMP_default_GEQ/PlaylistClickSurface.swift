import AppKit
import SwiftUI

/// Mouse clicks use AppKit's click count; the underlying Button keeps keyboard and AX actions.
struct PlaylistClickSurface: NSViewRepresentable {
    let entryID: UUID
    let click: (Int) -> Void
    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) { view.click = click; view.identifier = NSUserInterfaceItemIdentifier(entryID.uuidString) }
    final class ClickView: NSView {
        var click: ((Int) -> Void)?
        private var count: Int?
        private var origin = NSPoint.zero
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            count = event.clickCount
            origin = event.locationInWindow
        }
        override func mouseDragged(with event: NSEvent) {
            if hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 6 { count = nil }
        }
        override func mouseUp(with event: NSEvent) {
            defer { count = nil }
            guard let count, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // Triple clicks do not select or restart a track again.
            if count == 1 || count == 2 { click?(count) }
        }
    }
}
