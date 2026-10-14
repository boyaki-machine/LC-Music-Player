import Foundation

public enum WindowLayout {
    public static let mainSize = CGSize(width: 360, height: 210)
    public static let extensionSize = CGSize(width: 360, height: 300)
    public static let gap: CGFloat = 2

    /// Both windows stay on the main window's screen, extension immediately below.
    public static func frames(main: CGRect, visible: CGRect, expanded: Bool) -> (main: CGRect, extensionWindow: CGRect) {
        let totalHeight = main.height + (expanded ? extensionSize.height + gap : 0)
        let x = min(max(main.minX, visible.minX), max(visible.minX, visible.maxX - main.width))
        let minimumY = visible.minY + (expanded ? extensionSize.height + gap : 0)
        let y = min(max(main.minY, minimumY), max(minimumY, visible.maxY - main.height))
        let fitted = CGRect(origin: CGPoint(x: x, y: totalHeight <= visible.height ? y : visible.maxY - main.height), size: main.size)
        let height = min(extensionSize.height, max(0, fitted.minY - gap - visible.minY))
        return (fitted, CGRect(x: x, y: fitted.minY - gap - height, width: main.width, height: height))
    }
}
