import Foundation
import Testing
import AudioProcessingCore
@testable import PlaybackCore

@MainActor
private final class FakeBackend: PlaybackBackend {
    let duration: TimeInterval = 12
    var supportsSeeking = true
    var seekError: PlaybackError?
    var seekCount = 0
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var bassEnhancement: BassEnhancement = .off
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var playCount = 0
    var pauseCount = 0
    var resumeCount = 0
    var stopCount = 0
    var playError: PlaybackError?

    func play() throws {
        if let playError { throw playError }
        playCount += 1
        // Preserve a prepared seek position on playback.
    }
    /// Calls that change what is heard, in order.
    var calls: [String] = []
    func pause() throws { pauseCount += 1; calls.append("pause") }
    func resume() throws { resumeCount += 1 }
    func clearNormalization() { calls.append("clearNormalization") }
    func seek(to seconds: TimeInterval) throws {
        if let seekError { throw seekError }
        seekCount += 1; currentTime = seconds
    }
    func stop() { stopCount += 1; currentTime = 0 }
    /// Keeps `currentTime`, as the engine backend keeps the position.
    func suspend() { calls.append("suspend") }
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var acquisitions = 0
    var count: Int { lock.withLock { value } }
    var activeCount: Int { lock.withLock { acquisitions - value } }
    func acquired() { lock.withLock { acquisitions += 1 } }
    func increment() { lock.withLock { value += 1 } }
}

@MainActor
private struct FakeAccess: FileAccess {
    var failure: PlaybackError?
    let releases: ReleaseCounter
    var denied: @MainActor () -> Bool = { false }
    func acquire(_ url: URL) throws -> FileLease {
        if denied() { throw PlaybackError.inaccessibleFile }
        if let failure { throw failure }
        releases.acquired()
        return FileLease { releases.increment() }
    }
}

@Suite @MainActor
struct PlaybackControllerTests {
    private let first = URL(fileURLWithPath: "/tmp/first.wav")
    private let second = URL(fileURLWithPath: "/tmp/second.flac")

    @Test func idleStatesReleaseAccessWhilePauseRetainsIt() {
        let backend = FakeBackend(), releases = ReleaseCounter()
        let controller = PlaybackController(fileAccess: FakeAccess(releases: releases), makeBackend: { _ in backend })
        controller.select(first)
        #expect(releases.activeCount == 0 && controller.canPlay && controller.canSeek)
        controller.seek(to: 3)
        #expect(releases.activeCount == 0 && controller.currentTime == 3)
        for _ in 0..<4 {
            controller.togglePlayPause()
            #expect(releases.activeCount == 1)
            controller.togglePlayPause()
            #expect(controller.state == .paused && releases.activeCount == 1)
            controller.togglePlayPause()
            backend.onEvent?(.finished)
            #expect(controller.state == .finished && releases.activeCount == 0 && backend.onEvent == nil)
            #expect(controller.selectedURL == first && controller.duration == 12)
        }
        controller.seek(to: 5)
        #expect(controller.state == .stopped && controller.currentTime == 5 && releases.activeCount == 0)
        controller.togglePlayPause(); controller.stop()
        #expect(controller.state == .stopped && releases.activeCount == 0)
        controller.togglePlayPause(); backend.onEvent?(.outputChanged)
        #expect(controller.state == .paused && releases.activeCount == 1)
        controller.stop(); controller.togglePlayPause(); backend.onEvent?(.failed(.playbackFailed("test")))
        #expect(releases.activeCount == 0)
        controller.close()
        #expect(releases.activeCount == 0)
    }

    /// The level gain steps at once, so turning the volume adjustment off never changes it while
    /// audio flows: a playing track keeps its level until the library replaces its run.
    @Test func turningOffTheVolumeAdjustmentNeverChangesTheGainWhileAudioFlows() {
        let backend = FakeBackend()
        let controller = PlaybackController(fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend })
        controller.select(first)
        controller.togglePlayPause()
        #expect(controller.state == .playing)
        controller.requireNormalization(false)
        #expect(controller.state == .playing && backend.calls.isEmpty)
        controller.togglePlayPause()
        controller.requireNormalization(false)
        #expect(controller.state == .paused && backend.calls == ["pause", "clearNormalization"])
    }

    @Test func lostAccessOnRestartFailsWithoutOpeningAudioAndCanBeRetried() {
        let backend = FakeBackend(), releases = ReleaseCounter()
        var denied = false
        let controller = PlaybackController(fileAccess: FakeAccess(releases: releases, denied: { denied }), makeBackend: { _ in backend })
        controller.select(first)
        denied = true
        controller.togglePlayPause()
        #expect(controller.state == .failed && backend.playCount == 0 && releases.activeCount == 0)
        denied = false
        controller.togglePlayPause()
        #expect(controller.state == .playing && backend.playCount == 1 && releases.activeCount == 1)
        controller.stop()
        denied = true; controller.seek(to: 2)
        #expect(controller.state == .failed && releases.activeCount == 0)
    }

    @Test func playPauseResumeStopAndReplay() {
        let backend = FakeBackend()
        let controller = PlaybackController(
            fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend }
        )
        #expect(!controller.canPlay)
        controller.select(first)
        #expect(controller.state == .ready)
        controller.togglePlayPause()
        #expect(controller.state == .playing)
        backend.currentTime = 4
        controller.togglePlayPause()
        #expect(controller.state == .paused)
        #expect(controller.currentTime == 4)
        controller.togglePlayPause()
        #expect(controller.state == .playing)
        #expect(backend.resumeCount == 1)
        controller.stop()
        #expect(controller.state == .stopped)
        #expect(controller.currentTime == 0)
        controller.togglePlayPause()
        #expect(backend.playCount == 2)
        #expect(backend.pauseCount == 1)
    }

    @Test func cancellationAndFailedSelectionPreserveCurrentPlayback() {
        let backend = FakeBackend()
        let releases = ReleaseCounter()
        let controller = PlaybackController(fileAccess: FakeAccess(releases: releases)) { url in
            if url == second { throw PlaybackError.loadingFailed("破損") }
            return backend
        }
        controller.select(first)
        controller.togglePlayPause()
        backend.currentTime = 3
        controller.selectionCancelled()
        #expect(controller.state == .playing)
        #expect(controller.currentTime == 3)
        controller.select(URL(fileURLWithPath: "/tmp/music.dsf"))
        #expect(controller.error == .unsupportedFormat)
        controller.select(second)
        #expect(controller.error == .loadingFailed("破損"))
        #expect(controller.selectedURL == first)
        #expect(controller.state == .playing)
        #expect(controller.currentTime == 3)
        #expect(releases.activeCount == 1)
    }

    @Test func inaccessibleFileDoesNotCreatePlayer() {
        var attempts = 0
        let controller = PlaybackController(
            fileAccess: FakeAccess(failure: .inaccessibleFile, releases: ReleaseCounter())
        ) { _ in attempts += 1; return FakeBackend() }
        controller.select(first)
        #expect(controller.error == .inaccessibleFile)
        #expect(controller.state == .empty)
        #expect(attempts == 0)
        #expect(!controller.canPlay)
    }

    @Test func switchingTracksStopsOldPlaybackAndReleasesAccess() {
        let old = FakeBackend()
        let next = FakeBackend()
        let releases = ReleaseCounter()
        let controller = PlaybackController(fileAccess: FakeAccess(releases: releases)) { url in
            url == first ? old : next
        }
        controller.select(first)
        controller.togglePlayPause()
        let lateCallback = old.onEvent
        controller.select(second)
        controller.togglePlayPause()
        #expect(old.stopCount == 1)
        #expect(releases.activeCount == 1)
        lateCallback?(.failed(.playbackFailed("古い通知")))
        #expect(controller.state == .playing)
        #expect(controller.error == nil)
        #expect(controller.selectedURL == second)
        controller.close()
        #expect(releases.activeCount == 0)
        #expect(next.stopCount == 1)
        #expect(controller.state == .empty)
    }

    @Test func lateCompletionAfterStopOrReplayDoesNotEndCurrentRun() {
        let backend = FakeBackend()
        let controller = PlaybackController(
            fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend }
        )
        controller.select(first)
        controller.togglePlayPause()
        let lateCallback = backend.onEvent
        controller.stop()
        lateCallback?(.finished)
        #expect(controller.state == .stopped)
        controller.togglePlayPause()
        lateCallback?(.finished)
        #expect(controller.state == .playing)
        backend.onEvent?(.finished)
        #expect(controller.state == .finished)
        #expect(controller.currentTime == 12)
        controller.togglePlayPause()
        #expect(controller.currentTime == 0)
        #expect(backend.playCount == 3)
    }

    @Test func synchronousAndAsynchronousErrorsAllowRetry() {
        let backend = FakeBackend()
        let controller = PlaybackController(
            fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend }
        )
        controller.select(first)
        backend.playError = .playbackFailed("出力なし")
        controller.togglePlayPause()
        #expect(controller.state == .failed)
        #expect(controller.error == .playbackFailed("出力なし"))
        backend.playError = nil
        controller.togglePlayPause()
        #expect(controller.state == .playing)
        backend.onEvent?(.failed(.playbackFailed("デコード失敗")))
        #expect(controller.state == .failed)
        controller.togglePlayPause()
        #expect(controller.error == nil)
        #expect(controller.state == .playing)
    }

    /// A lost connection or another device pauses where the track was, and only the listener resumes it.
    @Test func outputChangePausesAtThePositionUntilUserResumes() {
        let backend = FakeBackend()
        let controller = PlaybackController(
            fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend }
        )
        controller.select(first)
        controller.togglePlayPause()
        backend.currentTime = 7
        backend.onEvent?(.outputChanged)
        #expect(controller.state == .paused && controller.currentTime == 7)
        #expect(controller.canStop && backend.calls == ["suspend"] && backend.stopCount == 0)
        #expect(controller.message.contains("音声出力") && controller.analysisFrame == nil)
        controller.togglePlayPause()
        #expect(controller.state == .playing && backend.resumeCount == 1 && controller.currentTime == 7)
        // While paused, it stays paused.
        controller.togglePlayPause()
        backend.onEvent?(.outputChanged)
        #expect(controller.state == .paused && backend.calls == ["suspend", "pause", "suspend"])
    }

    @Test func theBassEnhancementReachesTheNextAndThePlayingBackend() {
        var backends: [FakeBackend] = []
        let controller = PlaybackController(
            fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in let b = FakeBackend(); backends.append(b); return b }
        )
        controller.setBassEnhancement(.strong)
        controller.select(first)
        #expect(backends.last?.bassEnhancement == .strong)
        controller.togglePlayPause()
        controller.setBassEnhancement(.light)
        #expect(controller.bassEnhancement == .light && backends.last?.bassEnhancement == .light)
        #expect(backends.last?.playCount == 1 && backends.last?.calls.isEmpty == true, "the track plays on")
        controller.select(second)
        #expect(backends.count == 2 && backends.last?.bassEnhancement == .light)
    }

    @Test func volumeIsClampedAndNonfiniteValuesAreIgnored() {
        let backend = FakeBackend()
        let controller = PlaybackController(
            fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend }
        )
        controller.setVolume(0.4)
        controller.select(first)
        #expect(backend.volume == 0.4)
        controller.setVolume(2)
        #expect(backend.volume == 1)
        controller.setVolume(-2)
        #expect(backend.volume == 0)
        controller.setVolume(.nan)
        controller.setVolume(.infinity)
        #expect(backend.volume == 0)
    }

    @Test func seekPreservesTransportAndInvalidatesOldNotifications() {
        let backend = FakeBackend()
        let controller = PlaybackController(fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend })
        controller.seek(to: 3)
        #expect(backend.seekCount == 0)
        controller.select(first)
        controller.seek(to: 3)
        #expect(controller.state == .ready && controller.currentTime == 3)
        controller.togglePlayPause()
        let oldCallback = backend.onEvent
        controller.seek(to: 8)
        oldCallback?(.finished)
        #expect(controller.state == .playing && controller.currentTime == 8)
        controller.togglePlayPause()
        controller.seek(to: 5)
        #expect(controller.state == .paused && controller.currentTime == 5)
        controller.togglePlayPause()
        #expect(controller.state == .playing)
        controller.stop()
        controller.seek(to: 6)
        #expect(controller.state == .stopped && controller.currentTime == 6)
        controller.seek(to: 12)
        #expect(controller.state == .finished && controller.currentTime == 12)
        controller.seek(to: 4)
        #expect(controller.state == .stopped && controller.currentTime == 4)
        controller.select(second)
        #expect(controller.currentTime == 0)
    }

    @Test func seekBoundsUnsupportedAndFailures() {
        let backend = FakeBackend()
        let controller = PlaybackController(fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend })
        controller.select(first)
        controller.seek(to: -8)
        #expect(controller.currentTime == 0)
        controller.seek(to: .nan); controller.seek(to: .infinity)
        #expect(backend.seekCount == 1)
        backend.supportsSeeking = false
        #expect(!controller.canSeek)
        controller.seek(to: 5)
        #expect(backend.seekCount == 1)
        backend.supportsSeeking = true
        backend.seekError = .playbackFailed("シーク失敗")
        controller.seek(to: 4)
        #expect(controller.state == .failed)
        #expect(controller.error == backend.seekError)
        #expect(!controller.canSeek)
        backend.seekError = nil
        controller.togglePlayPause()
        #expect(controller.state == .playing && controller.error == nil)
    }

    @Test func muteRestoresPreviousVolumeAndManualAdjustmentUnmutes() {
        let backend = FakeBackend()
        let controller = PlaybackController(fileAccess: FakeAccess(releases: ReleaseCounter()), makeBackend: { _ in backend })
        controller.setVolume(0.6); controller.select(first)
        controller.toggleMute()
        #expect(controller.isMuted && controller.volume == 0 && backend.volume == 0)
        controller.select(second)
        #expect(backend.volume == 0)
        controller.toggleMute()
        #expect(!controller.isMuted && controller.volume == 0.6 && backend.volume == 0.6)
        controller.toggleMute(); controller.setVolume(0.3)
        #expect(!controller.isMuted && backend.volume == 0.3)
        controller.toggleMute(); controller.toggleMute()
        #expect(controller.volume == 0.3)
    }

    @Test func localFileAccessRejectsFoldersAndMissingFiles() throws {
        let access = LocalFileAccess()
        #expect(throws: PlaybackError.inaccessibleFile) { try access.acquire(URL(fileURLWithPath: "/tmp")) }
        #expect(throws: PlaybackError.inaccessibleFile) {
            try access.acquire(URL(fileURLWithPath: "/tmp/lcmp-missing-\(UUID()).wav"))
        }
    }
}
