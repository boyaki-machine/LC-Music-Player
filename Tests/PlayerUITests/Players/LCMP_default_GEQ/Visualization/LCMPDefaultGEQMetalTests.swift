#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PlayerUI

/// The Metal renderer against the Canvas renderer it replaces on screen. The Canvas renderer stays the
/// reference: the glow images are made from its blurred layers, so the two must stay close.
@MainActor struct LCMPDefaultGEQMetalTests {
    static let size = CGSize(width: 360, height: 144)

    /// No cells lit, some, all, and some with afterglow above them.
    static func states() -> [(name: String, frame: LCMPDefaultGEQFrame)] {
        var some = SpectrumSnapshot()
        some.counts = [3, 8, 12, 15, 17, 20, 13, 9, 6, 11, 14, 7, 5, 3, 2, 1]
        var full = SpectrumSnapshot(); full.counts = Array(repeating: 24, count: 16)
        var afterglow = some
        for column in 0..<16 {
            for row in some.counts[column]..<min(24, some.counts[column] + 6) {
                afterglow.extinguishedAt[column * 24 + row] = 100 - Double(row - some.counts[column]) * 0.02
            }
        }
        return [("off", LCMPDefaultGEQFrame(now: 100)), ("some", LCMPDefaultGEQFrame(snapshot: some, now: 100)),
                ("full", LCMPDefaultGEQFrame(snapshot: full, now: 100)), ("afterglow", LCMPDefaultGEQFrame(snapshot: afterglow, now: 100.01))]
    }

    @Test(arguments: [1.0, 2.0, 3.0])
    func metalLooksLikeCanvas(scale: Double) throws {
        let metal = try #require(LCMPDefaultGEQMetal.shared)
        // The labels are drawn by a separate Canvas over the Metal view; compare above them.
        let layout = LCMPDefaultGEQLayout(size: Self.size, axisLabelSize: 9)
        let rows = Int(((layout.labelY - 9) * scale).rounded(.down))
        for (name, frame) in Self.states() {
            let canvas = try pixels(canvasImage(frame, scale: scale))
            let drawn = try pixels(#require(metal.image(frame, size: Self.size, scale: scale)))
            let width = Int(Self.size.width * scale)
            var largest = 0, total = 0, visible = 0, count = 0
            for y in 0..<rows {
                for x in 0..<width {
                    for channel in 0..<3 {
                        let i = (y * width + x) * 4 + channel
                        let d = abs(Int(canvas[i]) - Int(drawn[i]))
                        largest = max(largest, d); total += d; count += 1
                        if d > 4 { visible += 1 }
                    }
                }
            }
            let mean = Double(total) / Double(count), share = Double(visible) / Double(count)
            // Measured: mean 0.6 or less, max 27 (antialiased edges), 0.6% over 4 levels.
            #expect(mean < 1, "\(name) @\(scale)x mean \(mean)")
            #expect(largest <= 40, "\(name) @\(scale)x max \(largest)")
            #expect(share < 0.015, "\(name) @\(scale)x share over 4 levels \(share)")
        }
    }

    @Test func reduceMotionDrawsNoAfterglow() throws {
        let metal = try #require(LCMPDefaultGEQMetal.shared)
        let states = Self.states()
        var still = states[3].frame; still.reduceMotion = true
        // The same glow images: blurring them again can differ by a level or two.
        let glow = try #require(LCMPDefaultGEQGlow(layout: LCMPDefaultGEQLayout(size: Self.size, axisLabelSize: 9), scale: 2, device: metal.device))
        let withoutAfterglow = try pixels(#require(metal.image(still, glow: glow)))
        let lit = try pixels(#require(metal.image(states[1].frame, glow: glow)))
        let glowing = try pixels(#require(metal.image(states[3].frame, glow: glow)))
        #expect(withoutAfterglow == lit)
        #expect(glowing != lit)
    }

    @Test func lightAroundLitCellsIsDrawn() throws {
        let metal = try #require(LCMPDefaultGEQMetal.shared)
        let layout = LCMPDefaultGEQLayout(size: Self.size, axisLabelSize: 9)
        let full = try pixels(#require(metal.image(Self.states()[2].frame, size: Self.size, scale: 1)))
        let off = try pixels(#require(metal.image(Self.states()[0].frame, size: Self.size, scale: 1)))
        // The middle of the gap between the first two columns: dark when unlit, lit by the light around them.
        let x = Int(layout.columnX(1) - 3.5), y = Int(layout.plot.midY)
        let i = (y * Int(Self.size.width) + x) * 4 + 1
        #expect(Int(full[i]) - Int(off[i]) > 20)
    }

    @Test func glowImagesFollowTheSizeAndScale() throws {
        let metal = try #require(LCMPDefaultGEQMetal.shared)
        let layout = LCMPDefaultGEQLayout(size: Self.size, axisLabelSize: 9)
        let glow = try #require(LCMPDefaultGEQGlow(layout: layout, scale: 2, device: metal.device))
        #expect(glow.matches(layout, scale: 2))
        #expect(!glow.matches(layout, scale: 3))
        #expect(!glow.matches(LCMPDefaultGEQLayout(size: CGSize(width: 400, height: 144), axisLabelSize: 9), scale: 2))
        #expect(!glow.matches(LCMPDefaultGEQLayout(size: Self.size, axisLabelSize: 13), scale: 2))
        // Kept small: 4.2MB for the macOS window at 2x.
        #expect(glow.bytes < 6 << 20)
        #expect(LCMPDefaultGEQGlow(layout: LCMPDefaultGEQLayout(size: CGSize(width: 40, height: 40), axisLabelSize: 9), scale: 2, device: metal.device) == nil)
    }

    /// The Metal view takes each frame from the driver itself, and lets go of it when dismantled.
    @Test func stageFollowsTheDriverWithoutSwiftUI() async throws {
        let metal = try #require(LCMPDefaultGEQMetal.shared)
        let driver = VisualizationDriver()
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        let stage = LCMPDefaultGEQStageCoordinator(metal: metal)
        _ = stage.makeView()
        stage.follow(driver, reduceMotion: false, axisLabelSize: 9)
        driver.receive(frame(levels: Array(repeating: 1, count: 16)))
        try await Task.sleep(for: .milliseconds(10))
        #expect(stage.frame.snapshot == driver.snapshot && stage.frame.now == driver.drawTime)
        #expect(stage.frame.snapshot.counts.allSatisfy { $0 > 0 })

        stage.follow(driver, reduceMotion: true, axisLabelSize: 16)
        #expect(stage.frame.reduceMotion && stage.frame.axisLabelSize == 16)

        stage.follow(nil, reduceMotion: false, axisLabelSize: 9)
        let kept = stage.frame
        driver.receive(frame(levels: Array(repeating: 0.1, count: 16), sequence: 2))
        try await Task.sleep(for: .milliseconds(80))
        #expect(driver.snapshot != kept.snapshot)
        #expect(stage.frame.snapshot == kept.snapshot)
    }

    /// The waiting message has its own value, which does not change with every frame.
    @Test func waitingIsPublishedOnlyWhenItChanges() async throws {
        let driver = VisualizationDriver()
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        let changes = ChangeCount()
        withObservationTracking { _ = driver.waitingForData } onChange: { changes.add() }
        driver.receive(frame(levels: Array(repeating: 1, count: 16)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes.value == 0 && !driver.waitingForData)
        // No new frame for longer than the missing interval: the message appears once.
        try await Task.sleep(for: .milliseconds(400))
        #expect(driver.waitingForData == driver.snapshot.waitingForData && driver.waitingForData)
        #expect(changes.value == 1)
    }

    private func canvasImage(_ frame: LCMPDefaultGEQFrame, scale: Double) throws -> CGImage {
        let renderer = ImageRenderer(content: Canvas { context, size in
            LCMPDefaultGEQRenderer.draw(context: context, size: size, snapshot: frame.snapshot, now: frame.now,
                                        reduceMotion: frame.reduceMotion, axisLabelSize: frame.axisLabelSize)
        }.frame(width: Self.size.width, height: Self.size.height))
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    /// RGBA in sRGB, whatever the image's own layout.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
private final class ChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
#endif
