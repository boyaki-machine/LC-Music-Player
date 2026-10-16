import Foundation
import Testing
@testable import AudioProcessingCore

private func tone(_ seconds: Double, rate: Double = 48000, amplitude: Double, channels: UInt32 = 2,
                  frequency: Double = 1000, phase: Double = 0, chunk: Int = 4096, invert: Bool = false) throws -> AudioLevelMetrics {
    let meter = try LoudnessMeter(profile: MeasurementProfile(sampleRate: rate, channels: channels))
    let total = Int(seconds * rate)
    var left = [Float](repeating: 0, count: chunk), right = left
    for start in stride(from: 0, to: total, by: chunk) {
        let count = min(chunk, total-start)
        for i in 0..<count {
            let n = start+i
            let taper = min(1, Double(n)/(0.01*rate), Double(total-1-n)/(0.01*rate))
            left[i] = Float(amplitude * sin(2 * .pi * frequency * Double(n)/rate + phase) * taper)
            right[i] = invert ? -left[i] : left[i]
        }
        try left.withUnsafeBufferPointer { l in
            try right.withUnsafeBufferPointer { r in
                try meter.consume(left: l.baseAddress!, right: channels == 2 ? r.baseAddress! : nil, frames: UInt32(count))
            }
        }
    }
    return try meter.finish()
}

@Suite(.serialized) struct LevelTests {
    @Test(arguments: [44100.0, 48000, 96000])
    func referenceToneAndChannelEnergy(rate: Double) throws {
        let stereo = try tone(2, rate: rate, amplitude: pow(10,-23.0/20))
        #expect(abs(try #require(stereo.loudness.value) + 23) < 0.1)
        let mono = try tone(2, rate: rate, amplitude: pow(10,-23.0/20), channels: 1)
        #expect(abs(try #require(mono.loudness.value) + 26.0103) < 0.1)
        let inverted = try tone(2, rate: rate, amplitude: pow(10,-23.0/20), invert: true)
        #expect(abs(try #require(inverted.loudness.value) - #require(stereo.loudness.value)) < 1e-6)
    }
    @Test func truePeakFindsInterSamplePeakAndChunkingIsInvariant() throws {
        let a = try tone(1, amplitude: 0.5, frequency: 12000, phase: .pi/4, chunk: 4096)
        let b = try tone(1, amplitude: 0.5, frequency: 12000, phase: .pi/4, chunk: 157)
        #expect(abs(a.truePeakDBTP + 6.0206) < 0.2)
        #expect(a.truePeak > a.samplePeak * 1.3)
        #expect(a == b)
    }
    @Test func silenceShortSignalsNonFiniteAndSpoolLimit() throws {
        #expect(try tone(0.2, amplitude: 0).loudness == .silent)
        #expect(try tone(0.2, amplitude: 0.1).loudness == .tooShort)
        #expect(try tone(1, amplitude: 1e-6).loudness == .belowGate)
        let profile = try MeasurementProfile(sampleRate: 48000, channels: 1)
        let meter = try LoudnessMeter(profile: profile)
        let nan: [Float] = [.nan]
        #expect(throws: (any Error).self) { try nan.withUnsafeBufferPointer { try meter.consume(left: $0.baseAddress!, right: nil, frames: 1) } }
        let capped = try LoudnessMeter(profile: profile, energyByteLimit: 8)
        let data = [Float](repeating: 0.1, count: 8192)
        #expect(throws: (any Error).self) {
            for _ in 0..<5 { try data.withUnsafeBufferPointer { try capped.consume(left: $0.baseAddress!, right: nil, frames: 8192) } }
        }
        let active = try LoudnessMeter(profile: profile)
        let before = try FileManager.default.contentsOfDirectory(atPath: LoudnessMeter.temporaryDirectory.path)
        LoudnessMeter.cleanAbandonedFiles()
        #expect(try FileManager.default.contentsOfDirectory(atPath: LoudnessMeter.temporaryDirectory.path).count == before.count)
        withExtendedLifetime(active) {}
    }
    @Test func gainConstraintsAndInvalidData() throws {
        let profile = try MeasurementProfile(sampleRate: 48000, channels: 2)
        func plan(_ l: IntegratedLoudness, _ p: Double) throws -> NormalizationPlan {
            try NormalizationPlan(metrics: .init(loudness: l, samplePeak: p, truePeak: p, frameCount: 48000, blockCount: 7), profile: profile)
        }
        #expect(try plan(.measured(-12),0.9).gainDB == -11)
        #expect(try plan(.measured(-40),0.01).gainDB == 6)
        #expect(try plan(.tooShort,1).gainDB == -1.5)
        #expect(try plan(.silent,0).gainDB == 0)
        #expect(throws: (any Error).self) { try plan(.measured(.nan),1) }
        #expect(throws: (any Error).self) { try plan(.silent,1) }
        #expect(throws: (any Error).self) { try NormalizationSettings(targetLUFS: .infinity) }
    }

    @Test func absoluteAndRelativeGatesExcludeSilenceAndQuietSections() throws {
        let profile = try MeasurementProfile(sampleRate: 48000, channels: 2)
        let meter = try LoudnessMeter(profile: profile)
        let samples = 4800
        // 2s below absolute gate, 2s above absolute but below relative gate,
        // 8s reference, 2s quiet: independent expected integrated value −23 LUFS.
        var data = [Float](repeating: 0, count: samples)
        for block in 0..<140 {
            let db: Double = block < 20 ? -80 : (block < 40 || block >= 120 ? -43 : -23)
            for n in 0..<samples { data[n] = Float(pow(10,db/20)*sin(2 * .pi * Double(n)*1000/48000)) }
            try data.withUnsafeBufferPointer { try meter.consume(left: $0.baseAddress!, right: $0.baseAddress!, frames: UInt32(samples)) }
        }
        let result = try meter.finish()
        #expect(abs(try #require(result.loudness.value) + 23) < 0.2)
        #expect(result.blockCount == 137)
    }
}
