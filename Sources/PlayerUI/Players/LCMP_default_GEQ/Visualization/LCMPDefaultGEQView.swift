import SwiftUI

public struct LCMPDefaultGEQView: View {
    let driver: VisualizationDriver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geqAxisLabelSize) private var axisLabelSize
    public init(driver: VisualizationDriver) { self.driver = driver }
    public var body: some View {
        // This body reads no per-frame value: a new frame does not update SwiftUI. The Metal view
        // observes the driver itself and redraws only its own layer.
        let waiting = driver.waitingForData
        Group {
            if let metal = LCMPDefaultGEQMetal.shared {
                LCMPDefaultGEQStageView(metal: metal, driver: driver, reduceMotion: reduceMotion, axisLabelSize: axisLabelSize)
                    .overlay { LCMPDefaultGEQLabels(axisLabelSize: axisLabelSize) }
            } else {
                LCMPDefaultGEQCanvasView(driver: driver, reduceMotion: reduceMotion, axisLabelSize: axisLabelSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LCMP_default_GEQ、蛍光管LED、16帯域の周波数レベル")
        .accessibilityValue(waiting ? "解析データ待ち" : "")
        .allowsHitTesting(false)
    }
}

/// Without Metal: the whole picture in a Canvas, redrawn by SwiftUI for every frame.
struct LCMPDefaultGEQCanvasView: View {
    let driver: VisualizationDriver
    let reduceMotion: Bool
    let axisLabelSize: CGFloat
    var body: some View {
        let snapshot = driver.snapshot
        let now = driver.drawTime
        Canvas { context, size in
            LCMPDefaultGEQRenderer.draw(context: context, size: size, snapshot: snapshot, now: now,
                                       reduceMotion: reduceMotion, axisLabelSize: axisLabelSize)
        }
    }
}

/// The 20 Hz / 1k / 20k labels over the Metal view. A view of its own so that a new frame, which
/// re-evaluates `LCMPDefaultGEQView`, finds its input unchanged and does not redraw the Canvas.
struct LCMPDefaultGEQLabels: View, Equatable {
    let axisLabelSize: CGFloat
    var body: some View {
        Canvas { context, size in LCMPDefaultGEQRenderer.drawLabels(context: context, size: size, axisLabelSize: axisLabelSize) }
    }
}

/// Where the cells and labels lie in a view of the given size. Shared by the Canvas and Metal renderers.
struct LCMPDefaultGEQLayout: Equatable {
    let size: CGSize
    let plot: CGRect
    let columnWidth: CGFloat
    let cellHeight: CGFloat
    let labelY: CGFloat

    init(size: CGSize, axisLabelSize: CGFloat) {
        self.size = size
        // Larger axis labels take room from the plot's bottom edge.
        let labelGrowth = max(0, axisLabelSize - 9)
        plot = CGRect(x: 18, y: 20, width: max(0, size.width - 36), height: max(0, size.height - 47 - labelGrowth * 1.5))
        columnWidth = max(0, (plot.width - 7 * 15) / 16)
        cellHeight = max(0, (plot.height - 23) / 24)
        labelY = size.height - 11 - labelGrowth * 0.75
    }

    var isEmpty: Bool { columnWidth <= 0 || cellHeight <= 0 }
    func columnX(_ column: Int) -> CGFloat { plot.minX + Double(column) * (columnWidth + 7) }
    func cell(column: Int, row: Int) -> CGRect {
        CGRect(x: columnX(column), y: plot.maxY - Double(row + 1) * cellHeight - Double(row),
               width: columnWidth, height: cellHeight)
    }
    /// 0 for the lower 12 rows, 1 for the next 6, 2 for the top 6.
    static func colorIndex(row: Int) -> Int { row < 12 ? 0 : row < 18 ? 1 : 2 }
}

/// Colors belong to physical LED positions, never to individual frequencies.
public enum LCMPDefaultGEQRenderer {
    public static let background = Color(red: 5/255, green: 8/255, blue: 7/255)
    /// Lit and unlit colors as 0…255 sRGB components, by `LCMPDefaultGEQLayout.colorIndex`.
    static let onComponents: [SIMD3<Double>] = [[102, 255, 121], [234, 255, 81], [255, 88, 92]]
    static let darkComponents: [SIMD3<Double>] = [[13, 33, 19], [32, 33, 13], [36, 14, 18]]
    static let backgroundComponents = SIMD3<Double>(5, 8, 7)
    static let on = onComponents.map { Color(red: $0.x / 255, green: $0.y / 255, blue: $0.z / 255) }
    static let dark = darkComponents.map { Color(red: $0.x / 255, green: $0.y / 255, blue: $0.z / 255) }
    /// The diffuse light around lit cells: blur radius and opacity, drawn in this order.
    static let litGlow: [(radius: CGFloat, opacity: Double)] = [(4, 0.18), (9, 0.07)]
    static let afterglowRadius: CGFloat = 5
    static let afterglowGlowOpacity = 0.4

    public static func draw(context original: GraphicsContext, size: CGSize, snapshot: SpectrumSnapshot,
                            now: Double, reduceMotion: Bool = false, axisLabelSize: CGFloat = 9) {
        let context = original
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
        let layout = LCMPDefaultGEQLayout(size: size, axisLabelSize: axisLabelSize)
        guard !layout.isEmpty else { return }
        var lit = [Path(), Path(), Path()]
        var off = [Path(), Path(), Path()]
        var residuals: [(Path, Int, Double)] = []
        for col in 0..<16 {
            for row in 0..<24 {
                let rect = layout.cell(column: col, row: row)
                let color = LCMPDefaultGEQLayout.colorIndex(row: row)
                off[color].addRect(rect)
                if snapshot.isOn(column: col, row: row) { lit[color].addRect(rect) }
                else if !reduceMotion {
                    let value = snapshot.residual(column: col, row: row, now: now)
                    if value > 0 { residuals.append((Path(rect), color, value)) }
                }
            }
        }
        for i in 0..<3 { context.fill(off[i], with: .color(dark[i])) }
        // Batch three color paths. All diffuse light is drawn before crisp faces.
        for (radius, alpha) in litGlow { drawLitGlow(context, lit, radius: radius, opacity: alpha) }
        drawAfterglowGlow(context, residuals)
        for i in 0..<3 { context.fill(lit[i], with: .color(on[i])) }
        for (path, color, value) in residuals { context.fill(path, with: .color(on[color].opacity(value))) }
        drawLabels(context: context, size: size, axisLabelSize: axisLabelSize)
    }

    /// The light of lit cells, one path per color. The Metal renderer bakes the same calls into its glow images.
    static func drawLitGlow(_ context: GraphicsContext, _ lit: [Path], radius: CGFloat, opacity: Double) {
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: radius))
            for i in 0..<3 {
                glow.fill(lit[i], with: .color(on[i].opacity(opacity)))
                glow.stroke(lit[i], with: .color(on[i].opacity(opacity)), lineWidth: radius)
            }
        }
    }

    static func drawAfterglowGlow(_ context: GraphicsContext, _ residuals: [(Path, Int, Double)]) {
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: afterglowRadius))
            for (path, color, value) in residuals { glow.fill(path, with: .color(on[color].opacity(value * afterglowGlowOpacity))) }
        }
    }

    static func drawLabels(context: GraphicsContext, size: CGSize, axisLabelSize: CGFloat) {
        let layout = LCMPDefaultGEQLayout(size: size, axisLabelSize: axisLabelSize)
        guard !layout.isEmpty else { return }
        let axis = Color(red: 141/255, green: 162/255, blue: 148/255)
        for (label, x, anchor) in [("20 Hz", layout.plot.minX, UnitPoint.leading),
                                    ("1k", layout.plot.minX + layout.plot.width * 0.5663, .center),
                                    ("20k", layout.plot.maxX, .trailing)] {
            context.draw(Text(label).font(.system(size: axisLabelSize, design: .monospaced)).foregroundColor(axis),
                         at: CGPoint(x: x, y: layout.labelY), anchor: anchor)
        }
    }
}

extension EnvironmentValues {
    /// Point size of the 20 Hz / 1k / 20k labels. The macOS window uses 9.
    @Entry var geqAxisLabelSize: CGFloat = 9
}
