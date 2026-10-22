import Foundation

public enum WindowLayout {
    public static let mainSize = CGSize(width: 360, height: 210)
    public static let extensionSize = CGSize(width: 360, height: 300)
    public static let minimumExtensionHeight: CGFloat = 240
    public static let gap: CGFloat = 2

    /// Bottom-edge resizing keeps the main window and the extension's top edge fixed.
    public static func resizedExtensionHeight(_ proposed: CGFloat, main: CGRect, visible: CGRect) -> CGFloat {
        let available = max(0, main.minY - gap - visible.minY)
        let height = proposed.isFinite ? proposed : extensionSize.height
        return min(available, max(minimumExtensionHeight, height))
    }

    /// Both windows stay on the main window's screen, extension immediately below.
    public static func frames(main: CGRect, visible: CGRect, expanded: Bool,
                              extensionHeight: CGFloat = extensionSize.height) -> (main: CGRect, extensionWindow: CGRect) {
        let desiredHeight = max(minimumExtensionHeight, extensionHeight.isFinite ? extensionHeight : extensionSize.height)
        let totalHeight = main.height + (expanded ? desiredHeight + gap : 0)
        let x = min(max(main.minX, visible.minX), max(visible.minX, visible.maxX - main.width))
        let minimumY = visible.minY + (expanded ? desiredHeight + gap : 0)
        let y = min(max(main.minY, minimumY), max(minimumY, visible.maxY - main.height))
        let fitted = CGRect(origin: CGPoint(x: x, y: totalHeight <= visible.height ? y : visible.maxY - main.height), size: main.size)
        let height = min(desiredHeight, max(0, fitted.minY - gap - visible.minY))
        return (fitted, CGRect(x: x, y: fitted.minY - gap - height, width: main.width, height: height))
    }
}

#if os(macOS)
import AppKit

extension WindowLayout {
    /// Whether the player window shows its drawing. Behind other windows, on another Space, minimized
    /// or with the display asleep nothing is drawn, so analysis and the drawing clock stop too.
    public static func showsVisualization(isVisible: Bool, isMiniaturized: Bool, occlusion: NSWindow.OcclusionState) -> Bool {
        isVisible && !isMiniaturized && occlusion.contains(.visible)
    }
}
#endif
