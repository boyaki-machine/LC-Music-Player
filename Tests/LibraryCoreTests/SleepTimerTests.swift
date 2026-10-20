import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

@Suite struct SleepTimerTests {
    @Test func fadeFallsEvenlyInDecibelsFromFullVolumeToTheEnd() {
        var timer = SleepTimer(count: 3)
        #expect(timer.gain(currentFraction: 0) == 1 && timer.remainingSongs == 3 && !timer.isOnLastSong)
        func decibels(_ gain: Float) -> Double { 20 * log10(Double(gain)) }
        #expect(abs(decibels(timer.gain(currentFraction: 0.75)) + 7.5) < 0.01)
        timer.songChanged(); timer.songChanged()
        #expect(timer.remainingSongs == 1 && timer.isOnLastSong)
        #expect(abs(decibels(timer.gain(currentFraction: 0.5)) + 25) < 0.01)
        #expect(abs(decibels(timer.gain(currentFraction: 1)) + SleepTimer.finalAttenuationDB) < 0.01)
        // Steadily lower, never back up, while the songs play through.
        var previous: Float = 2
        var walk = SleepTimer(count: 2)
        for song in 0..<2 {
            for step in 0...10 {
                let gain = walk.gain(currentFraction: Double(step) / 10)
                #expect(gain <= previous); previous = gain
            }
            if song == 0 { walk.songChanged() }
        }
    }

    @Test func timerStartedMidSongBeginsAtFullVolumeAndAShorterCountFinishesTheCurrentSong() {
        var timer = SleepTimer(count: 1, startFraction: 0.8)
        #expect(timer.gain(currentFraction: 0.8) == 1)
        #expect(timer.progress(currentFraction: 0.9) > 0.49 && timer.progress(currentFraction: 0.9) < 0.51)
        #expect(timer.progress(currentFraction: 0.5) == 0)
        timer = SleepTimer(count: 5)
        timer.songChanged(); timer.songChanged()
        timer.setCount(1)
        #expect(timer.count == 3 && timer.isOnLastSong)
        #expect(SleepTimer(count: 0).count == 1)
    }
}

@Suite(.serialized) @MainActor struct SleepTimerPlaybackTests {
    private func model(_ fixture: Fixture, count: Int, preferences: MemoryPreferences = MemoryPreferences())
        async throws -> (LibraryController, PlaybackController, () -> TestBackend?) {
        var backends: [TestBackend] = []
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); backends.append(b); return b })
        let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(),
                                      preferences: preferences, sleepFadeInterval: .milliseconds(5))
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles(try (0..<count).map { try fixture.file("\($0).wav") }, into: list)
        return (model, playback, { backends.last })
    }

    @Test func stopsAfterTheChosenSongsCountingTheCurrentOneAndReportsTheEnd() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let preferences = MemoryPreferences()
        let (model, playback, backend) = try await model(fixture, count: 5, preferences: preferences)
        defer { model.shutdown() }
        var finished = 0
        model.onSleepTimerFinished = { finished += 1 }
        model.playPlaylist(try #require(model.document.currentPlaylistID))
        model.setSleepTimerCount(2)
        #expect(model.sleepTimer?.remainingSongs == 2 && preferences.object(forKey: "sleepTimerSongCount") as? Int == 2)
        backend()?.onEvent?(.finished)
        #expect(model.currentIndex == 1 && playback.state == .playing && model.sleepTimer?.remainingSongs == 1)
        backend()?.onEvent?(.finished)
        #expect(model.currentIndex == 1 && playback.state == .stopped)
        #expect(finished == 1 && model.sleepTimer == nil && playback.fadeGain == 1)
        // The choice is kept, but the timer itself starts off again.
        let next = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: MemoryStore(),
                                     references: TestReferences(), preferences: preferences)
        #expect(next.sleepTimerCount == 2 && next.sleepTimer == nil)
    }

    @Test func fadeLowersOnlyTheOutputAndTurningItOffRestoresTheVolume() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (model, playback, backend) = try await model(fixture, count: 3)
        defer { model.shutdown() }
        model.playPlaylist(try #require(model.document.currentPlaylistID))
        playback.setVolume(0.5)
        model.setSleepTimerCount(1)
        let output = try #require(backend())
        try await sleepWait { abs(output.volume - 0.5) < 0.001 }
        output.currentTime = 5
        // Halfway through the only song: 15dB down.
        try await sleepWait { abs(output.volume - 0.5 * Float(pow(10, -15.0 / 20))) < 0.001 }
        #expect(playback.volume == 0.5)
        playback.setVolume(0.4)
        #expect(abs(output.volume - 0.4 * playback.fadeGain) < 0.001)
        model.setSleepTimer(false)
        #expect(output.volume == 0.4 && playback.fadeGain == 1)
        output.onEvent?(.finished)
        #expect(model.currentIndex == 1 && playback.state == .playing)
    }

    @Test func theEndOfTheListEndsTheTimerAndATapStartsWithTheKeptCount() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let preferences = MemoryPreferences()
        preferences.set(10, forKey: "sleepTimerSongCount")
        let (model, playback, backend) = try await model(fixture, count: 2, preferences: preferences)
        defer { model.shutdown() }
        var finished = 0
        model.onSleepTimerFinished = { finished += 1 }
        #expect(model.sleepTimerCount == 10)
        model.setSleepTimer(true)
        #expect(model.sleepTimer?.count == 10)
        model.playPlaylist(try #require(model.document.currentPlaylistID))
        backend()?.onEvent?(.finished)
        backend()?.onEvent?(.finished)
        #expect(playback.state == .stopped && finished == 1 && model.sleepTimer == nil)
        // An unknown count from an older setting falls back to the default.
        preferences.set(7, forKey: "sleepTimerSongCount")
        let other = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: MemoryStore(),
                                      references: TestReferences(), preferences: preferences)
        #expect(other.sleepTimerCount == SleepTimer.defaultCount)
    }
}

@MainActor private func sleepWait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), sourceLocation: sourceLocation)
}
