// Renders the LCMP app icon (glowing play triangle over a level meter) into an .icns file.
// Usage: swift scripts/render-app-icon.swift assets/AppIcon.icns
// The drawing matches the B3 mockup in prototypes/app-icon.html, on a 1024 canvas with y pointing down.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

// Lit and unlit LED colours of the 16-column fluorescent LED view.
let lit = [color(0x66ff79), color(0xeaff51), color(0xff585c)]
let unlit = [color(0x0d2113), color(0x20210d), color(0x240e12)]

func draw(_ context: CGContext, size: Int) {
    let scale = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)
    // Shadow offsets and blur are in device space, so they are scaled by hand.
    func shadow(_ blur: CGFloat, _ shadowColor: CGColor, dy: CGFloat = 0) {
        context.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: shadowColor)
    }

    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    shadow(28, color(0x000000, 0.35), dy: 12)
    context.addPath(body)
    context.setFillColor(color(0x151719))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    context.drawLinearGradient(gradient([color(0x34383b), color(0x151719)]),
                               start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

    // Play triangle, lit green with a glow.
    let triangle = CGMutablePath()
    triangle.addLines(between: [CGPoint(x: 410, y: 196), CGPoint(x: 410, y: 532), CGPoint(x: 700, y: 364)])
    triangle.closeSubpath()
    context.saveGState()
    shadow(28, color(0x8dffa6, 0.9))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.saveGState()
    context.addPath(triangle)
    context.clip()
    context.drawLinearGradient(gradient([color(0xb9ffcb), color(0x4fe86a)]),
                               start: CGPoint(x: 410, y: 196), end: CGPoint(x: 700, y: 532), options: [])
    context.restoreGState()
    context.addPath(triangle)
    context.setStrokeColor(color(0xd6ffe0))
    context.setLineWidth(10)
    context.setLineJoin(.round)
    context.strokePath()
    context.endTransparencyLayer()
    context.restoreGState()

    // Level meter: five columns of six cells; the fifth cell is yellow and the sixth red, as in the GEQ view.
    let levels = [3, 5, 4, 6, 4], segments = 6
    let barWidth: CGFloat = 92, barGap: CGFloat = 26, cellHeight: CGFloat = 30, cellGap: CGFloat = 10, base: CGFloat = 818
    let left = 512 - (CGFloat(levels.count) * barWidth + CGFloat(levels.count - 1) * barGap) / 2
    for (column, level) in levels.enumerated() {
        for row in 0..<segments {
            let band = row < 4 ? 0 : row < 5 ? 1 : 2
            let cell = CGRect(x: left + CGFloat(column) * (barWidth + barGap),
                              y: base - CGFloat(row + 1) * cellHeight - CGFloat(row) * cellGap,
                              width: barWidth, height: cellHeight)
            context.saveGState()
            if row < level { shadow(12, lit[band]) }
            context.addPath(CGPath(roundedRect: cell, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.setFillColor(row < level ? lit[band] : unlit[band])
            context.fillPath()
            context.restoreGState()
        }
    }

    // Glass gloss over the upper half.
    context.drawLinearGradient(gradient([color(0xffffff, 0.10), color(0xffffff, 0)]),
                               start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 512), options: [])
    context.restoreGState()

    context.addPath(CGPath(roundedRect: CGRect(x: 101.5, y: 101.5, width: 821, height: 821),
                           cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.setStrokeColor(color(0xffffff, 0.14))
    context.setLineWidth(3)
    context.strokePath()
}

func writePNG(size: Int, to url: URL) throws {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.featureUnsupported)
    }
    draw(context, size: size)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: render-app-icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-icon-\(UUID().uuidString)")
let iconset = workspace.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workspace) }
// Each size is drawn from the vector shapes rather than downscaled.
for points in [16, 32, 128, 256, 512] {
    try writePNG(size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print(output.path)
