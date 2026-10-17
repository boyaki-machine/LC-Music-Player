import AppKit
import SwiftUI
import Testing
@testable import AnalysisCore
@testable import VisualizationKit
@testable import PlayerUI

@Suite struct ErmineChorusKeyTests {
    @Test func everyKeyIsAuthoredAndRaisedLegsPassBehindTheHead() {
        for name in ErmineKeyName.allCases { #expect(ErmineKeys.table[name] != nil, "missing key \(name)") }
        for name in [ErmineKeyName.jumpAir, .jumpAir2, .armsUp, .flex, .flexL, .flexR] { #expect(name.key.armsBehind) }
        #expect(ErmineKeyName.back.key.back && !ErmineKeyName.idleA.key.back)
        // Ermine 5 keeps his tail inside the right edge of the stage.
        #expect(ErmineCast.members.first { $0.id == 5 }?.features.tailSide == -1)
    }

    @Test func inbetweensEaseBetweenKeysAndCutsStayCuts() {
        #expect(ErmineInbetweener.ease(0) == 0 && ErmineInbetweener.ease(1) == 1 && ErmineInbetweener.ease(0.5) == 0.5)
        #expect(ErmineInbetweener.ease(0.25) < 0.25 && ErmineInbetweener.ease(0.75) > 0.75) // slow in, slow out
        let mid = ErmineInbetweener.lerp(ErmineKeyName.squash.key, ErmineKeyName.up.key, 0.5)
        #expect(mid.neck.y == (-51 + -69) / 2 && mid.hipW == (18 + 13) / 2)
        #expect(ErmineInbetweener.duration(from: .tallA, to: .tallB) == 0)
        #expect(ErmineInbetweener.duration(from: .reach, to: .reachSm) == 0)
        #expect(ErmineInbetweener.duration(from: .spin1, to: .back) == 0 && ErmineInbetweener.duration(from: .back, to: .spin2) == 0)
        #expect(ErmineInbetweener.duration(from: .idleA, to: .idleB) == 0.5)
        #expect(ErmineInbetweener.duration(from: .squash, to: .up) == 0.1)

        var tween = ErmineInbetweener()
        _ = tween.pose(for: .squash, at: 10)
        _ = tween.pose(for: .squash, at: 10.2) // settled on the key
        let start = tween.pose(for: .up, at: 10.2), half = tween.pose(at: 10.25), end = tween.pose(at: 10.3)
        #expect(start.neck.y == ErmineKeyName.squash.key.neck.y)
        #expect(half.neck.y < start.neck.y && half.neck.y > end.neck.y)
        #expect(end == ErmineKeyName.up.key)
        _ = tween.pose(for: .back, at: 11)
        #expect(tween.pose(at: 11) == ErmineKeyName.back.key) // cut, no in-between
    }
}

@Suite struct ErmineChorusBandTests {
    private let edges = (0...16).map { 20 * pow(1000, Double($0) / 16) }

    @Test func everyRegisterGetsBandsFromLowToHigh() throws {
        var owners = Array(repeating: 0, count: ErmineRange.allCases.count)
        for i in 0..<16 { owners[ErmineRange.of(centerHz: (edges[i] * edges[i + 1]).squareRoot()).rawValue] += 1 }
        #expect(owners.allSatisfy { $0 > 0 }, "\(owners)")
        // Only the bass bands are loud: only the bass register reads high.
        let db = (0..<16).map { i -> Float in ErmineRange.of(centerHz: (edges[i] * edges[i + 1]).squareRoot()) == .bass ? -10 : -95 }
        let registers = try #require(ErmineBandLevels.registerDB(bandDBFS: db, edgesHz: edges))
        #expect(registers[ErmineRange.bass.rawValue] > -11 && registers[ErmineRange.high.rawValue] < -90)
        #expect(ErmineBandLevels.registerDB(bandDBFS: Array(repeating: .nan, count: 16), edgesHz: edges) == nil)
        #expect(ErmineBandLevels.registerDB(bandDBFS: Array(repeating: -20, count: 15), edgesHz: edges) == nil)
    }

    @Test func eachRegisterFollowsItsOwnPeakSoQuietRegistersStillSing() throws {
        var bands = ErmineBandLevels()
        // A song whose highs sit 40 dB below its bass still drives every register to its top.
        let db = (0..<16).map { i -> Float in i < 8 ? -12 : -52 }
        let firstResult = bands.levels(bandDBFS: db, edgesHz: edges, dt: 0)
        let first = try #require(firstResult)
        #expect(first.allSatisfy { $0 > 0.99 }, "\(first)")
        // 15 dB below the recent peak reads half way.
        let softerResult = bands.levels(bandDBFS: db.map { $0 - 15 }, edgesHz: edges, dt: 0)
        let softer = try #require(softerResult)
        #expect(softer.allSatisfy { abs($0 - 0.5) < 0.02 }, "\(softer)")
        // Silence never sings, and the floor keeps noise from being amplified.
        let silentResult = bands.levels(bandDBFS: Array(repeating: -100, count: 16), edgesHz: edges, dt: 0)
        let silent = try #require(silentResult)
        #expect(silent.allSatisfy { $0 == 0 })
        var fresh = ErmineBandLevels()
        let hissResult = fresh.levels(bandDBFS: Array(repeating: -85, count: 16), edgesHz: edges, dt: 0)
        let hiss = try #require(hissResult)
        #expect(hiss.allSatisfy { $0 == 0 })
        // The peak releases slowly, so the next song re-learns its own range.
        _ = bands.levels(bandDBFS: Array(repeating: -100, count: 16), edgesHz: edges, dt: 10)
        #expect(bands.peaks[0] == -12 - ErmineBandLevels.releaseDBPerSecond * 10)
    }
}

@Suite struct ErmineChorusDirectorTests {
    private func member(_ id: Int) -> ErmineCastMember { ErmineCast.members.first { $0.id == id }! }

    /// Runs one ermine at 60 steps per second and records the key of every drawing.
    private func run(_ director: inout ErmineDirector, seconds: Double, level: Double, world: ErmineWorld = ErmineWorld()) -> [ErmineFrame] {
        var frames: [ErmineFrame] = []
        for _ in 0..<Int(seconds * 60) {
            director.step(dt: 1.0 / 60, level: level, playing: true, world: world)
            frames.append(director.frame)
        }
        return frames
    }

    @Test func anOnsetDipsThenStretchesThenSettlesIntoASingingPose() {
        var director = ErmineDirector(member: member(1), seed: 1)
        _ = run(&director, seconds: 1, level: 0)
        let keys = run(&director, seconds: 0.6, level: 0.4).map(\.key)
        let dip = keys.firstIndex(of: .squash)
        #expect(dip != nil)
        if let dip { #expect(keys[(dip + 1)...].contains(.up)) }
        #expect(keys.last == .singL || keys.last == .singR)
        #expect(run(&director, seconds: 0.2, level: 0.4).last.map { $0.face.mouth != .closed } == true)
    }

    @Test func ermine1GoesOnTiptoeWhenLoudForAWhileAndComesBack() {
        var director = ErmineDirector(member: member(1), seed: 2)
        let loud = run(&director, seconds: 6, level: 0.95)
        #expect(director.intense)
        let tail = loud.suffix(24)
        #expect(tail.contains { $0.key == .tallA } && tail.contains { $0.key == .tallB })
        #expect(tail.allSatisfy { $0.face.eye == .squeeze && $0.face.sweat != nil })
        _ = run(&director, seconds: 6, level: 0)
        #expect(!director.intense)
    }

    @Test func ermine4LooksAfterErmine1WithATroubledFace() {
        var director = ErmineDirector(member: member(4), seed: 3)
        let frames = run(&director, seconds: 1, level: 0.3, world: ErmineWorld(ermine1Intense: true))
        #expect(frames.suffix(6).allSatisfy { $0.key == .glanceL && $0.face.troubledBrows })
        let after = run(&director, seconds: 1, level: 0.3)
        #expect(after.last?.key != .glanceL)
    }

    @Test func ermine3JumpsOnlyWhenCarriedAway() {
        var calm = ErmineDirector(member: member(3), seed: 4)
        #expect(!run(&calm, seconds: 4, level: 0.3).contains { $0.key == .jumpAir })
        var hyped = ErmineDirector(member: member(3), seed: 4)
        // Loud beats: alternate levels so onsets keep coming.
        var frames: [ErmineFrame] = []
        for i in 0..<(8 * 60) {
            hyped.step(dt: 1.0 / 60, level: (i / 15) % 2 == 0 ? 1 : 0.55, playing: true, world: ErmineWorld())
            frames.append(hyped.frame)
        }
        #expect(frames.contains { $0.key == .jumpAir })
    }

    @Test func reduceMotionKeepsTheBodyStillButTheFaceSings() {
        var director = ErmineDirector(member: member(2), seed: 5)
        director.reduceMotion = true
        let frames = run(&director, seconds: 4, level: 0.8)
        #expect(frames.allSatisfy { $0.key == .idleA && $0.wag == 0 && $0.effects.shake == nil })
        #expect(frames.contains { $0.face.mouth != .closed })
    }

    @Test func pausedOrSilentErminesCloseTheirMouths() {
        var director = ErmineDirector(member: member(5), seed: 6)
        _ = run(&director, seconds: 2, level: 0.8)
        for _ in 0..<60 { director.step(dt: 1.0 / 60, level: 0.8, playing: false, world: ErmineWorld()) }
        #expect(director.frame.face.mouth == .closed)
    }
}

@Suite(.serialized) @MainActor struct ErmineChorusDriverTests {
    @Test func adoptsDueFramesDrivesRegistersAndReportsMissingData() {
        let driver = ErmineChorusDriver()
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        #expect(driver.isRunning)
        let id = UUID()
        driver.receive(frame(levels: Array(repeating: 0.8, count: 16), generation: id, sequence: 1))
        driver.receive(frame(levels: Array(repeating: 0.8, count: 16), generation: id, sequence: 1)) // stale: ignored
        #expect(driver.pendingCount == 1)
        let now = VisualizationClock.now()
        driver.step(now: now + 0.1)
        #expect(driver.levels.allSatisfy { $0 > 0.9 } && !driver.waitingForData)
        driver.step(now: now + 0.6)
        #expect(driver.waitingForData && driver.levels.allSatisfy { $0 == 0 })
        driver.reset()
        #expect(driver.pendingCount == 0)
    }

    @Test func stopsWhenHiddenOrStoppedAndSettlesAfterAPause() async throws {
        var driver: ErmineChorusDriver? = ErmineChorusDriver()
        weak let weakDriver = driver
        driver?.synchronize(activity: .playing, visible: true)
        driver?.receive(frame(levels: Array(repeating: 0.8, count: 16)))
        try await Task.sleep(for: .milliseconds(120))
        #expect(driver?.isRunning == true)
        driver?.synchronize(activity: .paused, visible: true)
        #expect(driver?.isRunning == true && driver?.pendingCount == 0) // settling into the idle pose
        try await Task.sleep(for: .seconds(ErmineChorusDriver.settleSeconds + 0.3))
        #expect(driver?.isRunning == false)
        #expect(driver?.drawings.allSatisfy { $0.frame.face.mouth == .closed } == true)
        driver?.synchronize(activity: .playing, visible: true)
        #expect(driver?.isRunning == true)
        driver?.synchronize(activity: .playing, visible: false)
        #expect(driver?.isRunning == false)
        driver?.synchronize(activity: .playing, visible: true)
        driver?.synchronize(activity: .inactive, visible: true)
        #expect(driver?.isRunning == false && driver?.drawings.allSatisfy { $0.pose == ErmineKeyName.idleA.key } == true)
        driver = nil
        try await Task.sleep(for: .milliseconds(80))
        #expect(weakDriver == nil)
    }

    @Test func designChoiceIsStoredAndSwitchingStopsTheOtherClock() {
        let preferences = MemoryPreferences()
        let presentation = PlayerPresentation(preferences: preferences)
        #expect(presentation.visualizationDesign == .fluorescentLED)
        presentation.visualizationDriver.synchronize(activity: .playing, visible: true)
        presentation.setVisualizationDesign(.ermineChorus)
        #expect(!presentation.visualizationDriver.isRunning)
        #expect(preferences.object(forKey: VisualizationDesign.preferenceKey) as? String == "ermineChorus")
        #expect(PlayerPresentation(preferences: preferences).visualizationDesign == .ermineChorus)
        presentation.ermineChorusDriver.synchronize(activity: .playing, visible: true)
        #expect(presentation.ermineChorusDriver.isRunning)
        presentation.visualizationVisible = false
        #expect(!presentation.ermineChorusDriver.isRunning && !presentation.visualizationDriver.isRunning)
        preferences.set("unknown", forKey: VisualizationDesign.preferenceKey)
        #expect(PlayerPresentation(preferences: preferences).visualizationDesign == .fluorescentLED)
        #expect(VisualizationDesign.configuration == LCMPDefaultGEQ.configuration)
    }
}

@Suite @MainActor struct ErmineChorusRenderingTests {
    /// Renders the stage at 2× and returns the bitmap.
    private func render(_ drawings: [ErmineDrawing]) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: Canvas { context, size in
            ErmineChorusRenderer.draw(context: context, size: size, drawings: drawings)
        }.frame(width: 360, height: 144))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }

    private func color(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = rep.colorAt(x: Int(x * 2), y: Int(y * 2)) ?? .black
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    @Test func drawsFiveErminesOnCratesWithTheirCoatColours() throws {
        let driver = ErmineChorusDriver()
        let rep = try render(driver.drawings)
        // Body centres: 7 × 0.8 pt above the feet line at y = 120 is fur, not background.
        let white = color(rep, 180, 100), brown = color(rep, 120 - 9, 112), light = color(rep, 60 - 9, 112)
        #expect(white.r > 0.9 && white.g > 0.9 && white.b > 0.85, "\(white)")
        #expect(brown.r > brown.b + 0.25, "\(brown)")
        #expect(light.r > 0.7 && light.r > light.b + 0.2, "\(light)")
        let crate = color(rep, 180, 129)
        #expect(crate.r > crate.b + 0.15, "\(crate)")
        let sky = color(rep, 5, 5)
        #expect(sky.r < 0.1 && sky.g < 0.1)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ermine-chorus-idle.png"))
        }
    }

    @Test func singingSceneRendersEveryKeyAndCelWithoutGaps() throws {
        // A contact sheet of every key with the busiest face and effects, plus a sung scene.
        var drawings: [ErmineDrawing] = []
        for (i, name) in ErmineKeyName.allCases.enumerated() {
            let face = ErmineFace(eye: [.open, .surprise, .half, .closed, .happy, .squeeze][i % 6],
                                  mouth: [.closed, .small, .medium, .large, .round][i % 5], troubledBrows: i % 2 == 0,
                                  glint: i % 3 == 0, blush: 4, sweat: i)
            let effects = ErmineEffects(shake: i, laugh: i, notes: [ErmineNote(position: CGPoint(x: 20, y: -90), glyph: "♪", size: 12)])
            drawings.append(ErmineDrawing(pose: name.key, frame: ErmineFrame(key: name, face: face, effects: effects, wag: 1)))
        }
        for start in stride(from: 0, to: drawings.count, by: 5) {
            let group = Array(drawings[start..<min(start + 5, drawings.count)])
            let rep = try render(group + Array(repeating: group[0], count: 5 - group.count))
            #expect(rep.pixelsWide == 720)
            if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("ermine-chorus-keys-\(start / 5).png"))
            }
        }
        let driver = ErmineChorusDriver()
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        let t0 = VisualizationClock.now()
        for i in 0..<240 {
            let level: Float = (i / 8) % 2 == 0 ? 0.95 : 0.6
            driver.receive(frame(levels: Array(repeating: level, count: 16), sequence: UInt64(i + 1)))
            driver.step(now: t0 + Double(i) / 30)
        }
        let rep = try render(driver.drawings)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ermine-chorus-singing.png"))
        }
        #expect(driver.drawings.contains { $0.frame.face.mouth != .closed })
    }

    @Test func drawingFiveErminesFitsInAFrameBudget() throws {
        let drawings = ErmineChorusDriver().drawings
        var durations: [Double] = []
        for _ in 0..<40 {
            let renderer = ImageRenderer(content: Canvas { context, size in
                let began = VisualizationClock.now()
                ErmineChorusRenderer.draw(context: context, size: size, drawings: drawings)
                durations.append(VisualizationClock.now() - began)
            }.frame(width: 360, height: 144))
            renderer.scale = 2
            _ = renderer.cgImage
        }
        let median = durations.sorted()[durations.count / 2]
        print("Ermine chorus draw commands: median \(String(format: "%.2f", median * 1000)) ms")
        #expect(median < 0.012)
    }
}
