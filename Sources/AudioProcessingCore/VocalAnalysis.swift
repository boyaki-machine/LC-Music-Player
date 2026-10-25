import Accelerate
import Foundation

/// Follows the lead vocal of a whole track from its PCM, fed in order and in chunks while the track is
/// scanned before playback. Like `BeatDetecting`, an analyzer names itself in `algorithm`, which the
/// cache keys.
public protocol VocalAnalyzing: AnyObject, SendableMetatype {
    static var algorithm: UInt16 { get }
    init(sampleRate: Double) throws
    /// Up to 8192 frames of float PCM. `right` is nil for mono, which has no centre to single out.
    func consume(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) throws
    func finish() throws -> VocalMap
}

/// An analyzer to make for each scan, named by its algorithm.
public struct VocalAnalyzer: Sendable {
    public let algorithm: UInt16
    private let make: @Sendable (Double) throws -> any VocalAnalyzing
    public init<A: VocalAnalyzing>(_ type: A.Type) { algorithm = A.algorithm; make = { try A(sampleRate: $0) } }
    public func callAsFunction(sampleRate: Double) throws -> any VocalAnalyzing { try make(sampleRate) }
    /// The analyzer the app uses.
    public static let standard = VocalAnalyzer(CentreVocalAnalyzer.self)
}

/// The lead vocal from the centre of the stereo image, where most mixes put it: the spectrum of the
/// mid signal less that of the side signal. Every 20ms, on audio averaged down to about 11kHz:
///
/// - the note, from a harmonic sum over 98Hz–1kHz, and how strongly the frame is pitched;
/// - a second note at a consonant interval once the first note's harmonics are taken out (a harmony);
/// - the level of the centre from 150Hz to 4kHz, its spectral flatness (a shout is loud and rough),
///   and how much of it lies in the band of open vowels.
///
/// At the end, phrases are where the centre is pitched and loud enough relative to the track; the mouth
/// follows the level and vowel within phrases, and long tones, high tones, shouts and harmonies are
/// runs of frames that keep their condition long enough.
public final class CentreVocalAnalyzer: VocalAnalyzing {
    public static let algorithm: UInt16 = 2

    static let windowSize = 1024
    static let frameSeconds = 0.02
    /// Candidate notes (MIDI) in steps of a third of a semitone.
    static let lowestNote = 43.0, highestNote = 84.0, noteStep = 1.0 / 3
    static let harmonics = 8, harmonicWeight: Float = 0.8

    let sampleRate: Double
    let rate: Double
    let hop: Int
    private var leftDecimator: Decimator, rightDecimator: Decimator
    private var left: [Float] = [], right: [Float] = []
    private var start = 0
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let binHz: Double
    private let candidates: [Double]
    /// For each candidate, its harmonics' lower bins, interpolation fractions and weights, flattened.
    private let harmonicBins: [Int32], harmonicFractions: [Float], harmonicWeights: [Float]
    private let weightSum: Float
    private var lr = [Float](repeating: 0, count: 512), li = [Float](repeating: 0, count: 512)
    private var rr = [Float](repeating: 0, count: 512), ri = [Float](repeating: 0, count: 512)
    private var windowed = [Float](repeating: 0, count: 1024)
    private var mr = [Float](repeating: 0, count: 512), mi = [Float](repeating: 0, count: 512)
    private var sr = [Float](repeating: 0, count: 512), si = [Float](repeating: 0, count: 512)
    private var midMagnitude = [Float](repeating: 0, count: 512), sideMagnitude = [Float](repeating: 0, count: 512)
    private var centre = [Float](repeating: 0, count: 512)
    private var compressed = [Float](repeating: 0, count: 512)
    private var power = [Float](repeating: 0, count: 512), logs = [Float](repeating: 0, count: 512)
    private var totalFrames = 0

    struct Frame {
        var level: Float
        var voicing: Float
        /// MIDI note, 0 when unpitched.
        var note: Float
        var open: Float
        var flatness: Float
        var harmony: Bool
    }
    private(set) var frames: [Frame] = []

    public init(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 768_000 else { throw AudioProcessingFailure.unsupportedProfile }
        self.sampleRate = sampleRate
        let decimation = max(1, Int((sampleRate / OnsetBeatDetector.targetRate).rounded()))
        rate = sampleRate / Double(decimation)
        hop = max(1, Int((rate * Self.frameSeconds).rounded()))
        leftDecimator = Decimator(factor: decimation); rightDecimator = Decimator(factor: decimation)
        let n = Self.windowSize
        guard let fft = vDSP.FFT(log2n: vDSP_Length(n.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self) else {
            throw AudioProcessingFailure.unsupportedProfile
        }
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        binHz = rate / Double(n)
        candidates = Array(stride(from: Self.lowestNote, through: Self.highestNote, by: Self.noteStep))
        weightSum = (0..<Self.harmonics).reduce(0) { $0 + pow(Self.harmonicWeight, Float($1)) }
        var bins: [Int32] = [], fractions: [Float] = [], weights: [Float] = []
        for candidate in candidates {
            let f0 = 440 * pow(2, (candidate - 69) / 12)
            var weight: Float = 1
            for h in 1...Self.harmonics {
                let position = Double(h) * f0 / binHz
                let k = Int(position)
                // Harmonics past the spectrum weigh nothing.
                let inside = k + 1 < n / 2
                bins.append(Int32(inside ? k : 0)); fractions.append(Float(position - Double(k))); weights.append(inside ? weight : 0)
                weight *= Self.harmonicWeight
            }
        }
        harmonicBins = bins; harmonicFractions = fractions; harmonicWeights = weights
    }

    public func consume(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>?, frames count: Int) throws {
        guard count >= 0, count <= 8192 else { throw AudioProcessingFailure.invalidMeasurement }
        totalFrames += count
        leftDecimator.push(l, count: count, into: &left)
        rightDecimator.push(r ?? l, count: count, into: &right)
        while left.count - start >= Self.windowSize && right.count - start >= Self.windowSize {
            analyzeFrame(at: start)
            start += hop
        }
        if start > 8192 { left.removeFirst(start); right.removeFirst(start); start = 0 }
    }

    private func transform(_ samples: [Float], at offset: Int, real: inout [Float], imag: inout [Float]) {
        let n = Self.windowSize
        samples.withUnsafeBufferPointer { s in vDSP.multiply(UnsafeBufferPointer(rebasing: s[offset..<offset + n]), window, result: &windowed) }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                fft.forward(input: split, output: &split)
                // Bin 0 holds the DC and Nyquist terms, which nothing here uses.
                re[0] = 0; im[0] = 0
            }
        }
    }

    private func analyzeFrame(at offset: Int) {
        let half = Self.windowSize / 2
        transform(left, at: offset, real: &lr, imag: &li)
        transform(right, at: offset, real: &rr, imag: &ri)
        // Centre = |mid| - |side| (both halved, so the sums and differences of the channels are used
        // as they are and the factor goes into the scale); a mono track is all centre.
        let scale = 1 / Float(Self.windowSize)
        vDSP.add(lr, rr, result: &mr); vDSP.add(li, ri, result: &mi)
        vDSP.subtract(lr, rr, result: &sr); vDSP.subtract(li, ri, result: &si)
        mr.withUnsafeMutableBufferPointer { re in mi.withUnsafeMutableBufferPointer { im in
            vDSP.absolute(DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!), result: &midMagnitude)
        } }
        sr.withUnsafeMutableBufferPointer { re in si.withUnsafeMutableBufferPointer { im in
            vDSP.absolute(DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!), result: &sideMagnitude)
        } }
        vDSP.subtract(midMagnitude, sideMagnitude, result: &centre)
        vDSP.clip(centre, to: 0...Float.greatestFiniteMagnitude, result: &centre)
        vDSP.multiply(scale, centre, result: &centre)
        vForce.sqrt(centre, result: &compressed)
        vDSP.square(centre, result: &power)
        func bins(_ lo: Double, _ hi: Double) -> Range<Int> { max(1, Int(lo / binHz))..<min(half, Int(hi / binHz)) }
        func energy(_ lo: Double, _ hi: Double) -> Float { vDSP.sum(power[bins(lo, hi)]) }
        let level = 10 * log10(energy(150, 4000) + 1e-12)
        let low = energy(150, 450), open = energy(450, 1100)
        // Flatness from 300Hz to 4kHz: the geometric over the arithmetic mean of the power.
        let band = bins(300, 4000)
        let flatness: Float
        if band.isEmpty { flatness = 1 } else {
            vDSP.add(1e-12, power[band], result: &logs[0..<band.count])
            vForce.log(logs[0..<band.count], result: &logs[0..<band.count])
            flatness = exp(vDSP.mean(logs[0..<band.count])) / (vDSP.mean(power[band]) + 1e-12)
        }
        let meanCompressed = vDSP.mean(compressed[bins(80, 4000)])
        let first = bestNote(excluding: nil)
        var frame = Frame(level: level, voicing: 0, note: 0, open: open / max(1e-12, low + open), flatness: flatness, harmony: false)
        if meanCompressed > 1e-7, let first {
            frame.voicing = first.salience / (weightSum * meanCompressed)
            frame.note = Float(first.note)
            // Take the first note's harmonics out and look for a second voice, only where a voice sings.
            guard frame.voicing >= Self.voicedThreshold else { frames.append(frame); return }
            let f0 = 440 * pow(2, (first.note - 69) / 12)
            for h in 1...12 {
                let bin = Int((Double(h) * f0 / binHz).rounded())
                guard bin + 1 < half else { break }
                for k in max(0, bin - 1)...(bin + 1) { compressed[k] = 0 }
            }
            if let second = bestNote(excluding: first.note) {
                let voicing = second.salience / (weightSum * meanCompressed)
                let interval = Int((abs(second.note - first.note)).rounded()) % 12
                frame.harmony = voicing >= max(2, 0.6 * frame.voicing) && [3, 4, 5, 7, 8, 9].contains(interval)
            }
        }
        frames.append(frame)
    }

    /// The candidate note whose harmonics carry the most of the compressed centre spectrum.
    private func bestNote(excluding note: Double?) -> (note: Double, salience: Float)? {
        var best: (Double, Float)?
        let h = Self.harmonics
        compressed.withUnsafeBufferPointer { c in
            harmonicBins.withUnsafeBufferPointer { bins in
                harmonicFractions.withUnsafeBufferPointer { fractions in
                    harmonicWeights.withUnsafeBufferPointer { weights in
                        for (index, candidate) in candidates.enumerated() {
                            if let note {
                                let d = abs(candidate - note)
                                if d < 0.7 || abs(d - 12) < 0.7 || abs(d - 24) < 0.7 { continue }
                            }
                            var salience: Float = 0
                            for j in index * h..<(index + 1) * h {
                                let k = Int(bins[j]), f = fractions[j]
                                salience += weights[j] * (c[k] * (1 - f) + c[k + 1] * f)
                            }
                            if salience > (best?.1 ?? 0) { best = (candidate, salience) }
                        }
                    }
                }
            }
        }
        return best
    }

    // MARK: Summary

    static let voicedThreshold: Float = 2.2
    static let levelRange: Float = 28
    static let mouthMilliseconds: UInt16 = 40

    public func finish() throws -> VocalMap {
        let duration = UInt32(clamping: Int((Double(totalFrames) / sampleRate * 1000).rounded()))
        let frameMs = Double(hop) / rate * 1000
        func ms(_ frame: Int) -> UInt32 { UInt32(clamping: Int((Double(frame) * frameMs + Double(Self.windowSize) / 2 / rate * 1000).rounded())) }
        let count = frames.count
        let mouthCount = Int(Double(duration) / Double(Self.mouthMilliseconds))
        let empty = VocalMap(algorithm: Self.algorithm, durationMilliseconds: duration, register: .unknown, medianNote: 0,
                             frameMilliseconds: Self.mouthMilliseconds, mouth: Array(repeating: 0, count: mouthCount),
                             notes: Array(repeating: 0, count: mouthCount / 2), events: [])
        guard count > 10 else { return empty }
        let reference = percentile(frames.map(\.level).filter { $0 > -100 }, 0.95)
        guard reference > -70 else { return empty }

        // Voiced frames, then a median over five frames so single frames neither start nor break a phrase.
        let raw = frames.map { $0.voicing >= Self.voicedThreshold && $0.level >= reference - Self.levelRange }
        let voiced = raw.indices.map { i in raw[max(0, i - 2)...min(count - 1, i + 2)].filter { $0 }.count >= 3 }
        let fps = 1 / Self.frameSeconds
        // Shouts: as loud as the track gets, rough, and still a little pitched. The noise in them lowers
        // how pitched they are, so they belong to the phrases without being voiced.
        let loud = frames.map { $0.level >= reference - Self.levelRange }
        let rough = max(0.25, percentile(frames.indices.filter { loud[$0] }.map { frames[$0].flatness }, 0.85))
        let shouting = frames.map { $0.level >= reference - 6 && $0.flatness >= rough && $0.voicing >= 1.0 }
        let phrases = runs(voiced.indices.map { voiced[$0] || shouting[$0] }, joiningGaps: Int(0.25 * fps), minimum: Int(0.3 * fps))
        var inPhrase = [Bool](repeating: false, count: count)
        for p in phrases { for i in p { inPhrase[i] = true } }

        // The mouth: level and vowel within phrases, a little open on unvoiced sounds inside them.
        var mouth = [UInt8](repeating: 0, count: mouthCount)
        for m in 0..<mouthCount {
            let centre = (Double(m) * Double(Self.mouthMilliseconds) - Double(Self.windowSize) / 2 / rate * 1000) / frameMs
            let i = Int(centre.rounded())
            guard i >= 0, i < count, inPhrase[i] else { continue }
            let f = frames[i]
            var value = min(1, max(0, (f.level - (reference - 30)) / 27)) * (0.55 + 0.45 * f.open)
            if !voiced[i] && !shouting[i] { value *= 0.3 }
            mouth[m] = UInt8((value * 15).rounded())
        }
        // Notes every two mouth entries: the median of the voiced frames there.
        let noteFrames = max(1, Int((2 * Double(Self.mouthMilliseconds) / frameMs).rounded()))
        var notes = [UInt8](repeating: 0, count: mouthCount / 2)
        for n in notes.indices {
            let first = Int((Double(n) * 2 * Double(Self.mouthMilliseconds) - Double(Self.windowSize) / 2 / rate * 1000) / frameMs)
            let lower = min(count, max(0, first))
            let values = (lower..<min(count, lower + noteFrames)).filter { voiced[$0] && inPhrase[$0] }.map { frames[$0].note }
            if !values.isEmpty { notes[n] = UInt8(min(127, max(1, values.sorted()[values.count / 2].rounded()))) }
        }

        let sung = frames.indices.filter { voiced[$0] && inPhrase[$0] }.map { frames[$0].note }
        let median = sung.isEmpty ? 0 : sung.sorted()[sung.count / 2]
        let register: VocalMap.Register = sung.count < Int(5 * fps) ? .unknown : median < 53 ? .low : median > 57 ? .high : .unknown

        var events: [VocalMap.Event] = []
        func add(_ kind: VocalMap.Event.Kind, _ run: Range<Int>, strength: Float) {
            let start = ms(run.lowerBound), end = min(duration, ms(run.upperBound))
            guard end > start else { return }
            events.append(.init(kind: kind, startMilliseconds: start, durationMilliseconds: end - start,
                                strength: UInt8(clamping: Int((min(1, max(0, strength)) * 127).rounded()))))
        }
        func loudness(_ run: Range<Int>) -> Float { ((run.map { frames[$0].level }.max() ?? -100) - (reference - 30)) / 30 }
        for p in phrases { add(.phrase, p, strength: loudness(p)) }
        // Long tones: one note held for 0.6s or more, within 0.8 semitone (vibrato included) of where it settled.
        var i = 0
        while i < count {
            guard voiced[i], inPhrase[i] else { i += 1; continue }
            let settle = (i..<min(count, i + 5)).filter { voiced[$0] }.map { frames[$0].note }.sorted()
            let anchor = settle[settle.count / 2]
            var end = i
            while end < count, voiced[end], inPhrase[end], abs(frames[end].note - anchor) <= 0.8 { end += 1 }
            if end - i >= Int(0.6 * fps) { add(.longTone, i..<end, strength: loudness(i..<end)) }
            i = max(i + 1, end)
        }
        // High tones: well above this vocal's usual notes.
        if !sung.isEmpty {
            let high = max(percentile(sung, 0.8), median + 4)
            let isHigh = frames.indices.map { voiced[$0] && inPhrase[$0] && frames[$0].note >= high }
            for r in runs(isHigh, joiningGaps: Int(0.1 * fps), minimum: Int(0.2 * fps)) {
                add(.highTone, r, strength: (r.map { frames[$0].note }.max()! - median) / 12)
            }
        }
        for r in runs(shouting.indices.map { shouting[$0] && inPhrase[$0] }, joiningGaps: Int(0.1 * fps), minimum: Int(0.2 * fps)) {
            add(.shout, r, strength: loudness(r))
        }
        // Harmonies: half the frames of half a second carry a second voice.
        let harmonyWindow = Int(0.5 * fps)
        var harmonyCount = 0
        var isHarmony = [Bool](repeating: false, count: count)
        for i in 0..<count {
            if frames[i].harmony && inPhrase[i] { harmonyCount += 1 }
            if i >= harmonyWindow, frames[i - harmonyWindow].harmony && inPhrase[i - harmonyWindow] { harmonyCount -= 1 }
            isHarmony[i] = harmonyCount * 2 >= harmonyWindow
        }
        for r in runs(isHarmony, joiningGaps: Int(0.25 * fps), minimum: harmonyWindow) {
            add(.harmony, r.lowerBound >= harmonyWindow / 2 ? (r.lowerBound - harmonyWindow / 2)..<(r.upperBound - harmonyWindow / 2) : r,
                strength: Float(r.filter { frames[$0].harmony }.count) / Float(r.count))
        }
        events.sort { ($0.startMilliseconds, $0.kind.rawValue) < ($1.startMilliseconds, $1.kind.rawValue) }
        return VocalMap(algorithm: Self.algorithm, durationMilliseconds: duration, register: register,
                        medianNote: UInt8(min(127, max(0, median.rounded()))), frameMilliseconds: Self.mouthMilliseconds,
                        mouth: mouth, notes: notes, events: events)
    }

    /// Runs of true, with gaps of up to `joiningGaps` frames closed and runs shorter than `minimum` left out.
    private func runs(_ flags: [Bool], joiningGaps gap: Int, minimum: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var i = 0
        while i < flags.count {
            guard flags[i] else { i += 1; continue }
            var end = i
            while end < flags.count && flags[end] { end += 1 }
            if let last = result.last, i - last.upperBound <= gap { result[result.count - 1] = last.lowerBound..<end }
            else { result.append(i..<end) }
            i = end
        }
        return result.filter { $0.count >= max(1, minimum) }
    }

    private func percentile(_ x: [Float], _ q: Double) -> Float {
        guard !x.isEmpty else { return -100 }
        let sorted = x.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
    }
}
