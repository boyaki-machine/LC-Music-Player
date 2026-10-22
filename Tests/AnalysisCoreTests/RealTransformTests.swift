import Accelerate
import Foundation
import Testing
@testable import AnalysisCore

/// The real transform gives the band powers of a full complex transform of the same window.
@Suite struct RealTransformTests {
    /// Band powers in dBFS from a complex transform with a zero imaginary part, as the analyzer did before.
    private func complexReference(_ left: [Float], _ right: [Float], configuration: AnalysisConfiguration,
                                  edges: [Double], rate: Double) -> [Float] {
        let n = configuration.fftSize, log = vDSP_Length(n.trailingZeroBitCount)
        let setup = vDSP_create_fftsetup(log, FFTRadix(kFFTRadix2))!; defer { vDSP_destroy_fftsetup(setup) }
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(n)) }
        let scale = 1 / (Float(n) * window.reduce(0) { $0 + $1 * $1 })
        var powers = [Float](repeating: 0, count: configuration.bandCount)
        for samples in [left, right] {
            let mean = samples.reduce(0, +) / Float(n)
            var re = zip(samples, window).map { ($0 - mean) * $1 }, im = [Float](repeating: 0, count: n)
            var mag = [Float](repeating: 0, count: n / 2 + 1)
            re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
                var c = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &c, 1, log, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&c, 1, &mag, 1, vDSP_Length(n / 2 + 1))
            } }
            for bin in 1...n / 2 {
                let hz = Double(bin) * rate / Double(n)
                guard hz >= edges[0], hz <= min(20_000, rate / 2) else { continue }
                var band = 0
                while band < powers.count - 1 && hz >= edges[band + 1] { band += 1 }
                powers[band] += (bin == n / 2 ? mag[bin] / 2 : mag[bin]) * scale
            }
        }
        return powers.map { max(-100, min(0, 10 * log10(max(1e-10, $0)))) }
    }

    @Test(arguments: [44100.0, 48000, 96000])
    func bandPowersMatchTheComplexTransform(_ rate: Double) throws {
        let configuration = try AnalysisConfiguration()
        let analyzer = try SpectrumAnalyzer(configuration: configuration)
        let n = configuration.fftSize
        var seed: UInt64 = 7
        func noise() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23) }
        let left = (0..<n).map { i in 0.3 * Float(sin(2 * .pi * 997 * Double(i) / rate)) + 0.05 * Float(sin(2 * .pi * 61 * Double(i) / rate)) + 0.01 * noise() }
        let right = (0..<n).map { i in 0.2 * Float(sin(2 * .pi * 7919 * Double(i) / rate)) + 0.02 * noise() + (i == n / 2 ? 0.5 : 0) }
        let result = try #require(analyzer.analyze(left: left, right: right, sampleRate: rate))
        let reference = complexReference(left, right, configuration: configuration, edges: result.edges, rate: rate)
        for (band, (db, expected)) in zip(result.db, reference).enumerated() {
            #expect(abs(db - expected) < 0.01, "band \(band): \(db) / \(expected)")
        }
        #expect(result.db.contains { $0 > -40 })
    }
}
