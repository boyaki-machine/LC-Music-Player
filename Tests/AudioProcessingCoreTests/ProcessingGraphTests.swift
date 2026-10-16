import AVFAudio
import Foundation
import Testing
import PreprocessingCore
@testable import AudioProcessingCore

@MainActor private func render(_ input: AVAudioPCMBuffer, profile: MeasurementProfile,
                               plan: NormalizationPlan?, volume: Float = 1) throws -> [[Float]] {
    let engine = AVAudioEngine(), source = AVAudioPlayerNode(), converter = AVAudioMixerNode()
    let observation = AVAudioUnitEQ(numberOfBands: 0), chain = AudioProcessingChain(plan: plan)
    for node in [source, converter, observation, chain.levelNode] as [AVAudioNode] { engine.attach(node) }
    engine.connect(source, to: converter, format: input.format)
    engine.connect(converter, to: observation, format: profile.format)
    engine.connect(observation, to: chain.levelNode, format: profile.format)
    engine.connect(chain.levelNode, to: engine.mainMixerNode, format: profile.format)
    engine.mainMixerNode.outputVolume = volume
    try engine.enableManualRenderingMode(.offline, format: profile.format, maximumFrameCount: 1024)
    source.scheduleBuffer(input)
    try engine.start(); defer { engine.stop() }
    source.play()
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: profile.format, frameCapacity: 1024))
    let count = Int(Double(input.frameLength) / input.format.sampleRate * profile.sampleRate)
    var result = Array(repeating: [Float](), count: Int(profile.channels))
    var frames = 0, retries = 0
    while frames < count {
        let requested = UInt32(min(1024, count-frames))
        let status = try engine.renderOffline(requested, to: buffer)
        if status == .cannotDoInCurrentContext { retries += 1; #expect(retries < 20); if retries >= 20 { break }; continue }
        #expect(status == .success)
        guard status == .success else { break }
        for ch in result.indices { result[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(requested))) }
        frames += Int(requested)
    }
    return result
}
private func measure(_ samples: [[Float]], profile: MeasurementProfile) throws -> AudioLevelMetrics {
    let meter = try LoudnessMeter(profile: profile)
    for start in stride(from: 0, to: samples[0].count, by: 4096) {
        let count = min(4096, samples[0].count-start)
        try samples[0].withUnsafeBufferPointer { l in
            if samples.count == 1 { try meter.consume(left: l.baseAddress!+start, right: nil, frames: UInt32(count)) }
            else { try samples[1].withUnsafeBufferPointer { try meter.consume(left: l.baseAddress!+start, right: $0.baseAddress!+start, frames: UInt32(count)) } }
        }
    }
    return try meter.finish()
}
@Suite(.serialized) @MainActor struct ProcessingGraphTests {
    @Test(arguments: [44100.0, 48000, 96000], [44100.0, 48000, 96000])
    func measuredProfileMatchesMixerAndGainIsTransparent(rate: Double, outputRate: Double) async throws {
        let profile = try MeasurementProfile(sampleRate: outputRate, channels: 2)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate*2)))
        buffer.frameLength = buffer.frameCapacity
        for n in 0..<Int(buffer.frameLength) {
            let t = Double(n)/rate
            buffer.floatChannelData![0][n] = Float(0.3*sin(2 * .pi * 997*t) + 0.08*sin(2 * .pi * 11700*t))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-graph-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let metrics = try await AudioPreprocessor.shared.measureLevels(url, profile: profile)
        // SFB receives ProfileDecoder PCM; the mixer no longer chooses an implicit mono map.
        let source = try AudioDecoderFactory.open(url)
        let decoder = try ProfileDecoder(base: source, profile: profile, frameLength: metrics.levels.frameCount)
        defer { try? decoder.close() }
        let prepared = try #require(AVAudioPCMBuffer(pcmFormat: profile.format, frameCapacity: UInt32(metrics.levels.frameCount)))
        try decoder.decode(into: prepared, length: prepared.frameCapacity)
        #expect(prepared.frameLength == prepared.frameCapacity)
        let baseline = try render(prepared, profile: profile, plan: nil)
        let actual = try measure(baseline, profile: profile)
        #expect(abs(try #require(metrics.levels.loudness.value) - #require(actual.loudness.value)) < 0.1)
        #expect(abs(metrics.levels.truePeakDBTP - actual.truePeakDBTP) < 0.4)
        let plan = try NormalizationPlan(metrics: metrics.levels, profile: profile)
        let adjusted = try render(prepared, profile: profile, plan: plan, volume: 0.4)
        let gain = Float(plan.linearGain)*0.4
        var maximumError: Float = 0
        for ch in baseline.indices { for n in baseline[ch].indices { maximumError = max(maximumError, abs(adjusted[ch][n]-baseline[ch][n]*gain)) } }
        print("profile \(rate)→\(outputRate) mono→stereo LUFSdiff=\(metrics.levels.loudness.value!-actual.loudness.value!), peakdiff=\(metrics.levels.truePeakDBTP-actual.truePeakDBTP), waveform error=\(maximumError)")
        #expect(maximumError < 2e-6) // same sample positions: also detects added DSP delay
        let muted = try render(prepared, profile: profile, plan: plan, volume: 0)
        #expect(muted.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test(arguments: [UInt32(1),2], [UInt32(1),2])
    func channelConversionMatchesPlayback(inputChannels: UInt32, outputChannels: UInt32) async throws {
        let rate = 48000.0, profile = try MeasurementProfile(sampleRate: 48000, channels: outputChannels)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: inputChannels))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        input.frameLength = input.frameCapacity
        for ch in 0..<Int(inputChannels) { for n in 0..<48000 {
            input.floatChannelData![ch][n] = Float(sin(2 * .pi * Double(n) * (ch == 0 ? 1000 : 3000)/rate)*0.3)
        } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-channels-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: input) }
        let result = try await AudioPreprocessor.shared.measureLevels(url, profile: profile)
        let source = try AudioDecoderFactory.open(url)
        let decoder = try ProfileDecoder(base: source, profile: profile, frameLength: result.levels.frameCount)
        defer { try? decoder.close() }
        let prepared = try #require(AVAudioPCMBuffer(pcmFormat: profile.format, frameCapacity: UInt32(result.levels.frameCount)))
        try decoder.decode(into: prepared, length: prepared.frameCapacity)
        let actual = try measure(render(prepared, profile: profile, plan: nil), profile: profile)
        #expect(abs(try #require(result.levels.loudness.value) - #require(actual.loudness.value)) < 0.1)
        #expect(abs(result.levels.truePeakDBTP - actual.truePeakDBTP) < 0.4)
    }
}
