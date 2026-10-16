import AVFAudio
import AnalysisTransport
import Foundation
import Testing
@testable import AnalysisCore

struct AnalysisTests {
    @Test func validatesConfigurationAndFutureCompensation() throws {
        #expect(throws: AnalysisError.self) { try AnalysisConfiguration(bandCount: 0) }
        #expect(throws: AnalysisError.self) { try AnalysisConfiguration(framesPerSecond: 120) }
        #expect(throws: AnalysisError.self) { try AnalysisConfiguration(fftSize: 2000) }
        #expect(abs(SynchronizationEstimate.additionalAudioDelay(visualLatency: 0.06, outputLatency: 0.02)! - 0.04) < 1e-10)
        #expect(SynchronizationEstimate.additionalAudioDelay(visualLatency: 0.02, outputLatency: 0.1) == 0)
        #expect(SynchronizationEstimate.additionalAudioDelay(visualLatency: .nan, outputLatency: 0) == nil)
        let timing = AnalysisTiming(windowStartSample: 1024, windowFrameCount: 2048, sampleRate: 48000,
            windowCenterHostTime: 5, estimatedOutputLatency: 0.02, appliedAudioDelay: 0.04, producedHostTime: 5.01)
        #expect(abs(timing.estimatedPresentationHostTime! - 5.06) < 1e-10)
        let unknown = AnalysisTiming(windowStartSample: nil, windowFrameCount: 2048, sampleRate: 48000,
            windowCenterHostTime: 5, estimatedOutputLatency: nil, appliedAudioDelay: 0, producedHostTime: 5.01)
        #expect(unknown.estimatedPresentationHostTime == nil)
    }

    @Test(arguments: [44100.0, 48000.0, 96000.0])
    func sinePowerAndAntiphaseAreStable(_ rate: Double) throws {
        let configuration = try AnalysisConfiguration()
        let analyzer = try SpectrumAnalyzer(configuration: configuration)
        let n = configuration.fftSize
        let frequency = Double(Int(1000 * Double(n) / rate)) * rate / Double(n)
        let samples = (0..<n).map { Float(sin(2 * .pi * frequency * Double($0) / rate)) }
        let full = try #require(analyzer.analyze(left: samples, right: samples.map { -$0 }, sampleRate: rate))
        let half = try #require(analyzer.analyze(left: samples.map { $0 / 2 }, right: samples.map { -$0 / 2 }, sampleRate: rate))
        let index = try #require(full.db.indices.max { full.db[$0] < full.db[$1] })
        #expect(full.edges[index] <= frequency && full.edges[index + 1] >= frequency)
        #expect(abs((half.db[index] - full.db[index]) + 6.0206) < 0.01)
        #expect(abs(full.rms[0] - sqrt(0.5)) < 0.001)
        #expect(full.db[index] > -10) // antiphase must not cancel
        let totalPower = full.db.reduce(0.0) { $0 + pow(10, Double($1) / 10) }
        #expect(abs(totalPower - 0.5) < 0.001)
    }

    @Test func silenceDCNyquistAndChannelIsolation() throws {
        let analyzer = try SpectrumAnalyzer(configuration: AnalysisConfiguration(bandCount: 128))
        let n = 2048
        let zero = Array(repeating: Float(0), count: n)
        let silent = try #require(analyzer.analyze(left: zero, right: zero, sampleRate: 48000))
        #expect(silent.db.allSatisfy { $0 == -100 })
        let dc = try #require(analyzer.analyze(left: Array(repeating: 0.5, count: n),
                                              right: Array(repeating: 0.5, count: n), sampleRate: 48000))
        #expect(dc.db.allSatisfy { $0 == -100 })
        #expect(abs(dc.rms[0] - 0.5) < 0.00001)
        let left = (0..<n).map { Float(sin(2 * .pi * 1500 * Double($0) / 48000)) }
        let frame = try #require(analyzer.analyze(left: left, right: zero, sampleRate: 48000))
        #expect(frame.rms[0] > 0.7 && frame.rms[1] == 0)
        #expect(frame.peak[0] > 0.99 && frame.peak[1] == 0)
        let invalid = try #require(analyzer.analyze(left: Array(repeating: .nan, count: n), right: zero, sampleRate: 48000))
        #expect(invalid.levels.allSatisfy { $0.isFinite && $0 == 0 })
        #expect(analyzer.analyze(left: left, right: zero, sampleRate: .nan) == nil)
        // At 8kHz Nyquist is inside the supported range; its power must not be doubled.
        let nyquist = (0..<n).map { Float($0 % 2 == 0 ? 1 : -1) }
        let edge = try #require(analyzer.analyze(left: nyquist, right: nyquist, sampleRate: 8000))
        #expect(abs(edge.db.reduce(0.0) { $0 + pow(10, Double($1) / 10) } - 1) < 0.001)
    }

    @Test func transportHasBoundedCapacityAndCopiesOwnedPCM() throws {
        let queue = try #require(lcmp_pcm_create(2, 16))
        defer { lcmp_pcm_destroy(queue) }
        var values: [Float] = [1, 2, 3, 4]
        var stamp = LCMPPCMStamp()
        stamp.frames = 4
        stamp.sequence = 1
        #expect(values.withUnsafeBufferPointer { lcmp_pcm_push(queue, $0.baseAddress, nil, stamp) })
        values[0] = 99
        stamp.sequence = 2
        #expect(values.withUnsafeBufferPointer { lcmp_pcm_push(queue, $0.baseAddress, nil, stamp) })
        #expect(!values.withUnsafeBufferPointer { lcmp_pcm_push(queue, $0.baseAddress, nil, stamp) })
        #expect(lcmp_pcm_dropped(queue) == 1)
        var left = Array(repeating: Float(0), count: 16), right = left
        for sequence in 1...2 {
            let ok = left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                lcmp_pcm_pop(queue, l.baseAddress, r.baseAddress, &stamp)
            } }
            #expect(ok && stamp.sequence == sequence)
            #expect(left[0] == (sequence == 1 ? 1 : 99))
            #expect(left == right)
        }
        stamp.frames = 17
        #expect(!values.withUnsafeBufferPointer { lcmp_pcm_push(queue, $0.baseAddress, nil, stamp) })
        #expect(lcmp_pcm_dropped(queue) == 2)
    }

    @Test(arguments: [15, 30, 60])
    func streamsHavePCMTimingBoundedCadenceAndTeardown(_ fps: Int) async throws {
        let session = try AnalysisSession(configuration: AnalysisConfiguration(framesPerSecond: fps))
        let generation = session.generation
        let collector = Task { () -> [AnalysisFrame] in
            var result: [AnalysisFrame] = []
            for await frame in session.frames { result.append(frame) }
            return result
        }
        let rate = 48000.0
        let base = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        for i in 0..<40 {
            let sample = i * 1024
            let buffer = try makeBuffer(frames: 1024, sample: sample, rate: rate)
            session.accept(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: base + Double(sample) / rate),
                sampleTime: Int64(sample), atRate: rate), outputLatency: 0.03)
            try await Task.sleep(for: .milliseconds(22))
        }
        session.finish()
        session.finish()
        let frames = await collector.value
        #expect(frames.count >= fps / 3)
        #expect(frames.count <= fps + 2)
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(b.sequence > a.sequence)
            // A phase-stable cadence allows adjacent intervals to vary with the
            // producer and timer quantum; it must not send catch-up bursts.
            #expect(b.timing.producedHostTime - a.timing.producedHostTime >= 0.003)
        }
        for frame in frames {
            #expect(frame.generation == generation)
            let timing = frame.timing
            let sample = try #require(timing.windowStartSample)
            #expect(abs(timing.windowCenterHostTime! - (base + (sample + 1024) / rate)) < 1e-6)
            #expect(abs(timing.estimatedPresentationHostTime! - (timing.windowCenterHostTime! + 0.03)) < 1e-6)
            #expect(timing.appliedAudioDelay == 0)
            #expect(frame.leftRMS > 0.6)
        }
    }

    @Test func unknownTimestampsStayUnknownAndSessionReleases() async throws {
        weak var weakSession: AnalysisSession?
        let task: Task<[AnalysisFrame], Never>
        do {
            let session = try AnalysisSession(configuration: AnalysisConfiguration())
            weakSession = session
            let stream = session.frames
            task = Task { var result: [AnalysisFrame] = []; for await f in stream { result.append(f) }; return result }
            session.accept(try makeBuffer(frames: 4096, sample: 0, rate: 48000),
                at: AVAudioTime(sampleTime: 0, atRate: 48000), outputLatency: nil)
            try await Task.sleep(for: .milliseconds(80))
            session.finish()
        }
        let frames = await task.value
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.timing.windowCenterHostTime == nil && $0.timing.estimatedPresentationHostTime == nil })
        for _ in 0..<20 where weakSession != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(weakSession == nil)
    }

    @Test func fftComputationBenchmark() throws {
        let analyzer = try SpectrumAnalyzer(configuration: AnalysisConfiguration(framesPerSecond: 60))
        let input = (0..<2048).map { Float(sin(Double($0))) }
        var durations: [Double] = []
        for _ in 0..<200 {
            let start = ContinuousClock.now
            _ = analyzer.analyze(left: input, right: input, sampleRate: 48000)
            let elapsed = start.duration(to: .now).components
            durations.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        durations.sort()
        print("FFT 32band/2048/stereo p95 seconds: \(durations[190])")
        #expect(durations[190] < 0.02) // regression ceiling, tighter product goal measured separately
    }

    @Test func observationPathIsTransparentAndRenderSessionReleases() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let engine = AVAudioEngine()
        let source = AVAudioPlayerNode()
        let converter = AVAudioMixerNode()
        let observation = AVAudioUnitEQ(numberOfBands: 0)
        for node in [source, converter, observation] as [AVAudioNode] { engine.attach(node) }
        engine.connect(source, to: converter, format: format)
        engine.connect(converter, to: observation, format: format)
        engine.connect(observation, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let session = try AnalysisSession(configuration: AnalysisConfiguration())
        let renderSource = try AnalysisRenderSource(unit: observation.audioUnit)
        #expect(session.attach(to: renderSource, sampleRate: 48000, outputLatency: 0) == noErr)
        let input = try makeBuffer(frames: 8192, sample: 0, rate: 48000)
        source.scheduleBuffer(input)
        try engine.start()
        source.play()
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        for chunk in 0..<8 {
            #expect(try engine.renderOffline(1024, to: output) == .success)
            let actual = try #require(output.floatChannelData)[0]
            let expected = try #require(input.floatChannelData)[0]
            for i in 0..<1024 { #expect(abs(actual[i] - expected[chunk * 1024 + i]) < 1e-6) }
        }
        engine.stop()
        session.detach()
        session.finish()
    }

    @Test func timestampValidityTransitionsResetOverlappingWindows() async throws {
        let session = try AnalysisSession(configuration: AnalysisConfiguration())
        let stream = session.frames
        let collector = Task { var frames: [AnalysisFrame] = []; for await frame in stream { frames.append(frame) }; return frames }
        let base = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        for part in 0..<3 {
            let sample = part * 4096
            let time = part == 1
                ? AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: base + Double(sample) / 48000),
                              sampleTime: Int64(sample), atRate: 48000)
                : AVAudioTime(sampleTime: Int64(sample), atRate: 48000)
            session.accept(try makeBuffer(frames: 4096, sample: sample, rate: 48000), at: time, outputLatency: 0.01)
            try await Task.sleep(for: .milliseconds(80))
        }
        session.finish()
        let frames = await collector.value
        #expect(frames.count == 3)
        #expect(frames.first?.timing.windowCenterHostTime == nil)
        #expect(frames.last?.timing.windowCenterHostTime == nil)
        let known = try #require(frames.first { $0.timing.windowCenterHostTime != nil })
        let sample = try #require(known.timing.windowStartSample)
        #expect(sample >= 4096 && sample < 8192)
        #expect(abs(known.timing.windowCenterHostTime! - (base + (sample + 1024) / 48000)) < 1e-6)
    }

    @Test func fftBandsMatchIndependentDirectDFT() throws {
        let n = 1024, rate = 48000.0
        let input = (0..<n).map { i in Float(0.3 * sin(Double(i) * 0.131) + 0.2 * cos(Double(i) * 0.41) + 0.05) }
        let analyzer = try SpectrumAnalyzer(configuration: AnalysisConfiguration(bandCount: 16, fftSize: n))
        let result = try #require(analyzer.analyze(left: input, right: input, sampleRate: rate))
        let mean = input.reduce(0.0) { $0 + Double($1) } / Double(n)
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n)) }
        let signal = zip(input, window).map { (Double($0.0) - mean) * $0.1 }
        let scale = 2 / (Double(n) * window.reduce(0) { $0 + $1 * $1 })
        var power = Array(repeating: 0.0, count: 16)
        for bin in 1...n/2 {
            let hz = Double(bin) * rate / Double(n)
            guard hz >= 20, hz <= 20000 else { continue }
            var re = 0.0, im = 0.0
            for i in 0..<n {
                let angle = 2 * .pi * Double(bin * i) / Double(n)
                re += signal[i] * cos(angle); im -= signal[i] * sin(angle)
            }
            let band = min(15, Int(log(hz / 20) / log(1000) * 16))
            power[band] += (re * re + im * im) * scale
        }
        for band in power.indices {
            let expected = max(-100, min(0, 10 * log10(max(1e-10, power[band]))))
            #expect(abs(Double(result.db[band]) - expected) < 0.04)
        }
    }

    private func makeBuffer(frames: Int, sample: Int, rate: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        let p = try #require(buffer.floatChannelData)[0]
        for i in 0..<frames { p[i] = Float(sin(2 * .pi * 1000 * Double(sample + i) / rate)) }
        return buffer
    }
}
