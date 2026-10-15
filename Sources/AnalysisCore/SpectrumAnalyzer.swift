import Accelerate
import AnalysisTransport
import Foundation

/// Confined to the serial analysis worker. No audio engine or UI dependency.
public final class SpectrumAnalyzer {
    public let configuration: AnalysisConfiguration
    private let setup: FFTSetup
    private let logSize: vDSP_Length
    private let window: [Float]
    private let powerScale: Float
    private var real: [Float]
    private var imaginary: [Float]
    private var sanitized: [Float]
    private var magnitudes: [Float]
    private var cachedRate: Double = 0
    private var edges: [Double] = []
    private var ranges: [Range<Int>] = []

    public init(configuration: AnalysisConfiguration) throws {
        self.configuration = configuration
        logSize = vDSP_Length(configuration.fftSize.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2)) else {
            throw AnalysisError.allocationFailed
        }
        self.setup = setup
        let n = configuration.fftSize
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(n)) }
        // One-sided power factor 2 and channel average factor 1/2 cancel.
        powerScale = 1 / (Float(n) * window.reduce(0) { $0 + $1 * $1 })
        real = Array(repeating: 0, count: n)
        imaginary = Array(repeating: 0, count: n)
        sanitized = Array(repeating: 0, count: n)
        magnitudes = Array(repeating: 0, count: n / 2 + 1)
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    private func prepareBands(sampleRate: Double) {
        guard cachedRate != sampleRate else { return }
        cachedRate = sampleRate
        let n = configuration.fftSize
        let upper = min(20_000, sampleRate / 2)
        edges = (0...configuration.bandCount).map {
            20 * pow(upper / 20, Double($0) / Double(configuration.bandCount))
        }
        // Use exactly the same Hz comparisons at boundaries as the public edges.
        var bins = Array(repeating: [Int](), count: configuration.bandCount)
        var band = 0
        for bin in 1...n/2 {
            let hz = Double(bin) * sampleRate / Double(n)
            guard hz >= edges[0], hz <= upper else { continue }
            while band < bins.count - 1 && hz >= edges[band + 1] { band += 1 }
            bins[band].append(bin)
        }
        ranges = bins.map { values in
            guard let first = values.first, let last = values.last else { return 0..<0 }
            return first..<(last + 1)
        }
    }

    public func analyze(left: [Float], right: [Float], sampleRate: Double) ->
        (edges: [Double], db: [Float], levels: [Float], rms: [Float], peak: [Float])? {
        let n = configuration.fftSize
        guard left.count == n, right.count == n, sampleRate.isFinite, sampleRate >= 8000 else { return nil }
        prepareBands(sampleRate: sampleRate)
        var powers = Array(repeating: Float(0), count: configuration.bandCount)
        var rms: [Float] = [], peak: [Float] = []
        for samples in [left, right] {
            var channelRMS: Float = 0, channelPeak: Float = 0
            samples.withUnsafeBufferPointer { input in
                sanitized.withUnsafeMutableBufferPointer { clean in
                    lcmp_copy_finite(input.baseAddress!, clean.baseAddress!, UInt32(n))
                    vDSP_rmsqv(clean.baseAddress!, 1, &channelRMS, vDSP_Length(n))
                    vDSP_maxmgv(clean.baseAddress!, 1, &channelPeak, vDSP_Length(n))
                    var mean: Float = 0
                    vDSP_meanv(clean.baseAddress!, 1, &mean, vDSP_Length(n))
                    mean = -mean
                    vDSP_vsadd(clean.baseAddress!, 1, &mean, clean.baseAddress!, 1, vDSP_Length(n))
                    real.withUnsafeMutableBufferPointer { re in
                        window.withUnsafeBufferPointer { w in
                            vDSP_vmul(clean.baseAddress!, 1, w.baseAddress!, 1, re.baseAddress!, 1, vDSP_Length(n))
                        }
                    }
                }
            }
            rms.append(channelRMS); peak.append(channelPeak)
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    vDSP_vclr(im.baseAddress!, 1, vDSP_Length(n))
                    var complex = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_fft_zip(setup, &complex, 1, logSize, FFTDirection(FFT_FORWARD))
                    magnitudes.withUnsafeMutableBufferPointer { mag in
                        vDSP_zvmags(&complex, 1, mag.baseAddress!, 1, vDSP_Length(n / 2 + 1))
                        for band in ranges.indices {
                            let range = ranges[band]
                            guard !range.isEmpty else { continue }
                            var sum: Float = 0
                            vDSP_sve(mag.baseAddress! + range.lowerBound, 1, &sum, vDSP_Length(range.count))
                            // Nyquist is one-sided already; do not double its power.
                            if range.contains(n / 2) { sum -= mag[n / 2] / 2 }
                            powers[band] += sum * powerScale
                        }
                    }
                }
            }
        }
        let db = powers.map { max(-100, min(0, 10 * log10(max(1e-10, $0)))) }
        return (edges, db, db.map { ($0 + 100) / 100 }, rms, peak)
    }
}
