#if os(macOS)
import Foundation
import simd
import Testing
@testable import AnalysisCore
@testable import PlayerUI
@testable import VisualizationKit

@Suite struct PuppetShowRegisterTests {
    @Test func everyRegisterGetsBandsAndFollowsItsOwnPeak() throws {
        let edges = (0...16).map { 20 * pow(1000, Double($0) / 16) }
        var counts = Array(repeating: 0, count: 4)
        for i in 0..<16 { counts[PuppetRegister.of(centerHz: (edges[i] * edges[i + 1]).squareRoot()).rawValue] += 1 }
        #expect(counts.allSatisfy { $0 >= 3 }, "each puppet sings bands of its own: \(counts)")
        // A quiet high register still reaches the top of its range: each follows its own peak.
        var levels = PuppetRegisterLevels()
        let db = try #require(PuppetRegisterLevels.registerDB(bandDBFS: (0..<16).map { $0 < 12 ? -10 : -45 }, edgesHz: edges))
        let first = levels.levels(registerDB: db, dt: 0.033)
        #expect(first.allSatisfy { $0 > 0.99 })
        // Silence and malformed input give nothing.
        #expect(levels.levels(registerDB: Array(repeating: -90, count: 4), dt: 0.033).allSatisfy { $0 == 0 })
        #expect(PuppetRegisterLevels.registerDB(bandDBFS: [.nan] + Array(repeating: -20, count: 15), edgesHz: edges) == nil)
        // The peak falls 1.5dB a second, so 30dB below the old peak is 0 and the level climbs back slowly.
        let quieter = levels.levels(registerDB: db.map { $0 - 15 }, dt: 2)
        #expect(quieter.allSatisfy { abs($0 - 0.6) < 0.01 })
    }
}

@Suite struct PuppetShowDirectorTests {
    static let beatPeriod = 0.5
    /// Runs one director on a steady beat at 120 BPM with a level, returning (time, mouth) samples.
    static func run(_ director: inout PuppetDirector, seconds: Double, level: Double, beat: Bool = true, start: Double = 0,
                    playing: Bool = true) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var t = start
        while t < start + seconds {
            t += 1 / 30
            director.update(dt: 1 / 30, now: t, levels: Array(repeating: level, count: 4),
                            beat: beat ? PuppetBeat(count: t / beatPeriod, bpm: 120) : nil, playing: playing)
            out.append((t, director.mouth))
        }
        return out
    }

    @Test func theMouthOpensOnTheBeatAndClosesBetweenBeats() {
        var d = PuppetDirector(member: PuppetMember.all[2])
        let samples = Self.run(&d, seconds: 4, level: 0.7).filter { $0.0 > 2 }
        func phase(_ t: Double) -> Double { let p = (t / Self.beatPeriod).truncatingRemainder(dividingBy: 1); return p < 0.5 ? p : p - 1 }
        let onBeat = samples.filter { abs(phase($0.0) - 0.04) < 0.08 }.map(\.1)
        let between = samples.filter { abs(phase($0.0)) > 0.4 }.map(\.1)
        #expect(onBeat.min()! > between.max()! + 0.2, "on the beat \(onBeat.min()!) between \(between.max()!)")
        // The body sinks on the beat.
        #expect(d.pose(now: 4).bodyPosition.y <= 0)
    }

    @Test func silenceWhilePlayingSlumpsButAPauseOnlySettles() {
        var playing = PuppetDirector(member: PuppetMember.all[0])
        _ = Self.run(&playing, seconds: 2, level: 0.6)
        _ = Self.run(&playing, seconds: 2, level: 0, start: 2)
        #expect(playing.actions.slump > 0 && playing.pose(now: 4).rootY < 0)
        var paused = PuppetDirector(member: PuppetMember.all[0])
        _ = Self.run(&paused, seconds: 2, level: 0.6)
        _ = Self.run(&paused, seconds: 3, level: 0, beat: false, start: 2, playing: false)
        #expect(paused.actions.slump == 0 && paused.mouth < 0.01 && paused.isSettled)
    }

    @Test func aSuddenSwellShoutsAndSparklesButNotForever() {
        var d = PuppetDirector(member: PuppetMember.all[2])
        _ = Self.run(&d, seconds: 6, level: 0.3)
        #expect(d.actions.shout == 0 && d.actions.sparkle == 0)
        var shouted = false
        for k in 0..<40 {
            _ = Self.run(&d, seconds: 1 / 30, level: 1, start: 6 + Double(k) / 30)
            shouted = shouted || d.actions.shout > 0
        }
        #expect(shouted, "the strongest swell makes the puppet shout")
        let pose = d.pose(now: 7.3)
        #expect(pose.upperRotationX < -0.5 && pose.squeeze > 0.5 && pose.shoutLines.allSatisfy { $0.x > 0.5 })
        // A shout lasts 2.2s and then waits 20s before the next.
        _ = Self.run(&d, seconds: 3, level: 1, start: 7.4)
        #expect(d.actions.shout == 0 && d.cooldown.shout > 10)
    }

    @Test func onlyTheSpikyHairedBoyHeadbangsAndOnlyOnAClearBeat() {
        for member in PuppetMember.all {
            var d = PuppetDirector(member: member)
            var banged = false
            var t = 0.0
            while t < 12 {
                t += 1 / 30
                d.update(dt: 1 / 30, now: t, levels: Array(repeating: 0.9, count: 4), beat: PuppetBeat(count: t * 2, bpm: 120))
                banged = banged || d.actions.headbang > 0
            }
            #expect(banged == (member.name == "spiky"), "\(member.name)")
        }
        var noBeat = PuppetDirector(member: PuppetMember.all[1])
        _ = Self.run(&noBeat, seconds: 12, level: 0.9, beat: false)
        #expect(noBeat.actions.headbang == 0)
    }

    @Test func armsAndFacingChangePerPhraseOnly() {
        var d = PuppetDirector(member: PuppetMember.all[3])
        var t = 0.0, changes: [Int] = [], last: (PuppetArmPose, Double)?
        while t < 40 {
            t += 1 / 30
            d.update(dt: 1 / 30, now: t, levels: Array(repeating: 0.5, count: 4), beat: PuppetBeat(count: t * 2, bpm: 120))
            let now = (d.armPose, d.turn)
            if let last, last != now { changes.append(Int((t * 2).rounded(.down))) }
            last = now
        }
        #expect(!changes.isEmpty && changes.allSatisfy { $0 % 8 == 0 }, "changes on beats \(changes)")
    }

    @Test func reducedMotionKeepsTheBodyStillWhileTheMouthSings() {
        var d = PuppetDirector(member: PuppetMember.all[1])
        _ = Self.run(&d, seconds: 3.1, level: 0.8)
        let moving = d.pose(now: 3.1), still = d.pose(now: 3.1, reduceMotion: true)
        #expect(abs(moving.bodyPosition.y) > 0.05 && still.bodyPosition.y == 0 && still.bodyRotation.z == 0)
        #expect(still.upperRotationX == moving.upperRotationX)
    }

    @Test func eyesGlowInEachPuppetsOwnWay() {
        for member in PuppetMember.all {
            var d = PuppetDirector(member: member)
            d.actions.sparkle = 3
            _ = Self.run(&d, seconds: 1, level: 0.5)
            let pose = d.pose(now: 1)
            #expect(pose.eyeGlow.allSatisfy { $0 > 0.2 } && pose.eyeCore.allSatisfy { $0 > 0.9 }, "\(member.name)")
            #expect(pose.ripples.contains { $0.x > 0 } == (member.eyes.kind == .wave), "\(member.name)")
        }
    }
}

@Suite struct PuppetShowEnsembleTests {
    @Test func thePuppetsLookAtEachOtherAndTheGirlsBlush() {
        var d = PuppetMember.all.map { PuppetDirector(member: $0) }
        var e = PuppetEnsemble()
        var t = 0.0, log: Set<String> = [], ponyBlushed = false, twinShy = false, synced = false
        let twin = PuppetMember.index("twin"), pony = PuppetMember.index("pony"), spiky = PuppetMember.index("spiky")
        var spikyLooked = false
        while t < 180 {
            t += 1 / 30
            let beat = PuppetBeat(count: t * 2, bpm: 120)
            for i in d.indices { d[i].update(dt: 1 / 30, now: t, levels: Array(repeating: 0.45, count: 4), beat: beat) }
            e.update(&d, now: t)
            for line in e.log { log.insert(String(line.split(separator: " ", maxSplits: 1)[1])) }
            ponyBlushed = ponyBlushed || (d[pony].actions.blush > 0 && d[pony].actions.sparkle > 0)
            twinShy = twinShy || d[twin].actions.shy > 0
            synced = synced || (d[pony].sync?.phrase == d[pony].phrase && d[pony].armPose == d[twin].armPose)
            if let look = d[spiky].look, t < look.until, look.turn > 0 { spikyLooked = true }
        }
        #expect(spikyLooked, "the spiky-haired boy looks right, toward the boy with glasses")
        #expect(ponyBlushed && twinShy && synced, "log: \(log)")
        #expect(log.contains("ポニーテールとメガネくんの目が合う") && log.contains("ツインテールとポニーテールが同じ振り付け"))
    }

    @Test func facingPointsTowardTheOther() {
        #expect(PuppetEnsemble.toward(1, 2) == 1.3 && PuppetEnsemble.toward(3, 2) == -1.3)
        #expect(PuppetEnsemble.toward(0, 2) == 1.3 * 1.25)
    }
}

@Suite struct PuppetShowBackdropTests {
    @Test func timesOfDayBlendAndTheSkyFollows() {
        for t in stride(from: 0.0, to: 1, by: 0.01) {
            #expect(abs(PuppetBackdrop.weights(t).reduce(0, +) - 1) < 1e-9)
        }
        for (i, key) in PuppetBackdrop.timeKeys.enumerated() { #expect(PuppetBackdrop.weights(key)[i] == 1) }
        guard case let .sky(top, _) = PuppetBackdrop.layers(tod: 0.25, time: 0, moonAge: 10)[0] else { Issue.record("sky first"); return }
        #expect(top[1] == SIMD3(62, 141, 217))
    }

    @Test func theSunShinesByDayAndTheMoonAndStarsByNight() {
        func has(_ layers: [PuppetBackdrop.Layer], _ test: (PuppetBackdrop.Layer) -> Bool) -> Bool { layers.contains(where: test) }
        let noon = PuppetBackdrop.layers(tod: 0.3, time: 5, moonAge: 14)
        let night = PuppetBackdrop.layers(tod: 0.8, time: 5, moonAge: 14)
        let sun = { (l: PuppetBackdrop.Layer) -> Bool in if case .picture("sun", _, _, _, _) = l { true } else { false } }
        let moon = { (l: PuppetBackdrop.Layer) -> Bool in if case .moon = l { true } else { false } }
        let star = { (l: PuppetBackdrop.Layer) -> Bool in if case .glint = l { true } else { false } }
        #expect(has(noon, sun) && !has(noon, moon) && !has(noon, star))
        #expect(!has(night, sun) && has(night, moon) && has(night, star))
        // No moon around the new moon.
        #expect(!has(PuppetBackdrop.layers(tod: 0.8, time: 5, moonAge: 0.2), moon))
        // The land slides once around a day; only the times of day in the mix are drawn.
        let lands = night.compactMap { l -> Double? in if case let .land(_, offset, alpha) = l { offset + alpha * 0 } else { nil } }
        #expect(!lands.isEmpty && lands.allSatisfy { $0 >= 0 && $0 < PuppetBackdrop.landTileWidth })
        #expect(abs(PuppetBackdrop.landTileWidth - 3198 * 108 / 656.0) < 1e-9)
    }

    @Test func cloudsDriftAndPassersByComeAndGo() {
        func clouds(_ time: Double) -> [Double] {
            PuppetBackdrop.layers(tod: 0.3, time: time, moonAge: 10).compactMap { if case let .cloud(_, f, _, _) = $0 { f.x } else { nil } }
        }
        let a = clouds(0), b = clouds(10)
        #expect(a.count == 4 && zip(a, b).allSatisfy { $1 > $0 || $1 < -50 })
        #expect((0..<3000).map { clouds(Double($0)) }.joined().allSatisfy { $0 >= -60 && $0 < PuppetBackdrop.width + 20 })
        let birds = (0..<600).filter { t in PuppetBackdrop.layers(tod: 0.3, time: Double(t), moonAge: 10).contains { if case .picture("birds", _, _, _, _) = $0 { true } else { false } } }
        #expect(!birds.isEmpty && birds.count < 600)
        // With reduced motion there are no shooting stars or comets.
        let reduced = (0..<200).flatMap { PuppetBackdrop.layers(tod: 0.8, time: Double($0) * 0.3, moonAge: 10, reduceMotion: true) }
        #expect(!reduced.contains { if case .streak = $0 { true } else if case .picture("comet", _, _, _, _) = $0 { true } else { false } })
    }

    @Test func theMoonsAgeFollowsTheCalendar() {
        // Full moon on 2024-04-23 23:49 UTC, new moon on 2024-05-08 03:22 UTC.
        let full = Date(timeIntervalSince1970: 1_713_916_140), new = Date(timeIntervalSince1970: 1_715_138_520)
        #expect(abs(PuppetBackdrop.moonAge(at: full) - 14.77) < 1)
        let age = PuppetBackdrop.moonAge(at: new)
        #expect(age < 1 || age > PuppetBackdrop.synodicMonth - 1)
    }
}

@Suite struct PuppetShowRigTests {
    @Test func theMouthInsideFitsTheHeadWithoutStickingOut() throws {
        let sphere = PuppetMesh.sphere(phiStart: 0, phiLength: 2 * .pi, thetaStart: 0, thetaLength: 2, color: { _ in SIMD4(1, 1, 1, 1) })
        // The ring at the cut: the last row of the upper shell.
        let ring = (0...40).map { sphere.position(sphere.vertexCount - 41 + $0) }
        let disc = PuppetMesh.halfDisc()
        let radius = sin(2.0)
        for i in 1..<disc.vertexCount {
            let p = disc.position(i)
            // The disc lies in the cut's plane (x, z) after turning; each corner meets a corner of the head's ring.
            let corner = SIMD2(p.x * radius, p.y * radius)
            #expect(ring.contains { simd_distance(SIMD2($0.x, $0.z), corner) < 1e-6 })
        }
    }

    @Test func puppetsAreBuiltFromTheirArtAndTheirPartsFollowThePose() throws {
        let artwork = try #require(PuppetShowArtwork.load())
        #expect(artwork.rigs.map(\.member.name) == ["twin", "spiky", "glasses", "pony"])
        for rig in artwork.rigs {
            // Body, sleeves, hair and eye stickers are present; only the boy with glasses has no hair beyond his head.
            let arts = Set(rig.pieces.compactMap { if case let .art(name) = $0.texture { name } else { nil } })
            #expect(arts.count == (rig.member.name == "glasses" ? 5 : 6), "\(rig.member.name) \(arts)")
            // Parts are trimmed: their textures are much smaller than the sheet's 596-pixel height.
            let body = try #require(artwork.textures[.art("\(rig.member.name)/arm_l")])
            #expect(body.height < 300)
        }
        var rig = artwork.rigs[2]
        let before = rig.worldMatrices()
        var pose = PuppetPose()
        pose.upperRotationX = -0.6; pose.tears = 0.5; pose.eyeGlow = [0.8, 0.8]
        rig.apply(pose)
        let after = rig.worldMatrices()
        #expect(before[rig.upper] != after[rig.upper] && before[rig.jaw] == after[rig.jaw])
        #expect(rig.pieces.contains { $0.texture == .tearStream && $0.indexCount == 16 * 6 && $0.opacity == 1 })
        #expect(rig.pieces.filter { $0.texture == .eyeGlow("glasses") }.allSatisfy { $0.opacity == 0.8 })
        // Neighbors stand slightly apart in depth.
        #expect(artwork.rigs.map(\.depth) == [0, -4, 0, -4])
    }
}

@Suite(.serialized) @MainActor struct PuppetShowDriverTests {
    @Test func adoptsDueFramesAdvancesTheDayOnlyWhilePlayingAndReportsMissingData() {
        let driver = PuppetShowDriver()
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        #expect(driver.isRunning)
        let id = UUID()
        driver.receive(frame(levels: Array(repeating: 0.8, count: 16), generation: id, sequence: 1))
        driver.receive(frame(levels: Array(repeating: 0.8, count: 16), generation: id, sequence: 1)) // stale: ignored
        #expect(driver.pendingCount == 1)
        let now = VisualizationClock.now()
        driver.step(now: now)
        let day = driver.timeOfDay
        driver.step(now: now + 0.1)
        #expect(driver.levels.allSatisfy { $0 > 0.9 } && !driver.waitingForData)
        #expect(abs(driver.timeOfDay - day - 0.1 / PuppetBackdrop.daySeconds) < 1e-6)
        driver.step(now: now + 0.6)
        #expect(driver.waitingForData && driver.levels.allSatisfy { $0 == 0 })
        driver.reset()
        #expect(driver.pendingCount == 0)
        driver.synchronize(activity: .paused, visible: true)
        let paused = driver.timeOfDay
        driver.step(now: now + 1)
        #expect(driver.timeOfDay == paused)
        // Stopping returns the puppets to rest but keeps the time of day.
        driver.synchronize(activity: .inactive, visible: true)
        #expect(driver.timeOfDay == paused && driver.scene.poses == PuppetMember.all.map { PuppetDirector(member: $0).pose(now: driver.showTime) })
    }

    @Test func stopsWhenHiddenOrStoppedAndSettlesAfterAPause() async throws {
        var driver: PuppetShowDriver? = PuppetShowDriver()
        weak let weakDriver = driver
        driver?.synchronize(activity: .playing, visible: true)
        driver?.receive(frame(levels: Array(repeating: 0.8, count: 16)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(driver?.isRunning == true)
        driver?.synchronize(activity: .paused, visible: true)
        #expect(driver?.isRunning == true && driver?.pendingCount == 0)   // settling
        try await Task.sleep(for: .seconds(PuppetShowDriver.settleSeconds + 0.3))
        #expect(driver?.isRunning == false)
        driver?.synchronize(activity: .playing, visible: true)
        #expect(driver?.isRunning == true)
        driver?.synchronize(activity: .playing, visible: false)
        #expect(driver?.isRunning == false)
        driver = nil
        try await Task.sleep(for: .milliseconds(80))
        #expect(weakDriver == nil)
    }

    @Test func beatsComeFromAReplaceableSourceAndOnlyCountUp() {
        struct FixedBeat: PuppetBeatSource {
            var index = 0
            mutating func reset() {}
            mutating func feed(registerDB: [Double], at time: Double) {}
            func beat(at time: Double) -> (index: Int, phase: Double, period: Double)? { (Int(time / 0.5), (time / 0.5).truncatingRemainder(dividingBy: 1), 0.5) }
        }
        let driver = PuppetShowDriver()
        driver.beats = FixedBeat()
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        let now = VisualizationClock.now()
        var counts: [Double] = []
        for k in 0..<30 {
            driver.receive(frame(levels: Array(repeating: 0.6, count: 16), sequence: UInt64(k + 1)))
            driver.step(now: now + Double(k) * 0.05)
            counts.append(driver.beat?.count ?? -1)
        }
        #expect(counts.allSatisfy { $0 >= 0 } && zip(counts, counts.dropFirst()).allSatisfy { $1 >= $0 })
        #expect(abs((driver.beat?.bpm ?? 0) - 120) < 1e-9)
    }

    @Test func theDesignIsListedAndOwnsItsDriver() {
        let preferences = MemoryPreferences()
        let presentation = PlayerPresentation(preferences: preferences)
        #expect(VisualizationDesign.allCases.contains(.puppetShow))
        #expect(VisualizationDesign.puppetShow.title == "教育番組")
        #expect(VisualizationDesign.puppetShow.tagline == "思ってたのと違うけど、これはこれで味がある。絵心が欲しい...")
        presentation.setVisualizationDesign(.puppetShow)
        #expect(PlayerPresentation(preferences: preferences).visualizationDesign == .puppetShow)
        presentation.puppetShowDriver.synchronize(activity: .playing, visible: true)
        #expect(presentation.puppetShowDriver.isRunning)
        presentation.setVisualizationDesign(.ermineChorus)
        #expect(!presentation.puppetShowDriver.isRunning)
        presentation.puppetShowDriver.synchronize(activity: .playing, visible: true)
        presentation.visualizationVisible = false
        #expect(!presentation.puppetShowDriver.isRunning)
    }
}
#endif
