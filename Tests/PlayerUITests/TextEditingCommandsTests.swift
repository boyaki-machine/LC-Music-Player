#if os(macOS)
import AppKit
import Testing
@testable import PlayerUI

@Suite @MainActor struct TextEditingCommandsTests {
    private func key(_ key: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                         context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    }

    @Test func onlyTheStandardEditingShortcutsAreTaken() {
        #expect(TextEditingCommands.action(for: key("x", .command)) == #selector(NSText.cut(_:)))
        #expect(TextEditingCommands.action(for: key("c", .command)) == #selector(NSText.copy(_:)))
        #expect(TextEditingCommands.action(for: key("v", .command)) == #selector(NSText.paste(_:)))
        #expect(TextEditingCommands.action(for: key("a", .command)) == #selector(NSText.selectAll(_:)))
        #expect(TextEditingCommands.action(for: key("z", .command)) == Selector(("undo:")))
        #expect(TextEditingCommands.action(for: key("z", [.command, .shift])) == Selector(("redo:")))
        // The player's own shortcuts and other combinations pass through.
        for (k, m): (String, NSEvent.ModifierFlags) in [("v", []), ("v", [.command, .option]), ("c", [.command, .control]), ("v", [.command, .shift]),
                                                        ("o", .command), ("w", .command), ("q", .command), ("s", .command)] {
            #expect(TextEditingCommands.action(for: key(k, m)) == nil, "\(k) \(m)")
        }
    }

    @Test func shortcutsReachTheFocusedTextFieldAndNothingElse() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(field)
        // Without a text field in focus, nothing takes the paste and the event goes on.
        #expect(!TextEditingCommands.perform(key("v", .command, in: window), in: window))
        window.makeFirstResponder(field)
        let editor = try #require(window.firstResponder as? NSTextView)
        // Select All shows the delivery; copy and paste would touch the user's clipboard.
        editor.string = "LCMP"
        #expect(TextEditingCommands.perform(key("a", .command, in: window), in: window))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 4))
        #expect(!TextEditingCommands.perform(key("o", .command, in: window), in: window))
    }
}
#endif
