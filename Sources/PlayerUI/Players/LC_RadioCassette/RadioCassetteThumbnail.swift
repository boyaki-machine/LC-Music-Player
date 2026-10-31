import SwiftUI

/// The still picture on the display tab's selection card: the cassette and the meter on the LCD glass.
enum RadioCassetteThumbnail {
    typealias G = RadioCassetteGeometry
    static func draw(_ original: GraphicsContext, size: CGSize) {
        var context = original
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(cgColor: G.Ink.glass)))
        // The cassette (x 12...202) and the meter (x 304...344, moved to 212...252), fitted to the card.
        let content = CGRect(x: 4, y: 8, width: 256, height: 128), gapShift: CGFloat = 92
        let scale = min(size.width / content.width, size.height / content.height)
        context.translateBy(x: (size.width - content.width * scale) / 2 - content.minX * scale,
                            y: (size.height - content.height * scale) / 2 - content.minY * scale)
        context.scaleBy(x: scale, y: scale)
        let dark = Color(cgColor: G.Ink.dark), radii = [24.0, 18.0]
        context.stroke(Path(G.shell), with: .color(Color(cgColor: G.Ink.faint)), lineWidth: 1.2)
        for path in [G.guides, G.packs(radii: radii)] { context.stroke(Path(path), with: .color(dark), lineWidth: 1.6) }
        for center in [G.leftReel, G.rightReel] {
            context.stroke(Path(G.hub).applying(CGAffineTransform(translationX: center.x, y: center.y)), with: .color(dark), lineWidth: 1.6)
        }
        context.stroke(Path(G.tapePath(radii: radii)), with: .color(dark), style: StrokeStyle(lineWidth: 1.6, dash: G.tapeDash))
        let lit = [17, 14]
        for column in 0..<2 {
            for row in 0..<RadioCassetteMeter.cells {
                let cell = G.meterCell(column: column, row: row).offsetBy(dx: -gapShift, dy: 0)
                context.fill(Path(cell), with: .color(row < lit[column] ? dark : Color(cgColor: G.Ink.unlitCell)))
            }
        }
    }
}
