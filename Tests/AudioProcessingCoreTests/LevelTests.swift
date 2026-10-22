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
    @Test(arguments: MeasurementProfile.sampleRates)
    func referenceToneAndChannelEnergy(rate: Double) throws {
        let stereo = try tone(2, rate: rate, amplitude: pow(10,-23.0/20))
        #expect(abs(try #require(stereo.loudness.value) + 23) < 0.1)
        let mono = try tone(2, rate: rate, amplitude: pow(10,-23.0/20), channels: 1)
        #expect(abs(try #require(mono.loudness.value) + 26.0103) < 0.1)
        let inverted = try tone(2, rate: rate, amplitude: pow(10,-23.0/20), invert: true)
        #expect(abs(try #require(inverted.loudness.value) - #require(stereo.loudness.value)) < 1e-6)
    }
    @Test func profilesFollowTheListedOutputRates() throws {
        #expect(MeasurementProfile.sampleRates == [44100, 48000, 88200, 96000, 176400, 192000])
        for rate in MeasurementProfile.sampleRates { #expect(try MeasurementProfile(sampleRate: rate, channels: 2).sampleRate == rate) }
        for rate in [32000.0, 22050, 44100.5, 352800, 384000, 0, .nan] {
            #expect(throws: AudioProcessingFailure.unsupportedProfile) { try MeasurementProfile(sampleRate: rate, channels: 2) }
        }
    }
    /// BS.1770 gives the K-weighting as coefficients at 48kHz; every rate keeps that response.
    /// The high-pass's unnormalized numerator, as in the standard, passes 48kHz +0.043dB and 192kHz
    /// +0.011dB, so a rate shifts all frequencies alike by up to 0.032dB (inside EBU Tech 3341's 0.1LU).
    @Test(arguments: MeasurementProfile.sampleRates)
    func kWeightingFollowsTheReferenceRate(rate: Double) throws {
        let frequencies = [20.0, 100, 1000, 5000, 10000, 20000]
        let reference = try frequencies.map { try #require(tone(3, amplitude: 0.1, channels: 1, frequency: $0).loudness.value) }
        let measured = try frequencies.map { try #require(tone(3, rate: rate, amplitude: 0.1, channels: 1, frequency: $0).loudness.value) }
        let shift = measured[2] - reference[2]
        #expect(abs(shift) < 0.04)
        for (m, r) in zip(measured, reference) { #expect(abs(m - r - shift) < 0.02, "\(rate)Hz: \(m) against \(r)") }
    }
    /// Inter-sample peaks within EBU Tech 3341's +0.2/-0.4dB, at a quarter of the rate and near Nyquist.
    @Test(arguments: MeasurementProfile.sampleRates)
    func truePeakAtEveryRate(rate: Double) throws {
        for (frequency, phase) in [(rate / 4, Double.pi / 4), (rate * 0.45, 0.5)] {
            let a = try tone(1, rate: rate, amplitude: 0.5, frequency: frequency, phase: phase, chunk: 4096)
            let b = try tone(1, rate: rate, amplitude: 0.5, frequency: frequency, phase: phase, chunk: 157)
            #expect((-0.4...0.2).contains(a.truePeakDBTP + 6.0206), "\(rate)Hz, \(frequency)Hz: \(a.truePeakDBTP)")
            #expect(a == b)
            if frequency == rate / 4 { #expect(a.truePeak > a.samplePeak * 1.3) }
        }
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
        // The energies stay in memory: measuring writes no file.
        let directory = LoudnessMeter.temporaryDirectory
        let before = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let measuring = try LoudnessMeter(profile: profile)
        for _ in 0..<12 { try data.withUnsafeBufferPointer { try measuring.consume(left: $0.baseAddress!, right: nil, frames: 8192) } }
        _ = try measuring.finish()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count <= before.count)
        // A spool an earlier version left behind is removed; one another process still holds stays.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let abandoned = directory.appendingPathComponent(UUID().uuidString + ".energy")
        let held = directory.appendingPathComponent(UUID().uuidString + ".energy")
        try Data([0]).write(to: abandoned); try Data([0]).write(to: held)
        let handle = open(held.path, O_RDWR); defer { close(handle); unlink(held.path) }
        #expect(flock(handle, LOCK_EX | LOCK_NB) == 0)
        LoudnessMeter.cleanAbandonedFiles()
        #expect(!FileManager.default.fileExists(atPath: abandoned.path) && FileManager.default.fileExists(atPath: held.path))
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
