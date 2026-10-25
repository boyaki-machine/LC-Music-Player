import AVFAudio
import Foundation
import AnalysisCore
import AudioProcessingCore

@MainActor
public final class AudioEngineBackend: PlaybackBackend {
    isolated deinit { stopRun(retiring: false) }

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

    /// The format the output device renders: the profile of every measurement. Reading it builds an
    /// engine (a few milliseconds), so the result is kept until the output's device, rate or
    /// channels change, which `OutputSignature` reads in microseconds.
    public static func measurementProfile() throws -> MeasurementProfile {
        try cachedProfile(for: OutputSignature.current()) {
            let format = outputGraphFormat(of: AVAudioEngine())
            return try MeasurementProfile(sampleRate: format.sampleRate, channels: format.channelCount)
        }
    }
    private static var profileCache: (signature: OutputSignature, profile: MeasurementProfile)?
    /// The kept profile while the signature stays the same; an unknown signature always reads again.
    static func cachedProfile(for signature: OutputSignature?, read: () throws -> MeasurementProfile) throws -> MeasurementProfile {
        if let cached = profileCache, let signature, cached.signature == signature { return cached.profile }
        let profile = try read()
        profileCache = signature.map { ($0, profile) }
        return profile
    }
    /// The format the graph renders in, from the converter to the main mixer: the output device's
    /// rate, in at most two channels. It connects the main mixer to the output in the device's own
    /// format. A new engine otherwise reports a default format (44.1kHz on a 48kHz Mac) until it
    /// starts, and a graph built in it would convert the audio twice: to that rate and back.
    static func outputGraphFormat(of engine: AVAudioEngine) -> AVAudioFormat {
        let device = engine.outputNode.outputFormat(forBus: 0)
        guard device.sampleRate > 0, device.channelCount > 0,
              let output = AVAudioFormat(standardFormatWithSampleRate: device.sampleRate, channels: device.channelCount),
              let graph = AVAudioFormat(standardFormatWithSampleRate: device.sampleRate, channels: min(2, device.channelCount)) else {
            return engine.mainMixerNode.outputFormat(forBus: 0)
        }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: output)
        return graph
    }
    /// The engine of the current run, for tests.
    var currentEngine: AVAudioEngine? { run?.engine }
    public var volume: Float = 0.25 {
        didSet { run?.graph.setVolume(volume) }
    }

    private struct Run {
        let id: UUID
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        let graph: PlaybackGraph
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
    private var latencyTracker: OutputLatencyTracker?
    #if os(iOS)
    private static let routeChange: Notification.Name? = AVAudioSession.routeChangeNotification
    #else
    // A change of the default device on macOS changes the engine's configuration and stops playback.
    private static let routeChange: Notification.Name? = nil
    #endif

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
        if analysisSource == nil { analysisSource = try? AnalysisRenderSource(unit: node.audioUnit, keeping: node) }
        guard let source = analysisSource else { session.finish(); return }
        let status = session.attach(to: source, sampleRate: node.outputFormat(forBus: 0).sampleRate,
                                    outputLatency: node.outputPresentationLatency)
        guard status == noErr else { session.finish(); return }
        analysis = session
        analysisGeneration = session.generation
        latencyTracker = OutputLatencyTracker(initial: node.outputPresentationLatency, notification: Self.routeChange,
                                              read: { [weak node] in node?.outputPresentationLatency },
                                              apply: { [weak session] in session?.updateOutputLatency($0) })
        #if DEBUG
        startProbe()
        #endif
        analysisTask = Task { [weak self, frames = session.frames, id = session.generation] in
            for await frame in frames {
                guard !Task.isCancelled, let self, self.analysisGeneration == id else { break }
                var located = frame
                located.trackSeconds = self.trackSeconds(of: frame)
                self.receiveAnalysis?(located)
            }
        }
    }

    /// Where in the track the middle of the frame's window is: the window's sample time in the engine,
    /// through the player's timeline, after the position the run started from.
    private func trackSeconds(of frame: AnalysisFrame) -> Double? {
        guard let run, !paused, let start = frame.timing.windowStartSample, frame.timing.sampleRate > 0 else { return nil }
        let center = start + Double(frame.timing.windowFrameCount) / 2
        guard center.isFinite, abs(center) < 1e15 else { return nil }
        let nodeTime = AVAudioTime(sampleTime: AVAudioFramePosition(center.rounded()), atRate: frame.timing.sampleRate)
        guard let playerTime = run.player.playerTime(forNodeTime: nodeTime), playerTime.isSampleTimeValid,
              playerTime.sampleRate > 0 else { return nil }
        let seconds = run.startTime + Double(playerTime.sampleTime) / playerTime.sampleRate
        return seconds.isFinite && seconds >= 0 ? min(duration, seconds) : nil
    }

    private func endAnalysis() {
        latencyTracker?.cancel()
        latencyTracker = nil
        analysisGeneration = nil
        analysisTask?.cancel()
        analysisTask = nil
        analysis?.detach()
        analysis?.finish()
        analysis = nil
    }

    #if DEBUG
    /// Latency diagnostics for checking on a device; see LatencyProbe.
    public static var recordsLatency: Bool {
        get { LatencyProbe.isEnabled }
        set { LatencyProbe.isEnabled = newValue }
    }
    private var probeTimer: Timer?
    private var probeRoute: NSObjectProtocol?

    private func startProbe() {
        guard LatencyProbe.isEnabled else { return }
        probe("analysis")
        if probeTimer == nil {
            probeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.probe("tick") }
            }
        }
        #if os(iOS)
        if probeRoute == nil {
            probeRoute = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
                MainActor.assumeIsolated { self?.probe("route-\(reason)") }
            }
        }
        #endif
    }

    private func stopProbe() {
        probeTimer?.invalidate(); probeTimer = nil
        if let probeRoute { NotificationCenter.default.removeObserver(probeRoute) }
        probeRoute = nil
    }

    private func probe(_ event: String) {
        guard LatencyProbe.isEnabled, let run else { return }
        func ms(_ seconds: Double?) -> Double { seconds.map { $0.isFinite ? $0 * 1000 : -1 } ?? -1 }
        var values: [String: Any] = [
            "observedOutputPresentationLatencyMs": ms(analysisNode?.outputPresentationLatency),
            "outputNodePresentationLatencyMs": ms(run.engine.outputNode.presentationLatency),
            "outputNodeOutputPresentationLatencyMs": ms(run.engine.outputNode.outputPresentationLatency),
            "mixerOutputPresentationLatencyMs": ms(run.engine.mainMixerNode.outputPresentationLatency),
            "boundLatencyMs": ms(latencyTracker?.applied),
            "outputSampleRate": run.engine.outputNode.outputFormat(forBus: 0).sampleRate,
            "paused": paused,
        ]
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        values["sessionOutputLatencyMs"] = ms(session.outputLatency)
        values["sessionIOBufferDurationMs"] = ms(session.ioBufferDuration)
        values["sessionSampleRate"] = session.sampleRate
        // Kinds of ports only (speaker, Bluetooth A2DP, ...), never their names.
        values["routeOutputs"] = session.currentRoute.outputs.map(\.portType.rawValue)
        #endif
        LatencyProbe.write(event, values)
    }
    #endif

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

    /// The decoder for a run from `seconds`: the prepared one first, in the profile when normalizing.
    private func openDecoder(at seconds: TimeInterval) throws -> any PCMDecoding {
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
        return decoder
    }

    /// Events of a run reach the owner only while that run is current.
    private func sender(for id: UUID) -> @Sendable (PlaybackEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in
                guard let self, self.run?.id == id else { return }
                self.onEvent?(event)
            }
        }
    }

    private func observeConfiguration(of engine: AVAudioEngine, send: @escaping @Sendable (PlaybackEvent) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in send(.outputChanged) }
    }

    private func reportRenderSchedule(_ engine: AVAudioEngine) {
        guard let onRenderScheduled else { return }
        let latency = engine.outputNode.presentationLatency + engine.outputNode.outputPresentationLatency
        onRenderScheduled(mach_absolute_time() + AVAudioTime.hostTime(forSeconds: max(0, latency)))
    }

    private func start(at seconds: TimeInterval) throws {
        do {
            let decoder = try openDecoder(at: seconds)
            // The engine the previous track left running, while it still renders the current output.
            let handoff = Self.takeHandoff()
            let engine = handoff?.engine ?? AVAudioEngine()
            // A new engine reports the format its graph is built in before it starts; a running one
            // may report the device's instead, so a taken engine keeps the format of its graph.
            let outputFormat = handoff?.graph.format ?? Self.outputGraphFormat(of: engine)
            if let metrics = normalizationMetrics {
                do {
                    try metrics.source.validate()
                    guard try MeasurementProfile(sampleRate: outputFormat.sampleRate, channels: outputFormat.channelCount) == metrics.profile else {
                        throw AudioProcessingFailure.outputChanged
                    }
                } catch { try? decoder.close(); handoff?.stop(); throw error }
            }
            guard let observationFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate,
                                                         channels: outputFormat.channelCount) else {
                try? decoder.close(); handoff?.stop()
                throw PlaybackError.playbackFailed("解析接続用の音声形式を作成できません。")
            }
            // Retire the old run before transferring the decoder to the feeder.
            stopRun(retiring: false)
            let id = UUID()
            let send = sender(for: id)
            let graph: PlaybackGraph
            if let handoff {
                // Only the player changes; the level gain is set while no audio flows.
                graph = handoff.graph.taking(sourceFormat: decoder.processingFormat, plan: normalizationPlan)
                analysisSource = handoff.source
            } else {
                graph = PlaybackGraph(engine: engine, player: AVAudioPlayerNode(), sourceFormat: decoder.processingFormat,
                                      observationFormat: observationFormat, plan: normalizationPlan)
            }
            let player = graph.player
            graph.setVolume(volume)
            let feeder = PCMFeeder(decoder: decoder, player: player,
                                   finished: { send(.finished) },
                                   failed: { send(.failed(.playbackFailed($0.localizedDescription))) })
            let observer = observeConfiguration(of: engine, send: send)
            pendingTime = seconds
            run = Run(id: id, engine: engine, player: player, graph: graph, feeder: feeder, startTime: seconds, observer: observer)
            processingChain = graph.chain
            analysisNode = graph.observation
            try feeder.prime()
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            player.play()
            reportRenderSchedule(engine)
            startAnalysis()
        } catch {
            stop()
            throw PlaybackError.playbackFailed(error.localizedDescription)
        }
    }

    /// Seeking while playing keeps the running engine and graph: only the player restarts with a
    /// new feeder from the new position. Stopping and building an engine cost about 60ms more.
    private func reposition(to seconds: TimeInterval) throws {
        guard let old = run, old.engine.isRunning else { return try start(at: seconds) }
        do {
            let decoder = try openDecoder(at: seconds)
            guard decoder.processingFormat == old.player.outputFormat(forBus: 0) else {
                try? decoder.close(); return try start(at: seconds)
            }
            endAnalysis()
            NotificationCenter.default.removeObserver(old.observer)
            // Cancelled first, so the callbacks of the buffers the stop releases do nothing.
            old.feeder.cancel()
            old.player.stop()
            old.feeder.close()
            let id = UUID()
            let send = sender(for: id)
            let feeder = PCMFeeder(decoder: decoder, player: old.player,
                                   finished: { send(.finished) },
                                   failed: { send(.failed(.playbackFailed($0.localizedDescription))) })
            pendingTime = seconds
            run = Run(id: id, engine: old.engine, player: old.player, graph: old.graph, feeder: feeder, startTime: seconds,
                      observer: observeConfiguration(of: old.engine, send: send))
            try feeder.prime()
            old.player.play()
            reportRenderSchedule(old.engine)
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
            try reposition(to: seconds)
        } else {
            let wasPaused = paused
            let prepared = preparedDecoder
            preparedDecoder = nil
            stopRun(retiring: false)
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

    /// Stops the run and any engine left for the next track, so that the output, and on iOS the
    /// audio session, can be released after it.
    public func stop() {
        stopRun(retiring: false)
        Self.takeHandoff()?.stop()
    }

    /// Another track takes over: the player falls silent at once, and the running engine is left
    /// for the next track's run, which then starts in about the time of a seek instead of stopping
    /// one engine and starting another (about 80ms). An engine nobody takes stops after a moment.
    public func retire() { stopRun(retiring: true) }

    private func stopRun(retiring: Bool) {
        #if DEBUG
        stopProbe()
        #endif
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
            run.feeder.close()
            if retiring, run.engine.isRunning {
                Self.leave(Handoff(engine: run.engine, graph: run.graph, source: analysisSource, output: OutputSignature.current()))
            } else {
                run.engine.stop()
            }
        }
        analysisSource = nil
        analysisNode = nil
        processingChain = nil
    }
}

/// A running engine, with its graph and the render source of its observation node, that a track
/// left for the next one. The render source outlives the engine that calls it.
@MainActor private struct Handoff {
    let engine: AVAudioEngine
    let graph: PlaybackGraph
    let source: AnalysisRenderSource?
    /// The output when the engine was left; another output needs another engine.
    let output: OutputSignature?
    func stop() { engine.stop(); withExtendedLifetime(source) {} }
}

extension AudioEngineBackend {
    /// How long an engine waits for the next track before it stops.
    static let handoffLifetime = Duration.seconds(1)
    private static var handoff: Handoff?
    private static var handoffExpiry: Task<Void, Never>?
    /// Whether an engine waits for the next track, for tests.
    static var hasHandoff: Bool { handoff != nil }

    fileprivate static func leave(_ next: Handoff) {
        takeHandoff()?.stop()
        handoff = next
        let engine = ObjectIdentifier(next.engine)
        handoffExpiry = Task { @MainActor in
            try? await Task.sleep(for: handoffLifetime)
            guard !Task.isCancelled, let left = handoff, ObjectIdentifier(left.engine) == engine else { return }
            takeHandoff()?.stop()
        }
    }

    /// The waiting engine, if it still runs on the same output.
    fileprivate static func takeHandoff() -> Handoff? {
        handoffExpiry?.cancel(); handoffExpiry = nil
        guard let left = handoff else { return nil }
        handoff = nil
        guard left.engine.isRunning, let output = left.output, output == OutputSignature.current() else { left.stop(); return nil }
        return left
    }
}

/// The nodes between the player and the output, built the same way for playback and for the
/// offline tests: player → format mixer → observation → level gain → main mixer (app volume).
@MainActor struct PlaybackGraph {
    let engine: AVAudioEngine
    let player: AVAudioPlayerNode
    /// Converts the source format to the output's; the player is its only input.
    let converter: AVAudioMixerNode
    /// Zero filters, zero global gain: a pass-through AU with a public
    /// render-notification API. Future compensation belongs downstream.
    let observation: AVAudioUnitEQ
    let chain: AudioProcessingChain
    /// The format from the converter to the main mixer.
    let format: AVAudioFormat

    init(engine: AVAudioEngine, player: AVAudioPlayerNode, sourceFormat: AVAudioFormat,
         observationFormat: AVAudioFormat, plan: NormalizationPlan?) {
        self.engine = engine; self.player = player; format = observationFormat
        observation = AVAudioUnitEQ(numberOfBands: 0)
        chain = AudioProcessingChain(plan: plan)
        converter = AVAudioMixerNode()
        for node in [player, converter, observation, chain.levelNode] as [AVAudioNode] { engine.attach(node) }
        engine.connect(player, to: converter, format: sourceFormat)
        engine.connect(converter, to: observation, format: observationFormat)
        engine.connect(observation, to: chain.levelNode, format: observationFormat)
        engine.connect(chain.levelNode, to: engine.mainMixerNode, format: observationFormat)
    }

    /// The app volume and the sleep timer's fade change while audio flows, so they go to the main
    /// mixer, which ramps a change over about 20ms instead of stepping the waveform. The level
    /// gain steps at once and is therefore fixed before the engine starts.
    func setVolume(_ volume: Float) { engine.mainMixerNode.outputVolume = volume }

    private init(_ graph: PlaybackGraph, player: AVAudioPlayerNode) {
        engine = graph.engine; self.player = player; converter = graph.converter
        observation = graph.observation; chain = graph.chain; format = graph.format
    }

    /// The same graph for another track, with the player stopped. A source of another format gets
    /// a new player on the converter, whose input may change while the engine runs.
    func taking(sourceFormat: AVAudioFormat, plan: NormalizationPlan?) -> PlaybackGraph {
        chain.levelNode.globalGain = Float(plan?.gainDB ?? 0)
        guard player.outputFormat(forBus: 0) != sourceFormat else { return self }
        let next = AVAudioPlayerNode()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
        engine.attach(next)
        engine.connect(next, to: converter, format: sourceFormat)
        return PlaybackGraph(self, player: next)
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
