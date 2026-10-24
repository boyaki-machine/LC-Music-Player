import CoreGraphics
import Foundation
import ImageIO

/// An RGBA picture with straight (not premultiplied) 8-bit colors; row 0 is the top.
/// Straight colors keep the hair color under transparent pixels, so edges never filter toward black.
struct PuppetImage: Sendable {
    let width: Int, height: Int
    var pixels: [UInt8]
    /// Where this picture lies in the picture it was cut from (0 when it is whole).
    private(set) var origin = (x: 0, y: 0)

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Cut down to the pixels that are not fully transparent, plus a margin for filtering. Most parts are
    /// small in their sheet-sized canvases; this keeps their textures small.
    func trimmed(margin: Int = 2) -> PuppetImage {
        guard let b = opaqueBounds(threshold: 0) else { return self }
        let x0 = max(0, b.x0 - margin), y0 = max(0, b.y0 - margin)
        let x1 = min(width - 1, b.x1 + margin), y1 = min(height - 1, b.y1 + margin)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let s = ((y + y0) * width + x0) * 4
            out.replaceSubrange(y * w * 4..<(y + 1) * w * 4, with: pixels[s..<s + w * 4])
        }
        var image = PuppetImage(width: w, height: h, pixels: out)
        image.origin = (origin.x + x0, origin.y + y0)
        return image
    }

    func alpha(x: Int, y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }

    /// The smallest box holding every pixel whose alpha is above `threshold`.
    func opaqueBounds(threshold: UInt8 = 8) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > threshold {
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
            }
        }
        return x1 < 0 ? nil : (x0, y0, x1, y1)
    }

    /// Draws with CoreGraphics in canvas coordinates (y down) and returns straight colors, like a canvas's image data.
    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> PuppetImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        body(context)
        return PuppetImage(premultiplied: context)
    }

    /// Reads a premultiplied RGBA bitmap context (row 0 at the top) as straight colors.
    init(premultiplied context: CGContext) {
        let width = context.width, height = context.height, stride = context.bytesPerRow
        let source = context.data!.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let s = y * stride + x * 4, d = (y * width + x) * 4, a = Int(source[s + 3])
                pixels[d + 3] = UInt8(a)
                guard a > 0 else { continue }
                for c in 0..<3 { pixels[d + c] = UInt8(min(255, (Int(source[s + c]) * 255 + a / 2) / a)) }
            }
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// Decodes a PNG without premultiplying, so transparent pixels keep the colors the art tools gave them.
    /// With `maxSize`, a large picture is decoded smaller (its longer side at most that many pixels).
    static func load(_ url: URL, maxSize: Int? = nil) -> PuppetImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let image: CGImage?
        if let maxSize {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: maxSize,
                                                                     kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let image else { return nil }
        let width = image.width, height = image.height
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .last,
           order == [] || order == .byteOrder32Big, let data = image.dataProvider?.data as Data? {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for i in 0..<width * 4 { pixels[y * width * 4 + i] = bytes[y * image.bytesPerRow + i] }
                }
            }
            return PuppetImage(width: width, height: height, pixels: pixels)
        }
        return draw(width: width, height: height) { context in
            // Undo the canvas flip: CGContext.draw places images in its own y-up space.
            context.saveGState(); context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }
    }
}

/// One puppet as measured on the source sheet (`assets/puppet-show/puppets.png`), in its pixels.
/// Written by `scripts/make-puppet-parts.py` together with the parts.
struct PuppetCharacter: Decodable, Sendable {
    let box: [Double]
    let headCX: Double
    let headCenter: [Double]
    let headRadius: [Double]
    let hairScale: Double
    let sideburnY: Double
    let cutY: Double
    let eyes: [[Double]]
    let pivotArmL: [Double], pivotArmR: [Double], pivotNeck: [Double]
    let hipY: Double
    let skin: [Double], hair: [Double]

    enum CodingKeys: String, CodingKey {
        case box, eyes, skin, hair
        case headCX = "head_cx", headCenter = "head_center", headRadius = "head_radius", hairScale = "hair_scale"
        case sideburnY = "sideburn_y", cutY = "cut_y", pivotArmL = "pivot_arm_l", pivotArmR = "pivot_arm_r"
        case pivotNeck = "pivot_neck", hipY = "hip_y"
    }
}

/// The art bundled with the app: background pictures and the puppets' parts.
enum PuppetShowArt {
    static let bundleName = "LCMP_PlayerUI.bundle"
    private final class Token {}

    /// The `Art` folder. The macOS app keeps the resource bundle in Contents/Resources (a bundle in the
    /// app's root breaks code signing), the iPhone app in its root, and `swift build` products and
    /// tests next to the executable.
    static let directory: URL? = {
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle(for: Token.self).bundleURL.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            // Bundle finds the resources in both layouts: Contents/Resources on macOS, flat on iOS.
            guard let art = Bundle(url: root.appendingPathComponent(bundleName))?.resourceURL?.appendingPathComponent("Art") else { continue }
            if FileManager.default.fileExists(atPath: art.appendingPathComponent("characters.json").path) { return art }
        }
        return nil
    }()

    static func image(_ name: String, maxSize: Int? = nil) -> PuppetImage? {
        directory.flatMap { PuppetImage.load($0.appendingPathComponent(name + ".png"), maxSize: maxSize) }
    }

    static func characters() -> [String: PuppetCharacter]? {
        guard let url = directory?.appendingPathComponent("characters.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: PuppetCharacter].self, from: data)
    }
}
