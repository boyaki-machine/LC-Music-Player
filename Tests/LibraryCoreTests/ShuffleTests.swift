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

/// Plays one whole cycle with the same picks as playback: a random first entry, then random unplayed entries.
private func cycleOrder(_ list: MusicPlaylist, first: UUID? = nil, using random: inout some RandomNumberGenerator) -> [UUID] {
    var cycle = ShuffleCycle(playlistID: list.id, first: first ?? list.entries.randomElement(using: &random)!.id)
    while let pick = cycle.randomUnplayed(in: list, using: &random) { cycle.record(pick, keepsPosition: true) }
    return cycle.played
}

@Suite struct ShuffleCycleTests {
    @Test func cycleIsPermutationStartingAtTheFirstEntry() {
        var random = SplitMix64(seed: 1)
        let list = playlist(30)
        for first in [nil, list.entries[0].id, list.entries[17].id] {
            let order = cycleOrder(list, first: first, using: &random)
            #expect(order.count == 30 && Set(order) == Set(list.entries.map(\.id)))
            if let first { #expect(order[0] == first) }
        }
    }

    @Test func everyEntryIsEquallyLikelyAtEveryPosition() {
        var random = SplitMix64(seed: 2)
        let list = playlist(6), ids = list.entries.map(\.id), trials = 60_000
        var counts = Array(repeating: Array(repeating: 0, count: 6), count: 6)
        for _ in 0..<trials {
            for (position, id) in cycleOrder(list, using: &random).enumerated() {
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
        for _ in 0..<trials { counts[cycleOrder(list, using: &random), default: 0] += 1 }
        let expected = Double(trials) / 24
        #expect(counts.count == 24)
        #expect(counts.values.allSatisfy { abs(Double($0) - expected) < expected * 0.1 })
    }

    @Test func repeatedCyclesDoNotRepeatOrSettleIntoTheListOrder() {
        var system = SystemRandomNumberGenerator()
        let list = playlist(20), ids = list.entries.map(\.id)
        let orders = (0..<200).map { _ in cycleOrder(list, first: ids[0], using: &system) }
        #expect(Set(orders).count == orders.count)
        // Consecutive orders share about one position out of 19 by chance.
        for (a, b) in zip(orders, orders.dropFirst()) {
            #expect(zip(a.dropFirst(), b.dropFirst()).filter { $0 == $1 }.count < 10)
        }
        #expect(orders.filter { $0 == ids }.isEmpty)
    }

    @Test func recordingKeepsOrMovesPlayedEntriesAndEditsLeaveOnlyRemovals() {
        var list = playlist(6)
        let ids = list.entries.map(\.id)
        var cycle = ShuffleCycle(playlistID: list.id, first: ids[3])
        cycle.record(ids[1], keepsPosition: true); cycle.record(ids[4], keepsPosition: true)
        // Going back and forth keeps a played entry in place; choosing it again moves it to the end.
        cycle.record(ids[1], keepsPosition: true)
        #expect(cycle.played == [ids[3], ids[1], ids[4]])
        #expect(cycle.neighbor(of: ids[1], offset: -1) == ids[3] && cycle.neighbor(of: ids[1], offset: 1) == ids[4])
        cycle.record(ids[1], keepsPosition: false)
        #expect(cycle.played == [ids[3], ids[4], ids[1]] && cycle.neighbor(of: ids[1], offset: 1) == nil)
        // Reordering does nothing, a removed entry leaves, an added one is unplayed.
        list.entries.swapAt(0, 5)
        list.entries.removeAll { $0.id == ids[4] }
        let added = PlaylistEntry(trackID: UUID()); list.entries.append(added)
        cycle.reconcile(with: list)
        #expect(cycle.played == [ids[3], ids[1]])
        #expect(Set(cycle.unplayed(in: list)) == Set([ids[0], ids[2], ids[5], added.id]))
    }

    @Test func documentsWithoutCyclesStillLoadAndStaleCyclesAreDropped() throws {
        var doc = LibraryDocument()
        let track = LibraryTrack(name: "a", reference: TrackReference(bookmark: nil, lastKnownURL: URL(fileURLWithPath: "/tmp/a.wav")))
        doc.tracks = [track]
        let entries = [PlaylistEntry(trackID: track.id), PlaylistEntry(trackID: track.id)]
        doc.playlists[0].entries = entries
        // An older file has no "shuffleCycles" key, and a document without cycles writes none.
        let encoded = try JSONEncoder().encode(doc)
        #expect(String(decoding: encoded, as: UTF8.self).contains("shuffleCycles") == false)
        #expect(try JSONDecoder().decode(LibraryDocument.self, from: encoded) == doc)
        var cycle = ShuffleCycle(playlistID: doc.playlists[0].id, first: entries[0].id)
        cycle.record(UUID(), keepsPosition: true)
        doc.shuffleCycles = [cycle, ShuffleCycle(playlistID: UUID(), first: UUID())]
        let pruned = doc.prunedShuffleCycles()
        #expect(pruned.shuffleCycles?.map(\.played) == [[entries[0].id]])
        try pruned.validate()
        doc.playlists[0].entries = [entries[1]]
        #expect(doc.prunedShuffleCycles().shuffleCycles == nil)
    }
}

@Suite(.serialized) @MainActor struct ShufflePlaybackTests {
    private func model(_ fixture: Fixture, count: Int, preferences: MemoryPreferences = MemoryPreferences(),
                       store: MemoryStore = MemoryStore(), seed: UInt64 = 5) async throws -> (LibraryController, PlaybackController, () -> TestBackend?) {
        var backends: [TestBackend] = []
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); backends.append(b); return b })
        let model = LibraryController(playback: playback, store: store, references: TestReferences(),
                                      preferences: preferences, random: SplitMix64(seed: seed))
        let list = try #require(model.document.currentPlaylistID)
        if count > 0 { await model.importFiles(try (0..<count).map { try fixture.file("\($0).wav") }, into: list) }
        return (model, playback, { backends.last })
    }

    @Test func naturalFinishPlaysEveryEntryOnceAndStopsAfterOneCycle() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (model, playback, backend) = try await model(fixture, count: 8)
        defer { model.shutdown() }
        let list = try #require(model.currentPlaylist)
        model.setShufflesPlayback(true)
        model.playPlaylist(list.id)
        #expect(model.shufflePlayed?.count == 1 && playback.state == .playing)
        var played = [try #require(model.currentEntry?.id)]
        for _ in 1..<list.entries.count {
            backend()?.onEvent?(.finished)
            played.append(try #require(model.currentEntry?.id))
            #expect(playback.state == .playing)
        }
        #expect(Set(played).count == 8 && played != list.entries.map(\.id))
        #expect(model.shufflePlayed == played && !model.canNext && model.canPrevious)
        backend()?.onEvent?(.finished)
        #expect(model.currentEntry?.id == played.last && playback.state == .finished)
        // Playing the list again starts a new cycle.
        model.playPlaylist(list.id)
        #expect(model.shufflePlayed?.count == 1 && model.canNext)
    }

    @Test func previousAndNextWalkTheCycleAndClickingARowContinuesIt() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (model, playback, _) = try await model(fixture, count: 6)
        defer { model.shutdown() }
        let list = try #require(model.currentPlaylist)
        let start = list.entries[2].id
        model.clickEntry(start, in: list.id, clickCount: 2)
        #expect(model.shufflePlayed == nil)
        model.setShufflesPlayback(true)
        #expect(model.shufflePlayed == [start] && !model.canPrevious)
        model.next(); model.next()
        let order = try #require(model.shufflePlayed)
        #expect(order.count == 3 && model.currentEntry?.id == order[2] && playback.state == .playing)
        model.previous()
        #expect(model.currentEntry?.id == order[1])
        // Going back and on again replays the recorded entry, not a new pick.
        model.next()
        #expect(model.currentEntry?.id == order[2] && model.shufflePlayed == order)
        // Clicking an unplayed row adds it; clicking a played row moves it to the end.
        let unplayed = try #require(list.entries.map(\.id).first { !order.contains($0) })
        model.clickEntry(unplayed, in: list.id, clickCount: 1)
        #expect(model.shufflePlayed == order + [unplayed])
        model.clickEntry(order[0], in: list.id, clickCount: 1)
        #expect(model.shufflePlayed == [order[1], order[2], unplayed, order[0]])
        #expect(model.canNext && model.canPrevious)
        // Two unplayed entries remain; then the cycle ends.
        model.next(); model.next()
        #expect(Set(try #require(model.shufflePlayed)) == Set(list.entries.map(\.id)) && !model.canNext)
        model.setShufflesPlayback(false)
        #expect(model.shufflePlayed == nil && model.document.shuffleCycles == nil)
        let index = try #require(model.currentIndex)
        #expect(model.canNext == (index + 1 < list.entries.count))
        if model.canNext {
            model.next()
            #expect(model.currentEntry?.id == list.entries[index + 1].id)
        }
    }

    @Test func addedEntriesAreUnplayedAndRemovedEntriesLeaveTheCycle() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let (model, _, backend) = try await model(fixture, count: 5)
        defer { model.shutdown() }
        let list = try #require(model.currentPlaylist)
        model.setShufflesPlayback(true)
        model.playPlaylist(list.id)
        backend()?.onEvent?(.finished)
        let played = try #require(model.shufflePlayed)
        #expect(played.count == 2)
        model.addTracks([list.entries[0].trackID, list.entries[1].trackID], to: list.id)
        let added = try #require(model.currentPlaylist?.entries.suffix(2).map(\.id))
        #expect(model.shufflePlayed == played)
        model.removeEntry(played[0], from: list.id)
        #expect(model.document.shuffleCycles?.first?.played == [played[1]])
        var rest: [UUID] = []
        while model.canNext { backend()?.onEvent?(.finished); rest.append(try #require(model.currentEntry?.id)) }
        #expect(rest.count == 5 && Set(added).isSubset(of: rest) && !rest.contains(played[1]))
        // Deleting the list drops its cycle.
        model.deletePlaylist(list.id)
        #expect(model.document.shuffleCycles == nil)
    }

    @Test func theCycleIsSavedAndContinuesAfterTheAppIsClosed() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let preferences = MemoryPreferences(), store = MemoryStore()
        let (first, _, firstBackend) = try await model(fixture, count: 8, preferences: preferences, store: store)
        #expect(!first.shufflesPlayback)
        first.setShufflesPlayback(true)
        #expect(preferences.bool(forKey: "shufflePlayback"))
        let list = try #require(first.currentPlaylist)
        first.playPlaylist(list.id)
        for _ in 0..<2 { firstBackend()?.onEvent?(.finished) }
        let before = try #require(first.shufflePlayed)
        #expect(before.count == 3 && store.document.shuffleCycles?.first?.played == before)
        first.shutdown()
        // The next launch continues the same cycle: going back retraces it, going on picks only unplayed entries.
        let (second, _, secondBackend) = try await model(fixture, count: 0, preferences: preferences, store: store, seed: 6)
        defer { second.shutdown() }
        #expect(second.shufflesPlayback && second.shufflePlayed == before && second.currentEntry?.id == before[2])
        second.restore()
        second.previous()
        #expect(second.currentEntry?.id == before[1])
        second.next()
        #expect(second.currentEntry?.id == before[2])
        second.togglePlayPause()
        var played = before
        while second.canNext { secondBackend()?.onEvent?(.finished); played.append(try #require(second.currentEntry?.id)) }
        #expect(played.count == 8 && Set(played) == Set(list.entries.map(\.id)))
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
        let first = try #require(model.currentEntry?.id)
        // The prepared entry is the one that next() then plays.
        try await shuffleWait { model.preparedNextEntryID != nil }
        let prepared = try #require(model.preparedNextEntryID)
        let ids = try #require(model.playlist(list)?.entries.map(\.id))
        #expect(prepared != first)
        model.next()
        try await shuffleWait { !model.isPreparing && model.currentEntry?.id == prepared && playback.state == .playing }
        #expect(model.shufflePlayed == [first, prepared])
        try await shuffleWait { model.preparedNextEntryID.map { ![first, prepared].contains($0) && ids.contains($0) } == true }
        model.stop(); try await shuffleWait { refs.scopes.active == 0 }
    }
}

@MainActor private func shuffleWait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), sourceLocation: sourceLocation)
}
