import Foundation
import Observation
import OSLog
import AnalysisCore
import AudioProcessingCore

/// The shutdown steps and their timings, never song names or paths. Console: subsystem `io.github.boyaki-machine.LC-Music-Player`.
extension Logger {
    public static let shutdown = Logger(subsystem: "io.github.boyaki-machine.LC-Music-Player", category: "shutdown")
}

@Observable
@MainActor
public final class PlaybackController {
    public private(set) var state: PlaybackState = .empty
    public private(set) var selectedURL: URL?
    public private(set) var duration: TimeInterval = 0
    public private(set) var error: PlaybackError?
    public private(set) var message = "音楽ファイルを選択してください。"
    public private(set) var volume: Float = 0.25
    public private(set) var isMuted = false
    /// An extra factor on the app volume, used by the sleep timer's fade. It never changes
    /// `volume`, so the volume remembered for each output device stays the listener's choice.
    public private(set) var fadeGain: Float = 1
    private var outputVolume: Float { volume * fadeGain }
    public private(set) var normalizationRequired = false
    public var normalizationPlan: NormalizationPlan? { normalizationReady ? backend?.normalizationPlan : nil }
    @ObservationIgnored private var normalizationReady = false

    /// A playing track plays on with the level it has until the library replaces its run, because
    /// the level gain steps at once and must not change while audio flows.
    public func requireNormalization(_ enabled: Bool) {
        normalizationRequired = enabled
        normalizationReady = false
        if !enabled, state != .playing { backend?.clearNormalization() }
    }
    public private(set) var analysisFrame: AnalysisFrame?
    /// Invalidates cached display state even when analysisFrame was already nil.
    public private(set) var analysisResetID = UUID()
    public private(set) var analysisConfiguration: AnalysisConfiguration? = try? AnalysisConfiguration()
    @ObservationIgnored private var volumeBeforeMute: Float = 0.25
    @ObservationIgnored public var onActivityChange: (@MainActor () -> Void)?
    @ObservationIgnored public var onNaturalFinish: (@MainActor () -> Void)?
    /// Called after the app volume or mute changes, including changes made by code.
    @ObservationIgnored public var onVolumeChange: (@MainActor () -> Void)?

    @ObservationIgnored private var backend: (any PlaybackBackend)?
    @ObservationIgnored private var lease: FileLease?
    @ObservationIgnored private var selectionID = UUID()
    @ObservationIgnored private let fileAccess: any FileAccess
    @ObservationIgnored private let makeBackend: @MainActor (URL) throws -> any PlaybackBackend

    public init(
        fileAccess: any FileAccess = LocalFileAccess(),
        makeBackend: @escaping @MainActor (URL) throws -> any PlaybackBackend = { try AudioEngineBackend(url: $0) }
    ) {
        self.fileAccess = fileAccess
        self.makeBackend = makeBackend
    }

    public var activeFileLease: FileLease? { lease }

    public var canPlay: Bool { selectedURL != nil }
    public var canSeek: Bool {
        backend?.supportsSeeking == true && duration.isFinite && duration > 0 && state != .failed
    }
    public var canStop: Bool { state == .playing || state == .paused }
    public var currentTime: TimeInterval {
        if state == .finished { return duration }
        let time = backend?.currentTime ?? 0
        return time.isFinite ? max(0, min(time, duration)) : 0
    }

    /// Selection is transactional: a bad file leaves the existing playback intact.
    @discardableResult
    public func select(_ url: URL, using access: FileLease? = nil, committing: () throws -> Void = {}) -> Bool {
        do {
            guard SupportedAudio.accepts(url) else { throw PlaybackError.unsupportedFormat }
            let nextLease = try access ?? fileAccess.acquire(url)
            defer { withExtendedLifetime(nextLease) {} }
            let next = try makeBackend(url)
            next.volume = outputVolume
            try committing()
            endRun(retiring: true)
            backend = next
            connectAnalysis()
            selectedURL = url
            duration = next.duration
            state = .ready
            error = nil
            message = "再生できます。"
            return true
        } catch {
            self.error = (error as? PlaybackError) ?? .loadingFailed(error.localizedDescription)
            message = "ファイルを選択できませんでした。"
            return false
        }
    }

    @discardableResult
    public func selectMetadata(url: URL, duration: Double, supportsSeeking: Bool,
                               committing: () throws -> Void = {}) -> Bool {
        do {
            guard duration.isFinite, duration > 0 else { throw PlaybackError.inaccessibleFile }
            try committing()
            endRun(retiring: true)
            backend = AudioEngineBackend(url: url, duration: duration, supportsSeeking: supportsSeeking)
            backend?.volume = outputVolume
            selectedURL = url; self.duration = duration; state = .ready
            error = nil; message = "再生できます。"; connectAnalysis()
            return true
        } catch { self.error = .loadingFailed(error.localizedDescription); return false }
    }

    /// A completed background preparation enters the same transactional selection path.
    @discardableResult
    public func selectPrepared(_ prepared: PreparedAudio, using access: FileLease,
                               metrics: TrackAudioMetrics? = nil, settings: NormalizationSettings = .standard,
                               committing: () throws -> Void = {}) -> Bool {
        do {
            guard !normalizationRequired || metrics != nil else { throw AudioProcessingFailure.missingPlan }
            let next = try AudioEngineBackend(prepared: prepared, metrics: metrics, settings: settings)
            do { try committing() } catch { next.stop(); throw error }
            endRun(retiring: true)
            backend = next
            normalizationReady = metrics != nil
            lease = access
            selectedURL = prepared.source.url
            duration = next.duration
            next.volume = outputVolume
            state = .ready
            error = nil
            message = "再生できます。"
            connectAnalysis()
            return true
        } catch {
            self.error = .loadingFailed(error.localizedDescription)
            return false
        }
    }

    public func selectionCancelled() {
        error = nil
        message = "ファイル選択を取り消しました。"
    }

    public func togglePlayPause(using access: FileLease? = nil) {
        guard let backend else { return }
        do {
            if state != .playing, normalizationRequired, !normalizationReady { throw AudioProcessingFailure.missingPlan }
            switch state {
            case .playing:
                try backend.pause()
                state = .paused
                analysisFrame = nil
                message = "一時停止中"
            case .paused:
                invalidateAnalysis()
                connectAnalysis()
                try backend.resume()
                state = .playing
                message = "再生中"
            default:
                guard let selectedURL else { return }
                lease = try access ?? lease ?? fileAccess.acquire(selectedURL)
                connectAnalysis()
                bindEvents(to: backend)
                try backend.play()
                state = .playing
                message = "再生中"
            }
            error = nil
            onActivityChange?()
        } catch {
            handle(.failed((error as? PlaybackError) ?? .playbackFailed(error.localizedDescription)))
        }
    }

    public func stop() {
        guard selectedURL != nil else { return }
        endRun()
        state = .stopped
        error = nil
        message = "停止中"
        onActivityChange?()
    }

    /// Display implementations choose their resolution/cadence; nil unsubscribes.
    public func configureAnalysis(_ configuration: AnalysisConfiguration?) {
        analysisConfiguration = configuration
        invalidateAnalysis()
        connectAnalysis()
    }

    private func connectAnalysis() {
        let id = analysisResetID
        backend?.configureAnalysis(analysisConfiguration) { [weak self] frame in
            guard let self, self.state == .playing, self.analysisResetID == id else { return }
            self.analysisFrame = frame
        }
    }

    public func setVolume(_ value: Float) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
        isMuted = false
        if volume > 0 { volumeBeforeMute = volume }
        backend?.volume = outputVolume
        onVolumeChange?()
    }

    public func setFadeGain(_ gain: Float) {
        guard gain.isFinite else { return }
        fadeGain = min(1, max(0, gain))
        backend?.volume = outputVolume
    }

    public func toggleMute() {
        if isMuted {
            isMuted = false
            volume = volumeBeforeMute
        } else {
            volumeBeforeMute = volume
            isMuted = true
            volume = 0
        }
        backend?.volume = outputVolume
        onVolumeChange?()
    }

    /// The UI previews locally and commits once. Seeking never starts idle audio.
    public func seek(to seconds: TimeInterval) {
        guard canSeek, seconds.isFinite, let backend else { return }
        let target = min(duration, max(0, seconds))
        if target == duration {
            endRun()
            state = .finished
            error = nil
            message = "再生が終了しました。"
            onActivityChange?()
            return
        }
        do {
            // Idle backends may read while seeking; hold access only for that operation.
            let temporaryAccess = try lease == nil ? selectedURL.map { try fileAccess.acquire($0) } : nil
            defer { withExtendedLifetime(temporaryAccess) {} }
            invalidateAnalysis()
            connectAnalysis()
            bindEvents(to: backend)
            try backend.seek(to: target)
            if state == .finished { state = .stopped }
            error = nil
            onActivityChange?()
        } catch {
            handle(.failed((error as? PlaybackError) ?? .playbackFailed(error.localizedDescription)))
        }
    }

    /// Releases only the current playback resource; library persistence is independent.
    public func close() {
        let logger = Logger.shutdown
        let started = ContinuousClock.now
        endRun()
        backend = nil
        logger.notice("Playback resources cleared after \(String(describing: started.duration(to: .now)), privacy: .public)")
        selectedURL = nil
        duration = 0
        state = .empty
        error = nil
        message = "音楽ファイルを選択してください。"
        onActivityChange?()
    }

    private func handle(_ event: PlaybackEvent) {
        if case .outputChanged = event { return outputChanged() }
        // A finished track is usually followed by the next, which takes over the running output.
        if case .finished = event { endRun(retiring: true) } else { endRun() }
        switch event {
        case .finished:
            state = .finished
            message = "再生が終了しました。"
            error = nil
            onNaturalFinish?()
        case .failed(let failure):
            state = .failed
            error = failure
            message = "再生が停止しました。"
        case .outputChanged: break
        }
        onActivityChange?()
    }

    /// The output changed under the track (a lost connection, another device): it pauses where it
    /// was, keeping its file access, so nothing plays on the new output until the listener resumes.
    private func outputChanged() {
        backend?.suspend()
        analysisFrame = nil
        state = .paused
        error = nil
        message = "音声出力が変わったため一時停止しました。"
        onActivityChange?()
    }

    private func bindEvents(to backend: any PlaybackBackend) {
        let id = UUID()
        selectionID = id
        backend.onEvent = { [weak self] event in
            guard let self, self.selectionID == id else { return }
            self.handle(event)
        }
    }

    /// `retiring`: another track takes over, so the old output may finish stopping elsewhere.
    private func endRun(retiring: Bool = false) {
        normalizationReady = false
        invalidateAnalysis()
        let started = ContinuousClock.now
        let hadAccess = lease != nil
        selectionID = UUID()
        backend?.onEvent = nil
        if retiring { backend?.retire() } else { backend?.stop() }
        let logger = Logger.shutdown
        if hadAccess { logger.notice("Audio run stopped after \(String(describing: started.duration(to: .now)), privacy: .public)") }
        lease = nil
        if hadAccess { logger.notice("Active file access released after \(String(describing: started.duration(to: .now)), privacy: .public)") }
    }

    private func invalidateAnalysis() { analysisFrame = nil; analysisResetID = UUID() }
}
