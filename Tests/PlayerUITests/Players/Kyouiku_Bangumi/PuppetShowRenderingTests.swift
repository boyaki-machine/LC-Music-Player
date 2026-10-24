#if os(macOS)
import AppKit
import ImageIO
import Foundation
import Testing
@testable import PlayerUI

@MainActor
@Suite(.serialized) struct PuppetShowRenderingTests {
    static func save(_ image: CGImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The mock's simulated song (118 BPM): kick, snare, hi-hat and a singing voice, with a chorus and a break.
    static func simulatedLevels(_ t: Double) -> [Double] {
        let pb = 60 / 118.0, b = t / pb, ph = b - b.rounded(.down), beatN = Int(b.rounded(.down))
        let bar = beatN / 4, section = (beatN / 32) % 4
        let quiet = section == 3 && beatN % 32 >= 20, loud = section == 2
        let g = quiet ? 0.25 : loud ? 1 : 0.8
        let kick = exp(-ph * 7) * (quiet ? 0.1 : 1)
        let snare = beatN % 2 == 1 ? exp(-ph * 9) : 0
        let syl = max(0, sin(t * .pi * 2 * 3.6 + sin(t * 1.3) * 2))
        let phrase = (beatN % 8 < 7 ? 1 : 0.15) * (0.6 + 0.4 * PuppetRandom.hash(bar + 7))
        let vocal = pow(syl, 0.6) * phrase * g
        let hat = exp(-(b * 2).truncatingRemainder(dividingBy: 1) * 12) * (quiet ? 0.2 : 0.7)
        let c = { (v: Double) in PuppetMath.clamp(v) }
        return [c(0.15 + 0.8 * kick), c(0.2 + 0.5 * snare + 0.35 * vocal), c(0.1 + 0.85 * vocal), c(0.1 + 0.6 * hat + 0.2 * vocal)]
    }

    /// Plays the simulated song up to `seconds` at 30fps, as the mock's `?t=` does, optionally holding an action on everyone.
    static func simulate(_ seconds: Double, tod: Double = 0.3, ensemble: Bool = true,
                         action: WritableKeyPath<PuppetActions, Double>? = nil) -> PuppetShowScene {
        var directors = PuppetMember.all.map { PuppetDirector(member: $0) }
        var conductor = PuppetEnsemble()
        let dt = 1 / 30.0
        var t = 0.0
        while t < seconds {
            if let action { for i in directors.indices { directors[i].actions[keyPath: action] = 4 } }
            t += dt
            let beat = PuppetBeat(count: t * 118 / 60, bpm: 118)
            for i in directors.indices { directors[i].update(dt: dt, now: t, levels: simulatedLevels(t), beat: beat) }
            if ensemble { conductor.update(&directors, now: t) }
        }
        var scene = PuppetShowScene()
        scene.timeOfDay = tod; scene.time = t; scene.moonAge = 10
        scene.poses = directors.map { $0.pose(now: t) }
        return scene
    }

    @Test func drawsTheSimulatedSongAndEveryAction() throws {
        let renderer = try #require(PuppetShowLoader.shared.loadNow())
        Self.save(try #require(renderer.image(Self.simulate(12.3, ensemble: false), width: 900, height: 360)), "puppet-sim-12.3")
        let actions: [(String, WritableKeyPath<PuppetActions, Double>)] = [
            ("sparkle", \.sparkle), ("cry", \.cry), ("shout", \.shout), ("headbang", \.headbang), ("shy", \.shy), ("blush", \.blush), ("slump", \.slump),
        ]
        for (name, action) in actions {
            Self.save(try #require(renderer.image(Self.simulate(3, ensemble: false, action: action), width: 900, height: 360)), "puppet-fx-\(name)")
        }
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// The bundled card picture is the one the renderer draws now. After changing the puppets' look, regenerate it:
    /// LCMP_PUPPET_WRITE_THUMBNAIL=1 ./scripts/swift.sh test --filter PuppetShowRenderingTests
    @Test func theBundledCardPictureMatchesTheStage() throws {
        let renderer = try #require(PuppetShowLoader.shared.loadNow())
        let fresh = try #require(PuppetShowThumbnail.render(renderer))
        if ProcessInfo.processInfo.environment["LCMP_PUPPET_WRITE_THUMBNAIL"] == "1" {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let url = root.appendingPathComponent("Sources/PlayerUI/Players/Kyouiku_Bangumi/Art/\(PuppetShowThumbnail.fileName).png")
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, fresh, nil)
            #expect(CGImageDestinationFinalize(destination))
            // ImageIO adds EXIF and resolution chunks; the repository keeps only the picture.
            let png = data as Data
            var out = png.prefix(8), i = 8
            while i + 8 <= png.count {
                let length = png[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }, type = String(decoding: png[i + 4..<i + 8], as: UTF8.self)
                if type != "eXIf" && type != "pHYs" { out += png[i..<i + 12 + length] }
                i += 12 + length
            }
            try Data(out).write(to: url)
            return
        }
        let bundled = try #require(PuppetShowThumbnail.bundled, "the card picture is bundled")
        #expect(bundled.width == fresh.width && bundled.height == fresh.height)
        let a = Self.rgba(bundled), b = Self.rgba(fresh)
        var total = 0, far = 0
        for i in a.indices where i % 4 != 3 {
            let d = abs(Int(a[i]) - Int(b[i])); total += d; if d > 24 { far += 1 }
        }
        let mean = Double(total) / Double(a.count / 4 * 3)
        // The same GPU draws it identically; a slight change of skin color already differs by about 0.26.
        #expect(mean < 0.1 && far < a.count / 4 / 100, "mean difference \(mean), far channels \(far): regenerate the card picture")
    }

    @Test func drawsTheStageAtEveryTimeOfDay() throws {
        let renderer = try #require(PuppetShowLoader.shared.loadNow(), "Metal and the bundled art are available")
        for (name, tod) in [("morning", 0.05), ("noon", 0.3), ("evening", 0.5), ("night", 0.8)] {
            var scene = PuppetShowScene(); scene.timeOfDay = tod; scene.moonAge = 10
            let image = try #require(renderer.image(scene, width: 900, height: 360))
            Self.save(image, "puppet-stage-\(name)")
        }
    }
}
#endif
