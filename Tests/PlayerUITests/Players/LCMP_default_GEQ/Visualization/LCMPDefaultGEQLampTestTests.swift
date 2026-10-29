#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PlayerUI
import VisualizationKit

/// The LED's lamp test: the service sequence of the buttons, the sweeping pattern, and both renderers.
@MainActor struct LCMPDefaultGEQLampTestTests {
    static let size = CGSize(width: 360, height: 144)

    static func fingerprint(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// The presses of the service sequence, checked against its fingerprint.
    static var sequence: [LCMPDefaultGEQControl] {
        Array(0..<12).map(LCMPDefaultGEQServiceSequence.expected).prefix { $0 != 7 }.compactMap(LCMPDefaultGEQControl.init)
    }

    @Test func serviceSequenceIsUnchanged() {
        let presses = Self.sequence
        #expect(presses.count == 10)
        #expect(Self.fingerprint(presses.map { UInt8($0.rawValue) }) == 0x3451_2d22_5529_7ef2)
        #expect(presses.last == .menu)
    }

    @Test func onlyTheWholeSequenceStartsTheTest() {
        var sequence = LCMPDefaultGEQServiceSequence()
        let presses = Self.sequence
        for (i, control) in presses.enumerated() {
            let started = sequence.press(control, now: Double(i))
            #expect(started == (i == presses.count - 1))
        }
        // It starts over after completing.
        for (i, control) in presses.dropLast().enumerated() { let started = sequence.press(control, now: 20 + Double(i)); #expect(!started) }
        let again = sequence.press(presses.last!, now: 30)
        #expect(again)
    }

    @Test func aWrongPressStartsOver() {
        var sequence = LCMPDefaultGEQServiceSequence()
        let presses = Self.sequence
        let wrong = LCMPDefaultGEQControl.allCases.first { $0 != presses[5] && $0 != presses[0] }!
        for (i, control) in presses.prefix(5).enumerated() { _ = sequence.press(control, now: Double(i)) }
        let afterWrong = sequence.press(wrong, now: 5)
        #expect(!afterWrong)
        for (i, control) in presses.dropFirst(5).enumerated() { let started = sequence.press(control, now: 6 + Double(i)); #expect(!started) }
        for (i, control) in presses.enumerated() {
            let started = sequence.press(control, now: 20 + Double(i))
            #expect(started == (i == presses.count - 1))
        }
    }

    @Test func aLongPauseStartsOver() {
        let presses = Self.sequence
        var late = LCMPDefaultGEQServiceSequence(), onTime = LCMPDefaultGEQServiceSequence()
        var now = 0.0
        for control in presses.dropLast() { _ = late.press(control, now: now); _ = onTime.press(control, now: now); now += 1 }
        let lateStarted = late.press(presses.last!, now: now - 1 + LCMPDefaultGEQServiceSequence.timeout + 0.01)
        let onTimeStarted = onTime.press(presses.last!, now: now - 1 + LCMPDefaultGEQServiceSequence.timeout)
        #expect(!lateStarted)
        #expect(onTimeStarted)
    }

    @Test func patternIsUnchanged() {
        #expect(LCMPDefaultGEQLampTest.columns.count == 66)
        #expect(Self.fingerprint(LCMPDefaultGEQLampTest.columns) == 0x0f06_806c_2f40_86bc)
        #expect(LCMPDefaultGEQLampTest.columns.allSatisfy { $0 < 32 })
    }

    @Test func patternSweepsFromRightToLeftOnce() throws {
        let step = LCMPDefaultGEQLampTest.step
        #expect(try #require(LCMPDefaultGEQLampTest.pattern(at: 0)).allSatisfy { $0 == 0 })
        // The first column enters at the right edge, then moves one column per step.
        let first = UInt8(LCMPDefaultGEQLampTest.columns[0])
        let entering = try #require(LCMPDefaultGEQLampTest.pattern(at: step * 1.5))
        #expect(entering.dropLast().allSatisfy { $0 == 0 })
        #expect(entering[15] == LCMPDefaultGEQLampTest.rows(first))
        let moved = try #require(LCMPDefaultGEQLampTest.pattern(at: step * 2.5))
        #expect(moved[14] == LCMPDefaultGEQLampTest.rows(first))
        let last = try #require(LCMPDefaultGEQLampTest.pattern(at: LCMPDefaultGEQLampTest.duration - step / 2))
        #expect(last[0] == LCMPDefaultGEQLampTest.rows(LCMPDefaultGEQLampTest.columns.last!))
        #expect(last.dropFirst().allSatisfy { $0 == 0 })
        #expect(LCMPDefaultGEQLampTest.pattern(at: LCMPDefaultGEQLampTest.duration) == nil)
        #expect(LCMPDefaultGEQLampTest.pattern(at: -0.01) == nil)
        #expect(LCMPDefaultGEQLampTest.pattern(at: .nan) == nil)
    }

    @Test func dotsAreThreeRowsWithAGap() {
        #expect(LCMPDefaultGEQLampTest.rows(0) == 0)
        #expect(LCMPDefaultGEQLampTest.rows(1) == 0b111 << 2)
        #expect(LCMPDefaultGEQLampTest.rows(31) == 0b111_0111_0111_0111_0111 << 2)
        // Every row stays on the LED.
        #expect(LCMPDefaultGEQLampTest.rows(31) >> 24 == 0)
    }

    @Test func snapshotPatternReplacesTheBars() {
        var snapshot = SpectrumSnapshot()
        snapshot.counts = Array(repeating: 24, count: 16)
        snapshot.pattern = Array(repeating: 0b101, count: 16)
        #expect(snapshot.isOn(column: 3, row: 0))
        #expect(!snapshot.isOn(column: 3, row: 1))
        #expect(snapshot.isOn(column: 3, row: 2))
        #expect(!snapshot.isOn(column: 3, row: 10))
        // Bars that fell under the pattern leave no afterglow.
        snapshot.extinguishedAt[3 * 24 + 10] = 100
        #expect(snapshot.residual(column: 3, row: 10, now: 100.01) == 0)
        snapshot.pattern = nil; snapshot.counts[3] = 0
        #expect(snapshot.residual(column: 3, row: 10, now: 100.01) > 0)
    }

    @Test func driverRunsTheTestWhileStoppedAndEndsIt() throws {
        let driver = VisualizationDriver()
        driver.synchronize(activity: .inactive, visible: true)
        #expect(!driver.isRunning)
        driver.startLampTest(at: VisualizationClock.now() - LCMPDefaultGEQLampTest.step * 20)
        #expect(driver.isTestingLamps)
        #expect(driver.isRunning)
        #expect(try #require(driver.snapshot.pattern).contains { $0 != 0 })
        // A stop or a reset while visible keeps it running.
        driver.synchronize(activity: .inactive, visible: true)
        driver.reset()
        #expect(driver.isTestingLamps && driver.isRunning && driver.snapshot.pattern != nil)
        driver.endLampTest()
        #expect(!driver.isTestingLamps)
        #expect(driver.snapshot.pattern == nil)
        #expect(!driver.isRunning)
    }

    @Test func driverEndsTheTestAfterOnePass() {
        let driver = VisualizationDriver()
        driver.synchronize(activity: .paused, visible: true)
        driver.startLampTest(at: VisualizationClock.now() - LCMPDefaultGEQLampTest.duration)
        #expect(!driver.isTestingLamps)
        #expect(driver.snapshot.pattern == nil)
        #expect(!driver.isRunning)
    }

    @Test func hiddenDriverDoesNotTest() {
        let driver = VisualizationDriver()
        driver.startLampTest()
        #expect(!driver.isTestingLamps)
        driver.synchronize(activity: .playing, visible: true)
        driver.startLampTest()
        #expect(driver.isTestingLamps)
        driver.synchronize(activity: .playing, visible: false)
        #expect(!driver.isTestingLamps)
        #expect(driver.snapshot.pattern == nil)
    }

    @Test func playerStartsTheTestFromItsButtons() {
        let presentation = PlayerPresentation(preferences: MemoryPreferences())
        let driver = presentation.visualizationDriver
        driver.synchronize(activity: .inactive, visible: true)
        press(Self.sequence, on: presentation)
        #expect(driver.isTestingLamps)
        // Any press ends it.
        presentation.pressed(.volume)
        #expect(!driver.isTestingLamps)
        driver.endLampTest()
    }

    @Test func closingTheMenuAlsoCompletes() {
        let presentation = PlayerPresentation(preferences: MemoryPreferences())
        presentation.visualizationDriver.synchronize(activity: .inactive, visible: true)
        presentation.toggleExtension()
        press(Self.sequence, on: presentation)
        #expect(!presentation.extensionVisible)
        #expect(presentation.visualizationDriver.isTestingLamps)
        presentation.visualizationDriver.endLampTest()
    }

    @Test func otherDesignsDoNotTest() {
        let presentation = PlayerPresentation(preferences: MemoryPreferences())
        presentation.setVisualizationDesign(.ermineChorus)
        presentation.visualizationDriver.synchronize(activity: .inactive, visible: true)
        press(Self.sequence, on: presentation)
        #expect(!presentation.visualizationDriver.isTestingLamps)
        presentation.visualizationDriver.synchronize(activity: .inactive, visible: false)
    }

    /// Presses as the player view does: the menu button toggles the extension before it is reported.
    private func press(_ controls: [LCMPDefaultGEQControl], on presentation: PlayerPresentation) {
        for (i, control) in controls.enumerated() {
            if control == .menu { presentation.toggleExtension() }
            presentation.pressed(control, now: 1000 + Double(i))
        }
    }

    /// Lit cells of a pattern look lit in both renderers, the others unlit.
    @Test(arguments: [1.0, 2.0])
    func renderersDrawThePattern(scale: Double) throws {
        let metal = try #require(LCMPDefaultGEQMetal.shared)
        var snapshot = SpectrumSnapshot()
        snapshot.counts = Array(repeating: 24, count: 16)
        snapshot.pattern = try #require(LCMPDefaultGEQLampTest.pattern(at: LCMPDefaultGEQLampTest.step * 20.5))
        let frame = LCMPDefaultGEQFrame(snapshot: snapshot, now: 100)
        let layout = LCMPDefaultGEQLayout(size: Self.size, axisLabelSize: 9)
        let canvas = try pixels(canvasImage(frame, scale: scale))
        let drawn = try pixels(#require(metal.image(frame, size: Self.size, scale: scale)))
        let width = Int(Self.size.width * scale)
        var lit = 0, unlit = 0
        for column in 0..<16 {
            for row in 0..<24 {
                let cell = layout.cell(column: column, row: row)
                let i = (Int(cell.midY * scale) * width + Int(cell.midX * scale)) * 4
                let on = LCMPDefaultGEQRenderer.onComponents[LCMPDefaultGEQLayout.colorIndex(row: row)]
                let expected = snapshot.isOn(column: column, row: row)
                if expected { lit += 1 } else { unlit += 1 }
                for image in [canvas, drawn] {
                    // Green tells lit from unlit in all three colors; the light around lit cells stays well below.
                    let green = Double(image[i + 1])
                    #expect(expected ? abs(green - on.y) < 3 : green < on.y - 30, "column \(column) row \(row) green \(green)")
                }
            }
        }
        #expect(lit > 20 && unlit > 200)
    }

    private func canvasImage(_ frame: LCMPDefaultGEQFrame, scale: Double) throws -> CGImage {
        let renderer = ImageRenderer(content: Canvas { context, size in
            LCMPDefaultGEQRenderer.draw(context: context, size: size, snapshot: frame.snapshot, now: frame.now,
                                        reduceMotion: frame.reduceMotion, axisLabelSize: frame.axisLabelSize)
        }.frame(width: Self.size.width, height: Self.size.height))
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
#endif
