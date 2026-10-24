import CoreGraphics
import ImageIO
import SwiftUI

enum PuppetShowThumbnail {
    static let fileName = "thumbnail"

    /// The card picture bundled in `Art/`: shown at once, without loading the stage. It is the still that
    /// `render(_:)` draws; regenerate it when the puppets' look changes (see the design document).
    @MainActor static let bundled: CGImage? = {
        guard let url = PuppetShowArt.directory?.appendingPathComponent(fileName + ".png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    @MainActor static func image() -> CGImage? { bundled }

    /// The boy with glasses in the morning, cut from a still of the stage.
    @MainActor static func render(_ renderer: PuppetShowRenderer) -> CGImage? {
        guard let stage = renderer.image(PuppetShowScene(), width: 900, height: 360) else { return nil }
        // 900×360 pixels is 2.5 per stage point; the boy stands at x = 224.
        return stage.cropping(to: CGRect(x: 224 * 2.5 - 112, y: 118, width: 224, height: 168))
    }

    /// The still picture on the display tab's selection card.
    static func draw(_ context: GraphicsContext, size: CGSize, image: CGImage?) {
        guard let image else { return }
        context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size))
    }
}
