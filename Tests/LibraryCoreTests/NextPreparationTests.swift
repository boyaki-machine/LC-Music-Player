import AVFAudio
import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
import AudioProcessingCore
@testable import LibraryCore

/// Hold a real worker's return boundary so ownership tests do not depend on CPU speed.
private actor HeldPreprocessor: AudioPreprocessing {
    let worker = AudioPreprocessor()
    let heldURL: URL
    let holdPrefix: Bool
    var released = false
    var waiting = false
    var fails = false
    func fail() { fails = true }
    var levelCalls: [URL: Int] = [:]
    var prefixCalls: [URL: Int] = [:]
    init(_ url: URL, prefix: Bool) { heldURL = url; holdPrefix = prefix }
    func release() { released = true }
    private func hold(_ url: URL, cancellation: PreparationCancellation) async throws {
        guard url == heldURL else { return }
        waiting = true
        defer { waiting = false }
        while !released { try cancellation.check(); try await Task.sleep(for: .milliseconds(2)) }
        try cancellation.check()
    }
    func prepare(_ url: URL, cancellation: PreparationCancellation, seconds: Double, byteLimit: Int) async throws -> PreparedAudio {
        prefixCalls[url, default: 0] += 1
        let audio = try await worker.prepare(url, cancellation: cancellation, seconds: seconds, byteLimit: byteLimit)
        if holdPrefix { try await hold(url, cancellation: cancellation) }
        return audio
    }
    func measureLevels(_ url: URL, profile: MeasurementProfile, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackAudioMetrics {
        levelCalls[url, default: 0] += 1
        if !holdPrefix { try await hold(url, cancellation: cancellation) }
        if fails, url == heldURL { throw PreprocessingFailure.invalidAudio }
        return try await worker.measureLevels(url, profile: profile, cancellation: cancellation, ownerID: ownerID)
    }
    func measure(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackPeak {
        try await hold(url, cancellation: cancellation)
        return try await worker.measure(url, cancellation: cancellation, ownerID: ownerID)
    }
    func reconcileCacheOwners(_ owners: Set<UUID>) async { await worker.reconcileCacheOwners(owners) }
}

@Suite(.serialized) @MainActor struct NextPreparationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_TEST_AUDIO_OUTPUT"] == "1"),
          arguments: ["manual", "natural", "prefix", "stop", "saveFailure", "differentEntry", "removed", "settings", "measurementFailure", "sourceChanged", "repair", "off"])
    func transfersPendingWorkAndRetiresCancelledOwnership(_ action: String) async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlaybackCoreTests/Fixtures/tone.wav")
        let a = fixture.root.appendingPathComponent("a.wav"), b = fixture.root.appendingPathComponent("b.wav")
        try FileManager.default.copyItem(at: source, to: a); try FileManager.default.copyItem(at: source, to: b)
        let suite = "lcmp-next-transfer-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let worker = HeldPreprocessor(b, prefix: action == "prefix")
        let playback = PlaybackController(); playback.setVolume(0)
        let store = MemoryStore(), refs = TestReferences()
        let model = LibraryController(playback: playback, store: store, references: refs, preprocessingEnabled: true,
                                      preferences: defaults, preprocessor: worker)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([a, b], into: list)
        // Repeated source, distinct entry: entry identity must still select the requested row.
        if action == "differentEntry" { model.addTracks([model.playlist(list)!.entries[1].trackID], to: list) }
        let entries = try #require(model.playlist(list)?.entries)
        if action == "off" { model.setMeasuresMaximumVolume(true) } else { model.setNormalizesVolume(true) }
        model.playPlaylist(list)
        try await wait { playback.state == .playing && model.currentIndex == 0 }
        try await waitAsync { await worker.waiting }
        #expect(refs.scopes.active == 2)
        if action == "natural" {
            playback.seek(to: playback.duration - 0.04)
            try await wait { model.isPreparing }
        } else { model.next() }
        #expect(model.isPreparing && model.currentIndex == 0)
        if action != "off" { #expect(model.currentTrackMetrics?.source.url == a) }
        if action == "stop" { model.stop() }
        if action == "saveFailure" { store.fail = true }
        if action == "differentEntry" { model.selectEntry(entries[2].id, in: list, autoPlay: true) }
        if action == "removed" { model.removeEntry(entries[1].id, from: list) }
        if action == "settings" { model.setNormalizationTarget(-18) }
        if action == "measurementFailure" { await worker.fail() }
        if action == "sourceChanged" {
            let file = try FileHandle(forWritingTo: b); try file.seekToEnd(); try file.write(contentsOf: Data([0])); try file.close()
        }
        if action == "repair" {
            let repaired = fixture.root.appendingPathComponent("repaired.wav")
            try FileManager.default.copyItem(at: b, to: repaired)
            model.repairTrack(entries[1].trackID, using: repaired)
        }
        if action == "off" { try await wait { model.currentIndex == 1 && playback.state == .playing } }
        await worker.release()
        if ["stop", "settings"].contains(action) {
            try await wait { !model.isPreparing }
            #expect(model.currentIndex == 0 && playback.state != .playing)
        } else if ["saveFailure", "measurementFailure"].contains(action) {
            try await wait { !model.isPreparing }
            #expect(model.currentIndex == 0 && model.error != nil)
        } else if ["removed", "repair"].contains(action) {
            try await wait { !model.isPreparing }
            #expect(model.currentIndex == 0)
        } else {
            let expected = action == "differentEntry" ? entries[2].id : entries[1].id
            try await wait { model.currentEntry?.id == expected && playback.state == .playing }
            if action != "off" { #expect(model.currentTrackMetrics?.source.url == b && playback.normalizationPlan != nil) }
            if !["differentEntry", "off"].contains(action) {
                let expectedCalls = action == "sourceChanged" ? 2 : 1
                #expect(await worker.prefixCalls[b] == expectedCalls)
                #expect(await worker.levelCalls[b] == expectedCalls)
                #expect(await worker.worker.statistics().levelScans == expectedCalls + 1)
            }
        }
        model.stop()
        try await wait { refs.scopes.active == 0 }
        #expect(refs.scopes.maximum <= 2 && model.preparedNextEntryID == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_NEXT_PROMOTION_PROFILE"] == "1"))
    func largeFLACScanContinuesAcrossManualAndNaturalAdvance() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LCMP_PREPROCESS_FIXTURES"]))
        var rows: [[String: Any]] = []
        for natural in [false, true] {
            for run in 0..<5 {
                let suite = "lcmp-promotion-profile-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let worker = AudioPreprocessor(collectMeasurementTimings: true), refs = TestReferences()
                let playback = PlaybackController(); playback.setVolume(0)
                let model = LibraryController(playback: playback, store: MemoryStore(), references: refs,
                    preprocessingEnabled: true, preferences: defaults, preprocessor: worker)
                defer { model.shutdown() }
                let list = try #require(model.document.currentPlaylistID)
                await model.importFiles([root.appendingPathComponent("short.wav"), root.appendingPathComponent("large.flac")], into: list)
                // Discovery sorts filenames, so explicitly choose short -> large.
                let entries = try #require(model.playlist(list)?.entries)
                let short = try #require(entries.first { model.track($0.trackID)?.reference.lastKnownURL.lastPathComponent == "short.wav" })
                model.moveEntry(short.id, in: list, offset: -1)
                model.setNormalizesVolume(true); model.playPlaylist(list)
                try await wait { playback.state == .playing && model.currentTrackMetrics != nil }
                try await waitAsync { await worker.statistics().levelScans == 2 }
                let scanObserved = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(400))
                #expect(!model.preparedNextHasLevels)
                let requested = ContinuousClock.now
                if natural { playback.seek(to: playback.duration - 0.04) } else { model.next() }
                try await wait { playback.state == .playing && model.currentTrackMetrics?.source.url.lastPathComponent == "large.flac" }
                let stats = await worker.statistics()
                #expect(stats.levelScans == 2 && stats.coalescedRequests == 0 && model.error == nil)
                #expect(refs.scopes.maximum <= 2 && playback.normalizationPlan != nil)
                let elapsed = seconds(requested.duration(to: .now)), total = seconds(scanObserved.duration(to: .now))
                rows.append(["natural": natural, "run": run, "requestToPlayingSeconds": elapsed,
                             "scanObservedToPlayingSeconds": total, "levelScans": stats.levelScans,
                             "workerSeconds": stats.measurementWorkSeconds, "maxScopes": refs.scopes.maximum])
                model.stop(); try await wait { refs.scopes.active == 0 }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("next-promotion.json"))
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func wait(_ predicate: () -> Bool) async throws {
        try await waitAsync { predicate() }
    }
    private func waitAsync(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await predicate())
    }
}
