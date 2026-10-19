#if os(macOS)
import AppKit
import AVFAudio
import Darwin
import Foundation
import SwiftUI
import Testing
import AnalysisCore
import PlaybackCore
import VisualizationKit
import PlayerUI

/// Opt-in: real output at app volume zero; offscreen native rasterization.
/// This measures CPU/readback readiness, not photons or physical audio onset.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LCMP_VISUALIZATION_PROFILE"] == "1"))
@MainActor struct VisualizationPerformanceTests {
    @Test(arguments: [2048, 4096])
    func comparesAnalysisWindows(_ fft: Int) async throws {
        try await measure(fft: fft, seconds: 6, label: "window-\(fft)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LCMP_VISUALIZATION_SOAK"] == "1"))
    func tenMinuteRenderingRemainsBounded() async throws {
        try await measure(fft: 2048, seconds: 600, label: "soak-led")
    }

    private func measure(fft: Int, seconds: Double, label: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-led-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let data = try #require(buffer.floatChannelData)
        for i in 0..<48000 {
            let t = Double(i) / 48000
            data[0][i] = Float(0.08 * sin(2 * .pi * 90 * t) + 0.04 * sin(2 * .pi * 1000 * t))
            data[1][i] = Float(0.07 * sin(2 * .pi * 440 * t) + 0.03 * sin(2 * .pi * 6000 * t))
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<Int(seconds + 5) { try file.write(from: buffer) }
        }
        let driver = VisualizationDriver()
        driver.synchronize(activity: .playing, visible: true)
        let backend = try AudioEngineBackend(url: url)
        backend.volume = 0
        var inputs = 0, missing = 0, drops: UInt64 = 0
        var rate = 0.0, earlyEnd = false
        var age = BoundedHistogram(), compute = BoundedHistogram()
        backend.onEvent = { _ in earlyEnd = true }
        backend.configureAnalysis(try AnalysisConfiguration(bandCount: 16, framesPerSecond: 30, fftSize: fft)) { frame in
            driver.receive(frame)
            inputs += 1; drops = max(drops, frame.droppedBuffers); rate = frame.timing.sampleRate
            compute.add(frame.computationSeconds)
            if let center = frame.timing.windowCenterHostTime { age.add(frame.timing.producedHostTime - center) }
        }
        defer { backend.stop(); driver.synchronize(activity: .inactive, visible: false) }
        try backend.play()
        let start = VisualizationClock.now(), cpuStart = cpuSeconds()
        var checkpoint = start, next = start
        var render = BoundedHistogram(), handoff = BoundedHistogram(), late = BoundedHistogram(), early = BoundedHistogram()
        var commands = BoundedHistogram()
        var rasterized = 0, failures = 0, unique = 0
        var priorSequence: UInt64?
        var rss: [[String: Double]] = []
        while VisualizationClock.now() - start < seconds {
            let snapshot = driver.snapshot, time = driver.drawTime
            let began = VisualizationClock.now()
            let success = autoreleasepool {
                let content = Canvas { context, size in
                    let began = VisualizationClock.now()
                    LCMPDefaultGEQRenderer.draw(context: context, size: size, snapshot: snapshot, now: time)
                    commands.add(VisualizationClock.now() - began)
                }.frame(width: 360, height: 144)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1
                return renderer.cgImage != nil
            }
            let ended = VisualizationClock.now()
            render.add(ended - began); rasterized += 1
            if !success { failures += 1 }
            if snapshot.waitingForData { missing += 1 }
            if let adoption = driver.presentation.lastAdoption, adoption.sequence != priorSequence {
                priorSequence = adoption.sequence; unique += 1
                handoff.add(ended - adoption.producedAt)
                if let due = adoption.presentationAt, due.isFinite {
                    late.add(max(0, ended - due)); early.add(max(0, due - ended))
                }
            }
            if ended - checkpoint >= (seconds >= 60 ? 30 : 2) {
                let sample = ["elapsed": ended - start, "rssMB": rssMB()]
                rss.append(sample); print("LED_CHECKPOINT \(label) \(sample)"); fflush(nil)
                checkpoint = ended
            }
            next += 1 / 30.0
            if next <= ended { next = ended + 1 / 30.0 }
            try await Task.sleep(for: .seconds(max(0.001, next - VisualizationClock.now())))
        }
        let elapsed = VisualizationClock.now() - start
        let cpu = (cpuSeconds() - cpuStart) / elapsed * 100
        let highWater = driver.presentation.pendingHighWatermark
        let adopted = driver.presentation.adoptionCount
        backend.stop(); driver.synchronize(activity: .inactive, visible: false)
        let stoppedInputs = inputs
        try await Task.sleep(for: .milliseconds(100))
        #expect(inputs == stoppedInputs && !driver.isRunning && driver.presentation.pendingCount == 0)
        let summary: [String: Any] = [
            "label": label, "seconds": elapsed, "fftSize": fft, "observedSampleRate": rate,
            "received": inputs, "adopted": adopted, "rasterized": rasterized, "uniqueRendered": unique,
            "renderFPS": Double(rasterized) / elapsed, "offscreenRenderP95Ms": render.percentile(0.95) * 1000,
            "drawingCommandsP95Ms": commands.percentile(0.95) * 1000,
            "offscreenRenderMaxMs": render.maximum * 1000,
            "analysisP95Ms": compute.percentile(0.95) * 1000, "windowAgeP95Ms": age.percentile(0.95) * 1000,
            "producedToRasterP95Ms": handoff.percentile(0.95) * 1000,
            "estimatedPresentationLatenessP50Ms": late.percentile(0.5) * 1000,
            "estimatedPresentationLatenessP95Ms": late.percentile(0.95) * 1000,
            "estimatedPresentationLatenessMaxMs": late.maximum * 1000,
            "estimatedPresentationEarlinessMaxMs": early.maximum * 1000,
            "cpuPercentOneCore": cpu, "pendingHighWatermark": highWater,
            "droppedPCM": drops, "missingTicks": missing, "rssSamples": rss,
            "physicalSynchronizationMeasured": false
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print("LED_SUMMARY \(String(decoding: json, as: UTF8.self))")
        if let directory = ProcessInfo.processInfo.environment["LCMP_VISUALIZATION_REPORT_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try json.write(to: destination.appendingPathComponent(label + ".json"), options: .atomic)
        }
        #expect(!earlyEnd && failures == 0 && missing == 0)
        #expect(inputs > Int(seconds * 27) && unique > Int(seconds * 20))
        #expect(render.percentile(0.95) < 1 / 30.0)
        #expect(late.count > 0 && late.percentile(0.95) < 0.12)
        #expect(early.maximum < 0.002)
        #expect(highWater <= SpectrumPresentation.capacity && drops == 0 && cpu < 50)
        if seconds >= 600 {
            let warmed = rss.filter { $0["elapsed", default: 0] >= 60 }.compactMap { $0["rssMB"] }
            #expect((warmed.max() ?? 0) - (warmed.min() ?? 0) < 15)
        }
    }
}

private struct BoundedHistogram {
    private var bins = Array(repeating: 0, count: 10001)
    private(set) var count = 0
    private(set) var maximum = 0.0
    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        maximum = max(maximum, value); count += 1
        bins[min(10000, max(0, Int(ceil(value * 10000))))] += 1
    }
    func percentile(_ fraction: Double) -> Double {
        var total = 0
        for (index, value) in bins.enumerated() {
            total += value
            if total >= max(1, Int(ceil(Double(count) * fraction))) { return Double(index) / 10000 }
        }
        return maximum
    }
}
private func cpuSeconds() -> Double {
    var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { return .nan }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}
private func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : .nan
}
#endif
