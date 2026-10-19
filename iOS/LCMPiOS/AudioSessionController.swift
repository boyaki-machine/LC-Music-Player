import AVFAudio
import MediaPlayer
import UIKit
import Observation
import PlaybackCore
import LibraryCore

/// The iOS audio session, interruptions, and the lock screen / Control Center transport.
/// The system "Now Playing" shows only the app name and icon and no elapsed time, so other
/// people cannot read what is playing.
@MainActor final class AudioSessionController {
    private let playback: PlaybackController
    private let library: LibraryController
    private var observers: [any NSObjectProtocol] = []
    /// The app icon in place of song artwork (an app's own icon cannot be loaded as an image).
    private let artwork: MPMediaItemArtwork? = UIImage(named: "NowPlayingArtwork").map { image in
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    init(playback: PlaybackController, library: LibraryController) {
        self.playback = playback
        self.library = library
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                object: nil, queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { if began { self?.interrupted() } }
        })
        installRemoteCommands()
        track()
    }

    /// A call or another app's audio pauses playback. It never resumes by itself.
    private func interrupted() {
        if playback.state == .playing { library.togglePlayPause() }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AudioSessionController) -> Bool) {
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return .commandFailed }
                    return action(self) ? .success : .commandFailed
                }
            }
        }
        handle(center.playCommand) { $0.playback.state == .playing || $0.toggle() }
        handle(center.pauseCommand) { $0.playback.state != .playing || $0.toggle() }
        handle(center.togglePlayPauseCommand) { $0.toggle() }
        handle(center.stopCommand) { $0.library.stop(); return true }
        handle(center.nextTrackCommand) { $0.library.canNext ? ($0.library.next(), true).1 : false }
        handle(center.previousTrackCommand) { $0.library.canPrevious ? ($0.library.previous(), true).1 : false }
        for command in [center.changePlaybackPositionCommand, center.skipForwardCommand, center.skipBackwardCommand,
                        center.seekForwardCommand, center.seekBackwardCommand] { command.isEnabled = false }
    }
    private func toggle() -> Bool {
        guard playback.canPlay else { return false }
        library.togglePlayPause(); return true
    }

    /// Follows the playback state with Observation and mirrors it to the session and Now Playing.
    private func track() {
        withObservationTracking { _ = playback.state } onChange: { [weak self] in
            Task { @MainActor in self?.stateChanged(); self?.track() }
        }
        stateChanged()
    }
    private func nowPlaying(rate: Double) -> [String: Any] {
        var values: [String: Any] = [MPMediaItemPropertyTitle: "LC Music Player", MPNowPlayingInfoPropertyPlaybackRate: rate]
        if let artwork { values[MPMediaItemPropertyArtwork] = artwork }
        return values
    }
    private func stateChanged() {
        let info = MPNowPlayingInfoCenter.default()
        switch playback.state {
        case .playing:
            try? AVAudioSession.sharedInstance().setActive(true)
            info.nowPlayingInfo = nowPlaying(rate: 1)
            info.playbackState = .playing
        case .paused:
            info.nowPlayingInfo = nowPlaying(rate: 0)
            info.playbackState = .paused
        case .stopped:
            // Only an explicit stop hands the audio back; a finished track may be followed by the next.
            info.playbackState = .stopped
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        default:
            info.playbackState = .stopped
        }
    }
}
