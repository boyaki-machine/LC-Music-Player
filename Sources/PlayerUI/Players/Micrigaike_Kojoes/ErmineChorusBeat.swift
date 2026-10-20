import Foundation

/// The beat the whole chorus moves to. `count` only increases, so "every other beat" stays stable
/// while the tracker refines its estimate.
struct ErmineBeat: Sendable, Equatable {
    var count: Int
    /// 0 on the beat, approaching 1 just before the next one.
    var phase: Double
    var period: Double
    var secondsToNext: Double { (1 - phase) * period }
}

/// Estimates tempo and beat positions from the low registers, so the ermines can move together on the beat
/// instead of each reacting to its own notes.
///
/// Onset strength is the rise of the bass, low-mid and (half-weighted) mid registers between analysis frames.
/// Every half second the last six seconds are resampled at 30Hz; the autocorrelation over 70–180 BPM,
/// weighted toward 120 BPM, gives the period and a comb over that period gives the phase.
struct ErmineBeatTracker: Sendable {
    static let rate = 30.0, window = 6.0, minBPM = 70.0, maxBPM = 180.0
    /// How far the chosen period's autocorrelation must stand above the average over all tempos.
    /// Below it the beat is too unclear to follow.
    static let minimumConfidence = 1.8

    private var samples: [(time: Double, strength: Double)] = []
    private var previous: [Double]?
    private var lastEstimate = -Double.infinity
    private(set) var period: Double?
    private(set) var anchor: Double?
    private(set) var confidence = 0.0

    mutating func reset() {
        samples.removeAll(); previous = nil; lastEstimate = -.infinity; period = nil; anchor = nil; confidence = 0
    }

    mutating func feed(registerDB: [Double], at time: Double) {
        guard registerDB.count >= 3, registerDB.allSatisfy(\.isFinite) else { return }
        var strength = 0.0
        if let previous {
            strength = max(0, registerDB[0] - previous[0]) + max(0, registerDB[1] - previous[1]) + 0.5 * max(0, registerDB[2] - previous[2])
        }
        previous = registerDB
        if let last = samples.last, time <= last.time { return }
        samples.append((time, strength))
        samples.removeAll { $0.time < time - Self.window }
        if time - lastEstimate >= 0.5, let first = samples.first, time - first.time >= 3 {
            lastEstimate = time
            estimate(now: time)
        }
    }

    /// The beat at `time`, or nil while the tempo is unknown or unclear.
    func beat(at time: Double) -> (index: Int, phase: Double, period: Double)? {
        guard let period, let anchor, confidence >= Self.minimumConfidence, time - anchor < 4 * Self.window else { return nil }
        let beats = (time - anchor) / period
        let index = Int(beats.rounded(.down))
        return (index, beats - Double(index), period)
    }

    private mutating func estimate(now: Double) {
        let count = Int(Self.window * Self.rate)
        var grid = Array(repeating: 0.0, count: count)
        for sample in samples {
            let i = count - 1 - Int(((now - sample.time) * Self.rate).rounded())
            if i >= 0 && i < count { grid[i] = max(grid[i], sample.strength) }
        }
        let mean = grid.reduce(0, +) / Double(count)
        let x = grid.map { max(0, $0 - mean) }
        let energy = x.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { confidence = 0; return }
        let minLag = Int((60 / Self.maxBPM * Self.rate).rounded(.down)), maxLag = Int((60 / Self.minBPM * Self.rate).rounded(.up))
        func correlation(_ lag: Int) -> Double { (lag..<count).reduce(0) { $0 + x[$1] * x[$1 - lag] } }
        var best = minLag, bestScore = -1.0
        var scores: [Int: Double] = [:]
        for lag in minLag...maxLag {
            let ac = correlation(lag); scores[lag] = ac
            let bpm = 60 * Self.rate / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.6, 2))
            if ac * prior > bestScore { bestScore = ac * prior; best = lag }
        }
        // Refine between frames with a parabola through the neighbours.
        var lag = Double(best)
        if let a = scores[best - 1], let b = scores[best], let c = scores[best + 1] {
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 { lag += min(0.5, max(-0.5, 0.5 * (a - c) / denominator)) }
        }
        let average = scores.values.reduce(0, +) / Double(max(1, scores.count))
        confidence = average > 1e-12 ? (scores[best] ?? 0) / average : 0
        // Phase: the offset whose comb of past beats collects the most onset strength.
        var bestOffset = 0, bestComb = -1.0
        for offset in 0..<best {
            var sum = 0.0, i = count - 1 - offset
            while i >= 0 { sum += x[i]; i -= best }
            if sum > bestComb { bestComb = sum; bestOffset = offset }
        }
        period = lag / Self.rate
        anchor = now - Double(bestOffset) / Self.rate
    }
}
