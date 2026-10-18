import AVFAudio
import Foundation
import AnalysisCore
import AudioProcessingCore

@MainActor
public final class AudioEngineBackend: PlaybackBackend {
    isolated deinit { stop() }

    public let duration: TimeInterval
    public let supportsSeeking: Bool
    public var currentTime: TimeInterval {
        guard let run else { return pendingTime }
        if paused { return pausedTime }
        guard let nodeTime = run.player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = run.player.playerTime(forNodeTime: nodeTime) else { return run.startTime }
        return min(duration, run.startTime + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate))
    }
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    /// Optional diagnostics, called on the main actor after play starts. The host time is
    /// an estimated device presentation time, not a physical audibility measurement.
    public var onRenderScheduled: (@Sendable (UInt64) -> Void)?
    public private(set) var normalizationPlan: NormalizationPlan?
    private var normalizationMetrics: TrackAudioMetrics?
    private var processingChain: AudioProcessingChain?

    public func clearNormalization() {
        normalizationMetrics = nil; normalizationPlan = nil
        processingChain?.levelNode.globalGain = 0
    }

    /// The format the output device renders: the profile of every measurement.
    public static func measurementProfile() throws -> MeasurementProfile {
        let format = AVAudioEngine().mainMixerNode.outputFormat(forBus: 0)
        return try MeasurementProfile(sampleRate: format.sampleRate, channels: format.channelCount)
    }
    public var volume: Float = 0.25 {
        didSet { run?.engine.mainMixerNode.outputVolume = volume }
    }

    private struct Run {
        let id: UUID
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        let feeder: PCMFeeder
        let startTime: TimeInterval
        let observer: NSObjectProtocol
    }

    private let url: URL
    private var preparedDecoder: (any PCMDecoding)?
    private var run: Run?
    private var pendingTime: TimeInterval = 0
    private var pausedTime: TimeInterval = 0
    private var paused = false
    private var analysisConfiguration: AnalysisConfiguration?
    private var receiveAnalysis: (@MainActor (AnalysisFrame) -> Void)?
    private var analysis: AnalysisSession?
    private var analysisTask: Task<Void, Never>?
    private var analysisGeneration: UUID?
    private var analysisNode: AVAudioUnitEQ?
    private var analysisSource: AnalysisRenderSource?

    public func configureAnalysis(_ configuration: AnalysisConfiguration?,
                                  receive: (@MainActor (AnalysisFrame) -> Void)?) {
        endAnalysis()
        analysisConfiguration = configuration
        receiveAnalysis = receive
        if run != nil && !paused { startAnalysis() }
    }

    private func startAnalysis() {
        guard run != nil, let node = analysisNode,
              let analysisConfiguration, receiveAnalysis != nil,
              let session = try? AnalysisSession(configuration: analysisConfiguration) else { return }
        if analysisSource == nil { analysisSource = try? AnalysisRenderSource(unit: node.audioUnit) }
        guard let source = analysisSource else { session.finish(); return }
        let status = session.attach(to: source, sampleRate: node.outputFormat(forBus: 0).sampleRate,
                                    outputLatency: node.outputPresentationLatency)
        guard status == noErr else { session.finish(); return }
        analysis = session
        analysisGeneration = session.generation
        analysisTask = Task { [weak self, frames = session.frames, id = session.generation] in
            for await frame in frames {
                guard !Task.isCancelled, let self, self.analysisGeneration == id else { break }
                self.receiveAnalysis?(frame)
            }
        }
    }

    private func endAnalysis() {
        analysisGeneration = nil
        analysisTask?.cancel()
        analysisTask = nil
        analysis?.detach()
        analysis?.finish()
        analysis = nil
    }

    init(url: URL, duration: Double, supportsSeeking: Bool) {
        self.url = url; self.duration = duration; self.supportsSeeking = supportsSeeking
    }

    public init(prepared: PreparedAudio, metrics: TrackAudioMetrics? = nil,
                settings: NormalizationSettings = .standard) throws {
        if let metrics {
            guard metrics.source == prepared.source else { throw AudioProcessingFailure.invalidMeasurement }
            try metrics.source.validate()
            normalizationPlan = try NormalizationPlan(metrics: metrics.levels, profile: metrics.profile, settings: settings)
            normalizationMetrics = metrics
        }
        url = prepared.source.url
        duration = prepared.duration
        let decoder = try prepared.takeDecoder()
        supportsSeeking = decoder.supportsSeeking
        preparedDecoder = decoder
    }

    public init(url: URL) throws {
        self.url = url
        do {
            let decoder = try AudioDecoderFactory.open(url)
            defer { try? decoder.close() }
            let seconds = Double(decoder.length) / decoder.processingFormat.sampleRate
            guard seconds.isFinite, seconds > 0 else {
                throw PlaybackError.loadingFailed("音声データが空、または長さを取得できません。")
            }
            duration = seconds
            supportsSeeking = decoder.supportsSeeking
        } catch {
            throw (error as? PlaybackError) ?? PlaybackError.loadingFailed(error.localizedDescription)
        }
    }

    public func play() throws {
        try start(at: pendingTime)
    }

    private func start(at seconds: TimeInterval) throws {
        do {
            var decoder: any PCMDecoding
            if let preparedDecoder {
                decoder = preparedDecoder
                self.preparedDecoder = nil
            } else { decoder = try AudioDecoderFactory.open(url) }
            if let metrics = normalizationMetrics {
                do { decoder = try ProfileDecoder(base: decoder, profile: metrics.profile, frameLength: metrics.levels.frameCount) }
                catch { try? decoder.close(); throw error }
            }
            if seconds > 0 {
                let frame = AVAudioFramePosition(seconds * decoder.processingFormat.sampleRate)
                do { try decoder.seek(to: min(frame, decoder.length - 1)) }
                catch { try? decoder.close(); throw error }
            }
            let engine = AVAudioEngine()
            let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            if let metrics = normalizationMetrics {
                do {
                    try metrics.source.validate()
                    guard try MeasurementProfile(sampleRate: outputFormat.sampleRate, channels: outputFormat.channelCount) == metrics.profile else {
                        throw AudioProcessingFailure.outputChanged
                    }
                } catch { try? decoder.close(); throw error }
            }
            guard let observationFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate,
                                                         channels: outputFormat.channelCount) else {
                try? decoder.close()
                throw PlaybackError.playbackFailed("解析接続用の音声形式を作成できません。")
            }
            // Retire the old run before transferring the decoder to the feeder.
            stop()
            let id = UUID()
            let send: @Sendable (PlaybackEvent) -> Void = { [weak self] event in
                Task { @MainActor in
                    guard let self, self.run?.id == id else { return }
                    self.onEvent?(event)
                }
            }
            let player = AVAudioPlayerNode()
            // Zero filters, zero global gain: a pass-through AU with a public
            // render-notification API. Future compensation belongs downstream.
            let observation = AVAudioUnitEQ(numberOfBands: 0)
            let chain = AudioProcessingChain(plan: normalizationPlan)
            let converter = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(converter)
            engine.attach(observation)
            engine.attach(chain.levelNode)
            engine.connect(player, to: converter, format: decoder.processingFormat)
            engine.connect(converter, to: observation, format: observationFormat)
            engine.connect(observation, to: chain.levelNode, format: observationFormat)
            engine.connect(chain.levelNode, to: engine.mainMixerNode, format: observationFormat)
            engine.mainMixerNode.outputVolume = volume
            let feeder = PCMFeeder(decoder: decoder, player: player,
                                   finished: { send(.finished) },
                                   failed: { send(.failed(.playbackFailed($0.localizedDescription))) })
            let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                  object: engine, queue: nil) { _ in send(.outputChanged) }
            pendingTime = seconds
            run = Run(id: id, engine: engine, player: player, feeder: feeder, startTime: seconds, observer: observer)
            processingChain = chain
            analysisNode = observation
            try feeder.prime()
            engine.prepare()
            try engine.start()
            player.play()
            if let onRenderScheduled {
                let latency = engine.outputNode.presentationLatency + engine.outputNode.outputPresentationLatency
                onRenderScheduled(mach_absolute_time() + AVAudioTime.hostTime(forSeconds: max(0, latency)))
            }
            startAnalysis()
        } catch {
            stop()
            throw PlaybackError.playbackFailed(error.localizedDescription)
        }
    }

    public func seek(to seconds: TimeInterval) throws {
        guard supportsSeeking, seconds.isFinite, seconds >= 0, seconds < duration else {
            throw PlaybackError.playbackFailed("この再生位置へ移動できません。")
        }
        if run != nil && !paused {
            try start(at: seconds)
        } else {
            let wasPaused = paused
            let prepared = preparedDecoder
            preparedDecoder = nil
            stop()
            preparedDecoder = prepared
            pendingTime = seconds
            paused = wasPaused
        }
    }

    public func pause() throws {
        guard let run, !paused else {
            throw PlaybackError.playbackFailed("一時停止できませんでした。")
        }
        pausedTime = currentTime
        run.player.pause()
        run.engine.pause()
        paused = true
        endAnalysis()
    }

    public func resume() throws {
        if let metrics = normalizationMetrics {
            try metrics.source.validate()
            guard try Self.measurementProfile() == metrics.profile else { throw AudioProcessingFailure.outputChanged }
        }
        if run == nil && paused { try start(at: pendingTime); return }
        guard let run, paused else {
            throw PlaybackError.playbackFailed("再開できませんでした。")
        }
        do { try run.engine.start() } catch {
            throw PlaybackError.playbackFailed("再開できませんでした。")
        }
        run.player.play()
        paused = false
        startAnalysis()
    }

    public func stop() {
        try? preparedDecoder?.close()
        preparedDecoder = nil
        endAnalysis()
        pendingTime = 0
        pausedTime = 0
        paused = false
        if let run {
            self.run = nil
            NotificationCenter.default.removeObserver(run.observer)
            run.feeder.cancel()
            run.player.stop()
            run.engine.stop()
            run.feeder.close()
        }
        analysisSource = nil
        analysisNode = nil
        processingChain = nil
    }
}

/// Owns the decoder after a run starts. Decoding and scheduling happen only on `queue`,
/// never on the render thread; a bounded set of buffers is reused, so memory does not
/// grow with the length of the track. Only Sendable events leave this object.
final class PCMFeeder: @unchecked Sendable {
    static let bufferCount = 4
    static let bufferSeconds = 0.2

    private let queue = DispatchQueue(label: "LCMP.PCMFeeder", qos: .userInitiated)
    private let decoder: any PCMDecoding
    private let player: AVAudioPlayerNode
    private let finished: @Sendable () -> Void
    private let failed: @Sendable (any Error) -> Void
    private let endCallback: AVAudioPlayerNodeCompletionCallbackType
    private let buffers: [AVAudioPCMBuffer]
    private var free: [Int]
    private var scheduled: AVAudioFramePosition = 0
    private var endOfAudio = false
    private var cancelled = false

    /// `endCallback` is replaceable for offline rendering, which never reports `.dataPlayedBack`.
    init(decoder: any PCMDecoding, player: AVAudioPlayerNode,
         endCallback: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack,
         finished: @escaping @Sendable () -> Void, failed: @escaping @Sendable (any Error) -> Void) {
        self.decoder = decoder; self.player = player; self.endCallback = endCallback
        self.finished = finished; self.failed = failed
        let frames = AVAudioFrameCount(max(4096, (decoder.processingFormat.sampleRate * Self.bufferSeconds).rounded(.up)))
        buffers = (0..<Self.bufferCount).compactMap { _ in AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: frames) }
        free = Array(buffers.indices)
    }

    /// Schedules the first buffers before playback starts, so the timeline begins with audio.
    func prime() throws {
        guard buffers.count == Self.bufferCount else { throw PlaybackError.playbackFailed("再生用のバッファを確保できません。") }
        try queue.sync { try fill() }
    }

    func cancel() { queue.sync { cancelled = true } }

    /// Frames handed to the player so far, for tests.
    var scheduledFrames: AVAudioFramePosition { queue.sync { scheduled } }

    func close() { queue.async { try? self.decoder.close() } }

    private func fill() throws {
        while !cancelled, !endOfAudio, let index = free.popLast() {
            let buffer = buffers[index]
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            endOfAudio = buffer.frameLength < buffer.frameCapacity || decoder.position >= decoder.length
            guard buffer.frameLength > 0 else { free.append(index); break }
            scheduled += AVAudioFramePosition(buffer.frameLength)
            // A consumed buffer is refilled at once; the end is reported only after the
            // last buffer has also passed the output latency.
            if endOfAudio {
                player.scheduleBuffer(buffer, completionCallbackType: endCallback) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.playedBack() }
                }
            } else {
                player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.consumed(index) }
                }
            }
        }
        if endOfAudio, scheduled == 0, !cancelled { cancelled = true; finished() }
    }

    private func consumed(_ index: Int) {
        guard !cancelled else { return }
        free.append(index)
        do { try fill() } catch { cancelled = true; failed(error) }
    }

    private func playedBack() {
        guard !cancelled else { return }
        cancelled = true
        finished()
    }
}
