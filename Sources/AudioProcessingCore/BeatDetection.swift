import Accelerate
import Foundation

/// Finds the beats of a whole track from its PCM, fed in order and in chunks while the track is scanned
/// before playback. Detectors can be replaced without changing their callers or the cache: each names
/// itself in `algorithm`, which the cache keys, so a new detector or version measures tracks again.
public protocol BeatDetecting: AnyObject, SendableMetatype {
    /// The detector and its version. Raise it whenever a change can alter the maps it makes.
    static var algorithm: UInt16 { get }
    init(sampleRate: Double) throws
    /// Up to 8192 frames of float PCM. `right` is nil for mono.
    func consume(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) throws
    func finish() throws -> BeatMap
}

/// A detector to make for each scan, named by its algorithm.
public struct BeatDetector: Sendable {
    public let algorithm: UInt16
    private let make: @Sendable (Double) throws -> any BeatDetecting
    public init<D: BeatDetecting>(_ type: D.Type) { algorithm = D.algorithm; make = { try D(sampleRate: $0) } }
    public func callAsFunction(sampleRate: Double) throws -> any BeatDetecting { try make(sampleRate) }
    /// The detector the app uses.
    public static let standard = BeatDetector(OnsetBeatDetector.self)
}

/// Onset strength from a log-compressed filter bank, the tempo from its autocorrelation, and the beats
/// chosen over the whole track by dynamic programming (the beat tracker of D. P. W. Ellis, 2007), so
/// that each beat is placed with the beats before and after it in view.
///
/// The PCM is mixed to mono and averaged down to about 11kHz; a 512-point spectrum every 10ms gives
/// 24 bands from 30Hz to 5kHz. The memory kept grows with the track by a few floats per 10ms.
public final class OnsetBeatDetector: BeatDetecting {
    public static let algorithm: UInt16 = 1

    static let targetRate = 11025.0, windowSize = 512, bandCount = 24
    static let minBPM = 40.0, maxBPM = 240.0, preferredBPM = 120.0
    /// How strongly the dynamic programming keeps beats one period apart.
    static let tightness: Float = 100

    let sampleRate: Double
    let decimation: Int
    let rate: Double
    let hop: Int
    var framesPerSecond: Double { rate / Double(hop) }

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let bandRanges: [Range<Int>]
    private let lowBands: Int
    private var samples: [Float] = []
    private var sampleStart = 0
    private var decimator: Decimator
    private var mixed = [Float](repeating: 0, count: 8192)
    private var previousBands: [Float]?
    private var real: [Float], imag: [Float], frame: [Float], power: [Float], bands: [Float]
    /// Per analysis frame: onset strength over all bands and over the bass bands, and the frame's power in dB.
    private(set) var onset: [Float] = []
    private(set) var lowOnset: [Float] = []
    private(set) var level: [Float] = []
    private var totalFrames = 0

    public init(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 768_000 else { throw AudioProcessingFailure.unsupportedProfile }
        self.sampleRate = sampleRate
        decimation = max(1, Int((sampleRate / Self.targetRate).rounded()))
        rate = sampleRate / Double(decimation)
        hop = max(1, Int((rate / 100).rounded()))
        let n = Self.windowSize
        guard let fft = vDSP.FFT(log2n: vDSP_Length(n.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self) else {
            throw AudioProcessingFailure.unsupportedProfile
        }
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let upper = min(5000, rate * 0.45), lower = 30.0
        let edges = (0...Self.bandCount).map { lower * pow(upper / lower, Double($0) / Double(Self.bandCount)) }
        var ranges: [Range<Int>] = []
        for b in 0..<Self.bandCount {
            let first = max(1, Int((edges[b] * Double(n) / rate).rounded(.up)))
            let last = max(first + 1, Int((edges[b + 1] * Double(n) / rate).rounded(.up)))
            ranges.append(first..<min(last, n / 2))
        }
        bandRanges = ranges
        lowBands = edges.firstIndex { $0 >= 150 } ?? 1
        real = Array(repeating: 0, count: n / 2); imag = real
        frame = Array(repeating: 0, count: n); power = Array(repeating: 0, count: n / 2)
        bands = Array(repeating: 0, count: Self.bandCount)
        samples.reserveCapacity(n * 4)
        decimator = Decimator(factor: decimation)
    }

    public func consume(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) throws {
        guard frames >= 0, frames <= 8192 else { throw AudioProcessingFailure.invalidMeasurement }
        totalFrames += frames
        if let right {
            mixed.withUnsafeMutableBufferPointer { m in
                var half: Float = 0.5
                vDSP_vasm(left, 1, right, 1, &half, m.baseAddress!, 1, vDSP_Length(frames))
                decimator.push(m.baseAddress!, count: frames, into: &samples)
            }
        } else { decimator.push(left, count: frames, into: &samples) }
        while samples.count - sampleStart >= Self.windowSize {
            analyzeFrame(at: sampleStart)
            sampleStart += hop
        }
        if sampleStart > 8192 { samples.removeFirst(sampleStart); sampleStart = 0 }
    }

    private func analyzeFrame(at start: Int) {
        let n = Self.windowSize
        samples.withUnsafeBufferPointer { s in
            vDSP.multiply(UnsafeBufferPointer(rebasing: s[start..<start + n]), window, result: &frame)
        }
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                // The packed Nyquist term shares bin 0, which no band uses.
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // A full-scale sine gives a band magnitude of about 1 before compression.
        let scale = 1 / Float(n * n / 4)
        var total: Float = 0
        for b in 0..<Self.bandCount {
            var sum: Float = 0
            for k in bandRanges[b] { sum += power[k] }
            sum *= scale; total += sum
            bands[b] = log1p(1000 * sqrt(sum))
        }
        var all: Float = 0, low: Float = 0
        if let previous = previousBands {
            for b in 0..<Self.bandCount {
                let rise = max(0, bands[b] - previous[b])
                all += rise
                if b < lowBands { low += rise }
            }
        }
        previousBands = bands
        onset.append(all / Float(Self.bandCount)); lowOnset.append(low)
        level.append(10 * log10(total + 1e-12))
    }

    /// The time in seconds of analysis frame `index`. An onset raises the frame whose window it enters,
    /// shown at that window's first quarter; the tests pin this against clicks at known times.
    func seconds(ofFrame index: Double) -> Double {
        (index * Double(hop) + Double(Self.windowSize) * Self.onsetPosition) / rate
    }
    static let onsetPosition = 0.75

    public func finish() throws -> BeatMap {
        let duration = UInt32(clamping: Int((Double(totalFrames) / sampleRate * 1000).rounded()))
        let empty = BeatMap(algorithm: Self.algorithm, durationMilliseconds: duration, clarity: 0, tempos: [], beats: [])
        let count = onset.count, fps = framesPerSecond
        guard count >= Int(fps * 4), let loudest = level.max(), loudest > -70 else { return empty }

        // Remove the slowly changing part and scale to unit deviation.
        let o = normalized(highPassed(onset, width: Int(fps)))
        guard let (periods, periodicity) = localPeriods(o) else { return empty }
        let frames = track(o, periods: periods)
        // Leave out beats in silence before and after the music.
        let floor = loudest - 45
        let audible = frames.filter { f in
            let lo = max(0, f - Int(fps * 0.3)), hi = min(count, f + Int(fps * 0.3))
            return level[lo..<hi].contains { $0 > floor }
        }
        guard audible.count >= 4 else { return empty }

        // Strength relative to the strong beats of this track.
        func peak(_ f: Int) -> Float { max(0, o[max(0, f - 2)...min(count - 1, f + 2)].max() ?? 0) }
        var kept = audible
        var peaks = kept.map(peak)
        let reference = max(1e-6, percentile(peaks, 0.9))
        // The first and last beats need an onset of their own; the tracker carries on past the music.
        while let first = peaks.first, first < 0.3 * reference { kept.removeFirst(); peaks.removeFirst() }
        while let last = peaks.last, last < 0.3 * reference { kept.removeLast(); peaks.removeLast() }
        guard kept.count >= 4 else { return empty }
        // Clarity: how much more onset the beats collect than the points a quarter, half and three
        // quarters of the way to the next beat, measured the same way.
        var onBeat: Float = 0, offBeat: Float = 0
        for (i, f) in kept.enumerated().dropLast() {
            onBeat += peaks[i]
            let gap = Double(kept[i + 1] - f)
            for fraction in [0.25, 0.5, 0.75] { offBeat += peak(f + Int((gap * fraction).rounded())) / 3 }
        }
        let ratio = Double(onBeat / max(1e-6, offBeat))
        // Noise has neither, and its beats would stand out only because the tracker picks peaks.
        let clarity = min((ratio - 1.3) / 1.7, (periodicity - 0.05) / 0.25)
        let downbeat = downbeatPhase(kept)
        var beats: [BeatMap.Beat] = []
        for (i, f) in kept.enumerated() {
            let ms = UInt32(clamping: Int((seconds(ofFrame: Double(f)) * 1000).rounded()))
            let strength = UInt8(clamping: Int((127 * min(1, peaks[i] / reference)).rounded()))
            if ms <= duration { beats.append(BeatMap.Beat(milliseconds: ms, strength: strength, isDownbeat: i % 4 == downbeat)) }
        }
        return BeatMap(algorithm: Self.algorithm, durationMilliseconds: duration, clarity: clarity,
                       tempos: Self.segments(beats), beats: beats)
    }

    // MARK: Tempo

    /// The beat period in frames at every frame. Each 8-second window, every second, scores the periods
    /// by its autocorrelation with a prior around 120 BPM; a Viterbi path through the windows then
    /// chooses a tempo that changes only when the music clearly does, so that one window locking onto
    /// half or double the tempo does not move it.
    private func localPeriods(_ o: [Float]) -> (periods: [Double], periodicity: Double)? {
        let fps = framesPerSecond, count = o.count
        let minLag = max(1, Int((60 / Self.maxBPM * fps).rounded(.down))), maxLag = Int((60 / Self.minBPM * fps).rounded(.up))
        let width = min(count, Int(fps * 8)), step = Int(fps)
        guard width - maxLag > maxLag / 2 else { return nil }
        let lags = Array(minLag...maxLag)
        let prior = lags.map { Float(exp(-0.5 * pow(log2(60 * fps / Double($0) / Self.preferredBPM) / 0.9, 2))) }
        var centers: [Int] = [], scores: [[Float]] = []
        var ac = [Float](repeating: 0, count: maxLag + 2)
        // Without its mean, noise correlates near zero at every lag.
        let o = vDSP.add(-vDSP.mean(o), o)
        var start = 0
        repeat {
            let length = min(width, count - start) - maxLag - 1
            o.withUnsafeBufferPointer { p in
                let base = p.baseAddress! + start
                // C[k] = sum_j o[j + k] * o[j]
                vDSP_conv(base, 1, base, 1, &ac, 1, vDSP_Length(maxLag + 2), vDSP_Length(length))
            }
            let zero = max(ac[0], 1e-6)
            scores.append(lags.indices.map { max(0, ac[lags[$0]] / zero) * prior[$0] })
            centers.append(start + width / 2)
            start += step
        } while start + width <= count
        // Viterbi over the windows: a change of tempo costs in proportion to its square in octaves.
        let n = lags.count
        let logLag = lags.map { log2(Float($0)) }
        var total = scores[0]
        var back = [[Int32]](repeating: [Int32](repeating: 0, count: n), count: scores.count)
        var next = [Float](repeating: 0, count: n)
        for w in 1..<scores.count {
            for j in 0..<n {
                var best = -Float.infinity, arg = 0
                for i in 0..<n {
                    let d = logLag[i] - logLag[j]
                    let value = total[i] - Self.tempoChangeCost * d * d
                    if value > best { best = value; arg = i }
                }
                next[j] = best + scores[w][j]; back[w][j] = Int32(arg)
            }
            swap(&total, &next)
        }
        var state = total.indices.max { total[$0] < total[$1] } ?? 0
        var path = [Int](repeating: 0, count: scores.count)
        for w in stride(from: scores.count - 1, through: 0, by: -1) {
            path[w] = state
            if w > 0 { state = Int(back[w][state]) }
        }
        // Refine each window's lag between frames with a parabola through its neighbours.
        let refined = path.enumerated().map { w, j -> Double in
            guard j > 0, j < n - 1 else { return Double(lags[j]) }
            let a = Double(scores[w][j - 1]), b = Double(scores[w][j]), c = Double(scores[w][j + 1])
            let d = a - 2 * b + c
            return Double(lags[j]) + (abs(d) > 1e-12 ? min(0.5, max(-0.5, 0.5 * (a - c) / d)) : 0)
        }
        var periods = [Double](repeating: refined[0], count: count)
        var w = 0
        for f in 0..<count {
            while w + 1 < centers.count && abs(centers[w + 1] - f) <= abs(centers[w] - f) { w += 1 }
            periods[f] = refined[w]
        }
        // How strongly the onsets repeat at the chosen periods, without the prior: near 0 for noise.
        let periodicity = path.enumerated().reduce(0.0) { $0 + Double(scores[$1.offset][$1.element] / prior[$1.element]) } / Double(path.count)
        return (periods, periodicity)
    }
    static let tempoChangeCost: Float = 3

    // MARK: Beats

    /// Dynamic programming: the best score of a beat at each frame is its onset strength plus the best
    /// earlier beat, penalised by how far the gap is from the local period.
    private func track(_ o: [Float], periods: [Double]) -> [Int] {
        let count = o.count
        var score = [Float](repeating: 0, count: count)
        var back = [Int](repeating: -1, count: count)
        for t in 0..<count {
            let p = periods[t]
            let from = max(0, t - Int((2 * p).rounded())), to = t - Int((p / 2).rounded())
            var best = -Float.infinity, arg = -1
            if to >= from {
                for tau in from...to {
                    let x = Float(log(Double(t - tau) / p))
                    let value = score[tau] - Self.tightness * x * x
                    if value > best { best = value; arg = tau }
                }
            }
            if arg >= 0 && best > 0 { score[t] = o[t] + best; back[t] = arg } else { score[t] = o[t] }
        }
        // End on the best-scoring frame within the last period.
        let tail = max(0, count - Int(periods[count - 1].rounded()) - 1)
        var t = (tail..<count).max { score[$0] < score[$1] } ?? count - 1
        var beats: [Int] = []
        while t >= 0 { beats.append(t); t = back[t] }
        return beats.reversed()
    }

    /// Which of every four beats falls on the bar's first beat: the one where the bass rises most.
    private func downbeatPhase(_ beats: [Int]) -> Int {
        var sums = [Float](repeating: 0, count: 4)
        for (i, f) in beats.enumerated() {
            sums[i % 4] += lowOnset[max(0, f - 2)...min(lowOnset.count - 1, f + 2)].max() ?? 0
        }
        return sums.indices.max { sums[$0] < sums[$1] } ?? 0
    }

    /// Runs of steady tempo: a new segment begins where the median of the surrounding beat intervals
    /// moves more than 4% from the current one; segments shorter than eight beats join the one before.
    static func segments(_ beats: [BeatMap.Beat]) -> [BeatMap.TempoSegment] {
        guard beats.count >= 2 else { return [] }
        let intervals = zip(beats.dropFirst(), beats).map { Double($0.milliseconds - $1.milliseconds) }
        let local = intervals.indices.map { i -> Double in
            let part = intervals[max(0, i - 4)...min(intervals.count - 1, i + 4)].sorted()
            return part[part.count / 2]
        }
        var starts = [0]
        var current = local[0]
        for i in local.indices where abs(local[i] - current) / current > 0.04 {
            if i - starts.last! >= 8 { starts.append(i) } else if starts.count == 1 { starts[0] = 0 }
            current = local[i]
        }
        return starts.indices.map { s in
            let lo = starts[s], hi = s + 1 < starts.count ? starts[s + 1] : intervals.count
            let mean = intervals[lo..<hi].reduce(0, +) / Double(hi - lo)
            return BeatMap.TempoSegment(startMilliseconds: beats[lo].milliseconds, bpm: 60_000 / mean)
        }
    }

    // MARK: Helpers

    private func highPassed(_ x: [Float], width: Int) -> [Float] {
        guard width > 1, x.count > width else { return x }
        var prefix = [Float](repeating: 0, count: x.count + 1)
        for i in x.indices { prefix[i + 1] = prefix[i] + x[i] }
        return x.indices.map { i in
            let lo = max(0, i - width / 2), hi = min(x.count, i + width / 2 + 1)
            return max(0, x[i] - (prefix[hi] - prefix[lo]) / Float(hi - lo))
        }
    }

    private func normalized(_ x: [Float]) -> [Float] {
        let mean = vDSP.mean(x)
        let deviation = sqrt(vDSP.meanSquare(vDSP.add(-mean, x)))
        return deviation > 1e-9 ? vDSP.divide(x, deviation) : x
    }

    private func percentile(_ x: [Float], _ q: Double) -> Float {
        guard !x.isEmpty else { return 0 }
        let sorted = x.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
    }
}
