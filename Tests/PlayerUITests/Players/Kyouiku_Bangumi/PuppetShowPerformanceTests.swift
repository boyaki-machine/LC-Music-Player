#if os(macOS)
import Foundation
import Metal
import Testing
@testable import PlayerUI
@testable import VisualizationKit

/// Load and per-frame cost of the puppet show. Run in release to judge the numbers:
/// LCMP_PUPPET_PERF=1 ./scripts/swift.sh test -c release --filter PuppetShowPerformanceTests
@MainActor
@Suite(.serialized) struct PuppetShowPerformanceTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["LCMP_PUPPET_PERF"] == "1" }

    @Test(.enabled(if: PuppetShowPerformanceTests.enabled)) func measuresLoadAndFrameCost() throws {
        let clock = ContinuousClock()
        var renderer: PuppetShowRenderer?
        let load = clock.measure { renderer = PuppetShowArtwork.load().flatMap { PuppetShowRenderer(artwork: $0) } }
        let stage = try #require(renderer)
        var bytes = 0
        let mirror = Mirror(reflecting: stage)
        for child in mirror.children {
            if let t = child.value as? MTLTexture { bytes += t.allocatedSize }
            if let d = child.value as? [PuppetTexture: MTLTexture] { bytes += d.values.reduce(0) { $0 + $1.allocatedSize } }
            if let d = child.value as? [String: MTLTexture] { bytes += d.values.reduce(0) { $0 + $1.allocatedSize } }
        }
        print("puppet-perf load \(load) textures \(bytes / 1_048_576)MB")
        print("puppet-perf fabric \(clock.measure { _ = PuppetShowPatterns.fabric() })")
        print("puppet-perf pictures \(clock.measure { for n in PuppetBackdrop.landPictures + PuppetBackdrop.cloudPictures { _ = PuppetShowArt.image(n) } })")
        print("puppet-perf parts \(clock.measure { for m in PuppetMember.all { for p in ["body", "arm_l", "arm_r", "decal", "hair_cap", "hair_extra"] { _ = PuppetShowArt.image("\(m.name)/\(p)") } } })")
        let cloud = try #require(PuppetShowArt.image("cloud-dark"))
        print("puppet-perf shadow \(clock.measure { _ = PuppetShowPatterns.shadow(of: cloud, sigma: 25, pad: 75, reduce: 4) })")

        // A Mac window's stage (360×144pt at 2x) and an iPhone filling a landscape screen (about 2.6× at 3x).
        for (label, width, height) in [("mac", 720, 288), ("iphone", 2796, 1118)] {
            let device = stage.device
            func target(_ format: MTLPixelFormat, _ samples: Int) -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
                d.textureType = samples > 1 ? .type2DMultisample : .type2D; d.sampleCount = samples
                d.usage = .renderTarget; d.storageMode = .private
                return device.makeTexture(descriptor: d)!
            }
            let msaa = target(PuppetShowRenderer.colorFormat, 4), depth = target(PuppetShowRenderer.depthFormat, 4)
            let resolved = target(PuppetShowRenderer.colorFormat, 1)
            var directors = PuppetMember.all.map { PuppetDirector(member: $0) }
            var ensemble = PuppetEnsemble()
            var scene = PuppetShowScene(); scene.timeOfDay = 0.8
            var cpu: [Double] = [], gpu: [Double] = []
            for frame in 0..<300 {
                let t = Double(frame) / 30
                let started = clock.now
                let beat = PuppetBeat(count: t * 2, bpm: 120)
                let levels = (0..<4).map { 0.5 + 0.4 * sin(t * 7 + Double($0)) }
                for i in directors.indices { directors[i].update(dt: 1 / 30, now: t, levels: levels, beat: beat) }
                ensemble.update(&directors, now: t)
                scene.time = t; scene.poses = directors.map { $0.pose(now: t) }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = msaa; pass.colorAttachments[0].resolveTexture = resolved
                pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .multisampleResolve
                pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
                let commands = stage.queue.makeCommandBuffer()!
                let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
                stage.encode(scene, into: encoder, size: CGSize(width: width, height: height))
                encoder.endEncoding(); commands.commit()
                let encoded = clock.now - started
                commands.waitUntilCompleted()
                cpu.append(Double(encoded.components.attoseconds) / 1e15 + Double(encoded.components.seconds) * 1000)
                gpu.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
            }
            func summary(_ v: [Double]) -> String {
                let s = v.dropFirst(10).sorted()
                return String(format: "median %.2fms p95 %.2fms", s[s.count / 2], s[Int(Double(s.count) * 0.95)])
            }
            print("puppet-perf \(label) \(width)x\(height) cpu \(summary(cpu)) gpu \(summary(gpu))")
        }
    }
}
#endif
