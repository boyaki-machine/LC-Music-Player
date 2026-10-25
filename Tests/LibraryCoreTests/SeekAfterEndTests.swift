import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
@testable import LibraryCore

/// The player cannot open files on its own, as on the iPhone: only the library's references can.
@MainActor private struct DenyingAccess: FileAccess {
    func acquire(_ url: URL) throws -> FileLease { throw PlaybackError.inaccessibleFile }
}

/// Opt-in because it plays to the default output (at volume 0).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"))
@MainActor struct SeekAfterEndTests {
    /// Moving on the seek bar between a track's end and the start of the next plays the finished track
    /// again from there, instead of failing to open its file.
    @Test(arguments: [false, true])
    func seekingAfterTheEndReplaysTheFinishedTrack(throughLibrary: Bool) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let files = try ["a.wav", "b.wav"].map { try audioFile(f.root, name: $0, duration: 1) }
        let playback = PlaybackController(fileAccess: DenyingAccess()); playback.setVolume(0)
        let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(), preprocessingEnabled: true,
                                      preferences: MemoryPreferences(), preprocessor: AudioPreprocessor())
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles(files, into: list)
        // The listener moves back just as the track ends and the next one is on its way.
        let advance = playback.onNaturalFinish
        var moved = false
        playback.onNaturalFinish = {
            advance?()
            guard !moved else { return }
            moved = true
            if throughLibrary { model.seek(to: 0.3) } else { playback.seek(to: 0.3) }
        }
        model.playPlaylist(list)
        try await wait { moved }
        if throughLibrary {
            try await wait { playback.state == .playing && !model.isPreparing }
            #expect(model.currentIndex == 0 && playback.error == nil && model.error == nil)
            #expect(playback.currentTime >= 0.3 && playback.currentTime < 0.9)
        } else {
            // The player alone cannot reopen the finished track's file.
            #expect(playback.error == PlaybackError.inaccessibleFile)
        }
        model.stop()
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
}
