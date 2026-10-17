import AVFAudio
import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
@testable import LibraryCore

/// Deterministic generator so statistical checks never flake.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func playlist(_ count: Int) -> MusicPlaylist {
    MusicPlaylist(name: "list", entries: (0..<count).map { _ in PlaylistEntry(trackID: UUID()) })
}

@Suite struct ShuffleOrderTests {
    @Test func orderIsPermutationStartingAtCurrent() {
        var random = SplitMix64(seed: 1)
        let list = playlist(30)
        for first in [nil, list.entries[0].id, list.entries[17].id] {
            let order = ShuffleOrder(list, first: first, using: &random)
            #expect(order.entries.count == 30 && Set(order.entries) == Set(list.entries.map(\.id)))
            if let first { #expect(order.entries[0] == first) }
        }
    }

    @Test func everyEntryIsEquallyLikelyAtEveryPosition() {
        var random = SplitMix64(seed: 2)
        let list = playlist(6), ids = list.entries.map(\.id), trials = 60_000
        var counts = Array(repeating: Array(repeating: 0, count: 6), count: 6)
        for _ in 0..<trials {
            for (position, id) in ShuffleOrder(list, first: nil, using: &random).entries.enumerated() {
                counts[ids.firstIndex(of: id)!][position] += 1
            }
        }
        let expected = Double(trials) / 6
        // Pearson chi-square over 6×6 cells; the 99.9% point for 25 degrees of freedom is 52.6.
        let chiSquare = counts.joined().reduce(0.0) { $0 + pow(Double($1) - expected, 2) / expected }
        #expect(chiSquare < 52.6)
        #expect(counts.joined().allSatisfy { abs(Double($0) - expected) < expected * 0.05 })
    }

    @Test func everyOrderOfFourEntriesAppearsEquallyOften() {
        var random = SplitMix64(seed: 3)
        let list = playlist(4), trials = 48_000
        var counts: [[UUID]: Int] = [:]
        for _ in 0..<trials { counts[ShuffleOrder(list, first: nil, using: &random).entries, default: 0] += 1 }
        let expected = Double(trials) / 24
        #expect(counts.count == 24)
        #expect(counts.values.allSatisfy { abs(Double($0) - expected) < expected * 0.1 })
    }

    @Test func repeatedShufflesDoNotRepeatOrSettleIntoTheListOrder() {
        var system = SystemRandomNumberGenerator()
        let list = playlist(20), ids = list.entries.map(\.id)
        let orders = (0..<200).map { _ in ShuffleOrder(list, first: ids[0], using: &system).entries }
        #expect(Set(orders).count == orders.count)
        // Consecutive orders share about one position out of 19 by chance.
        for (a, b) in zip(orders, orders.dropFirst()) {
            #expect(zip(a.dropFirst(), b.dropFirst()).filter { $0 == $1 }.count < 10)
        }
        #expect(orders.filter { $0 == ids }.isEmpty)
    }

    @Test func editsRemoveEntriesAndAddNewOnesAfterTheCurrentEntry() {
        var random = SplitMix64(seed: 4)
        var list = playlist(8)
        var order = ShuffleOrder(list, first: list.entries[0].id, using: &random)
        let current = order.entries[3], played = Array(order.entries[0...3])
        let removed = order.entries[5]
        list.entries.removeAll { $0.id == removed }
        list.entries.swapAt(0, 1)
        let added = (0..<3).map { _ in PlaylistEntry(trackID: UUID()) }
        list.entries += added
        order.reconcile(with: list, current: current, using: &random)
        #expect(Set(order.entries) == Set(list.entries.map(\.id)) && order.entries.count == list.entries.count)
        #expect(Array(order.entries[0...3]) == played)
        #expect(added.allSatisfy { order.entries.firstIndex(of: $0.id)! > 3 })
        #expect(order.neighbor(of: played[0], offset: -1) == nil)
        #expect(order.neighbor(of: current, offset: -1) == played[2])
    }
}

@Suite(.serialized) @MainActor struct ShufflePlaybackTests {
    private func model(_ fixture: Fixture, count: Int, preferences: MemoryPreferences = MemoryPreferences(),
                       seed: UInt64 = 5) async throws -> (LibraryController, PlaybackController, () -> TestBackend?) {
        var backends: [TestBackend] = []
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); backends.append(b); return b })
        let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(),
                                      preferences: preferences, random: SplitMix64(seed: seed))
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles(try (0..<count).map { try fixture.file("\($0).wav") }, into: list)
        return (model, playback, { backends.last })
    }

    @Test func naturalFinishFollowsTheShuffleOrderAndStopsAfterOneCycle() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (model, playback, backend) = try await model(fixture, count: 8)
        defer { model.shutdown() }
        let list = try #require(model.currentPlaylist)
        model.setShufflesPlayback(true)
        model.playPlaylist(list.id)
        let order = try #require(model.shuffledEntries)
        #expect(model.currentEntry?.id == order[0] && playback.state == .playing)
        #expect(order != list.entries.map(\.id))
        var played = [order[0]]
        for _ in 1..<order.count {
            backend()?.onEvent?(.finished)
            played.append(try #require(model.currentEntry?.id))
            #expect(playback.state == .playing)
        }
        #expect(played == order && !model.canNext && model.canPrevious)
        backend()?.onEvent?(.finished)
        #expect(model.currentEntry?.id == order.last && playback.state == .finished)
    }

    @Test func previousAndNextWalkTheShuffleOrderAndTurningOffRestoresListOrder() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (model, playback, _) = try await model(fixture, count: 6)
        defer { model.shutdown() }
        let list = try #require(model.currentPlaylist)
        let start = list.entries[2].id
        model.clickEntry(start, in: list.id, clickCount: 2)
        #expect(model.shuffledEntries == nil)
        model.setShufflesPlayback(true)
        let order = try #require(model.shuffledEntries)
        #expect(order[0] == start && !model.canPrevious)
        model.next(); model.next()
        #expect(model.currentEntry?.id == order[2] && playback.state == .playing)
        model.previous()
        #expect(model.currentEntry?.id == order[1])
        // Clicking a row starts a new cycle from that row.
        let clicked = try #require(order.last)
        model.clickEntry(clicked, in: list.id, clickCount: 1)
        #expect(model.shuffledEntries?.first == clicked && model.canNext)
        model.setShufflesPlayback(false)
        #expect(model.shuffledEntries == nil)
        let index = try #require(model.currentIndex)
        #expect(model.canNext == (index + 1 < list.entries.count))
        if model.canNext {
            model.next()
            #expect(model.currentEntry?.id == list.entries[index + 1].id)
        }
    }

    @Test func addedEntriesJoinTheUnplayedPartOfTheCycle() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (model, _, backend) = try await model(fixture, count: 5)
        defer { model.shutdown() }
        let list = try #require(model.currentPlaylist)
        model.setShufflesPlayback(true)
        model.playPlaylist(list.id)
        backend()?.onEvent?(.finished)
        let current = try #require(model.currentEntry?.id)
        model.addTracks([list.entries[0].trackID, list.entries[1].trackID], to: list.id)
        #expect(model.canNext)
        let order = try #require(model.shuffledEntries)
        let added = try #require(model.currentPlaylist?.entries.suffix(2).map(\.id))
        let position = try #require(order.firstIndex(of: current))
        #expect(position == 1 && order.count == 7)
        #expect(added.allSatisfy { order.firstIndex(of: $0)! > position })
    }

    @Test func shuffleSettingPersistsButTheOrderIsMadeAgain() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let preferences = MemoryPreferences()
        let (first, _, _) = try await model(fixture, count: 6, preferences: preferences)
        #expect(!first.shufflesPlayback)
        first.setShufflesPlayback(true)
        #expect(preferences.bool(forKey: "shufflePlayback"))
        first.shutdown()
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let store = MemoryStore(); store.document = first.document
        let second = LibraryController(playback: playback, store: store, references: TestReferences(),
                                       preferences: preferences, random: SplitMix64(seed: 6))
        defer { second.shutdown() }
        #expect(second.shufflesPlayback && second.shuffledEntries == nil)
        let list = try #require(second.currentPlaylist)
        second.selectEntry(list.entries[3].id, in: list.id)
        #expect(second.canNext && second.shuffledEntries?.first == list.entries[3].id)
    }

    @Test func playlistPreprocessingRanksTheShuffleNeighbors() throws {
        var doc = LibraryDocument()
        for n in 0..<5 {
            let url = URL(fileURLWithPath: "/tmp/lcmp-shuffle-\(n).wav")
            let track = LibraryTrack(name: "\(n)", reference: TrackReference(bookmark: nil, lastKnownURL: url))
            doc.tracks.append(track); doc.playlists[0].entries.append(PlaylistEntry(trackID: track.id))
        }
        let entries = doc.playlists[0].entries
        doc.currentPlaylistID = doc.playlists[0].id; doc.currentEntryID = entries[1].id
        let ranked = PlaylistPreprocessing.ordered(doc, playing: true, adjacent: (entries[4], entries[3])).map(\.entry)
        #expect(Array(ranked.prefix(3)) == [entries[1].id, entries[4].id, entries[3].id])
        let plain = PlaylistPreprocessing.ordered(doc, playing: true).map(\.entry)
        #expect(Array(plain.prefix(3)) == [entries[1].id, entries[2].id, entries[0].id])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"), arguments: [false, true])
    func backgroundPreparationTargetsTheNextShuffledEntry(_ sweep: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        // Long enough that no natural finish advances the entry while the test waits.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000 * 12))
        silence.frameLength = silence.frameCapacity
        let urls = (0..<6).map { fixture.root.appendingPathComponent("\($0).wav") }
        for url in urls { try AVAudioFile(forWriting: url, settings: format.settings).write(from: silence) }
        let playback = PlaybackController(); playback.setVolume(0)
        let refs = TestReferences()
        let model = LibraryController(playback: playback, store: MemoryStore(), references: refs, preprocessingEnabled: true,
                                      playlistPreprocessingEnabled: sweep, preferences: MemoryPreferences(),
                                      preprocessor: AudioPreprocessor(), random: SplitMix64(seed: 7))
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles(urls, into: list)
        model.setShufflesPlayback(true)
        model.playPlaylist(list)
        try await shuffleWait { !model.isPreparing && playback.state == .playing }
        let order = try #require(model.shuffledEntries)
        #expect(model.currentEntry?.id == order[0])
        // The list neighbor would be a different entry for this seed.
        let ids = try #require(model.playlist(list)?.entries.map(\.id))
        let start = try #require(ids.firstIndex(of: order[0]))
        #expect(start + 1 == ids.count || ids[start + 1] != order[1])
        try await shuffleWait { model.preparedNextEntryID == order[1] }
        model.next()
        try await shuffleWait { !model.isPreparing && model.currentEntry?.id == order[1] && playback.state == .playing }
        try await shuffleWait { model.preparedNextEntryID == order[2] }
        model.stop(); try await shuffleWait { refs.scopes.active == 0 }
    }
}

@MainActor private func shuffleWait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), sourceLocation: sourceLocation)
}
