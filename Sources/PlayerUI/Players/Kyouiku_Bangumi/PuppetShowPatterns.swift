import CoreGraphics
import Foundation

/// Pictures the puppet show draws in code, ported from the mock's canvases with the same sizes, stops and seeds.
/// All are drawn in canvas coordinates (y down) and read back with straight colors.
enum PuppetShowPatterns {
    typealias RGBA = (Double, Double, Double, Double)

    static func color(_ c: RGBA) -> CGColor { CGColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: c.3) }

    static func gradient(_ stops: [(Double, RGBA)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { color($0.1) } as CFArray,
                   locations: stops.map { CGFloat($0.0) })!
    }

    /// Fills the current clip with a canvas-style radial gradient (the end colors continue outside the circles).
    static func radial(_ g: CGContext, _ x0: Double, _ y0: Double, _ r0: Double, _ x1: Double, _ y1: Double, _ r1: Double,
                       _ stops: [(Double, RGBA)]) {
        g.drawRadialGradient(gradient(stops), startCenter: CGPoint(x: x0, y: y0), startRadius: r0,
                             endCenter: CGPoint(x: x1, y: y1), endRadius: r1,
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func linear(_ g: CGContext, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ stops: [(Double, RGBA)]) {
        g.drawLinearGradient(gradient(stops), start: CGPoint(x: x0, y: y0), end: CGPoint(x: x1, y: y1),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func fill(_ g: CGContext, _ path: CGPath, _ paint: (CGContext) -> Void) {
        g.saveGState(); g.addPath(path); g.clip(); paint(g); g.restoreGState()
    }

    static func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    }

    // MARK: Cloth

    /// Fine weave, fuzz and the seams at the sides of the face (u = 0 and 0.5). Returns the picture and its
    /// mean brightness, by which the painted colors are divided so the cloth does not dull them.
    static func fabric() -> (image: PuppetImage, mean: Double) {
        let w = 1024, h = 512
        var r = PuppetRandom(seed: 23)
        let image = PuppetImage.draw(width: w, height: h) { g in
            let data = g.data!.assumingMemoryBound(to: UInt8.self), stride = g.bytesPerRow
            for y in 0..<h {
                for x in 0..<w {
                    let weave = 0.06 * sin(2 * .pi * Double(x) / 6) * sin(2 * .pi * Double(y) / 6) + 0.03 * sin(2 * .pi * Double(x + y) / 13)
                    let v = UInt8(clamped: PuppetMath.clamp(0.93 + weave + (r.next() - 0.5) * 0.16) * 255)
                    // The context is flipped; the buffer's first row is the canvas's top row.
                    let i = y * stride + x * 4
                    data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 255
                }
            }
            g.setLineWidth(1.2)
            for _ in 0..<6000 {
                let x = r.next() * Double(w), y = r.next() * Double(h), a = r.next() * .pi, l = 3 + r.next() * 7
                g.setStrokeColor(color(r.next() < 0.5 ? (255, 255, 255, 0.16) : (0, 0, 0, 0.12)))
                g.move(to: CGPoint(x: x, y: y)); g.addLine(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l)); g.strokePath()
            }
            for sx in [0.0, Double(w) / 2, Double(w)] {
                fill(g, CGPath(rect: CGRect(x: sx - 10, y: 0, width: 20, height: Double(h)), transform: nil)) {
                    linear($0, sx - 10, 0, sx + 10, 0, [(0, (0, 0, 0, 0)), (0.5, (0, 0, 0, 0.22)), (1, (0, 0, 0, 0))])
                }
                g.setStrokeColor(color((60, 40, 30, 0.55))); g.setLineWidth(1.6)
                for y in Swift.stride(from: 4, to: h, by: 14) {
                    g.move(to: CGPoint(x: sx - 4, y: Double(y))); g.addLine(to: CGPoint(x: sx + 4, y: Double(y + 5))); g.strokePath()
                }
            }
        }
        var sum = 0.0
        for i in Swift.stride(from: 0, to: image.pixels.count, by: 4) { sum += Double(image.pixels[i]) / 255 }
        return (image, sum / Double(w * h))
    }

    /// Fine noise laid over the paper scenery and the moon.
    static func grain() -> PuppetImage {
        var r = PuppetRandom(seed: 11), pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
        for i in Swift.stride(from: 0, to: pixels.count, by: 4) {
            let v: UInt8 = r.next() < 0.5 ? 0 : 255
            pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            pixels[i + 3] = UInt8(clamped: r.next() * 14)
        }
        return PuppetImage(width: 128, height: 128, pixels: pixels)
    }

    // MARK: Mouth

    /// The inside of the mouth: the roof (upper) or the tongue (lower). The canvas's top half faces the viewer.
    static func mouthCap(tongue: Bool) -> PuppetImage {
        PuppetImage.draw(width: 128, height: 128) { g in
            linear(g, 0, 0, 0, 64, [(0, tongue ? (138, 44, 48, 1) : (106, 34, 38, 1)), (1, tongue ? (58, 16, 18, 1) : (42, 10, 12, 1))])
            if tongue {
                g.setFillColor(color((200, 100, 104, 1))); g.addPath(ellipse(64, 20, 34, 16)); g.fillPath()
            } else {
                g.setStrokeColor(color((255, 255, 255, 0.18))); g.setLineWidth(3)
                g.addArc(center: CGPoint(x: 64, y: 64), radius: 58, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
                g.strokePath()
            }
        }
    }

    // MARK: Eyes

    static func eyeGlow(_ style: PuppetEyeStyle) -> PuppetImage {
        let (r, gg, b) = style.glow
        return PuppetImage.draw(width: 64, height: 96) { g in
            if style.kind == .flame {
                // A drop of flame stretched upward.
                g.translateBy(x: 32, y: 60); g.scaleBy(x: 1, y: 1.7)
                fill(g, ellipse(0, 0, 30, 30)) {
                    radial($0, 0, 0, 0, 0, 0, 30, [(0, (255, 220, 120, 0.95)), (0.3, (r, gg, b, 0.6)), (1, (r, gg, b, 0))])
                }
            } else {
                radial(g, 32, 48, 0, 32, 48, 32, [(0, (r, gg, b, 0.95)), (0.3, (r, gg, b, 0.4)), (1, (r, gg, b, 0))])
            }
        }
    }

    /// The opaque light over the pupil, whiter at the center; calm colors stay less white.
    static func eyeCore(_ style: PuppetEyeStyle) -> PuppetImage {
        let (r, gg, b) = style.core
        let center: RGBA = style.dim ? (round(r + (255 - r) * 0.35), round(gg + (255 - gg) * 0.35), round(b + (255 - b) * 0.35), 1) : (255, 250, 245, 1)
        return PuppetImage.draw(width: 48, height: 64) { g in
            fill(g, ellipse(24, 32, 22, 30)) {
                radial($0, 24, 30, 0, 24, 32, 24, [(0, center), (0.45, (r, gg, b, 1)), (1, (round(r * 0.7), round(gg * 0.7), round(b * 0.75), 1))])
            }
        }
    }

    /// A ring spreading from the eye (the wave style).
    static func ripple(_ style: PuppetEyeStyle) -> PuppetImage {
        let (r, gg, b) = style.glow
        return PuppetImage.draw(width: 64, height: 64) { g in
            g.setStrokeColor(color((r, gg, b, 0.9))); g.setLineWidth(3); g.addPath(ellipse(32, 32, 28, 28)); g.strokePath()
        }
    }

    static func blush() -> PuppetImage {
        PuppetImage.draw(width: 64, height: 32) { g in
            g.saveGState(); g.scaleBy(x: 1, y: 0.5)
            // As on a canvas, the gradient is placed in the scaled space it is filled in.
            fill(g, ellipse(32, 32, 30, 30)) { radial($0, 32, 16, 0, 32, 16, 30, [(0, (255, 90, 110, 0.7)), (1, (255, 90, 110, 0))]) }
            g.restoreGState()
            g.setStrokeColor(color((230, 60, 80, 0.55))); g.setLineWidth(2)
            for x in [22.0, 32, 42] { g.move(to: CGPoint(x: x + 3, y: 10)); g.addLine(to: CGPoint(x: x - 3, y: 22)); g.strokePath() }
        }
    }

    /// Skin over the pupil, then a line: an arch (closed in shyness) or a squeezed `>` / `<` (shouting).
    static func coveredEye(skin: [Double], squeeze right: Bool?) -> PuppetImage {
        let k = skin.map { round($0 * 255) }
        return PuppetImage.draw(width: 64, height: 48) { g in
            fill(g, CGPath(rect: CGRect(x: 0, y: 0, width: 64, height: 48), transform: nil)) {
                radial($0, 32, 24, 4, 32, 24, 30, [(0, (k[0], k[1], k[2], 1)), (0.75, (k[0], k[1], k[2], 1)), (1, (k[0], k[1], k[2], 0))])
            }
            g.setStrokeColor(color((42, 28, 24, 1))); g.setLineCap(.round); g.setLineJoin(.round)
            if let right {
                g.setLineWidth(4.5)
                let points = right ? [(42.0, 12.0), (22, 24), (42, 36)] : [(22, 12), (42, 24), (22, 36)]
                g.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
            } else {
                g.setLineWidth(4)
                g.move(to: CGPoint(x: 18, y: 30)); g.addQuadCurve(to: CGPoint(x: 46, y: 30), control: CGPoint(x: 32, y: 16))
            }
            g.strokePath()
        }
    }

    static func shoutLine() -> PuppetImage {
        PuppetImage.draw(width: 16, height: 64) { g in
            g.setFillColor(color((255, 255, 255, 0.95)))
            g.addLines(between: [CGPoint(x: 8, y: 2), CGPoint(x: 13, y: 62), CGPoint(x: 3, y: 62)]); g.closePath(); g.fillPath()
        }
    }

    /// A band of water repeating downward: swells and a highlight flow along it; faint light marks both banks.
    static func tearStream() -> PuppetImage {
        PuppetImage.draw(width: 32, height: 128) { g in
            for y in 0..<128 {
                let yy = Double(y), bulge = 0.75 + 0.25 * sin(yy / 128 * .pi * 6)
                let half = 12 + 3 * bulge, a = 0.4 + 0.12 * bulge
                fill(g, CGPath(rect: CGRect(x: 0, y: yy, width: 32, height: 1), transform: nil)) {
                    linear($0, 16 - half, 0, 16 + half, 0, [(0, (170, 215, 255, 0)), (0.3, (170, 215, 255, a)), (0.7, (170, 215, 255, a)), (1, (170, 215, 255, 0))])
                }
                g.setFillColor(color((235, 248, 255, 0.32 + 0.15 * bulge)))
                g.fill(CGRect(x: 16 - half + 2, y: yy, width: 2, height: 1)); g.fill(CGRect(x: 16 + half - 4, y: yy, width: 2, height: 1))
                let hx = 12 + 2 * sin(yy / 128 * .pi * 4)
                g.setFillColor(color((255, 255, 255, 0.3 + 0.3 * bulge))); g.fill(CGRect(x: hx - 1.5, y: yy, width: 3, height: 1))
            }
        }
    }

    // MARK: Sky

    /// A star's glow at full strength (the core and the faint ring); the caller scales its alpha.
    static func glint() -> PuppetImage {
        PuppetImage.draw(width: 64, height: 64) { g in
            radial(g, 32, 32, 0, 32, 32, 32, [(0, (255, 255, 245, 1)), (0.35, (220, 230, 255, 0.35)), (1, (200, 210, 255, 0))])
        }
    }

    /// White fading to transparent toward the rim, tinted when drawn (the low sun's glow).
    static func halo() -> PuppetImage {
        PuppetImage.draw(width: 64, height: 64) { g in radial(g, 32, 32, 0, 32, 32, 32, [(0, (255, 255, 255, 1)), (1, (255, 255, 255, 0))]) }
    }

    /// A shooting star's tail: transparent at the start, bright at the head.
    static func streak() -> PuppetImage {
        PuppetImage.draw(width: 64, height: 4) { g in linear(g, 0, 0, 64, 0, [(0, (255, 255, 255, 0)), (1, (255, 255, 240, 1))]) }
    }

    static let white = PuppetImage(width: 1, height: 1, pixels: [255, 255, 255, 255])

    // MARK: Clouds

    /// Evens a cloud picture to white, keeping only its shape and paper texture; the time of day tints it.
    static func neutralCloud(_ source: PuppetImage) -> PuppetImage {
        var image = source, lo = 255.0, hi = 0.0
        let p = image.pixels
        for i in Swift.stride(from: 0, to: p.count, by: 4) where p[i + 3] > 200 {
            let l = (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 3
            lo = min(lo, l); hi = max(hi, l)
        }
        for i in Swift.stride(from: 0, to: p.count, by: 4) {
            let l = (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 3
            let v = UInt8(clamped: 255 * (0.86 + 0.14 * (l - lo) / max(1, hi - lo)))
            image.pixels[i] = v; image.pixels[i + 1] = v; image.pixels[i + 2] = v
        }
        return image
    }

    /// The soft paper shadow of a picture: its alpha blurred (a Gaussian of `sigma` pixels) on a canvas
    /// widened by `pad` pixels on every side, computed at 1/`reduce` of the size since it is soft anyway.
    /// White; the caller tints it. Returns the picture (1 pixel = `reduce` source pixels) and the padding in source pixels.
    static func shadow(of source: PuppetImage, sigma: Double, pad: Int, reduce: Int = 1) -> (image: PuppetImage, pad: Double) {
        let f = max(1, reduce), p = (pad + f - 1) / f
        let sw = (source.width + f - 1) / f, sh = (source.height + f - 1) / f
        let w = sw + 2 * p, h = sh + 2 * p
        var alpha = [Double](repeating: 0, count: w * h)
        for y in 0..<source.height { for x in 0..<source.width { alpha[(y / f + p) * w + x / f + p] += Double(source.alpha(x: x, y: y)) / Double(f * f) } }
        let sigma = sigma / Double(f)
        let radius = Int((3 * sigma).rounded(.up))
        let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        var temp = alpha
        for y in 0..<h {
            for x in 0..<w {
                var s = 0.0
                for k in -radius...radius { let xx = x + k; if xx >= 0 && xx < w { s += alpha[y * w + xx] * kernel[k + radius] } }
                temp[y * w + x] = s / total
            }
        }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var s = 0.0
                for k in -radius...radius { let yy = y + k; if yy >= 0 && yy < h { s += temp[yy * w + x] * kernel[k + radius] } }
                pixels[(y * w + x) * 4 + 3] = UInt8(clamped: s / total)
            }
        }
        // Each shadow pixel covers f×f source pixels, starting `p·f` source pixels above and left of the picture.
        return (PuppetImage(width: w, height: h, pixels: pixels), Double(p * f))
    }
}

extension UInt8 {
    /// Rounds and clamps like a canvas's image data.
    init(clamped value: Double) {
        guard value.isFinite else { self = 0; return }
        self = UInt8(Swift.min(255, Swift.max(0, value.rounded(.toNearestOrEven))))
    }
}
