#if os(macOS)
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
        // Low to high from left to right; the rightmost ermine (2) keeps his tail inside the stage.
        let order = ErmineCast.members.sorted { $0.slot < $1.slot }
        #expect(order.map(\.id) == [5, 3, 1, 4, 2])
        #expect(order.map(\.range) == [.bass, .lowMid, .mid, .highMid, .high])
        #expect(order.last?.features.tailSide == -1 && order.dropLast().allSatisfy { $0.features.tailSide == 1 })
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

    @Test func ermine1TiptoesForAFewSecondsThenRests() {
        var director = ErmineDirector(member: member(1), seed: 2)
        _ = run(&director, seconds: 2, level: 0.9)
        director.cue(.solo)
        let tiptoe = run(&director, seconds: 1.5, level: 0.95)
        #expect(director.intense)
        let tail = tiptoe.suffix(10)
        #expect(tail.contains { $0.key == .tallA } && tail.contains { $0.key == .tallB })
        #expect(tail.allSatisfy { $0.face.eye == .squeeze && $0.face.sweat != nil })
        // Even while the voice stays loud, the tiptoe ends within four seconds and does not restart at once.
        let rest = run(&director, seconds: 6, level: 0.95)
        #expect(!director.intense)
        #expect(!rest.suffix(Int(3 * 60)).contains { $0.key == .tallA || $0.key == .tallB })
    }

    @Test func cuesMakeEveryoneHopBowAndBlush() {
        var director = ErmineDirector(member: member(3), seed: 7)
        _ = run(&director, seconds: 1, level: 0.5)
        director.cue(.hop)
        #expect(run(&director, seconds: 1, level: 0.5).contains { $0.key == .hop })
        director.cue(.bow(delayTicks: 0))
        let bow = run(&director, seconds: 1, level: 0)
        #expect(bow.contains { $0.key == .bow && $0.face.eye == .closed && $0.face.mouth == .closed })
        director.cue(.flustered)
        let shy = run(&director, seconds: 0.5, level: 0.3)
        #expect(shy.contains { $0.key == .glanceL && $0.face.blush == 4 && $0.face.troubledBrows })
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

@Suite struct ErmineChorusBeatTests {
    /// Feeds register levels at 30 frames per second with a bass hit on every beat.
    private func track(bpm: Double, seconds: Double, offset: Double = 0.1, noise: Bool = false) -> ErmineBeatTracker {
        var tracker = ErmineBeatTracker(), random = ErmineRandom(seed: 3)
        let period = 60 / bpm
        for frame in 0..<Int(seconds * 30) {
            let t = Double(frame) / 30
            let phase = ((t - offset) / period).truncatingRemainder(dividingBy: 1)
            let hit = !noise && phase >= 0 && phase < 1.0 / 30 / period * 1.5
            let bass = noise ? -50 + random.next() * 30 : (hit ? -18.0 : -45.0)
            tracker.feed(registerDB: [bass, noise ? -50 + random.next() * 30 : -40, -35, -40, -50], at: t)
        }
        return tracker
    }

    @Test(arguments: [90.0, 120.0, 150.0])
    func findsTheTempoAndWhereTheBeatsFall(_ bpm: Double) throws {
        let tracker = track(bpm: bpm, seconds: 9)
        let period = try #require(tracker.period)
        #expect(abs(period - 60 / bpm) < 0.02, "period \(period) for \(bpm) BPM")
        // A hit time reads as phase ~0 (or just before 1).
        let hitTime = 0.1 + (60 / bpm) * Double(Int(8.5 / (60 / bpm)))
        let beat = try #require(tracker.beat(at: hitTime + 0.01))
        #expect(beat.phase < 0.15 || beat.phase > 0.85, "phase \(beat.phase)")
    }

    @Test func findsTheBeatOfASynthesizedKickThroughTheRealAnalyzer() throws {
        // A 60Hz kick every 0.5 s (120 BPM) over soft noise, analysed like playback: 2048-point windows every 1/30 s.
        let rate = 48000.0, seconds = 9.0
        var random = ErmineRandom(seed: 9)
        let pcm = (0..<Int(rate * seconds)).map { i -> Float in
            let t = Double(i) / rate, sinceKick = (t - 0.1).truncatingRemainder(dividingBy: 0.5)
            let kick = t >= 0.1 ? 0.6 * sin(2 * .pi * 60 * sinceKick) * exp(-sinceKick * 18) : 0
            return Float(kick + 0.02 * (random.next() * 2 - 1))
        }
        let analyzer = try SpectrumAnalyzer(configuration: LCMPDefaultGEQ.configuration)
        var tracker = ErmineBeatTracker()
        let hop = Int(rate / 30)
        for start in stride(from: 0, to: pcm.count - 2048, by: hop) {
            let window = Array(pcm[start..<(start + 2048)])
            let result = try #require(analyzer.analyze(left: window, right: window, sampleRate: rate))
            let registers = try #require(ErmineBandLevels.registerDB(bandDBFS: result.db, edgesHz: result.edges))
            tracker.feed(registerDB: registers, at: (Double(start) + 1024) / rate)
        }
        let period = try #require(tracker.period)
        #expect(abs(period - 0.5) < 0.02, "period \(period), confidence \(tracker.confidence)")
        #expect(tracker.beat(at: 8.6) != nil)
    }

    @Test func noClearBeatMeansNoBeat() {
        let tracker = track(bpm: 120, seconds: 9, noise: true)
        #expect(tracker.beat(at: 9) == nil, "confidence \(tracker.confidence)")
        #expect(ErmineBeatTracker().beat(at: 1) == nil)
    }

    @Test func theSharedBeatCountOnlyGoesUp() {
        var ensemble = ErmineEnsemble()
        ensemble.follow((index: 10, phase: 0.2, period: 0.5))
        ensemble.follow((index: 11, phase: 0.1, period: 0.5))
        ensemble.follow((index: 3, phase: 0.5, period: 0.5)) // the estimate moved its anchor
        #expect(ensemble.beat?.count == 2)
        ensemble.follow(nil)
        #expect(ensemble.beat == nil)
    }
}

@Suite struct ErmineChorusGrooveTests {
    private func member(_ id: Int) -> ErmineCastMember { ErmineCast.members.first { $0.id == id }! }

    /// Runs ermines on a steady 120 BPM beat and returns each one's key per step.
    private func groove(_ ids: [Int], seconds: Double, level: Double) -> (keys: [[ErmineKeyName]], directors: [ErmineDirector]) {
        var directors = ids.enumerated().map { ErmineDirector(member: member($1), seed: 40 + UInt64($0)) }
        var keys: [[ErmineKeyName]] = Array(repeating: [], count: ids.count)
        for step in 0..<Int(seconds * 60) {
            let t = Double(step) / 60
            let beat = ErmineBeat(count: Int(t / 0.5), phase: (t / 0.5).truncatingRemainder(dividingBy: 1), period: 0.5)
            for i in directors.indices {
                directors[i].step(dt: 1.0 / 60, level: level, playing: true, world: ErmineWorld(beat: beat))
                keys[i].append(directors[i].frame.key)
            }
        }
        return (keys, directors)
    }

    @Test func everyoneSwaysTheSameWayOnTheBeat() {
        // Ermines 1, 4 and 5 (3 would sometimes be busy peeking at 4).
        let result = groove([1, 4, 5], seconds: 6, level: 0.45)
        // Sample a little after each beat from the third second on: all show the same sway.
        for beat in 6..<11 {
            let step = Int((Double(beat) * 0.5 + 0.2) * 60)
            let sways = result.keys.map { $0[step] }
            #expect(Set(sways).count == 1, "beat \(beat): \(sways)")
            #expect(sways[0] == ((beat / 2) % 2 == 0 ? .singL : .singR), "beat \(beat): \(sways)")
        }
        // The dip shows just before a beat, so the risen pose lands on it.
        let before = result.keys[0][Int((4.0 - 0.05) * 60)]
        #expect(before == .dip || before == .squash, "\(before)")
    }

    @Test func armsHoldAPoseForAPhrase() {
        var director = ErmineDirector(member: member(1), seed: 8)
        var poses: [ErmineArmPose] = []
        for step in 0..<(20 * 60) {
            let t = Double(step) / 60
            let beat = ErmineBeat(count: Int(t / 0.5), phase: (t / 0.5).truncatingRemainder(dividingBy: 1), period: 0.5)
            director.step(dt: 1.0 / 60, level: 0.5, playing: true, world: ErmineWorld(beat: beat))
            if poses.last != director.arms.pose { poses.append(director.arms.pose) }
        }
        // 40 beats in 20 seconds: a new pose at most every 8 beats.
        #expect(poses.count <= 6 && poses.count >= 2, "\(poses)")
        var quiet = ErmineDirector(member: member(1), seed: 8)
        for _ in 0..<(2 * 60) { quiet.step(dt: 1.0 / 60, level: 0, playing: true, world: ErmineWorld()) }
        #expect(quiet.arms.pose == .rest)
    }

    @Test func armPosesRideOnTheBodyAndPointWithAWink() {
        var tween = ErmineArmTween()
        let body = ErmineKeyName.singL.key
        _ = tween.apply(ErmineArms(pose: .pray, side: 1), to: .singL, pose: body, at: 0)
        let pray = tween.apply(ErmineArms(pose: .pray, side: 1), to: .singL, pose: body, at: 1)
        #expect(abs(pray.pawL.x - (body.neck.x - 2.2)) < 0.01 && abs(pray.pawR.y - (body.neck.y + 9)) < 0.01)
        let dip = tween.apply(ErmineArms(pose: .pray, side: 1), to: .dip, pose: ErmineKeyName.dip.key, at: 1)
        #expect(dip.pawR.y == ErmineKeyName.dip.key.neck.y + 9) // the paws move with the bob
        _ = tween.apply(ErmineArms(pose: .raise, side: -1), to: .singL, pose: body, at: 2)
        let raised = tween.apply(ErmineArms(pose: .raise, side: -1), to: .singL, pose: body, at: 3)
        // Up to beside the cheek: above the shoulder, outside the face, in front of the head.
        #expect(!raised.armsBehind && raised.pawL.x < body.neck.x - 20 && raised.pawL.y < body.neck.y - 8 && raised.pawL.y > body.neck.y - 20)
        _ = tween.apply(ErmineArms(pose: .point, side: 1), to: .singL, pose: body, at: 4)
        #expect(tween.apply(ErmineArms(pose: .point, side: 1), to: .singL, pose: body, at: 5).pointing == 1)
        // Signature keys keep their own legs.
        #expect(tween.apply(ErmineArms(pose: .pray, side: 1), to: .flex, pose: ErmineKeyName.flex.key, at: 6) == ErmineKeyName.flex.key)

        var director = ErmineDirector(member: member(2), seed: 1)
        director.cue(.arms(ErmineArms(pose: .point, side: 1), beats: 8))
        for _ in 0..<12 { director.step(dt: 1.0 / 60, level: 0.4, playing: true, world: ErmineWorld()) }
        #expect(director.frame.face.eye == .wink(side: 1))
        // Praying hands come with closed eyes.
        director.cue(.arms(ErmineArms(pose: .pray, side: 1), beats: 8))
        for _ in 0..<12 { director.step(dt: 1.0 / 60, level: 0.4, playing: true, world: ErmineWorld()) }
        #expect(director.frame.face.eye == .closed)
    }

    @Test func theMouthFollowsTheLevelOnEveryFrame() {
        var director = ErmineDirector(member: member(1), seed: 2)
        director.step(dt: 1.0 / 60, level: 0, playing: true, world: ErmineWorld())
        #expect(director.frame.face.mouth == .closed)
        // Well under one 1/12 s drawing later, the mouth is already open.
        for _ in 0..<3 { director.step(dt: 1.0 / 60, level: 1, playing: true, world: ErmineWorld()) }
        #expect(director.frame.face.mouth != .closed)
    }
}

@Suite struct ErmineChorusEnsembleTests {
    /// Steps the five ermines and the conductor at 60 steps per second; `levels` gives each register's level.
    private struct Band {
        var directors = ErmineCast.members.enumerated().map { ErmineDirector(member: $1, seed: 90 + UInt64($0)) }
        var ensemble = ErmineEnsemble(seed: 11)
        var keys: [[ErmineKeyName]] = Array(repeating: [], count: ErmineCast.members.count)
        mutating func run(seconds: Double, playing: Bool = true, _ levels: (Double, ErmineRange) -> Double) {
            for step in 0..<Int(seconds * 60) {
                let t = Double(step) / 60
                ensemble.update(&directors, dt: 1.0 / 60, playing: playing)
                let world = ErmineWorld(ermine1Intense: directors.first { $0.member.id == 1 }!.intense)
                for i in directors.indices {
                    directors[i].step(dt: 1.0 / 60, level: levels(t, directors[i].member.range), playing: playing, world: world)
                    keys[i].append(directors[i].frame.key)
                }
            }
        }
        func index(_ id: Int) -> Int { directors.firstIndex { $0.member.id == id }! }
        mutating func clear() { keys = Array(repeating: [], count: keys.count) }
    }

    @Test func aStandoutRegisterGetsASoloAndTheOthersWatch() {
        var band = Band()
        band.run(seconds: 8) { t, range in range == .bass ? (Int(t * 4) % 2 == 0 ? 0.9 : 0.7) : 0.12 }
        let five = band.index(5), one = band.index(1)
        #expect(band.keys[five].contains(.flex))
        #expect(band.keys[one].contains(.glanceL)) // 5 stands at the left end
        #expect(band.ensemble.stage.spotSlot == 0 || band.keys[five].contains(.flex))
    }

    @Test func theSingingRegisterNeedsAClearerLeadForASolo() {
        var band = Band()
        // The voice is a little above the rest, as in most songs: no solo for ermine 1.
        band.run(seconds: 8) { _, range in range == .mid ? 0.8 : 0.42 }
        #expect(band.ensemble.soloist == nil)
        #expect(!band.keys[band.index(2)].contains(.glanceL) || !band.keys[band.index(5)].contains(.glanceR))
    }

    @Test func aSuddenChorusStartsAWaveFromLeftToRight() {
        var band = Band()
        band.run(seconds: 8) { _, _ in 0.35 } // a verse
        band.clear()
        band.run(seconds: 1.5) { _, _ in 0.9 } // the chorus
        let firstRise = ErmineCast.members.sorted { $0.slot < $1.slot }.map { member -> Int in
            let i = band.directors.firstIndex { $0.member.id == member.id }!
            return band.keys[i].firstIndex(of: .up) ?? Int.max
        }
        #expect(firstRise.allSatisfy { $0 < Int.max }, "\(firstRise)")
        #expect(firstRise == firstRise.sorted() && firstRise.last! > firstRise.first!, "\(firstRise)")
    }

    @Test func aStrongBassAfterAQuietBreakMakesEveryoneHop() {
        var band = Band()
        band.run(seconds: 4) { _, _ in 0.05 }
        band.clear()
        band.run(seconds: 1.5) { t, range in range == .bass ? (t < 0.1 ? 0.05 : 1) : 0.3 }
        #expect(band.keys.allSatisfy { $0.contains(.hop) })
    }

    @Test func everyoneBowsWhenTheSongFallsSilent() {
        var band = Band()
        band.run(seconds: 5) { t, _ in Int(t * 4) % 2 == 0 ? 0.7 : 0.5 }
        band.clear()
        band.run(seconds: 3) { _, _ in 0 }
        #expect(band.keys.allSatisfy { $0.contains(.bow) })
        // Paused playback is not the end of a song.
        var paused = Band()
        paused.run(seconds: 5) { _, _ in 0.6 }
        paused.clear()
        paused.run(seconds: 3, playing: false) { _, _ in 0 }
        #expect(paused.keys.allSatisfy { !$0.contains(.bow) })
    }

    @Test func aChorusWaveEndsWithEveryoneRaisingAnArm() {
        var band = Band()
        band.run(seconds: 8) { _, _ in 0.35 }
        band.run(seconds: 1.5) { _, _ in 0.9 }
        #expect(band.directors.allSatisfy { $0.arms.pose == .raise })
    }

    @Test func neonLettersFlickerOnlyOnHighNotes() {
        var band = Band()
        var flickered = false
        band.run(seconds: 3) { _, _ in 0.3 }
        for _ in 0..<20 {
            band.run(seconds: 0.25) { t, range in range == .high ? (t < 0.05 ? 0.1 : 0.95) : 0.3 }
            if band.ensemble.stage.neon.contains(where: { $0 < 1 }) { flickered = true }
            band.run(seconds: 0.25) { _, range in range == .high ? 0.1 : 0.3 }
            if band.ensemble.stage.neon.contains(where: { $0 < 1 }) { flickered = true }
        }
        #expect(flickered)
        var calm = Band()
        calm.run(seconds: 6) { _, range in range == .high ? 0 : 0.5 }
        #expect(calm.ensemble.stage.neon.allSatisfy { $0 == 1 })
    }

    @Test func lampsFollowTheBass() {
        var band = Band()
        band.run(seconds: 1) { _, range in range == .bass ? 1 : 0.2 }
        let loud = band.ensemble.stage.light
        band.run(seconds: 1) { _, range in range == .bass ? 0 : 0.2 }
        #expect(loud > 0.8 && band.ensemble.stage.light < 0.4)
        band.run(seconds: 1) { _, range in range == .mid ? 1 : 0 }
        #expect(band.ensemble.stage.topLight > 0.8) // the hung lamps follow the voice
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
        #expect(VisualizationDesign.ermineChorus.title == "MICRIGAIKE コジョーズ" && VisualizationDesign.fluorescentLED.title == "Last Century イコライザー")
    }
}

@Suite struct ErmineChorusDustTests {
    @Test func dustDriftsSlowlyAndStaysInTheAir() {
        var dust = ErmineDust(seed: 5)
        let start = dust.motes
        for _ in 0..<(10 * 30) { dust.step(dt: 1.0 / 30) }
        #expect(dust.motes.count == ErmineDust.count)
        #expect(dust.motes.allSatisfy { ErmineDust.area.insetBy(dx: -0.01, dy: -0.01).contains($0.position) })
        #expect(dust.motes.allSatisfy { $0.size < 1 }) // really small specks
        // Slow: in one thirtieth of a second no speck moves more than a tenth of a point.
        var next = dust; next.step(dt: 1.0 / 30)
        #expect(zip(dust.motes, next.motes).allSatisfy { abs($0.position.x - $1.position.x) < 0.1 || abs($0.position.x - $1.position.x) > 300 })
        #expect(zip(start, dust.motes).contains { $0.position != $1.position })
    }

    @Test func onlySpecksInsideABeamAreLit() {
        let beams = ErmineChorusRenderer.floorBeams(stage: ErmineStage(light: 1))
        let inside = CGPoint(x: 60, y: 98), outside = CGPoint(x: 180, y: 110)
        #expect(beams.reduce(0) { $0 + $1.light(at: inside) } > 0.4)
        #expect(beams.reduce(0) { $0 + $1.light(at: outside) } == 0)
        #expect(ErmineChorusRenderer.floorBeams(stage: ErmineStage(light: 0)).allSatisfy { $0.light(at: inside) == 0 })
    }
}

@Suite @MainActor struct ErmineChorusRenderingTests {
    /// Renders the stage at 2× and returns the bitmap.
    private func render(_ drawings: [ErmineDrawing], stage: ErmineStage = ErmineStage(), dust: [ErmineMote] = [],
                        reduceMotion: Bool = false) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: Canvas { context, size in
            ErmineChorusRenderer.draw(context: context, size: size, drawings: drawings, stage: stage, dust: dust, reduceMotion: reduceMotion)
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
        let white = color(rep, 180, 100), brown = color(rep, 120 - 9, 112), light = color(rep, 300 - 9, 112), dark = color(rep, 60 - 10, 112)
        #expect(white.r > 0.9 && white.g > 0.9 && white.b > 0.85, "\(white)")
        #expect(brown.r > brown.b + 0.25, "\(brown)")
        #expect(light.r > 0.7 && light.r > light.b + 0.2, "\(light)")
        #expect(dark.r > dark.b + 0.2 && dark.r < light.r, "\(dark)")
        var pink = 0
        for y in stride(from: 6, to: 30, by: 1) { for x in stride(from: 90, to: 270, by: 2) {
            let c = color(rep, CGFloat(x), CGFloat(y)); if c.r > 0.75 && c.r > c.g + 0.25 { pink += 1 }
        } }
        #expect(pink > 60, "neon pixels \(pink)")
        let beam = color(rep, 180, 1), can = color(rep, 10, 128)
        #expect(beam.r > beam.b + 0.15, "\(beam)")
        #expect(can.r < 0.5 && can.g < 0.5, "\(can)")
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
            let effects = ErmineEffects(shake: i, notes: [ErmineNote(position: CGPoint(x: 20, y: -90), glyph: "♩", size: 14)])
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
        // Every arm pose on ermine 1, leading with either hand.
        var armSheet: [ErmineDrawing] = []
        for (i, pose) in ErmineArmPose.allCases.enumerated() {
            var tween = ErmineArmTween()
            let arms = ErmineArms(pose: pose, side: i % 2 == 0 ? 1 : -1)
            _ = tween.apply(arms, to: .singR, pose: ErmineKeyName.singR.key, at: 0)
            let posed = tween.apply(arms, to: .singR, pose: ErmineKeyName.singR.key, at: 1)
            armSheet.append(ErmineDrawing(pose: posed, frame: ErmineFrame(key: .singR, face: ErmineFace(eye: pose == .point ? .wink(side: arms.side) : .open, mouth: .medium), arms: arms)))
        }
        for start in stride(from: 0, to: armSheet.count, by: 5) {
            let group = Array(armSheet[start..<min(start + 5, armSheet.count)])
            let rep = try render(group + Array(repeating: group[0], count: 5 - group.count), stage: ErmineStage(light: 0.6, topLight: 0.6))
            if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ermine-chorus-arms-\(start / 5).png"))
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
        let rep = try render(driver.drawings, stage: driver.stage)
        // A solo: both lamps turn to ermine 1 in the middle and light the floor under him.
        let solo = try render(driver.drawings, stage: ErmineStage(light: 1, spotSlot: 2))
        let lit = solo.colorAt(x: 163 * 2, y: 123 * 2)!, dark = try render(driver.drawings, stage: ErmineStage(light: 0, spotSlot: 2)).colorAt(x: 163 * 2, y: 123 * 2)!
        #expect(lit.brightnessComponent > dark.brightnessComponent + 0.02)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ermine-chorus-singing.png"))
            try solo.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ermine-chorus-solo-lights.png"))
        }
        #expect(driver.drawings.contains { $0.frame.face.mouth != .closed })
    }

    @Test func dustGlittersInTheBeamsOnly() throws {
        let drawings = ErmineChorusDriver().drawings
        // In the left floor beam, over the dark background beside ermine 5.
        let speck = ErmineMote(position: CGPoint(x: 36, y: 112), velocity: CGVector(dx: 0, dy: 0), size: 0.9, phase: .pi / 2, speed: 1)
        func brightness(_ rep: NSBitmapImageRep) -> CGFloat { rep.colorAt(x: 72, y: 224)!.brightnessComponent }
        let lit = try render(drawings, stage: ErmineStage(light: 1), dust: [speck])
        let plain = try render(drawings, stage: ErmineStage(light: 1))
        let dark = try render(drawings, stage: ErmineStage(light: 0), dust: [speck])
        let calm = try render(drawings, stage: ErmineStage(light: 1), dust: [speck], reduceMotion: true)
        #expect(brightness(lit) > brightness(plain) + 0.1, "\(brightness(lit)) vs \(brightness(plain))")
        #expect(brightness(dark) < 0.2)
        #expect(brightness(calm) < brightness(lit) - 0.1)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            let driver = ErmineChorusDriver()
            var field = ErmineDust()
            for _ in 0..<90 { field.step(dt: 1.0 / 30) }
            let scene = try render(driver.drawings, stage: ErmineStage(light: 0.9, topLight: 0.8, spotSlot: nil), dust: field.motes)
            try scene.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ermine-chorus-dust.png"))
        }
    }

    @Test func drawingFiveErminesFitsInAFrameBudget() throws {
        let drawings = ErmineChorusDriver().drawings, dust = ErmineDust().motes
        var durations: [Double] = []
        for _ in 0..<40 {
            let renderer = ImageRenderer(content: Canvas { context, size in
                let began = VisualizationClock.now()
                ErmineChorusRenderer.draw(context: context, size: size, drawings: drawings, stage: ErmineStage(light: 1, topLight: 1), dust: dust)
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
/// The neon sign lays each letter out once a frame and only recolors it. It must draw exactly what
/// drawing a new `Text` for every glow and tube did.
@Suite @MainActor struct ErmineNeonRenderingTests {
    private static let neonPink = Color(red: 1, green: 0.27, blue: 0.68), neonCore = Color(red: 1, green: 0.74, blue: 0.91)
    private static let rope = Color(red: 0.78, green: 0.7, blue: 0.55)

    /// The drawing before the letters were laid out once, kept as the reference.
    private static func referenceNeon(_ context: GraphicsContext, brightness: [Double]) {
        var c = context
        c.translateBy(x: ErmineChorusRenderer.neonCenter.x, y: ErmineChorusRenderer.neonCenter.y); c.rotate(by: ErmineChorusRenderer.neonTilt)
        let font = Font.system(size: 14, weight: .heavy, design: .rounded)
        let letters = ErmineStage.neonText.map { c.resolve(Text(String($0)).font(font)) }
        let widths = letters.map { $0.measure(in: CGSize(width: 100, height: 100)).width }
        let total = widths.reduce(0, +)
        var strings = Path()
        for x in [-total * 0.36, total * 0.36] { strings.move(to: CGPoint(x: x, y: -11)); strings.addLine(to: CGPoint(x: x + 1.5, y: -20)) }
        c.stroke(strings, with: .color(rope.opacity(0.8)), lineWidth: 0.7)
        var tubes = Path()
        tubes.move(to: CGPoint(x: -total / 2 - 2, y: -11)); tubes.addLine(to: CGPoint(x: total / 2 + 2, y: -11.5))
        tubes.move(to: CGPoint(x: -total / 2 - 5, y: 10.5)); tubes.addLine(to: CGPoint(x: total / 2 + 5, y: 10))
        var x = -total / 2
        var centers: [CGFloat] = []
        for w in widths { centers.append(x + w / 2); x += w }
        for (radius, opacity) in [(CGFloat(6), 0.55), (CGFloat(2.5), 0.8)] {
            c.drawLayer { glow in
                glow.addFilter(.blur(radius: radius))
                glow.stroke(tubes, with: .color(neonPink.opacity(opacity)), lineWidth: 2)
                for (i, letter) in ErmineStage.neonText.enumerated() where letter != " " {
                    let level = i < brightness.count ? brightness[i] : 1
                    glow.draw(Text(String(letter)).font(font).foregroundColor(neonPink.opacity(opacity * level)), at: CGPoint(x: centers[i], y: 0))
                }
            }
        }
        c.stroke(tubes, with: .color(neonCore), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        for (i, letter) in ErmineStage.neonText.enumerated() where letter != " " {
            let level = i < brightness.count ? brightness[i] : 1
            let color = level > 0.5 ? neonCore : Color(red: 0.45, green: 0.2, blue: 0.33)
            c.draw(Text(String(letter)).font(font).foregroundColor(color), at: CGPoint(x: centers[i], y: 0))
        }
    }

    private func pixels(scale: CGFloat = 2, _ draw: @escaping (GraphicsContext) -> Void) throws -> Data {
        let renderer = ImageRenderer(content: Canvas { context, _ in
            context.fill(Path(CGRect(x: 0, y: 0, width: 360, height: 60)), with: .color(.black))
            draw(context)
        }.frame(width: 360, height: 60))
        renderer.scale = scale
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        return Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
    }

    @Test func layingLettersOutOnceDrawsTheSamePixels() throws {
        let count = ErmineStage.neonText.count
        for brightness in [Array(repeating: 1.0, count: count), (0..<count).map { $0 % 3 == 0 ? 0.2 : 1 }, Array(repeating: 0.0, count: count)] {
            for scale in [2.0, 1, 3] {
                let current = try pixels(scale: scale) { ErmineChorusRenderer.drawNeon($0, brightness: brightness) }
                let reference = try pixels(scale: scale) { Self.referenceNeon($0, brightness: brightness) }
                #expect(current == reference, "scale \(scale)")
                #expect(current.contains { $0 > 128 })
            }
        }
    }
}
#endif
