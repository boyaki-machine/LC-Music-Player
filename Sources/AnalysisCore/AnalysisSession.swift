import AVFAudio
import AnalysisTransport
import Foundation

/// One immutable configuration and timeline generation per playback run.
/// The C queue is SPSC: one render notification (or synthetic accept producer),
/// drain ONLY by worker. Never use both producers on the same session.
public final class AnalysisSession: @unchecked Sendable {
    public let generation = UUID()
    public let frames: AsyncStream<AnalysisFrame>
    private let continuation: AsyncStream<AnalysisFrame>.Continuation
    private var renderSource: AnalysisRenderSource?
    private let transport: OpaquePointer
    private let worker = DispatchQueue(label: "local.lcmp.analysis", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let analyzer: SpectrumAnalyzer
    private let stateLock = NSLock()
    private var ended = false // protected by stateLock
    private var producerSequence: UInt64 = 0 // producer only
    private var lastSequence: UInt64? // worker only below
    private var rate: Double = 0
    private var previousSampleEnd: Double?
    private var previousHostEnd: Double?
    private var windowStartSample: Double?
    private var windowStartHost: Double?
    private var windowLatency: Double?
    private var leftWindow: [Float] = []
    private var rightWindow: [Float] = []
    private var leftScratch = Array(repeating: Float(0), count: 16384)
    private var rightScratch = Array(repeating: Float(0), count: 16384)
    private var frameSequence: UInt64 = 0
    private var nextDelivery = -Double.infinity
    /// The newest complete window, copied into storage allocated once; `pending` holds its timing.
    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []
    private var pending: (sample: Double?, host: Double?, latency: Double?)?

    public init(configuration: AnalysisConfiguration) throws {
        analyzer = try SpectrumAnalyzer(configuration: configuration)
        guard let queue = lcmp_pcm_create(8, 16384) else { throw AnalysisError.allocationFailed }
        transport = queue
        let stream = AsyncStream<AnalysisFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = stream.stream
        continuation = stream.continuation
        timer = DispatchSource.makeTimerSource(queue: worker)
        leftWindow.reserveCapacity(configuration.fftSize)
        rightWindow.reserveCapacity(configuration.fftSize)
        pendingLeft = Array(repeating: 0, count: configuration.fftSize)
        pendingRight = Array(repeating: 0, count: configuration.fftSize)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
    }

    deinit {
        timer.cancel()
        continuation.finish()
        renderSource?.clear(transport)
        lcmp_pcm_destroy(transport)
    }

    /// No allocation, FFT, locks, tasks or UI work in this callback.
    /// Buffer belongs to the engine: only samples copied before returning are retained.
    public func accept(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, outputLatency: Double?) {
        producerSequence &+= 1
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved, let channels = buffer.floatChannelData,
              buffer.format.channelCount > 0 else { return }
        var stamp = LCMPPCMStamp()
        stamp.frames = buffer.frameLength
        stamp.sample_rate = buffer.format.sampleRate
        stamp.sample_time_valid = time.isSampleTimeValid
        stamp.sample_time = Double(time.sampleTime)
        stamp.host_time_valid = time.isHostTimeValid
        stamp.host_seconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : 0
        stamp.callback_seconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        stamp.latency_valid = outputLatency.map { $0.isFinite && $0 >= 0 } ?? false
        stamp.output_latency = outputLatency ?? 0
        stamp.sequence = producerSequence
        _ = lcmp_pcm_push(transport, channels[0],
                          buffer.format.channelCount > 1 ? channels[1] : nil, stamp)
    }

    /// Call after unregistering the render notification. Idempotent; does not wait for FFT work.
    public func finish() {
        stateLock.lock()
        ended = true
        continuation.finish()
        stateLock.unlock()
        timer.cancel()
    }

    public var droppedBuffers: UInt64 { lcmp_pcm_dropped(transport) }

    /// Production producer: C render notification copies PCM without entering Swift.
    public func attach(to source: AnalysisRenderSource, sampleRate: Double, outputLatency: Double) -> OSStatus {
        guard renderSource == nil else { return kAudio_ParamError }
        let status = source.bind(transport, rate: sampleRate, latency: outputLatency)
        if status == noErr { renderSource = source }
        return status
    }

    /// Stamps later renders with a new output latency, for a route change that keeps the engine running.
    public func updateOutputLatency(_ seconds: Double) { lcmp_pcm_set_output_latency(transport, seconds) }

    public func detach() {
        renderSource?.clear(transport)
        renderSource = nil
    }

    private func isEnded() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return ended
    }

    private func drain() {
        guard !isEnded() else { return }
        var stamp = LCMPPCMStamp()
        // Bound each drain even if the producer continues to fill the queue.
        for _ in 0..<8 {
            let available = leftScratch.withUnsafeMutableBufferPointer { left in
                rightScratch.withUnsafeMutableBufferPointer { right in
                    lcmp_pcm_pop(transport, left.baseAddress!, right.baseAddress!, &stamp)
                }
            }
            guard available, !isEnded() else { break }
            consume(stamp)
        }
        produce()
    }

    private func consume(_ stamp: LCMPPCMStamp) {
        guard stamp.sample_rate.isFinite, stamp.sample_rate >= 8000 else { return }
        let sample = stamp.sample_time_valid ? stamp.sample_time : nil
        let host = stamp.host_time_valid ? stamp.host_seconds : nil
        #if DEBUG
        if let host, stamp.callback_seconds > 0 { LatencyProbe.recordRenderLead(host - stamp.callback_seconds) }
        #endif
        let sampleGap = sample.flatMap { s in previousSampleEnd.map { abs(s - $0) > 0.5 } } ?? false
        let hostGap = host.flatMap { h in previousHostEnd.map { abs(h - $0) > 2 / stamp.sample_rate } } ?? false
        let discontinuity = rate != stamp.sample_rate || lastSequence.map { $0 &+ 1 != stamp.sequence } == true
            || sampleGap || hostGap || ((sample == nil) != (previousSampleEnd == nil))
            || ((host == nil) != (previousHostEnd == nil))
        if discontinuity {
            leftWindow.removeAll(keepingCapacity: true); rightWindow.removeAll(keepingCapacity: true)
            pending = nil
        }
        rate = stamp.sample_rate
        lastSequence = stamp.sequence
        previousSampleEnd = sample.map { $0 + Double(stamp.frames) }
        previousHostEnd = host.map { $0 + Double(stamp.frames) / rate }
        // Overlapping windows never empty, so each render brings its latency: a route change
        // that keeps the engine running reaches the next window.
        windowLatency = stamp.latency_valid ? stamp.output_latency : nil
        let n = analyzer.configuration.fftSize
        var offset = 0
        while offset < Int(stamp.frames) {
            if leftWindow.isEmpty {
                windowStartSample = sample.map { $0 + Double(offset) }
                windowStartHost = host.map { $0 + Double(offset) / rate }
            }
            let count = min(n - leftWindow.count, Int(stamp.frames) - offset)
            leftWindow.append(contentsOf: leftScratch[offset..<(offset + count)])
            rightWindow.append(contentsOf: rightScratch[offset..<(offset + count)])
            offset += count
            if leftWindow.count == n {
                // Copied, not shared: sharing would make the next append copy the whole window anew.
                pendingLeft.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: leftWindow) }
                pendingRight.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: rightWindow) }
                pending = (windowStartSample, windowStartHost, windowLatency)
                let hop = min(n / 2, max(1, Int(rate / Double(analyzer.configuration.framesPerSecond))))
                leftWindow.removeFirst(hop); rightWindow.removeFirst(hop)
                windowStartSample = windowStartSample.map { $0 + Double(hop) }
                windowStartHost = windowStartHost.map { $0 + Double(hop) / rate }
            }
        }
    }

    private func produce() {
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let interval = 1 / Double(analyzer.configuration.framesPerSecond)
        // Late work publishes only the latest frame at a bounded cadence, never catch-up bursts.
        guard now >= nextDelivery, let pending else { return }
        self.pending = nil
        let started = now
        guard let result = analyzer.analyze(left: pendingLeft, right: pendingRight, sampleRate: rate) else { return }
        let completed = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        frameSequence &+= 1
        let timing = AnalysisTiming(windowStartSample: pending.sample,
            windowFrameCount: analyzer.configuration.fftSize, sampleRate: rate,
            windowCenterHostTime: pending.host.map { $0 + Double(analyzer.configuration.fftSize) / (2 * rate) },
            estimatedOutputLatency: pending.latency, appliedAudioDelay: 0, producedHostTime: completed)
        let frame = AnalysisFrame(generation: generation, sequence: frameSequence, timing: timing,
            bandEdgesHz: result.edges, bandDBFS: result.db, levels: result.levels,
            leftRMS: result.rms[0], rightRMS: result.rms[1], leftPeak: result.peak[0], rightPeak: result.peak[1],
            droppedBuffers: droppedBuffers, queuedBufferHighWatermark: lcmp_pcm_high_water(transport),
            computationSeconds: completed - started)
        stateLock.lock()
        if !ended {
            continuation.yield(frame)
            // Keep a clock-based phase: adding the FFT duration to every interval
            // otherwise lowers 60Hz to ~40–50Hz. Skip missed deadlines, never burst.
            let following = nextDelivery + interval
            nextDelivery = following > completed ? following : completed + interval
        }
        stateLock.unlock()
    }
}

/// One stable context per observation AU. The owner stops its engine before releasing this source.
public final class AnalysisRenderSource: @unchecked Sendable {
    private let context: OpaquePointer
    public init(unit: AudioUnit) throws {
        guard let source = lcmp_render_source_create(unit) else { throw AnalysisError.allocationFailed }
        context = source
    }
    fileprivate func bind(_ queue: OpaquePointer, rate: Double, latency: Double) -> OSStatus {
        lcmp_render_source_bind(context, queue, rate, latency)
    }
    fileprivate func clear(_ queue: OpaquePointer) { lcmp_render_source_clear(context, queue) }
    deinit { lcmp_render_source_destroy(context) }
}
