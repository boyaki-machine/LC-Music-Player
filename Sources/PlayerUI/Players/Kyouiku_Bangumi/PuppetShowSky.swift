import Foundation

/// A rare sight in the sky: a rainbow under the sun or a meteor shower under the moon, for about ten seconds, while the
/// four shout together.
struct PuppetSkyEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case rainbow, meteorShower }
    var kind: Kind
    /// Seconds since it began. It runs on its own clock, so it also plays out while the time of day stands still.
    var elapsed = 0.0

    static let duration = 10.0
    var isOver: Bool { elapsed >= Self.duration }

    /// Short shouts together with a breath between them: start and length in seconds.
    static let shouts: [(start: Double, length: Double)] = [(0.6, 2), (3.2, 2), (5.8, 2), (8.4, 1.4)]
    /// Seconds left of the shout under way, or nil between shouts.
    var shoutLeft: Double? {
        Self.shouts.first { elapsed >= $0.start && elapsed < $0.start + $0.length }.map { $0.start + $0.length - elapsed }
    }

    /// The sight that fits the sky at `tod`: a rainbow while the sun climbs, then a meteor shower while the moon is out
    /// and a rainbow while only the sun is.
    static func kind(at tod: Double, moonAge: Double) -> Kind {
        if let sun = PuppetBackdrop.sunArc(tod), sun < 0.5 { return .rainbow }
        if PuppetBackdrop.moonArc(tod) != nil && PuppetBackdrop.moonShows(age: moonAge) { return .meteorShower }
        return PuppetBackdrop.sunArc(tod) != nil ? .rainbow : .meteorShower
    }

    /// The time of day when the sun and the moon are highest (the middle of their arcs in `PuppetBackdrop`).
    static func highest(_ kind: Kind) -> Double { kind == .rainbow ? 0.41 - 0.16 : 0.5 + 0.31 }

    /// Fades in over the first second and out over the last two.
    var opacity: Double { PuppetMath.clamp(min(elapsed, (Self.duration - elapsed) / 2)) }

    /// The layers drawn over the sky, behind the clouds and the land.
    func layers(reduceMotion: Bool) -> [PuppetBackdrop.Layer] {
        switch kind {
        case .rainbow:
            // It spans the sky from the left, drawn across in the first two seconds.
            let reveal = PuppetMath.smoothstep(0, 2, elapsed) * (Double.pi + 0.4)
            return [.rainbow(x: PuppetBackdrop.width / 2, y: 150, radius: 118, width: 11, reveal: reduceMotion ? .pi + 0.4 : reveal,
                             alpha: opacity)]
        case .meteorShower:
            guard !reduceMotion else { return [] }
            var out: [PuppetBackdrop.Layer] = []
            // From a point high on the right, streaks fall to the lower left, several at a time.
            for i in 0..<Self.meteorCount {
                let start = 0.3 + Double(i) * 0.13 + PuppetRandom.hash(i * 7 + 1) * 0.15
                let life = 0.6 + PuppetRandom.hash(i * 7 + 2) * 0.4
                let u = (elapsed - start) / life
                guard u >= 0 && u < 1 else { continue }
                let x0 = 70 + PuppetRandom.hash(i * 7 + 3) * 300, y0 = 2 + PuppetRandom.hash(i * 7 + 4) * 34
                let length = 50 + PuppetRandom.hash(i * 7 + 5) * 40, direction = SIMD2(-0.88, 0.47)
                let head = SIMD2(x0, y0) + direction * length * u
                let a = sin(.pi * min(1, u * 1.15)) * PuppetMath.clamp((Self.duration - elapsed) / 2)
                out.append(.streak(from: head - direction * (22 + 14 * PuppetRandom.hash(i * 7 + 6)), to: head, alpha: a))
                out.append(.glint(x: head.x, y: head.y, radius: 1.1, alpha: a))
            }
            return out
        }
    }
    static let meteorCount = 70
}

/// Whether the day or the night that has just begun brings a sight: drawn once as it begins, and if so the
/// sight comes around the sun's or the moon's highest point. The time of day moves only while playing,
/// so this happens only while music plays.
struct PuppetSkyCalendar: Sendable {
    /// The chance that a day or a night brings its sight.
    static let chance = 1.0 / 80
    /// Where the day and the night begin: night is half of the sky (see `PuppetBackdrop.weights`).
    static let dayBegins = 0.875, nightBegins = 0.625
    /// The sight drawn for the present day or night.
    private(set) var coming: PuppetSkyEvent.Kind?

    /// The time of day moved forward from `from` to `to`; `draw` gives a number in 0..<1.
    /// Returns the sight that begins now.
    mutating func advance(from: Double, to: Double, draw: () -> Double) -> PuppetSkyEvent.Kind? {
        if Self.passed(Self.dayBegins, from: from, to: to) { coming = draw() < Self.chance ? .rainbow : nil }
        if Self.passed(Self.nightBegins, from: from, to: to) { coming = draw() < Self.chance ? .meteorShower : nil }
        guard let coming else { return nil }
        let begins = PuppetSkyEvent.highest(coming) - PuppetSkyEvent.duration / 2 / PuppetBackdrop.daySeconds
        guard Self.passed(begins, from: from, to: to) else { return nil }
        self.coming = nil
        return coming
    }

    /// True when moving forward around the day from `from` to `to` passes `mark` (reaching it counts).
    static func passed(_ mark: Double, from: Double, to: Double) -> Bool {
        let step = (to - from + 1).truncatingRemainder(dividingBy: 1), gone = (mark - from + 1).truncatingRemainder(dividingBy: 1)
        return step > 0 && gone > 0 && gone <= step
    }
}
