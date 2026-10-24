import Foundation
import Observation

/// Everything the stage needs, prepared on the CPU: pictures, drawn patterns and the assembled puppets.
/// Building it takes a few tenths of a second, so it is done off the main thread.
struct PuppetShowArtwork: Sendable {
    struct Shadow: Sendable { let image: PuppetImage; let pad: Double, width: Double, height: Double }
    var pictures: [String: PuppetImage] = [:]
    /// Each cloud's paper shadow and where it lies around the cloud, in stage points.
    var cloudShadows: [Shadow] = []
    var textures: [PuppetTexture: PuppetImage] = [:]
    var rigs: [PuppetRig] = []

    /// The land pictures are 656 pixels high. A Mac window shows the land about 216 pixels high, so half is
    /// enough there; an iPhone filling the screen needs them whole.
    static var landMaxSize: Int? {
        #if os(macOS)
        Int(PuppetBackdrop.landPictureSize.width / 2)
        #else
        nil
        #endif
    }

    static func load() -> PuppetShowArtwork? {
        guard let characters = PuppetShowArt.characters() else { return nil }
        var art = PuppetShowArtwork()
        for name in ["sun", "comet", "birds", "airplane"] {
            guard let image = PuppetShowArt.image(name) else { return nil }
            art.pictures[name] = image
        }
        for name in PuppetBackdrop.landPictures {
            guard let image = PuppetShowArt.image(name, maxSize: landMaxSize) else { return nil }
            art.pictures[name] = image
        }
        for (shape, name) in PuppetBackdrop.cloudPictures.enumerated() {
            guard let image = PuppetShowArt.image(name) else { return nil }
            art.pictures[name] = PuppetShowPatterns.neutralCloud(image)
            // The canvas shadow's blur of 3pt is a Gaussian of 1.5pt; in this picture's pixels at its drawn width.
            let width = PuppetBackdrop.clouds.first { $0.shape == shape }!.width
            let perPoint = Double(image.width) / width, reduce = 4
            let shadow = PuppetShowPatterns.shadow(of: image, sigma: 1.5 * perPoint, pad: Int((4.5 * perPoint).rounded(.up)), reduce: reduce)
            art.cloudShadows.append(Shadow(image: shadow.image, pad: shadow.pad / perPoint,
                                           width: Double(shadow.image.width * reduce) / perPoint,
                                           height: Double(shadow.image.height * reduce) / perPoint))
        }
        let fabric = PuppetShowPatterns.fabric()
        art.textures[.fabric] = fabric.image
        art.textures[.mouthCap(tongue: false)] = PuppetShowPatterns.mouthCap(tongue: false)
        art.textures[.mouthCap(tongue: true)] = PuppetShowPatterns.mouthCap(tongue: true)
        art.textures[.blush] = PuppetShowPatterns.blush()
        art.textures[.shoutLine] = PuppetShowPatterns.shoutLine()
        art.textures[.tearStream] = PuppetShowPatterns.tearStream()
        for (index, member) in PuppetMember.all.enumerated() {
            guard let character = characters[member.name] else { return nil }
            var images: [String: PuppetImage] = [:]
            for part in ["body", "arm_l", "arm_r", "decal", "hair_cap", "hair_extra"] {
                guard let image = PuppetShowArt.image("\(member.name)/\(part)")?.trimmed() else { continue }
                images[part] = image
                art.textures[.art("\(member.name)/\(part)")] = image
            }
            let skin = PuppetMember.skin(member.name, measured: character.skin)
            art.textures[.eyeGlow(member.name)] = PuppetShowPatterns.eyeGlow(member.eyes)
            art.textures[.eyeCore(member.name)] = PuppetShowPatterns.eyeCore(member.eyes)
            art.textures[.ripple(member.name)] = PuppetShowPatterns.ripple(member.eyes)
            for squeeze in [nil, false, true] as [Bool?] {
                art.textures[.coveredEye(member.name, squeeze: squeeze)] = PuppetShowPatterns.coveredEye(skin: skin, squeeze: squeeze)
            }
            art.rigs.append(PuppetRig(member: member, index: index, character: character, images: images, fabricMean: fabric.mean))
        }
        return art
    }
}

/// Loads the stage once, in the background, and keeps it for every view and the selection card.
@Observable @MainActor
final class PuppetShowLoader {
    static let shared = PuppetShowLoader()
    private(set) var renderer: PuppetShowRenderer?
    /// True when Metal or the art is unavailable; the view then shows only the sky.
    private(set) var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Starts loading if it has not started.
    func request() {
        guard renderer == nil, !failed, task == nil else { return }
        task = Task { @MainActor in
            let artwork = await Task.detached(priority: .userInitiated) { PuppetShowArtwork.load() }.value
            if let artwork, let renderer = PuppetShowRenderer(artwork: artwork) { self.renderer = renderer } else { failed = true }
            task = nil
        }
    }

    /// Loads at once on the calling thread (tests).
    func loadNow() -> PuppetShowRenderer? {
        if let renderer { return renderer }
        guard let artwork = PuppetShowArtwork.load(), let renderer = PuppetShowRenderer(artwork: artwork) else { failed = true; return nil }
        self.renderer = renderer
        return renderer
    }
}
