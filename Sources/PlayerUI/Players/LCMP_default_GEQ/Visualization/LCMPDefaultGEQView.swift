import SwiftUI

public struct LCMPDefaultGEQView: View {
    let driver: VisualizationDriver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(driver: VisualizationDriver) { self.driver = driver }
    public var body: some View {
        let snapshot = driver.snapshot
        let now = driver.drawTime
        Canvas { context, size in
            LCMPDefaultGEQRenderer.draw(context: context, size: size, snapshot: snapshot, now: now,
                                       reduceMotion: reduceMotion)
        }
        .overlay(alignment: .topLeading) {
            if snapshot.waitingForData {
                Text("解析データを待っています").font(.system(size: 10)).foregroundStyle(Color(white: 0.65))
                    .padding(.leading, 18).padding(.top, 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LCMP_default_GEQ、蛍光管LED、16帯域の周波数レベル")
        .accessibilityValue(snapshot.waitingForData ? "解析データ待ち" : "")
        .allowsHitTesting(false)
    }
}

/// Colors belong to physical LED positions, never to individual frequencies.
public enum LCMPDefaultGEQRenderer {
    public static let background = Color(red: 5/255, green: 8/255, blue: 7/255)
    public static func draw(context original: GraphicsContext, size: CGSize, snapshot: SpectrumSnapshot,
                            now: Double, reduceMotion: Bool = false) {
        let context = original
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
        let plot = CGRect(x: 18, y: 20, width: max(0, size.width - 36), height: max(0, size.height - 47))
        let columnWidth = max(0, (plot.width - 7 * 15) / 16)
        let cellHeight = max(0, (plot.height - 23) / 24)
        guard columnWidth > 0, cellHeight > 0 else { return }
        var lit = [Path(), Path(), Path()]
        var off = [Path(), Path(), Path()]
        var residuals: [(Path, Int, Double)] = []
        for col in 0..<16 {
            for row in 0..<24 {
                let rect = CGRect(x: plot.minX + Double(col) * (columnWidth + 7),
                                  y: plot.maxY - Double(row + 1) * cellHeight - Double(row),
                                  width: columnWidth, height: cellHeight)
                let color = row < 12 ? 0 : row < 18 ? 1 : 2
                off[color].addRect(rect)
                if snapshot.isOn(column: col, row: row) { lit[color].addRect(rect) }
                else if !reduceMotion {
                    let value = snapshot.residual(column: col, row: row, now: now)
                    if value > 0 { residuals.append((Path(rect), color, value)) }
                }
            }
        }
        let on: [Color] = [Color(red: 102/255, green: 1, blue: 121/255),
                           Color(red: 234/255, green: 1, blue: 81/255),
                           Color(red: 1, green: 88/255, blue: 92/255)]
        let dark: [Color] = [Color(red: 13/255, green: 33/255, blue: 19/255),
                             Color(red: 32/255, green: 33/255, blue: 13/255),
                             Color(red: 36/255, green: 14/255, blue: 18/255)]
        for i in 0..<3 { context.fill(off[i], with: .color(dark[i])) }
        // Batch three color paths. All diffuse light is drawn before crisp faces.
        for (radius, alpha) in [(CGFloat(4), 0.18), (CGFloat(9), 0.07)] {
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: radius))
                for i in 0..<3 {
                    glow.fill(lit[i], with: .color(on[i].opacity(alpha)))
                    glow.stroke(lit[i], with: .color(on[i].opacity(alpha)), lineWidth: radius)
                }
            }
        }
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 5))
            for (path, color, value) in residuals { glow.fill(path, with: .color(on[color].opacity(value * 0.4))) }
        }
        for i in 0..<3 { context.fill(lit[i], with: .color(on[i])) }
        for (path, color, value) in residuals { context.fill(path, with: .color(on[color].opacity(value))) }
        let axis = Color(red: 141/255, green: 162/255, blue: 148/255)
        for (label, x, anchor) in [("20 Hz", plot.minX, UnitPoint.leading),
                                    ("1k", plot.minX + plot.width * 0.5663, .center),
                                    ("20k", plot.maxX, .trailing)] {
            context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(axis),
                         at: CGPoint(x: x, y: size.height - 11), anchor: anchor)
        }
    }
}
