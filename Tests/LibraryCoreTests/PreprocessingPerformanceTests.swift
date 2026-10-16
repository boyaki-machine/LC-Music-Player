import AVFAudio
import Darwin
import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
@testable import LibraryCore

@Suite(.serialized) @MainActor struct PreprocessingPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_PREPROCESS_OUTPUT_PROFILE"] == "1"))
    func engineAndFirstAnalysisTiming() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["LCMP_PREPROCESS_FIXTURES"])
        var rows: [[String: Any]] = []
        for name in ["tone.wav", "tone.flac", "tone.mp3"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            for run in 0..<5 {
                for preparedPath in (run.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    let preparation = preparedPath ? try await AudioPreprocessor.shared.prepare(url) : nil
                    let begin = now()
                    let backend = try preparation.map { try SFBAudioBackend(prepared: $0) } ?? SFBAudioBackend(url: url)
                    let selectionSeconds = now() - begin
                    backend.volume = 0
                    var firstAnalysis: Double?
                    backend.configureAnalysis(try .init(bandCount: 16, framesPerSecond: 30)) { _ in
                        if firstAnalysis == nil { firstAnalysis = now() - begin }
                    }
                    let playStart = now(); try backend.play(); let engineStart = now() - playStart
                    let deadline = now() + 2
                    while firstAnalysis == nil, now() < deadline { try await Task.sleep(for: .milliseconds(2)) }
                    backend.stop()
                    #expect(firstAnalysis != nil)
                    rows.append(["file": name, "run": run, "prepared": preparedPath, "selectionSeconds": selectionSeconds,
                                 "playCallSeconds": engineStart, "firstAnalysisSeconds": firstAnalysis ?? -1])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("output-startup.json"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_PREPROCESS_SOAK"] == "1" || ProcessInfo.processInfo.environment["LCMP_NORMALIZATION_SOAK"] == "1"))
    func tenMinutePlaybackPreparationAndMeasurementRemainBounded() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["LCMP_PREPROCESS_FIXTURES"])
        let suite = "lcmp-soak-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let refs = TestReferences(), playback = PlaybackController()
        playback.setVolume(0)
        playback.configureAnalysis(try .init(bandCount: 16, framesPerSecond: 30))
        let model = LibraryController(playback: playback, store: MemoryStore(), references: refs,
                                      preprocessingEnabled: true, preferences: defaults)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        let source = URL(fileURLWithPath: directory).appendingPathComponent("tone.wav")
        let second = URL(fileURLWithPath: directory).appendingPathComponent("tone.flac")
        await model.importFiles([source, second], into: list)
        model.setMeasuresMaximumVolume(true)
        let normalization = ProcessInfo.processInfo.environment["LCMP_NORMALIZATION_SOAK"] == "1"
        if normalization { model.setNormalizesVolume(true) }
        model.playPlaylist(list)
        let duration = Double(ProcessInfo.processInfo.environment["LCMP_PREPROCESS_SOAK_SECONDS"] ?? "600") ?? 600
        let started = now(), cpuStart = cpu()
        var nextSwitch = started + 6, nextCheckpoint = started + 10
        var samples: [[String: Double]] = []
        var maximumScopes = 0, maximumBytes = 0, transitions = 0, measured = 0, analysisFrames = 0
        var lastFrame: UUID?, lastSequence: UInt64 = 0
        var maxDropped: UInt64 = 0
        var observedPeak = false
        while now() - started < duration {
            try await Task.sleep(for: .milliseconds(20))
            maximumScopes = max(maximumScopes, refs.scopes.active)
            maximumBytes = max(maximumBytes, model.preparedNextByteCount)
            if model.currentTrackPeak != nil, !observedPeak { measured += 1; observedPeak = true }
            if let frame = playback.analysisFrame {
                if frame.generation != lastFrame || frame.sequence != lastSequence {
                    analysisFrames += 1; lastFrame = frame.generation; lastSequence = frame.sequence
                }
                maxDropped = max(maxDropped, frame.droppedBuffers)
            }
            #expect(playback.error == nil && model.error == nil)
            if now() >= nextSwitch {
                #expect(playback.state == .playing && model.currentTrackPeak != nil)
                if normalization { #expect(playback.normalizationPlan != nil && model.currentTrackMetrics != nil) }
                if model.canNext { model.next() } else { model.playPlaylist(list) }
                observedPeak = false; transitions += 1; nextSwitch += 6
            }
            if now() >= nextCheckpoint {
                let sample = ["seconds": now() - started, "rssMiB": rss(), "cpuSeconds": cpu() - cpuStart]
                samples.append(sample); print("PREPROCESS_CHECKPOINT \(sample)"); fflush(nil)
                nextCheckpoint += 10
            }
        }
        model.stop()
        let releaseDeadline = now() + 2
        while refs.scopes.active != 0, now() < releaseDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(refs.scopes.active == 0 && model.preparedNextEntryID == nil && !model.isPreparing)
        #expect(maximumScopes <= 2 && maximumBytes <= 32 * 1024 * 1024)
        #expect(analysisFrames > Int(duration * 20) && measured >= transitions)
        #expect(maxDropped == 0)
        let warmed = samples.filter { $0["seconds", default: 0] >= 60 }.compactMap { $0["rssMiB"] }
        if duration >= 600 { #expect((warmed.max() ?? 0) - (warmed.min() ?? 0) < 10) }
        let report: [String: Any] = ["normalization": normalization, "seconds": now() - started, "cpuPercentOfOneCore": (cpu() - cpuStart) / (now() - started) * 100,
            "maxScopes": maximumScopes, "maxPreparedBytes": maximumBytes, "transitions": transitions, "measuredTracks": measured,
            "analysisFrames": analysisFrames, "droppedBuffers": maxDropped, "postStopScopes": refs.scopes.active, "samples": samples]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(normalization ? "normalization-soak.json" : "soak.json"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_NORMALIZATION_PROFILE"] == "1"))
    func comparesSteadyPlaybackWithAndWithoutNormalization() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["LCMP_PREPROCESS_FIXTURES"])
        var rows: [[String: Any]] = []
        for enabled in [false, true] {
            let suite = "lcmp-level-profile-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let playback = PlaybackController(); playback.setVolume(0)
            let model = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(),
                                          preprocessingEnabled: true, preferences: defaults)
            defer { model.shutdown() }
            let list = try #require(model.document.currentPlaylistID)
            await model.importFiles([URL(fileURLWithPath: directory).appendingPathComponent("tone.wav")], into: list)
            model.setNormalizesVolume(enabled)
            let requested = now(); model.playPlaylist(list)
            while playback.state != .playing, now()-requested < 10 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(playback.state == .playing && model.error == nil)
            let startup = now()-requested
            let begin = now(), cpuBegin = cpu()
            try await Task.sleep(for: .seconds(10))
            let percent = (cpu()-cpuBegin)/(now()-begin)*100
            rows.append(["normalization":enabled,"startupSeconds":startup,"cpuPercentOfOneCore":percent,"rssMiB":rss()])
            #expect(percent < 30 && playback.state == .playing)
            model.stop()
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("normalization-profile.json"))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_PLAYLIST_SOAK"] == "1"))
    func tenMinutePlaylistSweepWithPlaybackInterruptions() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LCMP_PREPROCESS_FIXTURES"]))
        let suite = "lcmp-playlist-soak-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "normalizeVolume"); defaults.set(true, forKey: "measureMaximumVolume")
        let processor = AudioPreprocessor(cache: .init(url: root.appendingPathComponent("cache-\(UUID())/measurements.sqlite"),
            program: .init(applicationVersion: "soak", build: "1", executableDigest: "playlist-soak", environment: "test")))
        let refs = TestReferences(), playback = PlaybackController(); playback.setVolume(0)
        playback.configureAnalysis(try .init(bandCount: 16, framesPerSecond: 30))
        let model = LibraryController(playback: playback, store: MemoryStore(), references: refs, preprocessingEnabled: true,
            playlistPreprocessingEnabled: true, preferences: defaults, preprocessor: processor)
        defer { model.shutdown() }
        let list = try #require(model.document.currentPlaylistID)
        await model.importFiles([root.appendingPathComponent("tone.wav"), root.appendingPathComponent("tone.flac")], into: list)
        let backgroundList = try #require(model.createPlaylist("background"))
        model.playPlaylist(list)
        let readyDeadline = now() + 10
        while playback.state != .playing, now() < readyDeadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(playback.state == .playing && model.currentTrackMetrics != nil)
        let duration = Double(ProcessInfo.processInfo.environment["LCMP_PREPROCESS_SOAK_SECONDS"] ?? "600") ?? 600
        let started = now(), cpuStart = cpu()
        var nextWork = started + 2, nextSample = started + 10
        var transitions = 0, measuredFrames = 0, maxDrop: UInt64 = 0
        var generation: UUID?, sequence: UInt64 = 0
        var samples: [[String: Double]] = [], latencies: [[String: Double]] = []
        func observeFrame() {
            if let frame = playback.analysisFrame {
                if frame.generation != generation || frame.sequence != sequence {
                    measuredFrames += 1; generation = frame.generation; sequence = frame.sequence
                }
                maxDrop = max(maxDrop, frame.droppedBuffers)
            }
        }
        while now() - started < duration {
            try await Task.sleep(for: .milliseconds(20)); observeFrame()
            #expect(playback.error == nil && model.error == nil)
            if now() >= nextWork {
                let before = await processor.statistics().levelScans
                let url = root.appendingPathComponent("background-\(UUID()).flac")
                // APFS clones keep fixture blocks shared with independent file identity/revision.
                // Refuse to fall back to hard links, whose ctime changes invalidate every alias.
                guard clonefile(root.appendingPathComponent("large.flac").path, url.path, 0) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                await model.importFiles([url], into: backgroundList)
                let scanDeadline = now() + 5
                while await processor.statistics().levelScans <= before, now() < scanDeadline {
                    try await Task.sleep(for: .milliseconds(5)); observeFrame()
                }
                #expect(await processor.statistics().levelScans > before)
                try await Task.sleep(for: .milliseconds(400)); observeFrame()
                #expect(playback.state == .playing && model.currentTrackMetrics != nil)
                let request = now()
                if model.canNext { model.next() } else { model.playPlaylist(list) }
                let retiring = model.playlistWorkRetirement
                await retiring?.value
                let retiredAt = now()
                let playDeadline = now() + 5
                while (model.isPreparing || playback.state != .playing), now() < playDeadline {
                    try await Task.sleep(for: .milliseconds(2)); observeFrame()
                }
                #expect(playback.state == .playing && model.currentTrackMetrics != nil && model.error == nil)
                latencies.append(["retirementSeconds": retiredAt-request, "requestToPlayingSeconds": now()-request])
                transitions += 1; nextWork += 6
            }
            if now() >= nextSample {
                let sample = ["seconds": now()-started, "rssMiB": rss(), "cpuSeconds": cpu()-cpuStart]
                samples.append(sample); print("PLAYLIST_CHECKPOINT \(sample)"); fflush(nil); nextSample += 10
            }
        }
        model.stop()
        let deadline = now() + 5
        while refs.scopes.active != 0, now() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let stats = await processor.statistics()
        #expect(refs.scopes.active == 0 && refs.scopes.maximum <= 2 && !model.isPreparing)
        #expect(maxDrop == 0 && measuredFrames > Int(duration * 15) && transitions >= Int(duration / 6)-1)
        #expect(stats.levelScans >= transitions + 2)
        let warmed = samples.filter { $0["seconds", default: 0] >= 60 }.compactMap { $0["rssMiB"] }
        if duration >= 600 { #expect((warmed.max() ?? 0) - (warmed.min() ?? 0) < 10) }
        let report: [String: Any] = ["seconds": now()-started, "cpuPercentOfOneCore": (cpu()-cpuStart)/(now()-started)*100,
            "maxScopes": refs.scopes.maximum, "postStopScopes": refs.scopes.active, "transitions": transitions,
            "analysisFrames": measuredFrames, "droppedBuffers": maxDrop, "levelScans": stats.levelScans,
            "cacheHits": stats.cacheHits, "cacheWriteFailures": stats.cacheWriteFailures, "samples": samples, "interruptions": latencies]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("playlist-soak.json"))
    }

}
private func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
private func cpu() -> Double {
    var value = rusage(); getrusage(RUSAGE_SELF, &value)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}
private func rss() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : .nan
}
