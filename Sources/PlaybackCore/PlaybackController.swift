import Foundation
import Observation

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
    @ObservationIgnored private var volumeBeforeMute: Float = 0.25

    @ObservationIgnored private var backend: (any PlaybackBackend)?
    @ObservationIgnored private var lease: FileLease?
    @ObservationIgnored private var selectionID = UUID()
    @ObservationIgnored private let fileAccess: any FileAccess
    @ObservationIgnored private let makeBackend: @MainActor (URL) throws -> any PlaybackBackend

    public init(
        fileAccess: any FileAccess = LocalFileAccess(),
        makeBackend: @escaping @MainActor (URL) throws -> any PlaybackBackend = { try SFBAudioBackend(url: $0) }
    ) {
        self.fileAccess = fileAccess
        self.makeBackend = makeBackend
    }

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
    public func select(_ url: URL) {
        do {
            guard SupportedAudio.accepts(url) else { throw PlaybackError.unsupportedFormat }
            let nextLease = try fileAccess.acquire(url)
            let next = try makeBackend(url)
            next.volume = volume
            endRun()
            backend = next
            lease = nextLease
            selectedURL = url
            duration = next.duration
            state = .ready
            error = nil
            message = "再生できます。"
        } catch {
            self.error = (error as? PlaybackError) ?? .loadingFailed(error.localizedDescription)
            message = "ファイルを選択できませんでした。"
        }
    }

    public func selectionCancelled() {
        error = nil
        message = "ファイル選択を取り消しました。"
    }

    public func togglePlayPause() {
        guard let backend else { return }
        do {
            switch state {
            case .playing:
                try backend.pause()
                state = .paused
                message = "一時停止中"
            case .paused:
                try backend.resume()
                state = .playing
                message = "再生中"
            default:
                bindEvents(to: backend)
                try backend.play()
                state = .playing
                message = "再生中"
            }
            error = nil
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
    }

    public func setVolume(_ value: Float) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
        isMuted = false
        if volume > 0 { volumeBeforeMute = volume }
        backend?.volume = volume
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
        backend?.volume = volume
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
            return
        }
        do {
            bindEvents(to: backend)
            try backend.seek(to: target)
            if state == .finished { state = .stopped }
            error = nil
        } catch {
            handle(.failed((error as? PlaybackError) ?? .playbackFailed(error.localizedDescription)))
        }
    }

    /// Called on app termination. No bookmarks or library entries are persisted.
    public func close() {
        endRun()
        backend = nil
        lease = nil
        selectedURL = nil
        duration = 0
        state = .empty
        error = nil
        message = "音楽ファイルを選択してください。"
    }

    private func handle(_ event: PlaybackEvent) {
        endRun()
        switch event {
        case .finished:
            state = .finished
            message = "再生が終了しました。"
            error = nil
        case .failed(let failure):
            state = .failed
            error = failure
            message = "再生が停止しました。"
        case .outputChanged:
            state = .stopped
            error = nil
            message = "音声出力の設定が変わりました。再生ボタンで先頭から再開できます。"
        }
    }

    private func bindEvents(to backend: any PlaybackBackend) {
        let id = UUID()
        selectionID = id
        backend.onEvent = { [weak self] event in
            guard let self, self.selectionID == id else { return }
            self.handle(event)
        }
    }

    private func endRun() {
        selectionID = UUID()
        backend?.onEvent = nil
        backend?.stop()
    }
}
