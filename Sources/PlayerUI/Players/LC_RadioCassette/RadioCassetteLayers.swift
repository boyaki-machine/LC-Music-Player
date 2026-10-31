import CoreText
import QuartzCore
#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformFont = UIFont
#endif

/// The radio cassette as Core Animation layers. The shapes are built once; a frame only turns the
/// two hubs, moves the dashes, and changes the meter cells and lamps that differ from the last
/// frame. The render server composites them, so nothing is redrawn on the CPU every frame.
@MainActor final class RadioCassetteLayers {
    typealias G = RadioCassetteGeometry
    let root = CALayer()
    private let cassette = CALayer(), indicatorBlock = CALayer(), meterBlock = CALayer()
    private let packs = CAShapeLayer(), tape = CAShapeLayer()
    private let hubs = [CAShapeLayer(), CAShapeLayer()]
    private var boxes: [CAShapeLayer] = [], texts: [CATextLayer] = []
    private var cells: [[CALayer]] = []
    private var labels: [CATextLayer] = []
    private var shown: RadioCassetteFrame?
    private var shownRadii: [Double] = []
    private var textScale: CGFloat = 2
    private var laidOut: (size: CGSize, scale: CGFloat)?
    private let font = PlatformFont.systemFont(ofSize: G.indicatorFontSize, weight: .semibold)

    init() {
        root.backgroundColor = G.Ink.glass
        root.masksToBounds = true
        for block in [cassette, indicatorBlock, meterBlock] { block.anchorPoint = .zero; root.addSublayer(block) }
        buildCassette(); buildIndicators(); buildMeter()
    }

    private func buildCassette() {
        let shell = Self.stroke(G.shell, G.Ink.faint, G.faintLine)
        let guides = Self.stroke(G.guides, G.Ink.dark, G.brightLine)
        packs.strokeColor = G.Ink.dark; packs.fillColor = nil; packs.lineWidth = G.brightLine
        tape.strokeColor = G.Ink.dark; tape.fillColor = nil; tape.lineWidth = G.brightLine
        tape.lineDashPattern = G.tapeDash.map { NSNumber(value: Double($0)) }
        for layer in [shell, guides, packs, tape] { cassette.addSublayer(layer) }
        for (hub, center) in zip(hubs, [G.leftReel, G.rightReel]) {
            hub.path = G.hub; hub.strokeColor = G.Ink.dark; hub.fillColor = nil; hub.lineWidth = G.brightLine
            hub.position = center
            cassette.addSublayer(hub)
        }
    }

    private func buildIndicators() {
        for i in 0..<6 {
            let frame = G.indicatorFrame(i)
            let box = CAShapeLayer()
            box.path = CGPath(roundedRect: frame, cornerWidth: G.indicatorCorner, cornerHeight: G.indicatorCorner, transform: nil)
            let text = CATextLayer()
            text.alignmentMode = .center
            text.font = font; text.fontSize = G.indicatorFontSize
            text.truncationMode = .none
            indicatorBlock.addSublayer(box); indicatorBlock.addSublayer(text)
            boxes.append(box); texts.append(text)
        }
    }

    private func buildMeter() {
        for column in 0..<2 {
            var layers: [CALayer] = []
            for row in 0..<RadioCassetteMeter.cells {
                let cell = CALayer()
                cell.frame = G.meterCell(column: column, row: row)
                cell.backgroundColor = G.Ink.unlitCell
                meterBlock.addSublayer(cell); layers.append(cell)
            }
            cells.append(layers)
            let label = CATextLayer()
            label.string = column == 0 ? "L" : "R"
            label.font = PlatformFont.systemFont(ofSize: G.meterLabelSize, weight: .bold); label.fontSize = G.meterLabelSize
            label.foregroundColor = G.Ink.dark; label.alignmentMode = .center
            label.frame = CGRect(x: G.meterColumns[column] - 4, y: G.meterLabelY - G.meterLabelSize * 0.65,
                                 width: G.meterColumnWidth + 8, height: G.meterLabelSize * 1.3)
            meterBlock.addSublayer(label); labels.append(label)
        }
    }

    /// Fits the design into `size` (points) shown at `screenScale` pixels per point.
    func layout(size: CGSize, screenScale: CGFloat) {
        guard laidOut.map({ $0.size != size || $0.scale != screenScale }) ?? true else { return }
        laidOut = (size, screenScale)
        let layout = G.Layout(size: size)
        Self.withoutAnimation {
            root.frame = CGRect(origin: .zero, size: size)
            for (block, x) in [(cassette, layout.cassetteOffset), (indicatorBlock, layout.indicatorOffset), (meterBlock, layout.meterOffset)] {
                block.bounds = CGRect(origin: .zero, size: G.designSize)
                block.position = CGPoint(x: (layout.origin.x + x) * layout.scale, y: layout.origin.y * layout.scale)
                block.setAffineTransform(CGAffineTransform(scaleX: layout.scale, y: layout.scale))
            }
            textScale = max(1, screenScale * layout.scale)
            for text in texts + labels { text.contentsScale = textScale }
        }
        // Lamps are laid out again at the new text scale.
        if let frame = shown { shown = nil; shownRadii = []; render(frame) }
    }

    func render(_ frame: RadioCassetteFrame) {
        Self.withoutAnimation {
            let radii = frame.tape.radii
            // The packs change size over minutes; rebuild their paths only when it shows.
            if shownRadii.count != 2 || zip(radii, shownRadii).contains(where: { abs($0 - $1) > 0.02 }) {
                packs.path = G.packs(radii: radii); tape.path = G.tapePath(radii: radii); shownRadii = radii
            }
            for (hub, angle) in zip(hubs, frame.tape.angles) { hub.setAffineTransform(CGAffineTransform(rotationAngle: angle)) }
            tape.lineDashPhase = -frame.tape.flow
            // Only the cells between the old and the new level change.
            for column in 0..<2 {
                let lit = frame.litCells[column]
                let rows = shown.map { min($0.litCells[column], lit)..<max($0.litCells[column], lit) } ?? 0..<RadioCassetteMeter.cells
                for row in rows { cells[column][row].backgroundColor = row < lit ? G.Ink.dark : G.Ink.unlitCell }
            }
            for (i, indicator) in frame.indicators.enumerated() where i < boxes.count && shown?.indicators[safe: i] != indicator {
                show(indicator, at: i)
            }
        }
        shown = frame
    }

    private func show(_ indicator: RadioCassetteIndicator, at i: Int) {
        let box = boxes[i], text = texts[i], frame = G.indicatorFrame(i)
        box.lineWidth = indicator.lit ? G.brightLine : G.faintLine
        box.strokeColor = indicator.lit ? G.Ink.dark : G.Ink.dim
        box.fillColor = indicator.inverted ? G.Ink.dark : nil
        text.foregroundColor = indicator.inverted ? G.Ink.glass : indicator.lit ? G.Ink.dark : G.Ink.unlitText
        let fitted = Self.fit(indicator.text, font: font as CTFont, width: frame.width - 6)
        text.string = fitted.text
        let lineHeight = G.indicatorFontSize * 1.25
        text.bounds = CGRect(x: 0, y: 0, width: fitted.width, height: lineHeight)
        text.position = CGPoint(x: frame.midX, y: frame.midY + 0.3)
        text.setAffineTransform(CGAffineTransform(scaleX: fitted.squeeze, y: 1))
        // Draw the new text now: the new size applies at once, and the old text must not show in it.
        text.displayIfNeeded()
    }

    /// Squeezes long text sideways, then cuts it with an ellipsis if it still does not fit.
    nonisolated static func fit(_ string: String, font: CTFont, width: CGFloat) -> (text: String, width: CGFloat, squeeze: CGFloat) {
        func measure(_ s: String) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
            return ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 1
        }
        var text = string, natural = measure(text)
        let squeeze = natural > width ? max(G.minimumTextSqueeze, width / natural) : 1
        if natural * squeeze > width {
            while text.count > 1 && measure(text + "…") * squeeze > width { text.removeLast() }
            text += "…"; natural = measure(text)
        }
        return (text, natural, squeeze)
    }

    private static func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path; layer.strokeColor = color; layer.fillColor = nil; layer.lineWidth = width
        return layer
    }
    static func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
