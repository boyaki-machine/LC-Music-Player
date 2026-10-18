import CoreGraphics
import Foundation

/// Small deterministic generator, so each ermine has its own repeatable temperament in tests.
struct ErmineRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// What the ermines know about each other and the music they share.
struct ErmineWorld: Sendable {
    var ermine1Intense = false
    /// The shared beat, or nil while the tempo is unclear.
    var beat: ErmineBeat?
}

/// Cues from the ensemble (`ErmineEnsemble`) that make the ermines move together.
enum ErmineCue: Sendable, Equatable {
    /// Show your signature move: 1 tiptoe, 2 spin, 3 jump, 4 kira, 5 flex.
    case solo
    /// Look toward someone (−1 left, 1 right) for a number of drawings.
    case watch(direction: CGFloat, ticks: Int, smiling: Bool)
    /// Rise in turn from left to right.
    case wave(delayTicks: Int)
    /// Dip together and hop.
    case hop
    /// Bow at the end of a song.
    case bow(delayTicks: Int)
    /// Ermine 3, caught peeking: looks away, blushing.
    case flustered
    /// Hold an arm pose together for a number of beats.
    case arms(ErmineArms, beats: Int)
}

/// Chooses key drawings and how long to hold them, 12 decisions per second, like a director
/// marking a timing sheet. When a beat is known, everyone bobs on it and sways together every two beats;
/// the arms hold a meaningful pose for a phrase instead of moving on every note.
struct ErmineDirector: Sendable {
    static let tick = 1.0 / 12
    /// Beats per arm phrase while the beat is known; seconds per phrase otherwise.
    static let phraseBeats = 8, phraseSeconds = 4.0
    private enum Expression { case open, happy, dreamy, joy, surprise, trouble }
    private struct Note { var x: Double, y: Double, vx: Double, born: Double, glyph: String, size: Double }
    private struct FaceOverride { var eye: ErmineEye?; var troubled = false; var blush: Int?; var until: Double }

    let member: ErmineCastMember
    var reduceMotion = false
    private var rng: ErmineRandom
    private(set) var time = 0.0
    private(set) var envelope = 0.0, medium = 0.0, slow = 0.0
    /// Ermine 1 on tiptoe. Each tiptoe lasts a few seconds and is followed by a rest.
    private(set) var intense = false
    /// Everyone else gets carried away above 0.5 and calms below 0.4.
    private(set) var hype = false
    /// An onset (the start of a note or beat) happened in the latest step.
    private(set) var onsetNow = false
    /// Ermine 3 is peeking at ermine 4 on his own.
    private(set) var peeking = false
    private(set) var arms = ErmineArms()
    private(set) var frame = ErmineFrame()
    private var tickCount = 0, accumulator = 0.0, lastOnset = -9.0
    private var queue: [(key: ErmineKeyName, ticks: Int)] = []
    private var hold: ErmineKeyName? = .idleA
    private var loop: (keys: [ErmineKeyName], every: Int)?
    private var side = 1, blink: [ErmineEye] = [], nextBlink: Double, nextIdlePose: Double
    private var nextGesture: Double, nextSpin = 6.0, nextJump = 0.0, nextGlance: Double
    private var tiptoeUntil = 0.0, nextTiptoe = 4.0
    private var glintUntil = -1.0, nextGlint: Double, expression = Expression.open, nextExpression = 2.0
    private var laughUntil = -1.0, nextLaugh = 3.0, caring = false
    private var faceOverride: FaceOverride?
    private var lastBeatHandled = Int.min, nextArmBeat = Int.min, nextArmTime = 0.0, armsSince = 0.0
    private var grooving = false
    private var mouthLevel = 0, mouthSince = 0.0, roundMouth = false, sweat = 0
    private var notes: [Note] = []

    init(member: ErmineCastMember, seed: UInt64) {
        self.member = member
        rng = ErmineRandom(seed: seed)
        nextBlink = 1; nextIdlePose = 5; nextGesture = 8; nextGlance = 4; nextGlint = 3
        nextBlink += 2 * rng.next(); nextIdlePose += 6 * rng.next(); nextGesture += 4 * rng.next()
        nextGlance += 4 * rng.next(); nextGlint += 5 * rng.next()
    }

    var singing: Bool { envelope > 0.08 }
    var busy: Bool { !queue.isEmpty }
    private mutating func random() -> Double { rng.next() }
    private mutating func play(_ sequence: [(ErmineKeyName, Int)], then next: ErmineKeyName?) {
        queue = sequence.filter { $0.1 > 0 }.map { (key: $0.0, ticks: $0.1) }; hold = next; loop = nil
    }
    /// Without a beat, each onset of the ermine's own register bounces it; with a beat, the beat does.
    private mutating func singBounce() {
        guard !grooving else { return }
        side = -side
        play([(.squash, 1), (.up, 1)], then: side < 0 ? .singL : .singR)
    }
    private mutating func notesBurst(_ count: Int, glyphs: [String], size: ClosedRange<Double>) {
        for i in 0..<count {
            notes.append(Note(x: 10 + Double(i) * 6 + random() * 4, y: -88 - Double(i) * 5, vx: 4 + random() * 6, born: time + Double(i) * 0.12,
                              glyph: glyphs[Int(random() * Double(glyphs.count)) % glyphs.count], size: size.lowerBound + random() * (size.upperBound - size.lowerBound)))
        }
    }
    private static func approach(_ value: Double, _ goal: Double, _ tau: Double, _ dt: Double) -> Double {
        value + (goal - value) * min(1, dt / tau)
    }
    /// Where to return after a cue: the held pose, or a plain singing or idle pose.
    private var resting: ErmineKeyName { hold ?? (singing ? .singR : .idleA) }

    // MARK: Cues from the ensemble

    mutating func cue(_ cue: ErmineCue) {
        let current = frame.key
        switch cue {
        case .solo:
            switch member.id {
            case 1: startTiptoe()
            case 2: play([(.spin1, 2), (.back, 3), (.spin2, 2), (.up, 1)], then: resting); nextSpin = time + 8
            case 3: play([(.squash, 2), (.jumpAir, 3), (.jumpAir2, 1), (.squash, 2), (.armsUp, 6)], then: resting); nextJump = time + 3
            case 4: play([(.kira, 16)], then: resting); nextGesture = time + 10
            default: play([(.squash, 1), (.flex, 14)], then: resting); laugh()
            }
        case let .watch(direction, ticks, smiling):
            guard !intense else { return }
            play([(direction < 0 ? .glanceL : .glanceR, ticks)], then: resting)
            if smiling { faceOverride = FaceOverride(eye: .happy, until: time + Double(ticks) * Self.tick) }
        case let .wave(delay):
            if intense { endTiptoe() }
            play([(current, delay), (.squash, 1), (.up, 3)], then: resting)
        case .hop:
            if intense { endTiptoe() }
            play([(.squash, 3), (.hop, 3), (.squash, 2), (.up, 1)], then: singing ? .singR : .idleA)
            faceOverride = FaceOverride(eye: .happy, until: time + 0.8)
        case let .bow(delay):
            if intense { endTiptoe() }
            play([(current, delay), (.bow, 16)], then: .idleA)
            faceOverride = FaceOverride(eye: .closed, until: time + Double(delay + 16) * Self.tick)
            setArms(ErmineArms())
        case .flustered:
            play([(.glanceL, 12)], then: resting)
            faceOverride = FaceOverride(eye: .closed, troubled: true, blush: 4, until: time + 1)
            peeking = false
        case let .arms(next, beats):
            setArms(next)
            nextArmTime = time + Double(beats) * 0.5
            if let beat = lastKnownBeat { nextArmBeat = beat + beats }
        }
    }

    private var lastKnownBeat: Int?
    private mutating func setArms(_ next: ErmineArms) {
        if next != arms { arms = next; armsSince = time }
    }

    private mutating func startTiptoe() {
        intense = true; tiptoeUntil = time + 2.5 + random() * 1.5
        play([(.squash, 2), (.up, 1)], then: nil)
    }
    private mutating func endTiptoe() {
        intense = false; nextTiptoe = time + 8 + random() * 6
        play([(.squash, 1)], then: singing ? .singR : .idleA)
    }
    private mutating func laugh() {
        laughUntil = time + 1.6; nextLaugh = time + 5 + random() * 4
        notesBurst(3, glyphs: ["♩", "♪"], size: 13...16)
    }

    // MARK: Step

    /// Advances by `dt` seconds with this ermine's register level (0…1).
    mutating func step(dt: Double, level: Double, playing: Bool, world: ErmineWorld) {
        time += dt
        let input = playing && level.isFinite ? min(1, max(0, level)) : 0
        envelope = Self.approach(envelope, input, input > envelope ? 0.035 : 0.16, dt)
        medium = Self.approach(medium, envelope, 0.35, dt)
        slow = Self.approach(slow, envelope, 2.5, dt)
        if !hype && slow > 0.5 { hype = true }
        if hype && slow < 0.4 { hype = false }
        onsetNow = envelope - medium > 0.12 && time - lastOnset > 0.22
        if onsetNow { lastOnset = time }
        grooving = world.beat != nil && singing
        if let beat = world.beat { lastKnownBeat = beat.count }
        // Big moves start on notes that fall on the beat, so their key drawing lands with the music.
        let onBeat = world.beat.map { $0.phase < 0.15 || $0.phase > 0.9 } ?? true
        switch member.id {
        case 1: directErmine1(onset: onsetNow)
        case 2: directErmine2(onset: onsetNow && onBeat)
        case 3: directErmine3(onset: onsetNow, onBeat: onBeat)
        case 4: directErmine4(onset: onsetNow, world: world)
        default: directErmine5(onset: onsetNow && onBeat)
        }
        if let beat = world.beat { groove(beat) }
        chooseArms(world.beat)
        if !singing && !intense, let held = hold, [.singL, .singR, .wigL, .wigR, .flexL, .flexR, .armsUp].contains(held) { hold = .idleA }
        if onsetNow && envelope > 0.5 && random() < 0.2 {
            notes.append(Note(x: 14 + random() * 6, y: -92, vx: 4 + random() * 6, born: time,
                              glyph: random() < 0.5 ? "♪" : "♫", size: 10 + random() * 3))
        }
        accumulator += dt
        while accumulator >= Self.tick { accumulator -= Self.tick; onTick(world: world) }
        updateMouth()
        notes.removeAll { time - $0.born >= 1.6 }
    }

    /// Everyone bobs on the beat and sways together every two beats, like a choir.
    /// The dip starts just before the beat so the risen pose lands on it.
    private mutating func groove(_ beat: ErmineBeat) {
        guard singing, !busy, !intense, !caring else { return }
        let upcoming = beat.count + 1
        // Drawings change on a free-running 12fps grid; starting 1.5 drawings early puts the risen pose within half a drawing of the beat.
        guard beat.secondsToNext <= Self.tick * 1.5, lastBeatHandled < upcoming else { return }
        lastBeatHandled = upcoming
        let swayLeft = (upcoming / 2) % 2 == 0
        let sway: ErmineKeyName = member.id == 2 && hype ? (swayLeft ? .wigL : .wigR) : (swayLeft ? .singL : .singR)
        let accent = upcoming % 4 == 0 && envelope > 0.6
        play(accent ? [(.squash, 1), (.up, 1)] : [(.dip, 1)], then: sway)
    }

    /// The arms hold one meaningful pose per phrase, chosen by how loud the music is and by personality.
    private mutating func chooseArms(_ beat: ErmineBeat?) {
        guard singing else { if arms.pose != .rest { setArms(ErmineArms()) }; return }
        if let beat {
            guard beat.count >= nextArmBeat else { return }
            nextArmBeat = beat.count + Self.phraseBeats * (slow < 0.3 ? 2 : 1)
        } else {
            guard time >= nextArmTime else { return }
            nextArmTime = time + Self.phraseSeconds * (slow < 0.3 ? 2 : 1)
        }
        let table = Self.armChoices(id: member.id, level: slow)
        var r = random(), pose = ErmineArmPose.rest
        for (candidate, weight) in table { if r < weight { pose = candidate; break }; r -= weight }
        if pose == arms.pose && pose != .rest { pose = .rest }
        setArms(ErmineArms(pose: pose, side: random() < 0.5 ? -1 : 1))
    }

    /// Chances of each arm pose for quiet, middle and loud passages.
    static func armChoices(id: Int, level: Double) -> [(ErmineArmPose, Double)] {
        let band = level < 0.3 ? 0 : level < 0.55 ? 1 : 2
        switch (id, band) {
        case (1, 0): return [(.pray, 0.5), (.rest, 0.3), (.offer, 0.2)]
        case (1, 1): return [(.pray, 0.35), (.offer, 0.35), (.embrace, 0.15), (.rest, 0.15)]
        case (1, _): return [(.offer, 0.35), (.raise, 0.25), (.embrace, 0.25), (.pray, 0.15)]
        case (2, 0): return [(.rest, 0.5), (.pray, 0.3), (.point, 0.2)]
        case (2, 1): return [(.point, 0.35), (.raise, 0.25), (.offer, 0.2), (.rest, 0.2)]
        case (2, _): return [(.raise, 0.4), (.point, 0.4), (.embrace, 0.2)]
        case (3, 0): return [(.rest, 0.6), (.pray, 0.4)]
        case (3, 1): return [(.pray, 0.4), (.rest, 0.4), (.raise, 0.2)]
        case (3, _): return [(.raise, 0.5), (.pray, 0.3), (.embrace, 0.2)]
        case (4, 0): return [(.pray, 0.5), (.rest, 0.5)]
        case (4, 1): return [(.point, 0.35), (.pray, 0.35), (.offer, 0.3)]
        case (4, _): return [(.embrace, 0.35), (.raise, 0.35), (.point, 0.3)]
        case (_, 0): return [(.rest, 0.6), (.embrace, 0.4)]
        case (_, 1): return [(.embrace, 0.4), (.raise, 0.3), (.rest, 0.3)]
        default: return [(.raise, 0.5), (.embrace, 0.5)]
        }
    }

    /// Notes rising from the head, positioned at the display time.
    func notes(at displayTime: Double) -> [ErmineNote] {
        notes.filter { $0.born <= displayTime }.map { n in
            let age = displayTime - n.born
            return ErmineNote(position: CGPoint(x: n.x + n.vx * age, y: n.y - 18 * age), glyph: n.glyph, size: CGFloat(n.size))
        }
    }

    // MARK: Personalities

    private mutating func directErmine1(onset: Bool) {
        // The singing register is loud most of the time, so a tiptoe is short, rare and needs a strong voice.
        if intense && (time > tiptoeUntil || !singing) { endTiptoe() }
        if !intense && onset && slow > 0.62 && time > nextTiptoe && random() < 0.3 { startTiptoe() }
        if intense && !busy { loop = ([.tallA, .tallB], 1) }
        if onset && !intense && !busy { singBounce() }
        if onset && intense && !busy { play([(.tallDip, 1)], then: nil) }
    }

    private mutating func directErmine2(onset: Bool) {
        if hype && singing && !busy && onset && time > nextSpin {
            play([(.spin1, 2), (.back, 3), (.spin2, 2), (.up, 1)], then: .wigR); nextSpin = time + 8 + random() * 6
        } else if onset && !busy {
            if hype && !grooving { side = -side; let key: ErmineKeyName = side < 0 ? .wigL : .wigR; play([(key, 1)], then: key) } else { singBounce() }
        }
    }

    private mutating func directErmine3(onset: Bool, onBeat: Bool) {
        if onset && !busy {
            if hype && envelope > 0.5 && time > nextJump && onBeat {
                play([(.squash, 2), (.jumpAir, 3), (.jumpAir2, 1), (.squash, 2), (.armsUp, 1)], then: .singR)
                nextJump = time + 4 + random() * 3
            } else if !hype { singBounce() }
        }
        if !busy && time > nextGlance { // He keeps peeking at ermine 4, two places to his right.
            play([(.glanceR, 10 + Int(random() * 8))], then: hold); nextGlance = time + 6 + random() * 7; peeking = true
        }
        if peeking && frame.key != .glanceR && !busy { peeking = false }
        if time > nextGlint { glintUntil = time + 0.25; nextGlint = time + 6 + random() * 8 }
    }

    private mutating func directErmine4(onset: Bool, world: ErmineWorld) {
        if world.ermine1Intense && !caring { caring = true; play([(.glanceL, 1)], then: .glanceL) }
        if !world.ermine1Intense && caring { caring = false; play([(.idleA, 1)], then: singing ? .singR : .idleA) }
        guard !caring else { return }
        if singing && !busy && time > nextGesture && slow > 0.4 { play([(.kira, 12)], then: .singL); nextGesture = time + 10 + random() * 6 }
        else if onset && !busy { singBounce() }
    }

    private mutating func directErmine5(onset: Bool) {
        if onset && !busy {
            if envelope > 0.6 && hype && time > nextGesture { play([(.squash, 1), (.flex, 9)], then: hold); nextGesture = time + 8 + random() * 6 }
            else { singBounce() }
        }
        // A hearty laugh is shown with low notes rather than words.
        if hype && time > nextLaugh { laugh() }
    }

    // MARK: Drawing decisions

    /// The mouth follows the level on every display frame (lip sync), and never freezes open for long.
    private mutating func updateMouth() {
        var m = envelope < 0.12 ? 0 : envelope < 0.3 ? 1 : envelope < 0.55 ? 2 : 3
        if m == mouthLevel && m > 0 && time - mouthSince > 0.33 { m -= 1; mouthSince = time }
        if m != mouthLevel { mouthLevel = m; mouthSince = time }
        let laughing = member.id == 5 && time < laughUntil
        if laughing { m = 3 }
        if frame.key == .bow { m = 0 }
        var mouth: ErmineMouth = [.closed, .small, .medium, .large][m]
        if roundMouth && m > 0 { mouth = .round }
        frame.face.mouth = mouth
    }

    private mutating func onTick(world: ErmineWorld) {
        tickCount += 1
        var key: ErmineKeyName
        if !queue.isEmpty {
            key = queue[0].key; queue[0].ticks -= 1
            if queue[0].ticks <= 0 { queue.removeFirst() }
        } else if let loop {
            key = loop.keys[(tickCount / loop.every) % loop.keys.count]
        } else {
            key = hold ?? frame.key
        }
        // Idle breathing and an occasional glance or head tilt.
        if !singing && queue.isEmpty && !intense && !caring {
            if time > nextIdlePose {
                play([(random() < 0.5 ? .look : .tilt, 18 + Int(random() * 10))], then: nil); nextIdlePose = time + 5 + random() * 6
            }
            if queue.isEmpty { loop = ([.idleA, .idleA, .idleA, .idleB, .idleB], 5) }
        }
        // Eyes: blinks, then expressions by personality.
        var eye = ErmineEye.open, troubled = false
        roundMouth = false
        if time > nextBlink { blink = [.half, .closed, .half]; nextBlink = time + 2 + random() * 3.5 }
        if !blink.isEmpty { eye = blink.removeFirst() }
        if [.reachSm, .reach, .reachBk].contains(key) { eye = .happy }
        if member.id == 1 && intense { eye = .squeeze }
        if member.id == 4 {
            if caring { troubled = true } else if singing {
                if time > nextExpression {
                    let r = random()
                    expression = r < 0.35 ? .joy : r < 0.55 ? .surprise : r < 0.7 ? .trouble : .open
                    nextExpression = time + 1.5 + random() * 2.5
                }
                if expression == .joy || key == .kira { eye = .happy }
                if expression == .surprise && eye == .open { eye = .surprise; roundMouth = true }
                if expression == .trouble { troubled = true }
            }
        } else if singing && !(member.id == 1 && intense) {
            // While singing, the face changes every few seconds instead of the body swaying more.
            if time > nextExpression {
                let w = member.expressions, r = random()
                expression = r < w.open ? .open : r < w.open + w.happy ? .happy : .dreamy
                nextExpression = time + 2 + random() * 2.5
            }
            if eye == .open && expression == .happy { eye = .happy }
            if eye == .open && expression == .dreamy { eye = .half }
        }
        // Pointing at the audience comes with a wink: "you sing too!"; praying hands come with closed eyes.
        if arms.pose == .point && key.takesArmPose && time - armsSince < 0.9 { eye = .wink(side: arms.side) }
        if arms.pose == .pray && key.takesArmPose && singing { eye = .closed }
        if member.id == 3 && [.jumpAir, .jumpAir2, .armsUp].contains(key) { eye = .happy }
        if member.id == 5 && time < laughUntil { eye = .happy }
        var blushOverride: Int?
        if let face = faceOverride {
            if time < face.until {
                if let e = face.eye { eye = e }
                if face.troubled { troubled = true }
                blushOverride = face.blush
            } else { faceOverride = nil }
        }
        if key == .bow { eye = .closed }
        let straining = member.id == 1 && intense
        if straining && tickCount % 2 == 1 { sweat += 1 }
        if reduceMotion { key = .idleA }
        frame = ErmineFrame(
            key: key,
            face: ErmineFace(eye: eye, mouth: frame.face.mouth, troubledBrows: troubled, glint: time < glintUntil,
                             blush: blushOverride ?? (straining ? 4 : singing ? 2 : 1), sweat: straining ? sweat : nil),
            effects: ErmineEffects(shake: straining && !reduceMotion ? tickCount : nil),
            wag: member.id == 4 && singing && !reduceMotion ? ((tickCount / 3) % 2 == 1 ? 1 : -1) : 0,
            arms: reduceMotion ? ErmineArms() : arms)
    }
}
