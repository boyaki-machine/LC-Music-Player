import AVFAudio
import Foundation
import Testing
import PreprocessingCore
import AudioProcessingCore
@testable import PlaybackCore
@testable import LibraryCore

/// A real worker whose level measurements fail as if the output changed while they ran.
private actor OutputChangingPreprocessor: AudioPreprocessing {
    let worker = AudioPreprocessor()
    var changes: Int
    var levelCalls = 0
    init(changes: Int) { self.changes = changes }
    func prepare(_ url: URL, cancellation: PreparationCancellation, seconds: Double, byteLimit: Int) async throws -> PreparedAudio {
        try await worker.prepare(url, cancellation: cancellation, seconds: seconds, byteLimit: byteLimit)
    }
    func measureLevels(_ url: URL, profile: MeasurementProfile, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackAudioMetrics {
        levelCalls += 1
        if changes > 0 { changes -= 1; throw AudioProcessingFailure.outputChanged }
        return try await worker.measureLevels(url, profile: profile, cancellation: cancellation, ownerID: ownerID)
    }
    func measure(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackPeak {
        try await worker.measure(url, cancellation: cancellation, ownerID: ownerID)
    }
    func reconcileCacheOwners(_ owners: Set<UUID>) async { await worker.reconcileCacheOwners(owners) }
}

/// With the volume normalized, a change of the output while a track is prepared does not stop playback:
/// the track is measured again for the output it has then, and plays.
@Suite(.serialized) @MainActor struct OutputChangeSelectionTests {
    /// The output changes while the track is measured; after the retries run out, the failure is shown
    /// and playing again prepares the track again.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"), arguments: [1, 3, 4])
    func aMeasurementOnAChangingOutputIsMadeAgain(changes: Int) async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = try audioFile(fixture.root, name: "a.wav", duration: 5), b = try audioFile(fixture.root, name: "b.wav", duration: 5)
        let worker = OutputChangingPreprocessor(changes: changes)
        let playback = PlaybackController(); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(), preprocessingEnabled: true,
                                      preferences: MemoryPreferences(), preprocessor: worker)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list)
        model.setNormalizesVolume(true)
        model.playPlaylist(list)
        if changes <= LibraryController.outputChangeRetries {
            try await wait { playback.state == .playing && model.currentIndex == 0 }
            #expect(model.error == nil && playback.normalizationPlan != nil)
            #expect(await worker.levelCalls == changes + 1)
        } else {
            try await wait(seconds: 3) { !model.isPreparing && model.error != nil }
            #expect(playback.state != .playing)
            #expect(await worker.levelCalls == LibraryController.outputChangeRetries + 1)
            model.playPlaylist(list)
            try await wait { playback.state == .playing && model.error == nil }
        }
        model.next()
        try await wait { playback.state == .playing && model.currentIndex == 1 }
    }

    /// The reported failure: a profile read in the moment the output changed, kept for the new device,
    /// measured every track for the old format, and every start failed on it. The start forgets it,
    /// the track is measured for the output's real format and plays, and so does the next.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func aProfileKeptForTheWrongFormatDoesNotStopPlayback() async throws {
        AudioEngineBackend.forgetProfile(); defer { AudioEngineBackend.forgetProfile() }
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = try audioFile(fixture.root, name: "a.wav", duration: 5), b = try audioFile(fixture.root, name: "b.wav", duration: 5)
        let worker = OutputChangingPreprocessor(changes: 0)
        let playback = PlaybackController(); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(), preprocessingEnabled: true,
                                      preferences: MemoryPreferences(), preprocessor: worker)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list)
        let actual = try AudioEngineBackend.measurementProfile()
        let other = try MeasurementProfile(sampleRate: actual.sampleRate == 48000 ? 44100 : 48000, channels: actual.channels)
        let current = try #require(OutputSignature.current())
        AudioEngineBackend.forgetProfile()
        _ = try AudioEngineBackend.cachedProfile(for: OutputSignature(values: current.values, sampleRate: other.sampleRate)) { other }
        model.setNormalizesVolume(true)
        model.playPlaylist(list)
        try await wait { playback.state == .playing && model.currentIndex == 0 }
        #expect(model.error == nil && model.currentTrackMetrics?.profile == actual)
        model.next()
        try await wait { playback.state == .playing && model.currentIndex == 1 }
        #expect(model.error == nil && model.currentTrackMetrics?.profile == actual)
    }

    /// The reported steps: the output changes while the track plays, which pauses it; the kept profile still
    /// fits its levels, but the new output's engine renders another format. Pressing play once measures the
    /// track for that format and resumes it where it paused.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func resumingOnAnotherFormatMeasuresAgainAndPlaysOn() async throws {
        AudioEngineBackend.forgetProfile()
        defer { AudioEngineBackend.engineProfileOverride = nil; AudioEngineBackend.forgetProfile() }
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = try audioFile(fixture.root, name: "a.wav", duration: 8), b = try audioFile(fixture.root, name: "b.wav", duration: 5)
        let worker = OutputChangingPreprocessor(changes: 0)
        let playback = PlaybackController(); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(), preprocessingEnabled: true,
                                      preferences: MemoryPreferences(), preprocessor: worker)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list)
        model.setNormalizesVolume(true)
        model.playPlaylist(list)
        try await wait { playback.state == .playing && model.currentIndex == 0 }
        let actual = try #require(model.currentTrackMetrics?.profile)
        let other = try MeasurementProfile(sampleRate: actual.sampleRate == 48000 ? 44100 : 48000, channels: actual.channels)
        try await Task.sleep(for: .seconds(1))
        let engine = try #require((playback.backend as? AudioEngineBackend)?.currentEngine)
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await wait { playback.state == .paused }
        let paused = playback.currentTime
        AudioEngineBackend.engineProfileOverride = other
        model.togglePlayPause()
        try await wait { playback.state == .playing && !model.isPreparing }
        #expect(model.error == nil && model.currentIndex == 0 && model.currentTrackMetrics?.profile == other)
        #expect(playback.currentTime >= paused - 0.3 && playback.currentTime < paused + 1, "paused \(paused) now \(playback.currentTime)")
    }

    /// The steps of the second report: the playlist's sweep hears of the new output before the engine stops,
    /// and measures the current track for it. The levels shown then fit the output, but the track still
    /// plays with the old ones, so pressing play prepares it for the output instead of resuming on the old.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
    func aSweepThatMeasuredForTheNewOutputDoesNotMakeTheResumeFail() async throws {
        AudioEngineBackend.forgetProfile()
        defer { AudioEngineBackend.engineProfileOverride = nil; AudioEngineBackend.forgetProfile() }
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = try audioFile(fixture.root, name: "a.wav", duration: 8), b = try audioFile(fixture.root, name: "b.wav", duration: 5)
        let worker = OutputChangingPreprocessor(changes: 0)
        let playback = PlaybackController(); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(), preprocessingEnabled: true,
                                      playlistPreprocessingEnabled: true, preferences: MemoryPreferences(), preprocessor: worker)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list)
        model.setNormalizesVolume(true)
        model.playPlaylist(list)
        try await wait { playback.state == .playing && model.currentIndex == 0 }
        let actual = try #require(playback.normalizationPlan?.profile)
        let other = try MeasurementProfile(sampleRate: actual.sampleRate == 48000 ? 44100 : 48000, channels: actual.channels)
        AudioEngineBackend.engineProfileOverride = other; AudioEngineBackend.forgetProfile()
        try #require(model.playlistPreprocessing).outputChanged()
        try await wait { model.currentTrackMetrics?.profile == other }
        let engine = try #require((playback.backend as? AudioEngineBackend)?.currentEngine)
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await wait { playback.state == .paused }
        model.togglePlayPause()
        #expect(playback.error == nil && model.isPreparing)
        try await wait { playback.state == .playing && !model.isPreparing }
        #expect(model.error == nil && playback.normalizationPlan?.profile == other)
    }

    private func wait(seconds: Double = 5, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }
}
