import AVFAudio
import Darwin
import Foundation
import Testing
import PlaybackCore
import PreprocessingCore
import AudioProcessingCore

private final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?
    func receive(_ time: UInt64) { lock.withLock { if value == nil { value = time } } }
    var first: UInt64? { lock.withLock { value } }
}

/// Explicit opt-in; uses only generated fixtures in the supplied directory.
@Suite(.serialized) @MainActor struct StartupInvestigationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_STARTUP_INVESTIGATION"] == "1"))
    func stagesAndPreparedPrefixComparison() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["LCMP_STARTUP_INPUT"]))
        let processor = AudioPreprocessor()
        var rows: [[String: Any]] = []
        for name in ["short.wav", "short.flac", "large.wav", "large.flac"] {
            let url = root.appendingPathComponent(name)
            let profile = try SFBAudioBackend.measurementProfile()
            let openStart = startupClock()
            let decoder = try AudioDecoderFactory.open(url)
            let openSeconds = startupClock() - openStart
            let sourceRate = decoder.processingFormat.sampleRate, sourceFrames = decoder.length
            try decoder.close()
            let scanStart = startupClock(), cpuStart = processCPU()
            let metrics = try await processor.measureLevels(url, profile: profile)
            rows.append(["file": name, "kind": "measurement", "seconds": startupClock()-scanStart,
                "cpuSeconds": processCPU()-cpuStart, "openSeconds": openSeconds,
                "sourceRate": sourceRate, "sourceFrames": sourceFrames,
                "bytes": (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0])
            for run in 0..<3 {
                for prefixSeconds in (run.isMultiple(of: 2) ? [-1.0, 2, 0.05] : [0.05, 2, -1.0]) {
                    for normalized in [false, true] {
                        // -1 uses the existing synchronous metadata/open path as reference.
                        let begin = startupClock()
                        let prepared = prefixSeconds > 0 ? try await processor.prepare(url, seconds: prefixSeconds) : nil
                        let preparedAt = startupClock()
                        let backend: SFBAudioBackend
                        if let prepared {
                            backend = try SFBAudioBackend(prepared: prepared, metrics: normalized ? metrics : nil)
                        } else {
                            if normalized { continue } // direct URL doesn't carry a measured plan
                            backend = try SFBAudioBackend(url: url)
                        }
                        let selectedAt = startupClock(), probe = RenderProbe()
                        backend.onRenderScheduled = { probe.receive($0) }
                        backend.volume = 0
                        let playBegin = startupClock(); try backend.play(); let playEnd = startupClock()
                        let deadline = startupClock() + 4
                        while probe.first == nil, startupClock() < deadline { try await Task.sleep(for: .milliseconds(1)) }
                        let host = try #require(probe.first)
                        let receiptAt = startupClock()
                        let first = AVAudioTime.seconds(forHostTime: host)
                        backend.stop()
                        rows.append(["file":name, "kind":"startup", "run":run, "normalized":normalized,
                            "prefixSeconds":prefixSeconds, "prefixBytes":prepared?.bufferedBytes ?? 0,
                            "prepareSeconds":preparedAt-begin,"selectionSeconds":selectedAt-preparedAt,
                            "playCallSeconds":playEnd-playBegin,"renderAfterPlaySeconds":first-playBegin,
                            "requestToRenderSeconds":first-begin,"notificationReceiptSeconds":receiptAt-begin])
                    }
                }
            }
        }
        let destination = root.appendingPathComponent("startup-\(env["LCMP_STARTUP_LABEL"] ?? "baseline").json")
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]).write(to: destination)
        print("STARTUP_REPORT \(destination.lastPathComponent)")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_CACHE_TIMING"] == "1"))
    func persistentCacheSeparatesScanAndStartup() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["LCMP_STARTUP_INPUT"]))
        let label = env["LCMP_CACHE_TIMING_LABEL"] ?? "debug"
        let config = MeasurementCacheConfiguration(url: root.appendingPathComponent("timing-cache-\(label)/measurements.sqlite"),
            program: .init(applicationVersion: "timing", build: "1", executableDigest: label, environment: "timing"))
        let processor = AudioPreprocessor(cache: config, collectMeasurementTimings: true)
        var rows: [[String: Any]] = []
        for name in ["short.wav", "short.flac", "large.wav", "large.flac"] {
            let url = root.appendingPathComponent(name), profile = try SFBAudioBackend.measurementProfile()
            let before = await processor.statistics(), begin = startupClock(), cpu = processCPU(), memoryBefore = startupResidentMiB()
            _ = try await processor.measureLevels(url, profile: profile)
            let first = startupClock()-begin, after = await processor.statistics()
            var hitSeconds: [Double] = []
            let reopened = AudioPreprocessor(cache: config)
            for _ in 0..<5 {
                let start = startupClock()
                let metrics = try await reopened.measureLevels(url, profile: profile)
                hitSeconds.append(startupClock()-start)
                let requested = startupClock()
                let prepared = try await reopened.prepare(url)
                let backend = try SFBAudioBackend(prepared: prepared, metrics: metrics)
                let probe = RenderProbe(); backend.onRenderScheduled = { probe.receive($0) }; backend.volume = 0
                try backend.play()
                let deadline = startupClock()+4
                while probe.first == nil, startupClock() < deadline { try await Task.sleep(for: .milliseconds(1)) }
                let render = AVAudioTime.seconds(forHostTime: try #require(probe.first))
                backend.stop()
                rows.append(["file":name,"kind":"cachedStartup","seconds":render-requested])
            }
            let hits = await reopened.statistics()
            #expect(hits.levelScans == 0 && hits.cacheHits == 5)
            rows.append(["file":name,"kind":"cacheComparison","missSeconds":first,"hitSeconds":hitSeconds,
                "workSeconds":after.measurementWorkSeconds-before.measurementWorkSeconds,
                "nativePeakSeconds":after.nativePeakWorkSeconds-before.nativePeakWorkSeconds,
                "scanCount":after.levelScans-before.levelScans,"cpuSecondsIncludingStarts":processCPU()-cpu,
                "rssMiBBefore":memoryBefore,"rssMiBAfter":startupResidentMiB()])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("cache-timing-\(label).json"))
        let size = (try config.url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        print("CACHE_DATABASE_BYTES \(size)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_QUEUE_INVESTIGATION"] == "1"))
    func backgroundScansYieldToPreparationAndCancellation() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LCMP_STARTUP_INPUT"]))
        var rows: [[String: Any]] = []
        for name in ["large.wav", "large.flac"] {
            let processor = AudioPreprocessor(), token = PreparationCancellation()
            let measurement = Task { try await processor.measureLevels(root.appendingPathComponent(name), profile: SFBAudioBackend.measurementProfile(), cancellation: token) }
            var maxGap = 0.0
            let heartbeat = Task {
                var previous = startupClock()
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(5))
                    let time = startupClock(); maxGap = max(maxGap,time-previous); previous = time
                }
            }
            try await Task.sleep(for: .milliseconds(25))
            let started = startupClock()
            _ = try await processor.prepare(root.appendingPathComponent("short.wav"))
            let preparation = startupClock()-started
            let canceled = startupClock(); token.cancel()
            do { _ = try await measurement.value; Issue.record("Expected scan cancellation") }
            catch { #expect(error is CancellationError) }
            let cancellation = startupClock()-canceled
            heartbeat.cancel(); _ = await heartbeat.result
            rows.append(["background":name,"foregroundPreparationSeconds":preparation,
                "cancellationRetirementSeconds":cancellation,"maximumHeartbeatGapSeconds":maxGap])
            #expect(cancellation < 4)
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("queue-timing.json"))
    }

}
private func startupClock() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
private func processCPU() -> Double {
    var value = rusage(); getrusage(RUSAGE_SELF, &value)
    return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1e6
}

private func startupResidentMiB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.resident_size)/1048576 : -1
}
