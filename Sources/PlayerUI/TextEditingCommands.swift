#if os(macOS)
import AppKit

/// The player has no Edit menu: nothing in it edits anything. Text fields and selectable text in
/// the player's own windows still take the standard shortcuts: the app's key monitor passes them
/// here, and they go to the window's first responder. Nothing is added to the main menu, which
/// the sandboxed open panel mirrors; a hidden Edit menu there left the panel unresponsive.
public enum TextEditingCommands {
    static let commands: [(action: Selector, key: String, shift: Bool)] = [
        (Selector(("undo:")), "z", false), (Selector(("redo:")), "z", true),
        (#selector(NSText.cut(_:)), "x", false), (#selector(NSText.copy(_:)), "c", false),
        (#selector(NSText.paste(_:)), "v", false), (#selector(NSText.selectAll(_:)), "a", false),
    ]
    /// The editing action of Command with the key, and Shift only for redo; nil for anything else.
    static func action(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        return commands.first { $0.key == key && $0.shift == modifiers.contains(.shift) }?.action
    }
    /// Sends the shortcut's action along the window's responder chain. False when it is not an
    /// editing shortcut or nothing there takes it, so the event goes on as usual.
    public static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let action = action(for: event), let responder = window.firstResponder else { return false }
        return responder.tryToPerform(action, with: nil)
    }
}
#endif
