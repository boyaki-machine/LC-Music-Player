import Foundation
import Testing
@testable import AudioProcessingCore

/// A short song written sample by sample, in stereo: a sung line in the centre (harmonics shaped by
/// the formants of "a" or "i", with vibrato on long notes), a guitar panned hard left that plays other
/// notes, and a kick in the centre.
struct SyntheticSong {
    struct Note { var start: Double; var length: Double; var midi: Double; var vowel: Character = "a"; var shout = false; var harmony: Double? = nil }
    var notes: [Note]
    var duration: Double
    var rate = 44100.0
    var guitar = true

    static func formants(_ vowel: Character) -> [(Double, Double)] {
        vowel == "i" ? [(300, 1), (2300, 0.5), (3000, 0.3)] : [(800, 1), (1200, 0.7), (2500, 0.3)]
    }

    func samples() -> (left: [Float], right: [Float]) {
        let total = Int(duration * rate)
        var left = [Float](repeating: 0, count: total), right = left
        var seed: UInt32 = 99
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
        func voice(_ note: Note, midi: Double, gain: Double, pan: Float) {
            let s = Int(note.start * rate), n = Int(note.length * rate)
            let f0 = 440 * pow(2, (midi - 69) / 12)
            let shape = Self.formants(note.vowel)
            let count = Int(4000 / f0)
            let amplitudes = (1...max(1, count)).map { h -> Double in
                let f = Double(h) * f0
                return shape.reduce(0) { $0 + $1.1 / (1 + pow((f - $1.0) / 120, 2)) } / Double(h).squareRoot()
            }
            var phase = 0.0
            for i in 0..<n where s + i < total {
                let t = Double(i) / rate
                let vibrato = note.length > 1 ? 0.3 * sin(2 * .pi * 5.5 * t) : 0
                phase += 2 * .pi * f0 * pow(2, vibrato / 12) / rate
                let envelope = min(1, t / 0.03, (note.length - t) / 0.05)
                var v = 0.0
                for (h, a) in amplitudes.enumerated() { v += a * sin(Double(h + 1) * phase) }
                var x = Float(gain * envelope * v)
                if note.shout { x = x * 1.6 + Float(envelope) * 0.25 * (noise() - noise()) }
                left[s + i] += x * (1 - pan); right[s + i] += x * (1 + pan)
            }
        }
        for note in notes {
            voice(note, midi: note.midi, gain: 0.05, pan: 0)
            if let harmony = note.harmony { voice(note, midi: note.midi + harmony, gain: 0.04, pan: 0.1) }
        }
        // Kick every half second in the centre; a guitar on the left an octave and a fifth from the voice.
        for k in 0..<Int(duration * 2) {
            let s = Int(Double(k) * 0.5 * rate)
            for i in 0..<Int(0.2 * rate) where s + i < total {
                let t = Double(i) / rate
                let x = Float(0.4 * sin(2 * .pi * 55 * t) * exp(-t * 20))
                left[s + i] += x; right[s + i] += x
            }
        }
        if guitar {
            var phase = 0.0
            for i in 0..<total {
                let t = Double(i) / rate
                let midi = [45.0, 52, 47, 54][Int(t / 2) % 4]
                phase += 2 * .pi * 440 * pow(2, (midi - 69) / 12) / rate
                left[i] += Float(0.06 * (sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase) + 0.2 * sin(5 * phase)))
            }
        }
        return (left, right)
    }

    /// Sung syllables of `length` with `gap` between them, from `start` for `seconds`.
    static func line(from start: Double, seconds: Double, midi: [Double], length: Double = 0.3, gap: Double = 0.08,
                     vowels: [Character] = ["a"], harmony: Double? = nil) -> [Note] {
        var notes: [Note] = []
        var t = start, i = 0
        while t + length <= start + seconds {
            notes.append(Note(start: t, length: length, midi: midi[i % midi.count], vowel: vowels[i % vowels.count], harmony: harmony))
            t += length + gap; i += 1
        }
        return notes
    }
}

func analyze(_ song: SyntheticSong) throws -> VocalMap {
    let (l, r) = song.samples()
    let analyzer = try CentreVocalAnalyzer(sampleRate: song.rate)
    try l.withUnsafeBufferPointer { lp in
        try r.withUnsafeBufferPointer { rp in
            var s = 0
            while s < lp.count {
                let n = min(8192, lp.count - s)
                try analyzer.consume(left: lp.baseAddress! + s, right: rp.baseAddress! + s, frames: n)
                s += n
            }
        }
    }
    return try analyzer.finish()
}

@Suite struct VocalAnalysisTests {
    /// Verse (2–8s), an instrumental gap, a long tone (10–12.5s), a high line (13–17s),
    /// a shout (18–19s) and a harmonised line (20–26s).
    static let song = SyntheticSong(notes:
        SyntheticSong.line(from: 2, seconds: 6, midi: [62, 64, 65, 64], vowels: ["a", "i"])
        + [.init(start: 10, length: 2.5, midi: 67)]
        + SyntheticSong.line(from: 13, seconds: 4, midi: [74, 76])
        + [.init(start: 18, length: 1, midi: 69, shout: true)]
        + SyntheticSong.line(from: 20, seconds: 6, midi: [64, 62], harmony: 4),
        duration: 28)

    static func during(_ map: VocalMap, _ kind: VocalMap.Event.Kind, _ from: Double, _ to: Double) -> Double {
        let covered = map.events.filter { $0.kind == kind }.reduce(0.0) { sum, e in
            sum + max(0, min(to, Double(e.endMilliseconds) / 1000) - max(from, Double(e.startMilliseconds) / 1000))
        }
        return covered / (to - from)
    }

    @Test func phrasesNotesAndMouthFollowTheSungLine() throws {
        let map = try analyze(Self.song)
        #expect(map.algorithm == CentreVocalAnalyzer.algorithm && map.durationMilliseconds == 28_000)
        // Phrases cover the singing and leave the instrumental parts alone.
        #expect(Self.during(map, .phrase, 2.2, 7.8) > 0.9, "\(map.events.filter { $0.kind == .phrase })")
        #expect(Self.during(map, .phrase, 0, 1.8) == 0 && Self.during(map, .phrase, 8.3, 9.7) == 0)
        // The note is the sung one, not the guitar's.
        var right = 0, sung = 0
        for note in Self.song.notes where !note.shout {
            for t in stride(from: note.start + 0.1, to: note.start + note.length - 0.1, by: 0.04) {
                sung += 1
                if let n = map.note(at: t), abs(Double(n) - note.midi) <= 1 { right += 1 }
            }
        }
        #expect(Double(right) / Double(sung) > 0.85, "\(right) of \(sung)")
        // The mouth is shut between phrases and opens wider on "a" than on "i".
        #expect(map.mouth(at: 9) == 0 && map.mouth(at: 1) == 0)
        let a = Self.song.notes.filter { $0.start < 8 && $0.vowel == "a" }.map { map.mouth(at: $0.start + 0.15) }
        let i = Self.song.notes.filter { $0.start < 8 && $0.vowel == "i" }.map { map.mouth(at: $0.start + 0.15) }
        #expect(i.allSatisfy { $0 > 0 } && a.reduce(0, +) / Double(a.count) > 1.15 * i.reduce(0, +) / Double(i.count), "a \(a) i \(i)")
    }

    @Test func longHighShoutAndHarmonyAreFound() throws {
        let map = try analyze(Self.song)
        #expect(Self.during(map, .longTone, 10.2, 12.3) > 0.7, "\(map.events.filter { $0.kind == .longTone })")
        #expect(Self.during(map, .longTone, 2, 8) < 0.1)
        #expect(Self.during(map, .highTone, 13.2, 16.8) > 0.6, "\(map.events.filter { $0.kind == .highTone })")
        #expect(Self.during(map, .highTone, 2, 12.5) < 0.1)
        #expect(Self.during(map, .shout, 18.1, 18.9) > 0.5, "\(map.events.filter { $0.kind == .shout })")
        #expect(Self.during(map, .shout, 0, 17.5) == 0 && Self.during(map, .shout, 20, 28) == 0)
        #expect(Self.during(map, .harmony, 20.5, 25.5) > 0.6, "\(map.events.filter { $0.kind == .harmony })")
        #expect(Self.during(map, .harmony, 0, 19.5) < 0.1)
    }

    @Test func registerFollowsTheVocalsRange() throws {
        let high = try analyze(Self.song)
        #expect(high.register == .high && (62...70).contains(high.medianNote), "\(high.medianNote)")
        let low = try analyze(SyntheticSong(notes: SyntheticSong.line(from: 1, seconds: 10, midi: [48, 50, 52]), duration: 12, guitar: false))
        #expect(low.register == .low && (47...53).contains(low.medianNote), "\(low.medianNote)")
    }

    @Test func instrumentalAndSilentTracksHaveNoVocal() throws {
        let instrumental = try analyze(SyntheticSong(notes: [], duration: 12))
        #expect(instrumental.events.filter { $0.kind == .phrase }.reduce(0) { $0 + $1.durationMilliseconds } < 1000,
                "\(instrumental.events)")
        #expect(instrumental.register == .unknown)
        let analyzer = try CentreVocalAnalyzer(sampleRate: 48000)
        let silence = [Float](repeating: 0, count: 8192)
        for _ in 0..<30 { try silence.withUnsafeBufferPointer { try analyzer.consume(left: $0.baseAddress!, right: nil, frames: 8192) } }
        let silent = try analyzer.finish()
        #expect(silent.events.isEmpty && silent.mouth.allSatisfy { $0 == 0 } && silent.mouth.count == Int(silent.durationMilliseconds / 40))
    }
}

@Suite struct VocalMapTests {
    static let sample = VocalMap(algorithm: 2, durationMilliseconds: 1000, register: .high, medianNote: 64, frameMilliseconds: 40,
        mouth: [0, 3, 15, 7, 0], notes: [0, 64, 65], events: [
            .init(kind: .phrase, startMilliseconds: 40, durationMilliseconds: 200, strength: 90),
            .init(kind: .longTone, startMilliseconds: 80, durationMilliseconds: 100, strength: 127)])

    @Test func roundTripAndLookup() throws {
        #expect(try VocalMap(encoded: Self.sample.encoded()) == Self.sample)
        let map = Self.sample
        #expect(map.mouth(at: 0.08) == 1 && abs(map.mouth(at: 0.1) - 11.0 / 15) < 1e-9 && map.mouth(at: 5) == 0)
        #expect(map.note(at: 0) == nil && map.note(at: 0.1) == 64 && map.note(at: 0.2) == 65 && map.note(at: 9) == nil)
        #expect(map.events(at: 0.1).map(\.kind) == [.phrase, .longTone] && map.events(at: 0.3).isEmpty)
        let coarse = map.coarser()
        #expect(coarse.frameMilliseconds == 80 && coarse.mouth == [3, 15, 0] && coarse.notes == [64, 65])
    }

    @Test func rejectsDamagedData() throws {
        let data = Self.sample.encoded()
        for length in [0, 4, 5, data.count / 2, data.count - 1] {
            #expect(throws: (any Error).self) { try VocalMap(encoded: data.prefix(length)) }
        }
        var trailing = data; trailing.append(0)
        #expect(throws: (any Error).self) { try VocalMap(encoded: trailing) }
        let unknownRegister = VocalMap(algorithm: 1, durationMilliseconds: 10, register: .unknown, medianNote: 0, frameMilliseconds: 40, mouth: [], notes: [], events: []).encoded()
        // Bytes 0-4 are the magic and version, then algorithm and duration take one byte each.
        var badRegister = unknownRegister; badRegister[7] = 9
        #expect(throws: (any Error).self) { try VocalMap(encoded: badRegister) }
    }
}
