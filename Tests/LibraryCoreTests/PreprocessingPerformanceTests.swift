import AVFAudio
import Darwin
import Foundation
import Testing
import PlaybackCore
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_PREPROCESS_SOAK"] == "1"))
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
        let report: [String: Any] = ["seconds": now() - started, "cpuPercentOfOneCore": (cpu() - cpuStart) / (now() - started) * 100,
            "maxScopes": maximumScopes, "maxPreparedBytes": maximumBytes, "transitions": transitions, "measuredTracks": measured,
            "analysisFrames": analysisFrames, "droppedBuffers": maxDropped, "postStopScopes": refs.scopes.active, "samples": samples]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("soak.json"))
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
