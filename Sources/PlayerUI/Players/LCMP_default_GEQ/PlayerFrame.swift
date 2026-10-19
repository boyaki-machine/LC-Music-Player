import SwiftUI

/// How the host frames the player: a fixed macOS window, a card that scales with the screen
/// width (iPhone portrait), the whole screen (iPhone landscape with the extension closed), or a
/// panel that fills the space it is given (iPhone landscape beside the extension).
public enum PlayerFrame: Sendable {
    case window, card, fullScreen, panel
}

extension EnvironmentValues {
    @Entry public var playerFrame: PlayerFrame = .window
}

extension Font {
    /// Extension text keeps the macOS point sizes and reads larger on iPhone.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if os(iOS)
        .system(size: size + 3, weight: weight)
        #else
        .system(size: size, weight: weight)
        #endif
    }
}
