import Foundation
import Testing
@testable import AudioProcessingCore

/// A drum pattern written sample by sample: a kick on every beat (louder on the bar's first), a snare
/// on two and four, hi-hats on eighths and a quiet held chord that does not follow the beat.
struct SyntheticGroove {
    var sections: [(bpm: Double, seconds: Double)]
    var rate = 44100.0
    var lead = 0.5
    var chord = true

    /// The times in seconds of the beats and whether each begins a bar.
    var beats: [(time: Double, downbeat: Bool)] {
        var result: [(Double, Bool)] = []
        var start = lead
        for section in sections {
            let period = 60 / section.bpm
            var i = 0
            while Double(i) * period < section.seconds - 1e-9 {
                result.append((start + Double(i) * period, i % 4 == 0)); i += 1
            }
            start += Double(i) * period
        }
        return result
    }
    var duration: Double { lead + sections.reduce(0) { $0 + $1.seconds } + 1 }

    func samples() -> [Float] {
        let total = Int(duration * rate)
        var out = [Float](repeating: 0, count: total)
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
        func add(at time: Double, length: Double, _ f: (Double) -> Float) {
            let s = Int(time * rate)
            for i in 0..<Int(length * rate) where s + i < total { out[s + i] += f(Double(i) / rate) }
        }
        let beatList = beats
        for (index, beat) in beatList.enumerated() {
            let gain: Float = beat.downbeat ? 0.6 : 0.35
            add(at: beat.time, length: 0.25) { t in gain * Float(sin(2 * .pi * 55 * t) * exp(-t * 18)) }
            if index % 2 == 1 { add(at: beat.time, length: 0.15) { t in 0.25 * noise() * Float(exp(-t * 30)) } }
            let next = index + 1 < beatList.count ? beatList[index + 1].time : beat.time + 0.5
            for hat in [beat.time, (beat.time + next) / 2] {
                add(at: hat, length: 0.05) { t in
                    // A difference of noise is mostly high frequencies.
                    let a = noise(), b = noise()
                    return 0.08 * (a - b) * Float(exp(-t * 80))
                }
            }
        }
        if chord {
            for (i, x) in out.enumerated() {
                let t = Double(i) / rate
                out[i] = x + Float(0.04 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t)))
            }
        }
        return out
    }
}

func detect(_ pcm: [Float], rate: Double, chunk: Int = 4096) throws -> BeatMap {
    let detector = try OnsetBeatDetector(sampleRate: rate)
    try pcm.withUnsafeBufferPointer { p in
        var start = 0
        while start < p.count {
            let n = min(chunk, p.count - start)
            try detector.consume(left: p.baseAddress! + start, right: nil, frames: n)
            start += n
        }
    }
    return try detector.finish()
}

/// The share of expected beats with a detected beat within `tolerance` seconds.
func recall(_ map: BeatMap, _ expected: [Double], tolerance: Double) -> Double {
    let found = map.beats.map { Double($0.milliseconds) / 1000 }
    let hits = expected.filter { e in found.contains { abs($0 - e) <= tolerance } }.count
    return Double(hits) / Double(max(1, expected.count))
}

@Suite struct BeatDetectionTests {
    @Test(arguments: [(97.0, 44100.0), (120.0, 48000.0), (150.0, 44100.0), (128.0, 96000.0)])
    func steadyGroove(bpm: Double, rate: Double) throws {
        let groove = SyntheticGroove(sections: [(bpm, 30)], rate: rate)
        let map = try detect(groove.samples(), rate: rate)
        let expected = groove.beats
        let r = recall(map, expected.map(\.time), tolerance: 0.03)
        #expect(r >= 0.95, "recall \(r)")
        #expect(map.beats.count <= expected.count + 2)
        #expect(map.tempos.count == 1)
        #expect(abs((map.tempos.first?.bpm ?? 0) - bpm) / bpm < 0.01, "\(map.tempos)")
        #expect(map.clarity > 0.5, "clarity \(map.clarity)")
        // Bars begin where the accented kick is.
        let downbeats = map.beats.filter(\.isDownbeat).map { Double($0.milliseconds) / 1000 }
        let bars = expected.filter(\.downbeat).map(\.time)
        let onBars = downbeats.filter { d in bars.contains { abs($0 - d) <= 0.03 } }.count
        #expect(Double(onBars) >= 0.9 * Double(downbeats.count), "\(onBars) of \(downbeats.count)")
        #expect(map.algorithm == OnsetBeatDetector.algorithm)
    }

    /// The beats land on the onsets, not a constant amount late or early.
    @Test func beatTimesAreCentered() throws {
        let groove = SyntheticGroove(sections: [(120, 20)], chord: false)
        let map = try detect(groove.samples(), rate: groove.rate)
        let expected = groove.beats.map(\.time)
        var errors: [Double] = []
        for beat in map.beats {
            let t = Double(beat.milliseconds) / 1000
            if let nearest = expected.min(by: { abs($0 - t) < abs($1 - t) }), abs(nearest - t) < 0.1 { errors.append(t - nearest) }
        }
        let mean = errors.reduce(0, +) / Double(max(1, errors.count))
        #expect(abs(mean) <= 0.012, "mean offset \(mean)")
    }

    @Test func tempoChange() throws {
        let groove = SyntheticGroove(sections: [(100, 30), (132, 30)])
        let map = try detect(groove.samples(), rate: groove.rate)
        #expect(recall(map, groove.beats.map(\.time), tolerance: 0.04) >= 0.9)
        #expect(map.tempos.count == 2, "\(map.tempos)")
        if map.tempos.count == 2 {
            #expect(abs(map.tempos[0].bpm - 100) < 1.5)
            #expect(abs(map.tempos[1].bpm - 132) < 2)
            #expect(abs(Double(map.tempos[1].startMilliseconds) / 1000 - 30.5) < 2)
        }
    }

    @Test func silenceAndShortAudioHaveNoBeats() throws {
        let silent = try detect([Float](repeating: 0, count: 44100 * 10), rate: 44100)
        #expect(silent.beats.isEmpty && silent.clarity == 0 && silent.durationMilliseconds == 10_000)
        let short = try detect(SyntheticGroove(sections: [(120, 2)], lead: 0).samples(), rate: 44100)
        #expect(short.beats.isEmpty)
    }

    @Test func noiseIsUnclear() throws {
        var seed: UInt32 = 7
        let noise = (0..<(44100 * 20)).map { _ -> Float in
            seed = seed &* 1664525 &+ 1013904223
            return 0.2 * Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        let map = try detect(noise, rate: 44100)
        #expect(map.clarity < 0.2, "clarity \(map.clarity)")
    }

    @Test func stereoMatchesMonoMix() throws {
        let pcm = SyntheticGroove(sections: [(110, 15)]).samples()
        let detector = try OnsetBeatDetector(sampleRate: 44100)
        let silent = [Float](repeating: 0, count: pcm.count)
        let doubled = pcm.map { $0 * 2 }
        try doubled.withUnsafeBufferPointer { l in
            try silent.withUnsafeBufferPointer { r in
                var start = 0
                while start < pcm.count {
                    let n = min(8192, pcm.count - start)
                    try detector.consume(left: l.baseAddress! + start, right: r.baseAddress! + start, frames: n)
                    start += n
                }
            }
        }
        #expect(try detector.finish() == detect(pcm, rate: 44100, chunk: 1000))
    }
}

@Suite struct BeatMapTests {
    static let sample = BeatMap(algorithm: 3, durationMilliseconds: 200_000, clarity: 0.7,
        tempos: [.init(startMilliseconds: 500, bpm: 120), .init(startMilliseconds: 60_500, bpm: 128.25)],
        beats: [.init(milliseconds: 500, strength: 127, isDownbeat: true), .init(milliseconds: 1000, strength: 40, isDownbeat: false),
                .init(milliseconds: 1500, strength: 0, isDownbeat: false), .init(milliseconds: 199_999, strength: 90, isDownbeat: true)])

    @Test func roundTrip() throws {
        let data = Self.sample.encoded()
        #expect(try BeatMap(encoded: data) == Self.sample)
        #expect(Self.sample.clarity == 179.0 / 255)
        let empty = BeatMap(algorithm: 1, durationMilliseconds: 0, clarity: 0, tempos: [], beats: [])
        #expect(try BeatMap(encoded: empty.encoded()) == empty)
    }

    /// About three bytes a beat: an hour at 160 BPM stays under the cache's 32KiB record.
    @Test func compactSize() throws {
        let beats = (0..<9600).map { BeatMap.Beat(milliseconds: UInt32($0 * 375), strength: 100, isDownbeat: $0 % 4 == 0) }
        let map = BeatMap(algorithm: 1, durationMilliseconds: 3_600_000, clarity: 1, tempos: [.init(startMilliseconds: 0, bpm: 160)], beats: beats)
        #expect(map.encoded().count < 9600 * 3 + 32)
    }

    @Test func rejectsDamagedData() throws {
        let data = Self.sample.encoded()
        for length in [0, 3, 4, 5, data.count / 2, data.count - 1] {
            #expect(throws: (any Error).self) { try BeatMap(encoded: data.prefix(length)) }
        }
        var trailing = data; trailing.append(0)
        #expect(throws: (any Error).self) { try BeatMap(encoded: trailing) }
        var magic = data; magic[0] = 0
        #expect(throws: (any Error).self) { try BeatMap(encoded: magic) }
        var version = data; version[4] = 2
        #expect(throws: (any Error).self) { try BeatMap(encoded: version) }
        // A beat after the end of the track.
        let late = BeatMap(algorithm: 1, durationMilliseconds: 1000, clarity: 0, tempos: [], beats: [.init(milliseconds: 2000, strength: 1, isDownbeat: false)])
        #expect(throws: (any Error).self) { try BeatMap(encoded: late.encoded()) }
    }

    @Test func beatLookup() throws {
        let map = Self.sample
        #expect(map.beat(at: 0.4) == nil)
        let first = try #require(map.beat(at: 0.5))
        #expect(first.index == 0 && first.phase == 0 && first.period == 0.5)
        let mid = try #require(map.beat(at: 1.25))
        #expect(mid.index == 1 && abs(mid.phase - 0.5) < 1e-9)
        #expect(map.beat(at: 199.999) == nil)
        #expect(map.beat(at: .nan) == nil)
    }
}
