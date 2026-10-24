import Foundation

/// The beat the whole cast moves to. `count` grows continuously: its whole part counts beats, its fraction is the phase.
struct PuppetBeat: Sendable, Equatable {
    var count: Double
    var bpm: Double
}

/// Arm angles (the left arm; the right one mirrors it). 0 is the arm as drawn; the range stays small so the
/// sleeve's joint never shows.
enum PuppetArmPose: Sendable, Equatable {
    case neutral, up, spread, down
    var angle: Double {
        switch self { case .neutral: 0; case .up: -0.24; case .spread: 0.2; case .down: 0.34 }
    }
}

/// Seconds left of each action; 0 is off.
struct PuppetActions: Sendable, Equatable {
    var sparkle = 0.0, cry = 0.0, slump = 0.0, shout = 0.0, headbang = 0.0, shy = 0.0, blush = 0.0
    mutating func elapse(_ dt: Double) {
        sparkle = max(0, sparkle - dt); cry = max(0, cry - dt); slump = max(0, slump - dt); shout = max(0, shout - dt)
        headbang = max(0, headbang - dt); shy = max(0, shy - dt); blush = max(0, blush - dt)
    }
}

/// What a puppet's parts do in one picture. Angles are radians, distances stage points; opacity 0 hides a part.
struct PuppetPose: Sendable, Equatable {
    var rootY = 3.0
    var bodyPosition = SIMD2<Double>(0, 0)
    var bodyRotation = SIMD3<Double>(0, 0, 0)
    var headRotation = SIMD3<Double>(0, 0, 0)
    var upperRotationX = 0.0, jawRotationX = 0.0
    var armL = 0.0, armR = 0.0
    var squeeze = 0.0, closedEyes = 0.0, blush = 0.0
    /// The six lines around a shouting head: opacity and vertical stretch.
    var shoutLines = Array(repeating: SIMD2<Double>(0, 1), count: 6)
    /// Per eye: the glow's opacity and size (times its base), the core's opacity, and two ripples (opacity, size).
    var eyeGlow = Array(repeating: 0.0, count: 2)
    var eyeGlowScale = Array(repeating: SIMD2<Double>(1, 1), count: 2)
    var eyeCore = Array(repeating: 0.0, count: 2)
    var ripples = Array(repeating: SIMD2<Double>(0, 0.25), count: 4)
    /// How far the tears have run down (0…1) and how far their water has flowed.
    var tears = 0.0, tearFlow = 0.0
}

/// One puppet's performance: from its register's level and the shared beat it decides how it bobs, sways,
/// opens its mouth, where it looks and which action it shows. Ported from the agreed mock.
struct PuppetDirector: Sendable {
    let member: PuppetMember
    private var random: PuppetRandom
    private(set) var fastEnvelope = 0.0, slowEnvelope = 0.0
    private(set) var average = 0.5, middle = 0.5
    private(set) var armPose = PuppetArmPose.neutral
    private(set) var turn = 0.0
    private(set) var phrase = 0
    private var lastPhrase = Int.min, phraseClock = 0.0
    var actions = PuppetActions()
    var cooldown = (sparkle: 0.0, shout: 0.0, headbang: 6.0)
    private var silentFor = 0.0
    /// From the ensemble: look somewhere (or away) until a time.
    var look: (turn: Double, until: Double)?
    /// From the ensemble: the same choreography as a partner for one phrase.
    var sync: (pose: PuppetArmPose, turn: Double, phrase: Int)?
    private(set) var mouth = 0.0
    private(set) var beatCount = 0.0
    private(set) var pulse = 0.0

    private var armL = PuppetSpring(omega: 7), armR = PuppetSpring(omega: 7), turnSpring = PuppetSpring(omega: 5)
    private var slump = PuppetSpring(omega: 4), cry = PuppetSpring(omega: 5), sparkle = PuppetSpring(omega: 9)
    private var shout = PuppetSpring(omega: 9), bob = PuppetSpring(omega: 22), roll = PuppetSpring(omega: 8)
    private var headbang = PuppetSpring(omega: 6), shy = PuppetSpring(omega: 9), blush = PuppetSpring(omega: 4)

    init(member: PuppetMember) {
        self.member = member; random = PuppetRandom(seed: member.seed)
    }

    var lookingUntil: Double { look?.until ?? -.infinity }
    /// Settled enough to stop the clock after a pause.
    var isSettled: Bool {
        let springs = [armL, armR, turnSpring, slump, cry, sparkle, shout, bob, roll, headbang, shy, blush]
        return springs.allSatisfy { abs($0.value - $0.target) < 0.002 && abs($0.velocity) < 0.01 } && mouth < 0.002
    }

    private mutating func pick<T>(_ table: [(T, Double)]) -> T {
        var u = random.next()
        for (value, p) in table { u -= p; if u <= 0 { return value } }
        return table[0].0
    }

    /// Advances by `dt`. `levels` are the four registers (0…1); `beat` is nil while the tempo is unknown.
    /// While not playing the levels are zero and the clock of phrases and actions does not run toward a slump.
    mutating func update(dt: Double, now: Double, levels: [Double], beat: PuppetBeat?, playing: Bool = true) {
        let level = levels[member.register.rawValue]
        func follow(_ envelope: Double, attack: Double, release: Double) -> Double {
            envelope + (level - envelope) * (1 - exp(-dt / (level > envelope ? attack : release)))
        }
        fastEnvelope = follow(fastEnvelope, attack: 0.012, release: 0.06)
        slowEnvelope = follow(slowEnvelope, attack: 0.08, release: 0.35)
        let all = levels.reduce(0, +) / Double(levels.count)
        middle += (all - middle) * (1 - exp(-dt / 0.35))
        average += (all - average) * (1 - exp(-dt / 2.5))
        silentFor = playing && all < 0.06 ? silentFor + dt : 0
        beatCount = beat?.count ?? now * 2

        // Arms and facing are chosen per phrase: 8 beats, or 4 seconds while the tempo is unknown.
        if let beat { phrase = Int((beat.count / 8).rounded(.down)) } else {
            if playing { phraseClock += dt }
            phrase = Int((phraseClock / 4).rounded(.down))
        }
        if phrase != lastPhrase {
            lastPhrase = phrase
            let e = average
            armPose = e > 0.62 ? pick([(.up, 0.4), (.spread, 0.3), (.neutral, 0.3)])
                : e > 0.35 ? pick([(.neutral, 0.5), (.spread, 0.3), (.up, 0.2)])
                : pick([(.neutral, 0.5), (.down, 0.5)])
            turn = pick([(-1, 0.3), (0, 0.4), (1, 0.3)])
        }
        if let sync, sync.phrase == phrase { armPose = sync.pose; turn = sync.turn }
        cooldown.sparkle -= dt; cooldown.shout -= dt; cooldown.headbang -= dt
        let busy = actions.shout > 0 || actions.headbang > 0 || actions.shy > 0
        // Shout: the strongest swell (stricter than sparkling eyes); not together with sparkling.
        if !busy && cooldown.shout <= 0 && middle > 0.82 && middle - average > 0.26 {
            actions.shout = 2.2; cooldown.shout = 20; cooldown.sparkle = max(cooldown.sparkle, 4)
        }
        // Sparkling eyes: a sudden swell. The spiky-haired boy heats up more easily.
        let easy = member.name == "spiky" ? 0.08 : 0
        if !busy && cooldown.sparkle <= 0 && middle > 0.7 - easy && middle - average > 0.22 - easy {
            actions.sparkle = 1.8; cooldown.sparkle = 16
        }
        // Headbanging (spiky-haired boy): with a clear beat and loud music, for 8 beats.
        if member.name == "spiky", let beat, !busy, cooldown.headbang <= 0, average > 0.6 {
            actions.headbang = 8 * 60 / beat.bpm; cooldown.headbang = 22
        }
        // Slump when the music stops while playing.
        if silentFor > 1.2 { actions.slump = max(actions.slump, 0.6) }
        actions.elapse(dt)

        let slumping = actions.slump > 0, shouting = actions.shout > 0, isShy = actions.shy > 0
        // Arms rise in a shout and go to the mouth in shyness.
        let arm = shouting ? -0.3 : isShy ? -0.15 : (slumping ? PuppetArmPose.down : armPose).angle
        armL.target = arm; armR.target = arm
        var facing = turn
        if let look, now < look.until { facing = look.turn }
        turnSpring.target = facing * 0.34
        slump.target = slumping ? 1 : 0
        cry.target = actions.cry > 0 ? 1 : 0
        sparkle.target = actions.sparkle > 0 ? 1 : 0
        shout.target = shouting ? 1 : 0
        headbang.target = actions.headbang > 0 ? 1 : 0
        shy.target = isShy ? 1 : 0
        blush.target = actions.blush > 0 || isShy ? 1 : 0

        // Sink on the beat and sway every two beats; the mouth opens from just before the beat to after it.
        let swing: Double, chomp: Double
        if let beat {
            let ph = beat.count - beat.count.rounded(.down), d = ph < 0.5 ? ph : ph - 1
            pulse = exp(-(d * d) / (2 * 0.1 * 0.1))
            let dm = d - 0.04
            chomp = exp(-(dm * dm) / (2 * 0.13 * 0.13))
            swing = sin(.pi * beat.count)
        } else {
            pulse = PuppetMath.clamp((fastEnvelope - slowEnvelope) * 3); swing = sin(now * 1.6)
            chomp = PuppetMath.clamp((fastEnvelope - slowEnvelope) * 4)
        }
        let energy = 0.35 + 0.65 * PuppetMath.clamp(average * 1.3)
        bob.target = pulse * energy * (slumping ? 0.2 : 1)
        roll.target = swing * 0.045 * energy * (slumping ? 0.3 : 1)
        for keyPath in [\Self.armL, \.armR, \.turnSpring, \.slump, \.cry, \.sparkle, \.shout, \.bob, \.roll, \.headbang, \.shy, \.blush] {
            self[keyPath: keyPath].step(dt)
        }
        // How wide: the register's strength, plus quick rises. When: the beat. Smaller in shyness.
        let strength = PuppetMath.clamp(slowEnvelope)
        let detail = PuppetMath.clamp((fastEnvelope - slowEnvelope) * 2.5)
        mouth = PuppetMath.clamp(1.25 * strength * (0.25 + 0.75 * chomp) + detail * 0.6) * (1 - 0.8 * slump.value) * (1 - 0.6 * shy.value)
    }

    /// The picture at `now`. With reduced motion the body holds still: no bobbing, swaying, headbanging or trembling.
    func pose(now: Double, reduceMotion: Bool = false) -> PuppetPose {
        let clamp = { (v: Double) in PuppetMath.clamp(v) }
        let still = reduceMotion ? 0.0 : 1.0
        let slump = slump.value, bobV = bob.value * still, rollV = roll.value * still
        var p = PuppetPose()
        p.rootY = 3 - slump * 5
        // Headbanging: down on the beat, up between beats.
        let hb = headbang.value, hbPhase = cos(2 * .pi * beatCount) * still
        // Shy: eyes closed, trembling.
        let shyV = shy.value, tremble = (shyV * sin(now * 47) * 0.5 + shyV * sin(now * 29) * 0.5) * still
        // Shout: stretch up, face the sky, mouth wide open, shaking.
        let shoutV = shout.value, shake = shoutV * sin(now * 53) * still
        p.bodyPosition = SIMD2(tremble * 0.35, -bobV * 3.2 * (1 - shoutV) + shoutV * 2.2)
        p.bodyRotation = SIMD3(-shoutV * 0.06, turnSpring.value * 0.6,
                               rollV * (1 - shoutV) + slump * 0.06 * sin(now * 0.8) * still + shake * 0.012 + tremble * 0.02)
        p.headRotation = SIMD3(bobV * 0.08 * (1 - hb) + slump * 0.42 + cry.value * 0.12 - shoutV * 0.26 + hb * (0.12 + 0.3 * hbPhase) + shyV * 0.18,
                               turnSpring.value * 0.5,
                               -rollV * 0.6 + shoutV * 0.025 * sin(now * 41) * still)
        // Mouth: the upper head tips back and the jaw drops a little; a shout opens it to the limit.
        p.upperRotationX = -(mouth * 0.62 * (1 - shoutV) + shoutV * (0.78 + 0.04 * sin(now * 37) * still))
        p.jawRotationX = mouth * 0.22 * (1 - shoutV) + shoutV * 0.36 + cry.value * 0.03 * sin(now * 30) * still
        p.squeeze = shoutV > 0.05 ? clamp(shoutV * 1.6) : 0
        p.closedEyes = shyV > 0.05 && shoutV < 0.05 ? clamp(shyV * 1.6) : 0
        p.blush = blush.value > 0.03 ? clamp(blush.value) : 0
        for i in 0..<6 {
            let f = clamp(shoutV * 1.4) * (0.6 + 0.4 * sin(now * 23 + Double(i) * 1.7))
            p.shoutLines[i] = SIMD2(shoutV > 0.05 ? clamp(shoutV * 1.4) : 0, 0.6 + 0.6 * f)
        }
        // Arms follow the bob slightly late.
        let lag = bobV * 0.06
        p.armL = armL.value + lag + sin(now * 2.1) * 0.02 * still
        p.armR = -armR.value - lag - sin(now * 2.3) * 0.02 * still
        // Glowing eyes: brightness wavers with the sound.
        let sp = sparkle.value
        var glow = sp * (0.55 + 0.45 * clamp(fastEnvelope * 1.2))
        switch member.eyes.kind {
        case .sakura: glow = sp * (0.7 + 0.3 * sin(now * 2.2)) * 0.55   // breathing slowly
        case .wave: glow = sp * (0.62 + 0.25 * clamp(fastEnvelope * 1.3) + 0.13 * pulse)   // flickers slightly with level and beat
        default: break
        }
        let eyesOpen = 1 - max(shyV, shoutV)
        for i in 0..<2 {
            let on = glow * eyesOpen, visible = on > 0.02
            p.eyeGlow[i] = visible ? on : 0
            p.eyeCore[i] = visible ? clamp(sp * 1.4) * eyesOpen : 0
            var sx = 0.85 + 0.15 * glow, sy = sx
            if member.eyes.kind == .flame {   // flickers, now and then flaring up
                let fl = 0.5 + 0.25 * sin(now * 17 + Double(i) * 2) + 0.25 * sin(now * 29.7 + Double(i))
                sx *= 0.85 + 0.2 * fl; sy *= 0.9 + 0.5 * fl
            }
            p.eyeGlowScale[i] = SIMD2(sx, sy)
            if member.eyes.kind == .wave {   // a ring spreads and fades on every beat, deeper when louder
                for k in 0..<2 {
                    let u = ((beatCount + Double(k)) / 2).truncatingRemainder(dividingBy: 1)
                    let u1 = u < 0 ? u + 1 : u
                    p.ripples[i * 2 + k] = SIMD2(visible ? on * (1 - u1) * (0.35 + 0.5 * clamp(slowEnvelope)) : 0, 0.25 + 0.75 * u1)
                }
            }
        }
        // Tears run down from the top, then keep flowing slowly.
        let cryV = cry.value
        p.tears = cryV > 0.03 ? clamp((cryV - 0.15) / 0.7) : 0
        p.tearFlow = now * 0.12
        return p
    }
}
