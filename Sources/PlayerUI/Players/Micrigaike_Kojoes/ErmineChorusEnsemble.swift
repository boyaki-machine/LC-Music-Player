import CoreGraphics
import Foundation

/// The conductor. It watches all five ermines and starts moves that involve several of them,
/// so the chorus reacts to each other instead of only to its own register:
/// - solo: one register stands out for a while; that ermine shows its signature move and the others turn to watch;
/// - wave: the whole band gets much louder than a moment ago (a chorus starts); everyone rises in turn from left to right;
/// - hop: after a quiet break, a strong bass note makes everyone dip and hop together;
/// - bow: when a song falls silent, everyone bows;
/// - exchanges: neighbours smile at each other, 4 catches 3 peeking, 1 thanks 4 for looking after him.
/// It also keeps the shared beat count and sets the stage: floor lamps follow the bass and turn to a soloist,
/// hung lamps follow the voice, and a letter or two of the neon sign flickers on high notes.
struct ErmineEnsemble: Sendable {
    /// How far a register's slow level must exceed the others' average to count as a solo.
    /// The singing register (ermine 1) is loud most of the time, so it needs more.
    static let soloMargin = 0.3, leadSoloMargin = 0.42
    static let soloHoldSeconds = 1.5, soloSeconds = 3.0, soloRestSeconds = 10.0
    static let waveRestSeconds = 20.0, hopRestSeconds = 12.0

    private var rng: ErmineRandom
    private(set) var time = 0.0
    private(set) var stage = ErmineStage()
    private(set) var soloist: Int?
    private var soloUntil = 0.0, nextSolo = 4.0, candidate: Int?, candidateSince = 0.0
    private var nextWave = 4.0
    private var quietSince: Double?, quietEnded = -9.0, hopArmed = false, nextHop = 0.0
    private var lastSung = -99.0, silentSince: Double?, bowed = false
    private var nextExchange = 8.0, wasCaring = false, decidedPeek = false
    private var scheduled: [(at: Double, index: Int, cue: ErmineCue)] = []
    private var beatCount = 0, lastBeatIndex: Int?
    private(set) var beat: ErmineBeat?
    private var flickers: [(letter: Int, start: Double)] = [], nextFlicker = 0.0
    /// Brightness pattern of a flickering letter, one value per 1/30 s.
    static let flickerPattern = [0.15, 1, 0.3, 0.9, 0.1, 1]

    init(seed: UInt64 = 7) { rng = ErmineRandom(seed: seed) }

    private static func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    private static func direction(from a: ErmineCastMember, to b: ErmineCastMember) -> CGFloat { b.slot < a.slot ? -1 : 1 }

    mutating func reset() {
        soloist = nil; candidate = nil; quietSince = nil; silentSince = nil; hopArmed = false; bowed = false
        scheduled.removeAll(); stage = ErmineStage(); beat = nil; lastBeatIndex = nil; flickers.removeAll()
    }

    /// Turns the tracker's beat into one whose count only goes up, so sways stay in step when the estimate shifts.
    mutating func follow(_ tracked: (index: Int, phase: Double, period: Double)?) {
        guard let tracked else { beat = nil; lastBeatIndex = nil; return }
        if let last = lastBeatIndex, tracked.index != last { beatCount += max(1, min(2, tracked.index - last)) }
        lastBeatIndex = tracked.index
        beat = ErmineBeat(count: beatCount, phase: tracked.phase, period: tracked.period)
    }

    /// Reads the ermines after their latest step and gives cues for the next one.
    mutating func update(_ directors: inout [ErmineDirector], dt: Double, playing: Bool) {
        time += dt
        let ids = directors.map(\.member.id)
        let index = { (id: Int) in ids.firstIndex(of: id)! }
        let envelopes = directors.map(\.envelope), slows = directors.map(\.slow)
        let averageEnvelope = Self.mean(envelopes), averageSlow = Self.mean(slows)
        let bass = directors.firstIndex { $0.member.range == .bass }!

        for item in scheduled where item.at <= time { directors[item.index].cue(item.cue) }
        scheduled.removeAll { $0.at <= time }

        // Solo: one register stands out from the others for a while.
        if soloist != nil && time > soloUntil { soloist = nil }
        if soloist == nil {
            var best: (index: Int, margin: Double)?
            for i in directors.indices {
                let others = Self.mean(slows.enumerated().filter { $0.offset != i }.map(\.element))
                let margin = slows[i] - others - (directors[i].member.id == 1 ? Self.leadSoloMargin : Self.soloMargin)
                if slows[i] > 0.35 && margin > 0 && margin > (best?.margin ?? 0) { best = (i, margin) }
            }
            if let best, playing {
                if candidate != best.index { candidate = best.index; candidateSince = time }
                if time - candidateSince >= Self.soloHoldSeconds && time > nextSolo {
                    soloist = best.index; soloUntil = time + Self.soloSeconds; nextSolo = time + Self.soloRestSeconds
                    directors[best.index].cue(.solo)
                    for j in directors.indices where j != best.index {
                        directors[j].cue(.watch(direction: Self.direction(from: directors[j].member, to: directors[best.index].member),
                                                ticks: Int(Self.soloSeconds * 12), smiling: true))
                    }
                }
            } else { candidate = nil }
        }

        // Hop: after a quiet break, a strong bass note. It takes priority over a wave.
        if averageSlow < 0.2 { quietSince = quietSince ?? time } else { if quietSince != nil { quietEnded = time }; quietSince = nil }
        if let q = quietSince, time - q > 2 { hopArmed = true }
        // The chance passes if the music carries on for a while without that strong bass note.
        if hopArmed && quietSince == nil && time - quietEnded > 3 { hopArmed = false }
        if playing && hopArmed && directors[bass].onsetNow && directors[bass].envelope > 0.5 && time > nextHop {
            hopArmed = false; nextHop = time + Self.hopRestSeconds; nextWave = max(nextWave, time + 5)
            for i in directors.indices { directors[i].cue(.hop) }
        }

        // Wave: the band is suddenly much louder than a moment ago, as when a chorus starts.
        if playing && !hopArmed && averageEnvelope > 0.55 && averageEnvelope - averageSlow > 0.3 && time > nextWave {
            nextWave = time + Self.waveRestSeconds
            for i in directors.indices { directors[i].cue(.wave(delayTicks: directors[i].member.slot * 2)) }
            // Then everyone raises an arm together for the chorus, the outer hand of each half.
            for i in directors.indices {
                let side: CGFloat = directors[i].member.slot < 2 ? -1 : 1
                scheduled.append((time + 0.9, i, .arms(ErmineArms(pose: .raise, side: side), beats: 8)))
            }
        }

        // Bow: the song falls silent after everyone has been singing.
        if averageSlow > 0.3 { lastSung = time }
        if playing && averageEnvelope < 0.03 { silentSince = silentSince ?? time } else { silentSince = nil; bowed = false }
        if !bowed, let s = silentSince, time - s > 1.2, time - lastSung < 12 {
            bowed = true
            for i in directors.indices { directors[i].cue(.bow(delayTicks: Int(rng.next() * 3))) }
        }

        // Exchanges between particular ermines.
        let three = index(3), four = index(4), one = index(1)
        if directors[three].peeking && !decidedPeek {
            decidedPeek = true
            if rng.next() < 0.5 { // 4 notices; 3 looks away, blushing.
                scheduled.append((time + 0.4, four, .watch(direction: Self.direction(from: directors[four].member, to: directors[three].member), ticks: 12, smiling: false)))
                scheduled.append((time + 0.8, three, .flustered))
            }
        }
        if !directors[three].peeking { decidedPeek = false }
        let caring = directors[one].intense
        if wasCaring && !caring { // 1 smiles at 4, who looked after him; she smiles back.
            scheduled.append((time + 0.4, one, .watch(direction: Self.direction(from: directors[one].member, to: directors[four].member), ticks: 14, smiling: true)))
            scheduled.append((time + 0.6, four, .watch(direction: Self.direction(from: directors[four].member, to: directors[one].member), ticks: 10, smiling: true)))
        }
        wasCaring = caring
        if playing && averageSlow > 0.25 && soloist == nil && time > nextExchange {
            nextExchange = time + 8 + rng.next() * 6
            let left = Int(rng.next() * 4) // a pair of neighbours, by slot
            if let a = directors.firstIndex(where: { $0.member.slot == left }), let b = directors.firstIndex(where: { $0.member.slot == left + 1 }),
               !directors[a].intense, !directors[b].intense, !directors[a].busy, !directors[b].busy {
                directors[a].cue(.watch(direction: 1, ticks: 10, smiling: true))
                directors[b].cue(.watch(direction: -1, ticks: 10, smiling: true))
            }
        }

        // Neon: on a strong high note, a letter or two flickers briefly. Nothing flickers on its own.
        let high = directors.firstIndex { $0.member.range == .high }!
        if playing && directors[high].onsetNow && directors[high].envelope > 0.45 && time > nextFlicker && rng.next() < 0.35 {
            nextFlicker = time + 0.6
            let letters = ErmineStage.neonText.indices.filter { ErmineStage.neonText[$0] != " " }
            let first = letters[Int(rng.next() * Double(letters.count)) % letters.count]
            flickers.append((first, time))
            if rng.next() < 0.4, first + 1 < ErmineStage.neonText.count, ErmineStage.neonText[first + 1] != " " { flickers.append((first + 1, time + 0.03)) }
        }
        let length = Double(Self.flickerPattern.count) / 30
        flickers.removeAll { time - $0.start >= length }
        var neon = Array(repeating: 1.0, count: ErmineStage.neonText.count)
        for flicker in flickers where time >= flicker.start {
            neon[flicker.letter] = Self.flickerPattern[min(Self.flickerPattern.count - 1, Int((time - flicker.start) * 30))]
        }
        // Lamps: floor lamps on the bass, pointing at a soloist; hung lamps on the voice.
        let voice = directors.firstIndex { $0.member.range == .mid }!
        stage = ErmineStage(light: playing ? 0.25 + 0.75 * envelopes[bass] : 0.15,
                            topLight: playing ? 0.2 + 0.8 * envelopes[voice] : 0.1,
                            spotSlot: soloist.map { directors[$0].member.slot }, neon: neon)
    }
}
