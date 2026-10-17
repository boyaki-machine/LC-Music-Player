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

/// What the ermines know about each other.
struct ErmineWorld: Sendable { var ermine1Intense = false }

/// Chooses key drawings and how long to hold them, 12 decisions per second, like a director
/// marking a timing sheet. Inputs are one register level per frame; output is an `ErmineFrame`.
struct ErmineDirector: Sendable {
    static let tick = 1.0 / 12
    private enum Expression { case open, happy, dreamy, joy, surprise, trouble }
    private struct Note { var x: Double, y: Double, vx: Double, born: Double, glyph: String, size: Double }

    let member: ErmineCastMember
    var reduceMotion = false
    private var rng: ErmineRandom
    private(set) var time = 0.0
    private(set) var envelope = 0.0, medium = 0.0, slow = 0.0
    /// Ermine 1 on tiptoe (hysteresis 0.55 / 0.44 of the slow level).
    private(set) var intense = false
    /// Everyone else gets carried away above 0.5 and calms below 0.4.
    private(set) var hype = false
    private(set) var frame = ErmineFrame()
    private var tickCount = 0, accumulator = 0.0, lastOnset = -9.0
    private var queue: [(key: ErmineKeyName, ticks: Int)] = []
    private var hold: ErmineKeyName? = .idleA
    private var loop: (keys: [ErmineKeyName], every: Int)?
    private var side = 1, blink: [ErmineEye] = [], nextBlink: Double, nextIdlePose: Double
    private var gesture = false, nextGesture: Double, nextSpin = 6.0, nextJump = 0.0, nextGlance: Double
    private var glintUntil = -1.0, nextGlint: Double, expression = Expression.open, nextExpression = 2.0
    private var laughUntil = -1.0, nextLaugh = 3.0, caring = false
    private var mouth = 0, mouthAge = 0, sweat = 0
    private var notes: [Note] = []

    init(member: ErmineCastMember, seed: UInt64) {
        self.member = member
        rng = ErmineRandom(seed: seed)
        nextBlink = 1; nextIdlePose = 5; nextGesture = 5; nextGlance = 4; nextGlint = 3
        nextBlink += 2 * rng.next(); nextIdlePose += 6 * rng.next(); nextGesture += 4 * rng.next()
        nextGlance += 4 * rng.next(); nextGlint += 5 * rng.next()
    }

    private var singing: Bool { envelope > 0.08 }
    private var busy: Bool { !queue.isEmpty }
    private mutating func random() -> Double { rng.next() }
    private mutating func play(_ sequence: [(ErmineKeyName, Int)], then next: ErmineKeyName?) {
        queue = sequence.map { (key: $0.0, ticks: $0.1) }; hold = next; loop = nil
    }
    private mutating func singBounce() {
        side = -side
        play([(.squash, 1), (.up, 1)], then: side < 0 ? .singL : .singR)
    }
    private static func approach(_ value: Double, _ goal: Double, _ tau: Double, _ dt: Double) -> Double {
        value + (goal - value) * min(1, dt / tau)
    }

    /// Advances by `dt` seconds with this ermine's register level (0…1).
    mutating func step(dt: Double, level: Double, playing: Bool, world: ErmineWorld) {
        time += dt
        let input = playing && level.isFinite ? min(1, max(0, level)) : 0
        envelope = Self.approach(envelope, input, input > envelope ? 0.035 : 0.16, dt)
        medium = Self.approach(medium, envelope, 0.35, dt)
        slow = Self.approach(slow, envelope, 2.5, dt)
        if !hype && slow > 0.5 { hype = true }
        if hype && slow < 0.4 { hype = false }
        let onset = envelope - medium > 0.12 && time - lastOnset > 0.22
        if onset { lastOnset = time }
        switch member.id {
        case 1: directErmine1(onset: onset)
        case 2: directErmine2(onset: onset)
        case 3: directErmine3(onset: onset)
        case 4: directErmine4(onset: onset, world: world)
        default: directErmine5(onset: onset)
        }
        if !singing && !intense, let held = hold, [.singL, .singR, .wigL, .wigR, .flexL, .flexR].contains(held) { hold = .idleA }
        if onset && envelope > 0.5 && random() < 0.25 {
            notes.append(Note(x: 14 + random() * 6, y: -92, vx: 4 + random() * 6, born: time,
                              glyph: random() < 0.5 ? "♪" : "♫", size: 10 + random() * 3))
        }
        accumulator += dt
        while accumulator >= Self.tick { accumulator -= Self.tick; onTick(world: world) }
        notes.removeAll { time - $0.born >= 1.6 }
    }

    /// Notes rising from the head, positioned at the display time.
    func notes(at displayTime: Double) -> [ErmineNote] {
        notes.map { n in
            let age = max(0, displayTime - n.born)
            return ErmineNote(position: CGPoint(x: n.x + n.vx * age, y: n.y - 18 * age), glyph: n.glyph, size: CGFloat(n.size))
        }
    }

    // MARK: Personalities

    private mutating func directErmine1(onset: Bool) {
        if !intense && slow > 0.55 { intense = true; play([(.squash, 2), (.up, 1)], then: nil) }
        if intense && slow < 0.44 { intense = false; play([(.squash, 1)], then: .idleA) }
        if intense && !busy { loop = ([.tallA, .tallB], 1) }
        if onset {
            if intense { if !busy { play([(.tallDip, 1)], then: nil) } } else if !gesture { singBounce() }
        }
        if singing && !intense && !gesture && slow > 0.22 && time > nextGesture {
            gesture = true; play([(.reachAnt, 2), (.reachSm, 1), (.reach, 8), (.reachBk, 2)], then: .singR)
        }
        if gesture && !busy { gesture = false; nextGesture = time + 5 + random() * 6 }
    }

    private mutating func directErmine2(onset: Bool) {
        if hype && singing && !busy && time > nextSpin {
            play([(.spin1, 2), (.back, 3), (.spin2, 2), (.up, 1)], then: .wigR); nextSpin = time + 8 + random() * 6
        } else if onset && !busy {
            if hype { side = -side; let key: ErmineKeyName = side < 0 ? .wigL : .wigR; play([(key, 1)], then: key) } else { singBounce() }
        }
    }

    private mutating func directErmine3(onset: Bool) {
        if onset && !busy {
            if hype && envelope > 0.5 && time > nextJump {
                play([(.squash, 2), (.jumpAir, 3), (.jumpAir2, 1), (.squash, 2), (.armsUp, 1)], then: .armsUp)
                nextJump = time + 2.5 + random() * 2
            } else if !hype { singBounce() }
        }
        if !busy && time > nextGlance { // He keeps peeking at ermine 4, two places to his right.
            play([(.glanceR, 10 + Int(random() * 8))], then: hold); nextGlance = time + 6 + random() * 7
        }
        if time > nextGlint { glintUntil = time + 0.25; nextGlint = time + 6 + random() * 8 }
        if !singing && hold == .armsUp { hold = .idleA }
    }

    private mutating func directErmine4(onset: Bool, world: ErmineWorld) {
        if world.ermine1Intense && !caring { caring = true; play([(.glanceL, 1)], then: .glanceL) }
        if !world.ermine1Intense && caring { caring = false; play([(.idleA, 1)], then: singing ? .singR : .idleA) }
        guard !caring else { return }
        if singing && !busy && time > nextGesture { play([(.kira, 12)], then: .singL); nextGesture = time + 6 + random() * 4 }
        else if onset && !busy { singBounce() }
    }

    private mutating func directErmine5(onset: Bool) {
        if onset && !busy {
            if envelope > 0.55 && time > nextGesture { play([(.squash, 1), (.flex, 9)], then: hold); nextGesture = time + 5 + random() * 5 }
            else if hype { side = -side; let key: ErmineKeyName = side < 0 ? .flexL : .flexR; play([(.squash, 1), (key, 1)], then: key) }
            else { singBounce() }
        }
        if hype && time > nextLaugh { laughUntil = time + 1.6; nextLaugh = time + 4 + random() * 4 }
    }

    // MARK: One drawing decision

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
        var mouthOverride: ErmineMouth?
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
                if expression == .surprise && eye == .open { eye = .surprise; mouthOverride = .round }
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
        if member.id == 3 && [.jumpAir, .jumpAir2, .armsUp].contains(key) { eye = .happy }
        let laughing = member.id == 5 && time < laughUntil
        if laughing { eye = .happy }
        // Mouth flaps: four drawings chosen by level, never frozen for long while singing.
        var m = envelope < 0.12 ? 0 : envelope < 0.3 ? 1 : envelope < 0.55 ? 2 : 3
        if m == mouth && m > 0 { mouthAge += 1; if mouthAge >= 4 { m -= 1; mouthAge = 0 } } else if m != mouth { mouthAge = 0 }
        mouth = m
        if laughing { m = 3 }
        var mouthDrawing: ErmineMouth = [.closed, .small, .medium, .large][m]
        if let mouthOverride, m > 0 { mouthDrawing = mouthOverride }
        let straining = member.id == 1 && intense
        if straining && tickCount % 2 == 1 { sweat += 1 }
        if reduceMotion { key = .idleA }
        frame = ErmineFrame(
            key: key,
            face: ErmineFace(eye: eye, mouth: mouthDrawing, troubledBrows: troubled, glint: time < glintUntil,
                             blush: straining ? 4 : singing ? 2 : 1, sweat: straining ? sweat : nil),
            effects: ErmineEffects(shake: straining && !reduceMotion ? tickCount : nil, laugh: laughing ? tickCount : nil),
            wag: member.id == 4 && singing && !reduceMotion ? ((tickCount / 3) % 2 == 1 ? 1 : -1) : 0)
    }
}
