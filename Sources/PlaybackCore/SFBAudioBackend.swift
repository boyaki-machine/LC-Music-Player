import AVFAudio
import Foundation
import SFBAudioEngine

@MainActor
public final class SFBAudioBackend: PlaybackBackend {
    public let duration: TimeInterval
    public let supportsSeeking: Bool
    public var currentTime: TimeInterval { player?.currentTime ?? pendingTime }
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    public var volume: Float = 0.25 {
        didSet { player?.mainMixerNode.outputVolume = volume }
    }

    private let url: URL
    private var player: AudioPlayer?
    private var delegate: PlayerDelegate?
    private var runID: UUID?
    private var pendingTime: TimeInterval = 0
    private var paused = false

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
            let decoder = try AudioDecoderFactory.open(url)
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
            try next.play(decoder)
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
            stop()
            pendingTime = seconds
            paused = wasPaused
        }
    }

    public func pause() throws {
        guard let player, player.pause() else {
            throw PlaybackError.playbackFailed("一時停止できませんでした。")
        }
        paused = true
    }

    public func resume() throws {
        if player == nil && paused { try start(at: pendingTime); return }
        guard let player, player.resume() else {
            throw PlaybackError.playbackFailed("再開できませんでした。")
        }
        paused = false
    }

    public func stop() {
        pendingTime = 0
        paused = false
        runID = nil
        player?.delegate = nil
        player?.stop()
        player = nil
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
