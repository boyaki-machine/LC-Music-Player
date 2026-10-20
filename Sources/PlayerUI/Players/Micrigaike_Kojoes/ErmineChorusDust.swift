import CoreGraphics
import Foundation

/// One speck of dust in the air of the stage.
struct ErmineMote: Sendable, Equatable {
    var position: CGPoint
    var velocity: CGVector
    /// Diameter in points.
    var size: CGFloat
    /// Twinkle phase and speed: a speck catches the light now and then as it tumbles.
    var phase: Double
    var speed: Double

    /// 0…1. Mostly dim with brief glints.
    var twinkle: Double { 0.25 + 0.75 * pow(0.5 + 0.5 * sin(phase), 6) }
}

/// Tiny dust drifting in the air of a live house. It is drawn behind the ermines and only shows where
/// a lamp's beam passes through it, so it glitters against the dark background.
struct ErmineDust: Sendable {
    static let count = 140
    /// The air above the crates.
    static let area = CGRect(x: 0, y: 0, width: 360, height: 118)
    private(set) var motes: [ErmineMote]
    private var rng: ErmineRandom

    init(seed: UInt64 = 23) {
        var rng = ErmineRandom(seed: seed)
        motes = (0..<Self.count).map { _ in
            ErmineMote(position: CGPoint(x: Self.area.width * rng.next(), y: Self.area.height * rng.next()),
                       velocity: CGVector(dx: (rng.next() - 0.5) * 1.6, dy: -0.2 - rng.next() * 1.0),
                       size: 0.35 + 0.45 * rng.next(), phase: 2 * .pi * rng.next(), speed: 0.8 + 1.7 * rng.next())
        }
        self.rng = rng
    }

    /// Drifts slowly upward and sideways with a little random wander; specks leaving the air come back on the other side.
    mutating func step(dt: Double) {
        guard dt > 0 else { return }
        for i in motes.indices {
            var m = motes[i]
            m.velocity.dx = min(1.2, max(-1.2, m.velocity.dx + (rng.next() - 0.5) * 1.5 * dt))
            m.velocity.dy = min(-0.1, max(-1.4, m.velocity.dy + (rng.next() - 0.5) * 1.0 * dt))
            m.position.x += m.velocity.dx * dt; m.position.y += m.velocity.dy * dt
            if m.position.x < 0 { m.position.x += Self.area.width } else if m.position.x > Self.area.width { m.position.x -= Self.area.width }
            if m.position.y < 0 { m.position.y += Self.area.height; m.position.x = Self.area.width * rng.next() }
            m.phase += m.speed * dt
            motes[i] = m
        }
    }
}
