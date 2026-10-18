// Renders the background of the DMG window (charcoal glass with an LED chevron arrow) into a HiDPI TIFF.
// Usage: swift scripts/render-dmg-background.swift assets/DMGBackground.tiff
// The drawing is the chosen A design (see the installer in the UI/UX design), on a 640x400 point canvas with
// y pointing down. Finder draws the icons and their labels; the layout must match scripts/build-dmg.py.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width: CGFloat = 640, height: CGFloat = 400
let appCentre = CGPoint(x: 170, y: 176), applicationsCentre = CGPoint(x: 470, y: 176)
// Finder centres the 13-point label about 19 points under the 128-point icon.
let labelCentre = appCentre.y + 64 + 19
let message = "LCMP を Applications フォルダへドラッグしてください"
let gatekeeper = "初めて開くときに確認が出たら：システム設定 › プライバシーとセキュリティ › 「このまま開く」"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

// LED colours of the fluorescent LED view, shared with the app icon.
let lit = [color(0x66ff79), color(0xeaff51), color(0xff585c)]
let unlit = [color(0x0d2113), color(0x20210d), color(0x240e12)]

func draw(_ context: CGContext, scale: CGFloat) {
    context.translateBy(x: 0, y: height * scale)
    context.scaleBy(x: scale, y: -scale)
    // Shadow offsets and blur are in device space, so they are scaled by hand.
    func glow(_ blur: CGFloat, _ glowColor: CGColor) {
        context.setShadow(offset: .zero, blur: blur * scale, color: glowColor)
    }
    func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, colour: CGColor,
              x: CGFloat, baseline: CGFloat, centred: Bool = false, kern: CGFloat = 0) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .kern: kern]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.saveGState()
        // Undo the y flip for glyphs only.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: centred ? x - lineWidth / 2 : x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    let full = CGRect(x: 0, y: 0, width: width, height: height)
    context.drawLinearGradient(gradient([color(0x34383b), color(0x151719)]),
                               start: .zero, end: CGPoint(x: 0, y: height), options: [])
    context.drawLinearGradient(gradient([color(0xffffff, 0.09), color(0xffffff, 0)]),
                               start: .zero, end: CGPoint(x: 0, y: height * 0.45), options: [])

    // A faint green haze behind the arrow.
    context.saveGState()
    context.clip(to: full)
    context.translateBy(x: width / 2, y: appCentre.y)
    context.scaleBy(x: 250 / 70, y: 1)
    context.drawRadialGradient(gradient([color(0x66ff79, 0.07), color(0x66ff79, 0)]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 90, options: [])
    context.restoreGState()

    text("LC Music Player", size: 15, weight: .semibold, colour: color(0xe0eae3), x: 28, baseline: 40, kern: 0.5)

    // Mini level meter: five columns of six cells, as in the app icon.
    let levels = [3, 5, 4, 6, 2], cell: CGFloat = 4, cellGap: CGFloat = 2
    for (column, level) in levels.enumerated() {
        for row in 0..<6 {
            let band = row < 4 ? 0 : row < 5 ? 1 : 2
            let rect = CGRect(x: 588 + CGFloat(column) * (cell + cellGap), y: 46 - CGFloat(row + 1) * (cell + cellGap),
                              width: cell, height: cell)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil))
            context.setFillColor(row < level ? lit[band] : unlit[band])
            context.fillPath()
        }
    }

    // LED chevrons light up towards the Applications folder: green, then yellow and red at the tip.
    let chevrons = 7, step: CGFloat = 15, chevronHeight: CGFloat = 20, chevronWidth: CGFloat = 7
    for index in 0..<chevrons {
        let x = width / 2 - CGFloat(chevrons - 1) * step / 2 + CGFloat(index) * step
        let band = index < chevrons - 2 ? 0 : index < chevrons - 1 ? 1 : 2
        let alpha = 0.45 + 0.55 * CGFloat(index + 1) / CGFloat(chevrons)
        let chevron = CGMutablePath()
        chevron.addLines(between: [CGPoint(x: x - chevronWidth / 2, y: appCentre.y - chevronHeight / 2),
                                   CGPoint(x: x + chevronWidth / 2, y: appCentre.y),
                                   CGPoint(x: x - chevronWidth / 2, y: appCentre.y + chevronHeight / 2)])
        context.saveGState()
        context.setAlpha(alpha)
        glow(4.4, lit[band])
        context.addPath(chevron)
        context.setStrokeColor(lit[band])
        context.setLineWidth(4.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    // Mid-grey plates under the Finder labels: black (light mode) and white (dark mode) text both reach about 4.5:1.
    for centre in [appCentre, applicationsCentre] {
        let plate = CGPath(roundedRect: CGRect(x: centre.x - 56, y: labelCentre - 12, width: 112, height: 24),
                           cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.addPath(plate)
        context.setFillColor(color(0x767c78))
        context.fillPath()
        context.addPath(plate)
        context.setStrokeColor(color(0xffffff, 0.12))
        context.setLineWidth(1)
        context.strokePath()
    }

    text(message, size: 14, colour: color(0xe0eae3), x: width / 2, baseline: 318, centred: true)
    context.move(to: CGPoint(x: 40, y: 345.5))
    context.addLine(to: CGPoint(x: width - 40, y: 345.5))
    context.setStrokeColor(color(0xffffff, 0.08))
    context.setLineWidth(1)
    context.strokePath()
    text(gatekeeper, size: 11, colour: color(0x9bae9d), x: width / 2, baseline: 370, centred: true)
}

func render(scale: CGFloat) throws -> CGImage {
    guard let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw CocoaError(.featureUnsupported)
    }
    draw(context, scale: scale)
    guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
    return image
}

func writeTIFF(_ image: CGImage, dpi: Int, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: render-dmg-background.swift <output.tiff>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-dmg-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workspace) }
// Both resolutions are drawn from the shapes; Finder picks the one for the display.
let standard = workspace.appendingPathComponent("background.tiff")
let retina = workspace.appendingPathComponent("background@2x.tiff")
try writeTIFF(try render(scale: 1), dpi: 72, to: standard)
try writeTIFF(try render(scale: 2), dpi: 144, to: retina)
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", standard.path, retina.path, "-out", output.path]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { exit(tiffutil.terminationStatus) }
print(output.path)
