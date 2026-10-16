import AVFAudio
import Foundation
import SFBAudioEngine
import AnalysisCore

@MainActor
public final class SFBAudioBackend: PlaybackBackend {
    isolated deinit { stop() }

    public let duration: TimeInterval
    public let supportsSeeking: Bool
    public var currentTime: TimeInterval { player?.currentTime ?? pendingTime }
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    public var volume: Float = 0.25 {
        didSet { player?.mainMixerNode.outputVolume = volume }
    }

    private let url: URL
    private var preparedDecoder: (any PCMDecoding)?
    private var player: AudioPlayer?
    private var delegate: PlayerDelegate?
    private var runID: UUID?
    private var pendingTime: TimeInterval = 0
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
        if player != nil && !paused { startAnalysis() }
    }

    private func startAnalysis() {
        guard player != nil, let node = analysisNode,
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

    public init(prepared: PreparedAudio) throws {
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
            let decoder: any PCMDecoding
            if let preparedDecoder {
                decoder = preparedDecoder
                self.preparedDecoder = nil
            } else { decoder = try AudioDecoderFactory.open(url) }
            if seconds > 0 {
                let frame = AVAudioFramePosition(seconds * decoder.processingFormat.sampleRate)
                do { try decoder.seek(to: min(frame, decoder.length - 1)) }
                catch { try? decoder.close(); throw error }
            }
            let next = AudioPlayer()
            let id = UUID()
            let nextDelegate = PlayerDelegate { [weak self] event in
                guard let self, self.runID == id else { return }
                self.onEvent?(event)
            }
            // Retire the old run before transferring the prepared decoder.
            stop()
            pendingTime = seconds
            runID = id
            player = next
            delegate = nextDelegate
            next.delegate = nextDelegate
            next.mainMixerNode.outputVolume = volume
            // Zero filters, zero global gain: a pass-through AU with a public
            // render-notification API. Future compensation belongs downstream.
            let observation = AVAudioUnitEQ(numberOfBands: 0)
            let converter = AVAudioMixerNode()
            let outputFormat = next.mainMixerNode.outputFormat(forBus: 0)
            guard let observationFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate,
                                                         channels: outputFormat.channelCount) else {
                try? decoder.close()
                throw PlaybackError.playbackFailed("解析接続用の音声形式を作成できません。")
            }
            next.modifyProcessingGraph { engine in
                // Keep SFB's initial source format: SFB must reconfigure its own
                // decoder ring before changing it. The mixer accepts that change.
                let sourceFormat = next.sourceNode.outputFormat(forBus: 0)
                engine.attach(converter)
                engine.attach(observation)
                engine.disconnectNodeOutput(next.sourceNode)
                engine.connect(next.sourceNode, to: converter, format: sourceFormat)
                engine.connect(converter, to: observation, format: observationFormat)
                engine.connect(observation, to: engine.mainMixerNode, format: observationFormat)
            }
            analysisNode = observation
            try next.play(decoder)
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
        if player != nil && !paused {
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
        guard let player, player.pause() else {
            throw PlaybackError.playbackFailed("一時停止できませんでした。")
        }
        paused = true
        endAnalysis()
    }

    public func resume() throws {
        if player == nil && paused { try start(at: pendingTime); return }
        guard let player, player.resume() else {
            throw PlaybackError.playbackFailed("再開できませんでした。")
        }
        paused = false
        startAnalysis()
    }

    public func stop() {
        try? preparedDecoder?.close()
        preparedDecoder = nil
        endAnalysis()
        pendingTime = 0
        paused = false
        runID = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        analysisSource = nil
        analysisNode = nil
        delegate = nil
    }
}

/// SFBAudioEngine callbacks may arrive on any queue. Only immutable Sendable
/// events cross to the main actor; decoders are never accessed after enqueue.
private final class PlayerDelegate: NSObject, AudioPlayer.Delegate, Sendable {
    let receive: @MainActor @Sendable (PlaybackEvent) -> Void

    init(receive: @escaping @MainActor @Sendable (PlaybackEvent) -> Void) {
        self.receive = receive
    }

    private func send(_ event: PlaybackEvent) {
        Task { @MainActor [receive] in receive(event) }
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        send(.finished)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        send(.failed(.playbackFailed(error.localizedDescription)))
    }

    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        decodingAborted decoder: any PCMDecoding,
        error: Error,
        framesRendered: AVAudioFramePosition
    ) {
        send(.failed(.playbackFailed(error.localizedDescription)))
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, audioEngineConfigurationChange userInfo: [AnyHashable: Any]?) {
        send(.outputChanged)
    }
}
