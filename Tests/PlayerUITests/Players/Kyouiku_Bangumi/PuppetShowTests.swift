#if os(macOS)
import Foundation
import simd
import Testing
@testable import AnalysisCore
import AudioProcessingCore
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
        // A shout lasts 2.2s and then waits 14s before the next.
        _ = Self.run(&d, seconds: 3, level: 1, start: 7.4)
        #expect(d.actions.shout == 0 && d.cooldown.shout > 6)
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

@Suite struct PuppetShowSwayTests {
    /// Runs on a steady beat from `start` and returns (beat count, sway) per frame.
    static func run(_ d: inout PuppetDirector, bpm: Double, seconds: Double, start: Double = 0, beat: Bool = true,
                    playing: Bool = true) -> [(count: Double, sway: Double)] {
        var out: [(Double, Double)] = []
        var t = start
        while t < start + seconds {
            t += 1 / 30
            let count = t * bpm / 60
            d.update(dt: 1 / 30, now: t, levels: Array(repeating: playing ? 0.6 : 0, count: 4),
                     beat: beat && playing ? PuppetBeat(count: count, bpm: bpm) : nil, playing: playing)
            out.append((count, d.sway))
        }
        return out
    }

    /// The body reaches a side on every beat, alternating, at slow and fast tempos alike and as wide.
    @Test(arguments: [70.0, 120.0, 170.0])
    func theSwayReachesASideOnEveryBeat(bpm: Double) {
        var d = PuppetDirector(member: PuppetMember.all[1])
        let samples = Self.run(&d, bpm: bpm, seconds: 8).filter { $0.count > 4 * bpm / 60 }
        let widest = samples.map { abs($0.sway) }.max()!
        #expect(widest > 0.02 && widest < 0.04, "about the same width at \(bpm) BPM: \(widest)")
        for s in samples {
            let n = s.count.rounded(), off = abs(s.count - n)
            // Near a beat the body is at the side of that beat's parity; halfway between beats it is in the middle.
            if off < 0.04 { #expect(s.sway * (Int(n) % 2 == 0 ? -1 : 1) > 0.97 * widest, "beat \(n) at \(bpm) BPM: \(s.sway)") }
            if abs(off - 0.5) < 0.04 { #expect(abs(s.sway) < 0.15 * widest) }
        }
    }

    /// A lost beat keeps its tempo for a while, then a slow sway of its own takes over without a jump; a pause stills it.
    @Test func aLostBeatKeepsItsTempoThenEasesIntoAFreeSway() {
        var d = PuppetDirector(member: PuppetMember.all[0])
        let onBeat = Self.run(&d, bpm: 120, seconds: 6)
        let lost = Self.run(&d, bpm: 120, seconds: 10, start: 6, beat: false)
        let widest = onBeat.map { abs($0.sway) }.max()!
        // Within the hold the sides still land on the old beats.
        for s in lost where s.count < 6 * 2 + PuppetDirector.swayHoldSeconds * 2 - 1 {
            let n = s.count.rounded()
            if abs(s.count - n) < 0.04 { #expect(s.sway * (Int(n) % 2 == 0 ? -1 : 1) > 0.9 * widest) }
        }
        let all = onBeat + lost
        let steepest = zip(all, all.dropFirst()).map { abs($1.sway - $0.sway) }.max()!
        #expect(steepest < widest * 0.25, "no jump: \(steepest) per frame")
        // Later the slow sway is still moving, smaller.
        let late = lost.suffix(60).map(\.sway)
        #expect(late.max()! - late.min()! > 0.005 && late.map(abs).max()! < widest)
        // Not playing: the sway dies down.
        let paused = Self.run(&d, bpm: 120, seconds: 4, start: 16, playing: false)
        #expect(abs(paused.last!.sway) < 0.001)
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

/// A track map with these beats and, unless given, no vocal.
func trackMap(_ beats: BeatMap, vocals: VocalMap? = nil) -> TrackMap {
    TrackMap(beats: beats, vocals: vocals ?? VocalMap(algorithm: 1, durationMilliseconds: beats.durationMilliseconds, register: .unknown,
                                                      medianNote: 0, frameMilliseconds: 40, mouth: [], notes: [], events: []))
}

/// A vocal over 30 seconds whose syllables open the mouth fully for 0.2s every 0.4s within its phrases
/// (by default one, from 2 to 10s), at `note` (`median` overall), with the given extra events.
func vocalMap(register: VocalMap.Register, median: UInt8, note: UInt8? = nil, phrases: [(Double, Double)] = [(2, 10)],
              events: [VocalMap.Event] = [], duration: UInt32 = 30_000) -> VocalMap {
    func sung(_ t: Double) -> Bool { phrases.contains { $0.0 <= t && t < $0.1 } }
    let mouth = (0..<Int(duration / 40)).map { i -> UInt8 in sung(Double(i) * 0.04) && i % 10 < 5 ? 15 : 0 }
    let notes = (0..<Int(duration / 80)).map { i -> UInt8 in sung(Double(i) * 0.08) ? (note ?? median) : 0 }
    let phraseEvents = phrases.map { VocalMap.Event(kind: .phrase, startMilliseconds: UInt32($0.0 * 1000),
                                                    durationMilliseconds: UInt32(($0.1 - $0.0) * 1000), strength: 100) }
    return VocalMap(algorithm: 1, durationMilliseconds: duration, register: register, medianNote: median, frameMilliseconds: 40,
                    mouth: mouth, notes: notes, events: (phraseEvents + events).sorted { $0.startMilliseconds < $1.startMilliseconds })
}

@Suite struct PuppetShowVocalTests {
    static let twin = PuppetMember.index("twin"), spiky = PuppetMember.index("spiky")
    static let glasses = PuppetMember.index("glasses"), pony = PuppetMember.index("pony")
    /// Nine phrases of 0.8s a second apart from 1s, a pause, and three more from 12s.
    static let phrases: [(Double, Double)] = {
        let first = (0..<9).map { (i: Int) -> (Double, Double) in (1 + Double(i), 1.8 + Double(i)) }
        let after = (0..<3).map { (i: Int) -> (Double, Double) in (12 + Double(i), 12.8 + Double(i)) }
        return first + after
    }()

    @Test func eachSongHasOneLeadAndTheOtherPartsMove() {
        let casting = PuppetCasting(vocals: vocalMap(register: .low, median: 50, phrases: Self.phrases))
        // Sections: four phrases, four more, the ninth, then the phrases after the pause.
        #expect(casting.sections.map(\.start) == [0, 5, 9, 12])
        for section in casting.sections { #expect(Set(section.parts) == Set(PuppetVocalPart.allCases)) }
        let leads = casting.sections.map { $0.parts.firstIndex(of: .lead)! }
        #expect(Set(leads).count == 1 && casting.part(of: leads[0], at: 6) == .lead && casting.part(of: leads[0], at: 0.5) == .lead)
        // The other parts are dealt again: not every section gives the sub to the same puppet.
        #expect(Set(casting.sections.map { $0.parts.firstIndex(of: .sub)! }).count > 1)
        // The same song is cast the same way; across songs every puppet gets to lead.
        #expect(casting == PuppetCasting(vocals: vocalMap(register: .low, median: 50, phrases: Self.phrases)))
        var everyLead = Set<Int>()
        for d in 0..<12 {
            let other = PuppetCasting(vocals: vocalMap(register: .low, median: 50, phrases: Self.phrases, duration: 30_000 + UInt32(d) * 1000))
            everyLead.formUnion(other.sections.map { $0.parts.firstIndex(of: .lead)! })
        }
        #expect(everyLead == Set(PuppetMember.all.indices))
        // The bands move with the parts: the lead follows the voice's band.
        #expect(casting.register(for: .lead) == .lowMid && casting.register(for: .sub) == .highMid)
        #expect(casting.register(for: .beat) == .bass && casting.register(for: .hum) == .high)
        #expect(PuppetCasting(vocals: vocalMap(register: .high, median: 64)).register(for: .lead) == .highMid)
    }

    @Test func theVocalIsReadAheadWithItsEvents() throws {
        let map = vocalMap(register: .low, median: 50, events: [
            .init(kind: .longTone, startMilliseconds: 3000, durationMilliseconds: 1000, strength: 100),
            .init(kind: .shout, startMilliseconds: 5000, durationMilliseconds: 500, strength: 100)])
        // Syllables open at 2.0, 2.4, ...: just before one, the mouth already opens.
        #expect(map.puppetVocal(at: 2.37).mouth > 0.5 && map.puppetVocal(at: 2.37, lead: 0).mouth < 0.5)
        let long = map.puppetVocal(at: 3.5)
        #expect(long.singing && long.longTone && !long.shout && long.pitch == 0)
        #expect(map.puppetVocal(at: 5.2).shout)
        #expect(map.puppetVocal(at: 11) == PuppetVocal())
    }

    /// Runs a director at `bpm` with a level and an optional vocal, returning its mouth samples.
    static func run(_ d: inout PuppetDirector, seconds: Double, level: Double = 0.7, bpm: Double = 120,
                    vocal: (Double) -> PuppetVocal?, part: PuppetVocalPart) -> [Double] {
        var out: [Double] = []
        var t = 0.0
        while t < seconds {
            t += 1 / 30
            d.update(dt: 1 / 30, now: t, levels: Array(repeating: level, count: 4), beat: PuppetBeat(count: t * bpm / 60, bpm: bpm),
                     vocal: vocal(t), part: part)
            out.append(d.mouth)
        }
        return out
    }

    @Test func eachPartSingsItsOwnWay() {
        // The vocal opens fully for 0.2s every 0.4s, off the 0.5s beat.
        let syllables: (Double) -> PuppetVocal? = { t in
            var v = PuppetVocal(); v.singing = true; v.mouth = t.truncatingRemainder(dividingBy: 0.4) < 0.2 ? 1 : 0; return v
        }
        var lead = PuppetDirector(member: PuppetMember.all[Self.twin])
        let sung = Self.run(&lead, seconds: 4, vocal: syllables, part: .lead).suffix(60)
        #expect(sung.max()! == 1 && sung.min()! == 0)
        var sub = PuppetDirector(member: PuppetMember.all[Self.spiky])
        let along = Self.run(&sub, seconds: 4, vocal: syllables, part: .sub).suffix(60)
        #expect(abs(along.max()! - PuppetDirector.subMouth) < 1e-9 && along.min()! == 0)
        var harmony = PuppetDirector(member: PuppetMember.all[Self.spiky])
        let joined = Self.run(&harmony, seconds: 4, vocal: { t in var v = syllables(t)!; v.harmony = true; return v }, part: .sub).suffix(60)
        #expect(abs(joined.max()! - 0.95) < 1e-9)
        var beat = PuppetDirector(member: PuppetMember.all[Self.glasses]), alone = beat
        #expect(Self.run(&beat, seconds: 4, vocal: syllables, part: .beat) == Self.run(&alone, seconds: 4, vocal: { _ in nil }, part: .beat))
        var hum = PuppetDirector(member: PuppetMember.all[Self.pony]), reference = hum
        let quiet = Self.run(&hum, seconds: 4, vocal: syllables, part: .hum).suffix(60)
        let onBeat = Self.run(&reference, seconds: 4, vocal: { _ in nil }, part: .hum).suffix(60)
        for (q, b) in zip(quiet, onBeat) { #expect(abs(q - b * PuppetDirector.humMouth) < 1e-9) }
        // Between phrases every part sings on the beat.
        var between = PuppetDirector(member: PuppetMember.all[Self.glasses]), plain = between
        #expect(Self.run(&between, seconds: 2, vocal: { _ in PuppetVocal() }, part: .hum)
                == Self.run(&plain, seconds: 2, vocal: { _ in nil }, part: .hum))
    }

    @Test func whoeverLeadsActsOutTheVocal() {
        func with(_ change: @escaping (inout PuppetVocal) -> Void) -> (Double) -> PuppetVocal? {
            { _ in var v = PuppetVocal(); v.singing = true; v.mouth = 0.5; change(&v); return v }
        }
        for member in PuppetMember.all.indices {
            // Everyone shouts with the singer, whatever the part.
            for part in PuppetVocalPart.allCases {
                var shouting = PuppetDirector(member: PuppetMember.all[member])
                _ = Self.run(&shouting, seconds: 1, vocal: with { $0.shout = true }, part: part)
                #expect(shouting.actions.shout > 0)
            }
            var high = PuppetDirector(member: PuppetMember.all[member])
            _ = Self.run(&high, seconds: 1, vocal: with { $0.highTone = true }, part: .lead)
            #expect(high.actions.reach > 0 && high.actions.sparkle > 0 && high.pose(now: 1).armL < -0.2)
            var long = PuppetDirector(member: PuppetMember.all[member])
            _ = Self.run(&long, seconds: 1.5, vocal: with { $0.longTone = true }, part: .lead)
            #expect(long.actions.dreamy > 0 && long.pose(now: 1.5).closedEyes > 0.5 && long.actions.cry == 0)
        }
        // Tears: a long tone in a slow song, or a quiet one.
        var slow = PuppetDirector(member: PuppetMember.all[Self.spiky])
        _ = Self.run(&slow, seconds: 1, bpm: 80, vocal: with { $0.longTone = true }, part: .lead)
        var quiet = PuppetDirector(member: PuppetMember.all[Self.glasses])
        _ = Self.run(&quiet, seconds: 4, level: 0.3, vocal: with { $0.longTone = true }, part: .lead)
        #expect(slow.actions.cry > 0 && quiet.actions.cry > 0)
        // The lead lifts its head for high notes.
        var lifted = PuppetDirector(member: PuppetMember.all[Self.glasses]), level = lifted
        _ = Self.run(&lifted, seconds: 1, vocal: with { $0.pitch = 0.4 }, part: .lead)
        _ = Self.run(&level, seconds: 1, vocal: with { _ in }, part: .lead)
        #expect(lifted.pose(now: 1).headRotation.x < level.pose(now: 1).headRotation.x - 0.05)
    }

    @Test func theOthersSmileNowAndThenAndSwellsMakeShouts() {
        var smiles = 0, leadSmiles = 0
        for member in PuppetMember.all.indices {
            var d = PuppetDirector(member: PuppetMember.all[member]), lead = d
            var t = 0.0
            while t < 60 {
                t += 1 / 30
                d.update(dt: 1 / 30, now: t, levels: Array(repeating: 0.6, count: 4), beat: PuppetBeat(count: t * 2, bpm: 120), part: .hum)
                lead.update(dt: 1 / 30, now: t, levels: Array(repeating: 0.6, count: 4), beat: PuppetBeat(count: t * 2, bpm: 120),
                            vocal: PuppetVocal(), part: .lead)
                if d.actions.smile > 1.7 { smiles += 1 }
                if lead.actions.smile > 0 { leadSmiles += 1 }
            }
        }
        #expect(smiles >= 12 && leadSmiles == 0, "\(smiles)")
        let smiling = { () -> PuppetDirector in
            var d = PuppetDirector(member: PuppetMember.all[0]); d.actions.smile = 1.8
            d.update(dt: 0.5, now: 0.5, levels: [0.5, 0.5, 0.5, 0.5], beat: nil); return d
        }()
        #expect(smiling.pose(now: 0.5).blush > 0 && smiling.pose(now: 0.5).closedEyes > 0)
        // A swell after the music has been going: from quiet to loud makes the puppet on the beat shout,
        // not the one humming. Loud music from the very start is no swell.
        var start = PuppetDirector(member: PuppetMember.all[Self.glasses])
        _ = Self.run(&start, seconds: 4, level: 0.95, vocal: { _ in nil }, part: .beat)
        #expect(start.actions.shout == 0 && start.actions.sparkle == 0)
        var beat = PuppetDirector(member: PuppetMember.all[Self.glasses]), hum = beat
        _ = Self.run(&beat, seconds: 6, level: 0.3, vocal: { _ in PuppetVocal() }, part: .beat)
        _ = Self.run(&beat, seconds: 1.5, level: 0.95, vocal: { _ in PuppetVocal() }, part: .beat)
        _ = Self.run(&hum, seconds: 6, level: 0.3, vocal: { _ in PuppetVocal() }, part: .hum)
        _ = Self.run(&hum, seconds: 1.5, level: 0.95, vocal: { _ in PuppetVocal() }, part: .hum)
        #expect(beat.actions.shout > 0 && hum.actions.shout == 0)
    }
}

@Suite struct PuppetShowSkyTests {
    @Test func passingAMarkWrapsAroundTheDay() {
        #expect(PuppetSkyCalendar.passed(0.5, from: 0.49, to: 0.5) && !PuppetSkyCalendar.passed(0.5, from: 0.5, to: 0.51))
        #expect(PuppetSkyCalendar.passed(0.0, from: 0.99, to: 0.01) && PuppetSkyCalendar.passed(0.995, from: 0.99, to: 0.01))
        #expect(!PuppetSkyCalendar.passed(0.3, from: 0.2, to: 0.2) && !PuppetSkyCalendar.passed(0.3, from: 0.99, to: 0.01))
    }

    /// One draw as the day and as the night begin; a winning draw brings the sight around the highest point.
    @Test func eachDayAndNightDrawsOnceAndTheSightComesAtTheHighestPoint() {
        var draws = 0, starts: [(Double, PuppetSkyEvent.Kind)] = []
        var calendar = PuppetSkyCalendar()
        var tod = 0.0
        for _ in 0..<(2 * 36_000) {   // two days in steps of a hundredth of a second
            let next = (tod + 0.01 / PuppetBackdrop.daySeconds).truncatingRemainder(dividingBy: 1)
            if let kind = calendar.advance(from: tod, to: next, draw: { draws += 1; return 0 }) { starts.append((next, kind)) }
            tod = next
        }
        #expect(draws == 4)
        #expect(starts.map(\.1) == [.meteorShower, .rainbow, .meteorShower])   // the last day's rainbow falls on the third day
        let half = PuppetSkyEvent.duration / 2 / PuppetBackdrop.daySeconds
        #expect(starts.allSatisfy { abs($0.0 + half - PuppetSkyEvent.highest($0.1)) < 1e-4 })
        // The sun and the moon are highest there.
        #expect(abs(PuppetBackdrop.arc((PuppetSkyEvent.highest(.rainbow) + 0.16) / 0.82).y - 12) < 1e-9)
        #expect(abs(PuppetBackdrop.arc((PuppetSkyEvent.highest(.meteorShower) - 0.5) / 0.62).y - 12) < 1e-9)
        // A losing draw brings nothing; the chance is one in eighty.
        var losing = PuppetSkyCalendar()
        #expect(losing.advance(from: 0.62, to: 0.63, draw: { PuppetSkyCalendar.chance }) == nil && losing.coming == nil)
        #expect(PuppetSkyCalendar.chance == 1.0 / 80)
    }

    @Test func theSightFitsTheTimeOfDayAndShoutsWithBreaths() {
        // The moon out makes a meteor shower, even as it rises in the evening sun; the sun alone a rainbow.
        #expect(PuppetSkyEvent.kind(at: 0.25, moonAge: 10) == .rainbow && PuppetSkyEvent.kind(at: 0.45, moonAge: 10) == .rainbow)
        #expect(PuppetSkyEvent.kind(at: 0.52, moonAge: 10) == .meteorShower && PuppetSkyEvent.kind(at: 0.81, moonAge: 10) == .meteorShower)
        // In the morning the sun climbs while the moon sets: a rainbow.
        #expect(PuppetSkyEvent.kind(at: 0.05, moonAge: 10) == .rainbow && PuppetSkyEvent.kind(at: 0.95, moonAge: 10) == .rainbow)
        #expect(PuppetSkyEvent.kind(at: 0.83, moonAge: 10) == .meteorShower)
        // Around the new moon the moon is not out: the sun decides, and at night it is still a meteor shower.
        #expect(PuppetSkyEvent.kind(at: 0.52, moonAge: 0) == .rainbow && PuppetSkyEvent.kind(at: 0.75, moonAge: 0) == .meteorShower)
        var event = PuppetSkyEvent(kind: .rainbow)
        var shouting = 0.0, breaths = 0, was = false
        while !event.isOver {
            event.elapsed += 0.01
            let now = event.shoutLeft != nil
            if now { shouting += 0.01 } else if was { breaths += 1 }
            was = now
        }
        #expect(shouting > 6.5 && breaths >= 3, "shouting \(shouting)s with \(breaths) breaths")
        #expect(PuppetSkyEvent(kind: .rainbow, elapsed: 0).opacity == 0 && PuppetSkyEvent(kind: .rainbow, elapsed: 5).opacity == 1)
        // Meteors fall through the whole time, several at once; reduced motion leaves them out.
        let counts = stride(from: 1.0, to: 9.0, by: 0.5).map { PuppetSkyEvent(kind: .meteorShower, elapsed: $0).layers(reduceMotion: false).count / 2 }
        #expect(counts.min()! >= 3, "\(counts)")
        #expect(PuppetSkyEvent(kind: .meteorShower, elapsed: 4).layers(reduceMotion: true).isEmpty)
        #expect(PuppetSkyEvent(kind: .rainbow, elapsed: 4).layers(reduceMotion: true).count == 1)
        // The backdrop draws it in front of the sky and behind the clouds and the land.
        let layers = PuppetBackdrop.layers(tod: 0.25, time: 0, moonAge: 10, event: PuppetSkyEvent(kind: .rainbow, elapsed: 4))
        let rainbow = layers.firstIndex { if case .rainbow = $0 { true } else { false } }!
        let cloud = layers.firstIndex { if case .cloud = $0 { true } else { false } }!
        #expect(rainbow > 0 && rainbow < cloud)
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
        #expect(driver.timeOfDay == paused && driver.scene.poses == PuppetMember.all.map { PuppetDirector(member: $0).pose(now: driver.stageTime) })
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

    /// A clear map of the track's beats leads; without it, or without the track position, the live estimate decides.
    @Test func aClearBeatMapLeadsAndTheLiveEstimateStandsIn() throws {
        struct HalfSecondBeat: PuppetBeatSource {
            mutating func reset() {}
            mutating func feed(registerDB: [Double], at time: Double) {}
            func beat(at time: Double) -> (index: Int, phase: Double, period: Double)? { (Int(time / 0.5), 0, 0.5) }
        }
        let driver = PuppetShowDriver()
        driver.beats = HalfSecondBeat()
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        // 150 BPM from one second in.
        let beats = (0..<40).map { (i: Int) -> BeatMap.Beat in
            BeatMap.Beat(milliseconds: UInt32(1000 + i * 400), strength: 100, isDownbeat: i % 4 == 0)
        }
        let map = trackMap(BeatMap(algorithm: 1, durationMilliseconds: 30_000, clarity: 1, tempos: [.init(startMilliseconds: 1000, bpm: 150)], beats: beats))
        driver.receive(trackMap: map)
        var located = frame(levels: Array(repeating: 0.6, count: 16), sequence: 1)
        located.trackSeconds = 2.1
        driver.receive(located)
        let heard = try #require(located.timing.estimatedPresentationHostTime)
        // Heard at `heard`, the track is at 2.1s: three quarters past the beat at 1.8s.
        let beat = try #require(driver.trackedBeat(at: heard))
        #expect(beat.index == 2 && abs(beat.phase - 0.75) < 1e-6 && abs(beat.period - 0.4) < 1e-9)
        #expect(driver.trackedBeat(at: heard + 0.2)?.index == 3)
        driver.step(now: heard + 0.1)
        #expect(abs((driver.beat?.bpm ?? 0) - 150) < 1e-6)
        // Before the map's first beat there is no beat, whatever the live estimate says.
        var intro = frame(levels: Array(repeating: 0.6, count: 16), generation: located.generation, sequence: 2)
        intro.trackSeconds = 0.5
        driver.receive(intro)
        #expect(driver.trackedBeat(at: try #require(intro.timing.estimatedPresentationHostTime)) == nil)
        // The track position is not extrapolated for long.
        #expect(driver.trackedBeat(at: heard + PuppetShowDriver.trackClockLimit + 0.5)?.period == 0.5)
        // An unclear map, a seek and a frame without its position leave the beat to the live estimate.
        driver.receive(trackMap: trackMap(BeatMap(algorithm: 1, durationMilliseconds: 30_000, clarity: 0.1, tempos: [], beats: beats)))
        driver.receive(located)
        #expect(driver.trackedBeat(at: heard)?.period == 0.5)
        driver.receive(trackMap: map)
        driver.reset()
        #expect(driver.trackedBeat(at: heard)?.period == 0.5)
        driver.receive(frame(levels: Array(repeating: 0.6, count: 16), sequence: 9))
        #expect(driver.trackedBeat(at: heard)?.period == 0.5)
        driver.receive(trackMap: nil)
        #expect(driver.beatMap == nil)
    }

    /// The driver reads the vocal at the moment it shows and gives each puppet its part.
    @Test func theDriverCastsTheVocal() throws {
        let driver = PuppetShowDriver()
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        driver.receive(trackMap: trackMap(BeatMap(algorithm: 1, durationMilliseconds: 30_000, clarity: 0, tempos: [], beats: []),
                                          vocals: vocalMap(register: .high, median: 64)))
        let casting = try #require(driver.casting)
        #expect(casting.sections.count == 1)
        var located = frame(levels: Array(repeating: 0.6, count: 16), sequence: 1)
        // 2.0s into the track a syllable opens (read slightly ahead).
        located.trackSeconds = 2.0
        driver.receive(located)
        let heard = try #require(located.timing.estimatedPresentationHostTime)
        driver.step(now: heard - VisualizationClock.presentationLead)
        #expect(driver.vocal?.singing == true)
        // The lead sings the vocal's open syllable.
        let lead = try #require(casting.sections[0].parts.firstIndex(of: .lead))
        #expect(driver.directors[lead].mouth > 0)
        // A map without a sung phrase casts no one.
        driver.receive(trackMap: trackMap(BeatMap(algorithm: 1, durationMilliseconds: 30_000, clarity: 0, tempos: [], beats: [])))
        #expect(driver.casting == nil)
    }

    /// One shout starts the others: everyone free joins for the rest of it, at the same time.
    @Test func everyoneShoutsTogether() {
        var directors = PuppetMember.all.map { PuppetDirector(member: $0) }
        var ensemble = PuppetEnsemble()
        directors[1].actions.shout = 2.2; directors[1].cooldown.shout = 14
        directors[3].actions.shy = 2
        ensemble.update(&directors, now: 1)
        #expect(directors[0].actions.shout == 2.2 && directors[2].actions.shout == 2.2 && directors[3].actions.shout == 0)
        #expect(directors[0].cooldown.shout == 14)
        // A shout nearly over draws no one in.
        var late = PuppetMember.all.map { PuppetDirector(member: $0) }
        late[0].actions.shout = 0.5
        ensemble.update(&late, now: 2)
        #expect(late[1...].allSatisfy { $0.actions.shout == 0 })
    }

    /// A winning draw while playing brings the sight, and the four shout through it.
    @Test func aRareSightComesWhilePlayingAndEveryoneShouts() {
        let driver = PuppetShowDriver()
        driver.draw = { 0 }
        driver.synchronize(activity: .playing, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        var now = VisualizationClock.now(), shouted = Set<Int>(), seen: PuppetSkyEvent.Kind?
        // From noon to past the moon's highest point: the night's draw wins.
        while driver.timeOfDay < 0.84 && now < VisualizationClock.now() + 400 {
            now += 0.1
            driver.step(now: now)
            if let event = driver.scene.event {
                seen = event.kind
                for (i, d) in driver.directors.enumerated() where d.actions.shout > 0 { shouted.insert(i) }
            }
        }
        #expect(seen == .meteorShower && shouted.count == 4)
        #expect(driver.event == nil)
    }

    /// The service test shows the sight even while stopped, then the puppets go back to rest.
    @Test func theServiceTestShowsTheSightWhileStopped() {
        let driver = PuppetShowDriver()
        driver.synchronize(activity: .inactive, visible: true)
        defer { driver.synchronize(activity: .inactive, visible: false) }
        driver.startServiceTest()
        #expect(driver.isRunning && driver.event?.kind == PuppetSkyEvent.kind(at: driver.timeOfDay, moonAge: driver.scene.moonAge))
        var now = VisualizationClock.now()
        driver.step(now: now)
        let day = driver.timeOfDay, stage = driver.stageTime
        for _ in 0..<20 { now += 0.1; driver.step(now: now) }
        #expect(driver.directors.allSatisfy { $0.actions.shout > 0 } && driver.scene.event?.elapsed ?? 0 > 1.9)
        #expect(driver.stageTime > stage && driver.timeOfDay == day && driver.showTime == 0)
        // Another stop report does not cut it short.
        driver.synchronize(activity: .inactive, visible: true)
        #expect(driver.event != nil && driver.isRunning && driver.directors.allSatisfy { $0.actions.shout > 0 })
        for _ in 0..<90 { now += 0.1; driver.step(now: now) }
        #expect(driver.event == nil && driver.scene.event == nil)
        // Hiding ends a sight at once.
        driver.startServiceTest()
        driver.synchronize(activity: .inactive, visible: false)
        #expect(driver.event == nil && !driver.isRunning)
        driver.startServiceTest()
        #expect(driver.event == nil)
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
