import CoreGraphics
import Foundation

/// The drawing of the radio cassette in the 360×144pt design, shared by the layers and the thumbnail.
enum RadioCassetteGeometry {
    static let designSize = CGSize(width: 360, height: 144)

    /// Monochrome LCD: one dark ink on a grey-green glass; unlit segments stay faintly visible.
    enum Ink {
        static let glass = CGColor(srgbRed: 0x8f / 255.0, green: 0x9a / 255.0, blue: 0x7e / 255.0, alpha: 1)
        static let dark = CGColor(srgbRed: 0x1d / 255.0, green: 0x24 / 255.0, blue: 0x18 / 255.0, alpha: 1)
        static let dim = CGColor(srgbRed: 0x46 / 255.0, green: 0x50 / 255.0, blue: 0x3c / 255.0, alpha: 1)
        static let faint = CGColor(srgbRed: 0x7f / 255.0, green: 0x8a / 255.0, blue: 0x6f / 255.0, alpha: 1)
        static let unlitText = CGColor(srgbRed: 0x7a / 255.0, green: 0x85 / 255.0, blue: 0x69 / 255.0, alpha: 1)
        static let unlitCell = CGColor(srgbRed: 0x81 / 255.0, green: 0x8c / 255.0, blue: 0x71 / 255.0, alpha: 1)
    }
    static let faintLine: CGFloat = 0.75, brightLine: CGFloat = 1.1

    /// Where the three blocks go in a view of `size`: the design scaled to the height, any spare
    /// width shared out around the cassette, the indicators and the meter.
    struct Layout: Equatable {
        var scale: CGFloat
        var origin: CGPoint
        var gap: CGFloat
        init(size: CGSize) {
            let s = max(0.01, min(size.width / designSize.width, size.height / designSize.height))
            let spare = max(0, size.width / s - designSize.width)
            scale = s; gap = spare * 0.25
            origin = CGPoint(x: gap, y: (size.height / s - designSize.height) / 2)
        }
        var cassetteOffset: CGFloat { 0 }
        var indicatorOffset: CGFloat { gap }
        var meterOffset: CGFloat { gap * 2 }
    }

    // MARK: Cassette

    static let leftReel = CGPoint(x: 69, y: 58), rightReel = CGPoint(x: 145, y: 58)
    static let leftGuide = CGPoint(x: 32, y: 116), rightGuide = CGPoint(x: 182, y: 116)
    static let guideRadius: CGFloat = 6
    static let toothLength: CGFloat = 3
    /// Dash and gap of the tape on the path.
    static let tapeDash: [CGFloat] = [5, 2.5]

    /// Shell, label window, head opening and the window between the reels.
    static var shell: CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 12, y: 12, width: 190, height: 120), cornerWidth: 7, cornerHeight: 7)
        path.addRoundedRect(in: CGRect(x: 21, y: 20, width: 172, height: 74), cornerWidth: 5, cornerHeight: 5)
        path.move(to: CGPoint(x: 46, y: 132)); path.addLine(to: CGPoint(x: 52, y: 100))
        path.addLine(to: CGPoint(x: 162, y: 100)); path.addLine(to: CGPoint(x: 168, y: 132))
        path.addRoundedRect(in: CGRect(x: 90, y: 48, width: 34, height: 20), cornerWidth: 1.5, cornerHeight: 1.5)
        return path
    }
    static var guides: CGPath {
        let path = CGMutablePath()
        for guide in [leftGuide, rightGuide] { path.addEllipse(in: circle(guide, guideRadius)) }
        return path
    }
    static func packs(radii: [Double]) -> CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: circle(leftReel, CGFloat(radii[0])))
        path.addEllipse(in: circle(rightReel, CGFloat(radii[1])))
        return path
    }
    /// A hub with six teeth, centred on the origin, to be turned by its layer.
    static var hub: CGPath {
        let path = CGMutablePath(), r = CGFloat(RadioCassetteTape.hubRadius)
        path.addEllipse(in: circle(.zero, r))
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            path.move(to: CGPoint(x: cos(a) * r, y: sin(a) * r))
            path.addLine(to: CGPoint(x: cos(a) * (r - toothLength), y: sin(a) * (r - toothLength)))
        }
        return path
    }
    /// From the left pack down to its guide, across the heads, and up from the right guide to its pack,
    /// in the direction the tape runs forward.
    static func tapePath(radii: [Double]) -> CGPath {
        let path = CGMutablePath()
        let (aL, bL) = tangent(reel: leftReel, radius: CGFloat(radii[0]), guide: leftGuide, side: 1)
        let (aR, bR) = tangent(reel: rightReel, radius: CGFloat(radii[1]), guide: rightGuide, side: -1)
        path.move(to: aL); path.addLine(to: bL)
        path.move(to: CGPoint(x: leftGuide.x, y: leftGuide.y + guideRadius))
        path.addLine(to: CGPoint(x: rightGuide.x, y: rightGuide.y + guideRadius))
        path.move(to: bR); path.addLine(to: aR)
        return path
    }
    /// The outer tangent between a pack and its guide: the points on the pack and on the guide.
    private static func tangent(reel: CGPoint, radius: CGFloat, guide: CGPoint, side: CGFloat) -> (CGPoint, CGPoint) {
        let distance = hypot(guide.x - reel.x, guide.y - reel.y)
        let a = atan2(guide.y - reel.y, guide.x - reel.x) + side * acos(min(1, (radius - guideRadius) / distance))
        return (CGPoint(x: reel.x + cos(a) * radius, y: reel.y + sin(a) * radius),
                CGPoint(x: guide.x + cos(a) * guideRadius, y: guide.y + sin(a) * guideRadius))
    }
    private static func circle(_ center: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    // MARK: Indicators

    static let indicatorX: CGFloat = 220, indicatorWidth: CGFloat = 64, indicatorHeight: CGFloat = 13
    static let indicatorPitch: CGFloat = 13 + 6.2, indicatorTop: CGFloat = 17
    static let indicatorCorner: CGFloat = 2.5, indicatorFontSize: CGFloat = 7
    /// Text is squeezed sideways down to this much before it is cut short.
    static let minimumTextSqueeze: CGFloat = 0.72
    static func indicatorFrame(_ index: Int) -> CGRect {
        CGRect(x: indicatorX, y: indicatorTop + CGFloat(index) * indicatorPitch, width: indicatorWidth, height: indicatorHeight)
    }

    // MARK: Meter

    static let meterTop: CGFloat = 14, meterBottom: CGFloat = 118, meterColumnWidth: CGFloat = 15
    static let meterColumns: [CGFloat] = [304, 329]
    static let meterLabelY: CGFloat = 128, meterLabelSize: CGFloat = 9
    static func meterCell(column: Int, row: Int) -> CGRect {
        let height = (meterBottom - meterTop) / CGFloat(RadioCassetteMeter.cells)
        return CGRect(x: meterColumns[column], y: meterBottom - CGFloat(row + 1) * height + 0.5,
                      width: meterColumnWidth, height: height - 1)
    }
}
