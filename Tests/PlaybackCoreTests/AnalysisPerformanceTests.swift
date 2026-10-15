import AnalysisCore
import AVFAudio
import Darwin
import Foundation
import Testing
@testable import PlaybackCore

/// Muted app output, real default-device rendering. Opt-in; no system-volume writes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LCMP_ANALYSIS_PROFILE"] == "1"))
@MainActor
struct AnalysisPerformanceTests {
    @Test(arguments: [0, 15, 30, 60])
    func measuresConfiguredCadence(_ fps: Int) async throws {
        try await measure(fps: fps, seconds: 6, label: "profile-\(fps)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_ANALYSIS_SOAK"] == "1"))
    func tenMinuteRealOutputRemainsBounded() async throws {
        try await measure(fps: 60, seconds: 600, label: "soak-60")
    }

    private func measure(fps: Int, seconds: Double, label: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-analysis-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let data = try #require(buffer.floatChannelData)
        for i in 0..<48000 {
            data[0][i] = Float(0.05 * sin(2 * .pi * 1000 * Double(i) / 48000))
            data[1][i] = Float(0.05 * sin(2 * .pi * 3000 * Double(i) / 48000))
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<Int(seconds + 4) { try file.write(from: buffer) }
        }
        let metrics = Metrics()
        var earlyEnd = false
        let backend = try SFBAudioBackend(url: url)
        defer { backend.stop() }
        backend.volume = 0
        backend.onEvent = { _ in earlyEnd = true }
        if fps > 0 {
            backend.configureAnalysis(try AnalysisConfiguration(framesPerSecond: fps)) { metrics.receive($0) }
        }
        try backend.play()
        let start = hostNow()
        let cpuStart = processCPUSeconds()
        var samples: [[String: Double]] = []
        var checkpoint = start
        while hostNow() - start < seconds {
            try await Task.sleep(for: .milliseconds(10))
            let now = hostNow()
            if now - checkpoint >= (seconds > 60 ? 30 : 2) {
                let sample = ["elapsed": now - start, "rssMB": residentMB(), "cpuSeconds": processCPUSeconds() - cpuStart,
                              "frames": Double(metrics.count), "droppedBuffers": Double(metrics.dropped)]
                samples.append(sample)
                print("ANALYSIS_CHECKPOINT \(label) \(sample)")
                fflush(nil)
                checkpoint = now
            }
        }
        let elapsed = hostNow() - start
        let cpu = (processCPUSeconds() - cpuStart) / elapsed * 100
        backend.stop()
        let stoppedCount = metrics.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(metrics.count == stoppedCount)
        #expect(!earlyEnd)
        let summary: [String: Any] = [
            "label": label, "seconds": elapsed, "fpsRequested": fps,
            "frames": metrics.count, "fpsObserved": Double(metrics.count) / elapsed,
            "computeP95Ms": metrics.compute.percentile(0.95) * 1000,
            "windowAgeP95Ms": metrics.age.percentile(0.95) * 1000,
            "deliveryGapP95Ms": metrics.gap.percentile(0.95) * 1000,
            "deliveryGapMaxMs": metrics.gap.maximum * 1000,
            "handoffP95Ms": metrics.handoff.percentile(0.95) * 1000,
            "presentationLatenessP95Ms": metrics.presentationLateness.percentile(0.95) * 1000,
            "queueHighWatermark": metrics.highWater,
            "cpuPercentOfOneCore": cpu, "droppedBuffers": metrics.dropped,
            "sampleRates": Array(metrics.rates).sorted(), "rssSamples": samples
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print("ANALYSIS_SUMMARY \(String(decoding: json, as: UTF8.self))")
        if let directory = ProcessInfo.processInfo.environment["LCMP_ANALYSIS_REPORT_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try json.write(to: destination.appendingPathComponent("\(label).json"), options: .atomic)
        }
        if fps > 0 {
            #expect(Double(metrics.count) / elapsed >= Double(fps) * 0.90)
            #expect(Double(metrics.count) / elapsed <= Double(fps) * 1.02)
            #expect(metrics.compute.percentile(0.95) <= 0.002)
            #expect(metrics.age.percentile(0.95) <= 0.080)
            #expect(metrics.handoff.percentile(0.95) <= 1 / Double(fps))
            #expect(metrics.presentationLateness.count > 0)
            #expect(metrics.presentationLateness.percentile(0.95) <= 1 / Double(fps))
            #expect(metrics.gap.maximum < 0.5)
            #expect(metrics.dropped == 0)
            #expect(metrics.highWater <= 8)
            #expect(cpu < 30)
        } else { #expect(metrics.count == 0) }
        if seconds >= 600 {
            let warmed = samples.filter { $0["elapsed", default: 0] >= 60 }
            let rss = warmed.compactMap { $0["rssMB"] }
            #expect((rss.max() ?? 0) - (rss.min() ?? 0) < 10)
        }
    }
}

@MainActor
private final class Metrics {
    var count = 0
    var dropped: UInt64 = 0
    var highWater: UInt32 = 0
    var rates: Set<Double> = []
    var previous: Double?
    var compute = Histogram(step: 0.000001, ceiling: 0.1)
    var age = Histogram(step: 0.0001, ceiling: 1)
    var gap = Histogram(step: 0.0001, ceiling: 1)
    var handoff = Histogram(step: 0.0001, ceiling: 1)
    var presentationLateness = Histogram(step: 0.0001, ceiling: 1)
    func receive(_ frame: AnalysisFrame) {
        let now = hostNow()
        count += 1
        dropped = max(dropped, frame.droppedBuffers)
        highWater = max(highWater, frame.queuedBufferHighWatermark)
        rates.insert(frame.timing.sampleRate)
        compute.add(frame.computationSeconds)
        if let center = frame.timing.windowCenterHostTime { age.add(frame.timing.producedHostTime - center) }
        handoff.add(now - frame.timing.producedHostTime)
        if let presentation = frame.timing.estimatedPresentationHostTime {
            presentationLateness.add(max(0, now - presentation))
        }
        if let previous { gap.add(now - previous) }
        previous = now
    }
}

/// Fixed-size histograms prevent the measurement itself growing memory over time.
private struct Histogram {
    let step: Double
    var buckets: [Int]
    var count = 0
    var maximum = 0.0
    init(step: Double, ceiling: Double) {
        self.step = step
        buckets = Array(repeating: 0, count: Int(ceiling / step) + 1)
    }
    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        maximum = max(maximum, value)
        buckets[min(buckets.count - 1, max(0, Int(ceil(value / step))))] += 1
        count += 1
    }
    func percentile(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let target = Int(ceil(Double(count) * fraction))
        var sum = 0
        for (i, n) in buckets.enumerated() { sum += n; if sum >= target { return Double(i) * step } }
        return maximum
    }
}

private func hostNow() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
private func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return .nan }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}
private func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : .nan
}
