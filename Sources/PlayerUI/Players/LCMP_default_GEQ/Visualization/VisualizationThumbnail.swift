import SwiftUI

/// A small still picture of each visualization design for the selection cards.
struct VisualizationThumbnail: View {
    let design: VisualizationDesign
    var body: some View {
        let puppet = design == .puppetShow ? PuppetShowThumbnail.image() : nil
        return Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(LCMPDefaultGEQRenderer.background))
            switch design {
            case .fluorescentLED: Self.drawLED(context, size: size)
            case .ermineChorus: ErmineChorusRenderer.drawThumbnail(context, size: size)
            case .puppetShow: PuppetShowThumbnail.draw(context, size: size, image: puppet)
            }
        }
        .accessibilityHidden(true)
    }

    private static func drawLED(_ context: GraphicsContext, size: CGSize) {
        let heights = [3, 5, 7, 8, 9, 9, 8, 7, 5, 2], rows = 12
        let columnWidth = size.width / CGFloat(heights.count), rowHeight = size.height / CGFloat(rows)
        for (column, height) in heights.enumerated() {
            for row in 0..<rows {
                let rect = CGRect(x: CGFloat(column) * columnWidth + 1, y: size.height - CGFloat(row + 1) * rowHeight + 0.5,
                                  width: columnWidth - 2, height: rowHeight - 1)
                let lit = row < height
                let color = row < 6 ? Color(red: 0.4, green: 1, blue: 0.47) : row < 9 ? Color(red: 0.92, green: 1, blue: 0.32) : Color(red: 1, green: 0.35, blue: 0.36)
                context.fill(Path(rect), with: .color(lit ? color : color.opacity(0.13)))
            }
        }
    }
}
