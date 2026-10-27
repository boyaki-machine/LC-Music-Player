#if os(macOS)
import AppKit
import AVFAudio
import Darwin
import Foundation
import Metal
import MetalKit
import SwiftUI
import Testing
import AnalysisCore
import PlaybackCore
import PreprocessingCore
import VisualizationKit
@testable import PlayerUI

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

    /// The same measurement for heavier sources: compressed, high sample rates, and the volume
    /// adjustment, which decodes through ProfileDecoder and adds the level gain.
    @Test(arguments: SourceCondition.allCases)
    func comparesSourceConditions(_ condition: SourceCondition) async throws {
        try await measure(fft: 2048, seconds: 6, label: "source-\(condition.rawValue)", source: condition)
    }

    /// The LED in a visible window at 30 Hz, drawn by the Canvas renderer and by the Metal view in turns.
    /// Only the drawing runs (no playback), so the difference is the renderer's own cost.
    @Test func comparesOnScreenRenderers() async throws {
        var results: [String: [(cpu: Double, milliwatts: Double, wakeups: Double)]] = [:]
        for renderer in ["canvas", "metal", "canvas", "metal"] {
            results[renderer, default: []].append(try await measureOnScreen(metal: renderer == "metal"))
        }
        var summary: [String: Any] = ["label": "onscreen-renderers"]
        for (name, samples) in results {
            summary[name] = ["cpuPercentOneCore": samples.map(\.cpu), "energyMilliwatts": samples.map(\.milliwatts),
                             "wakeupsPerSecond": samples.map(\.wakeups)]
        }
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print("LED_ONSCREEN \(String(decoding: json, as: UTF8.self))")
        if let directory = ProcessInfo.processInfo.environment["LCMP_VISUALIZATION_REPORT_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try json.write(to: destination.appendingPathComponent("onscreen-renderers.json"), options: .atomic)
        }
        let canvas = results["canvas", default: []].map(\.milliwatts).reduce(0, +)
        let metal = results["metal", default: []].map(\.milliwatts).reduce(0, +)
        #expect(metal < canvas)
    }

    private func measureOnScreen(metal: Bool, seconds: Double = 15) async throws -> (cpu: Double, milliwatts: Double, wakeups: Double) {
        let states = LCMPDefaultGEQMetalTests.states()
        let ticker = OnScreenTicker()
        let host = NSHostingView(rootView: OnScreenLED(ticker: ticker, states: states.map(\.frame), metal: metal))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 360, height: 144), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .seconds(1))
        let cpuStart = cpuSeconds(), energyStart = energy(), start = VisualizationClock.now()
        while VisualizationClock.now() - start < seconds {
            ticker.tick += 1
            try await Task.sleep(for: .milliseconds(33))
        }
        let elapsed = VisualizationClock.now() - start, energyEnd = energy()
        return ((cpuSeconds() - cpuStart) / elapsed * 100, Double(energyEnd.nanojoules - energyStart.nanojoules) / elapsed / 1e6,
                Double(energyEnd.wakeups - energyStart.wakeups) / elapsed)
    }

    private func measure(fft: Int, seconds: Double, label: String, source: SourceCondition = .wav48k) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-led-\(UUID()).\(source.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try source.write(url, seconds: Int(seconds + 5))
        let backend: AudioEngineBackend
        if source.normalized {
            let profile = try AudioEngineBackend.measurementProfile()
            let metrics = try await AudioPreprocessor.shared.measureLevels(url, profile: profile)
            backend = try AudioEngineBackend(prepared: try await AudioPreprocessor.shared.prepare(url), metrics: metrics)
        } else { backend = try AudioEngineBackend(url: url) }
        // The display clock starts with playback, after the measurement above.
        let driver = VisualizationDriver()
        driver.synchronize(activity: .playing, visible: true)
        backend.volume = 0
        var inputs = 0, missing = 0, drops: UInt64 = 0
        var rate = 0.0, earlyEnd = false, outputLatency = Double.nan
        var age = BoundedHistogram(), compute = BoundedHistogram()
        backend.onEvent = { _ in earlyEnd = true }
        backend.configureAnalysis(try AnalysisConfiguration(bandCount: 16, framesPerSecond: 30, fftSize: fft)) { frame in
            driver.receive(frame)
            inputs += 1; drops = max(drops, frame.droppedBuffers); rate = frame.timing.sampleRate
            compute.add(frame.computationSeconds); outputLatency = frame.timing.estimatedOutputLatency ?? .nan
            if let center = frame.timing.windowCenterHostTime { age.add(frame.timing.producedHostTime - center) }
        }
        defer { backend.stop(); driver.synchronize(activity: .inactive, visible: false) }
        // The view's Metal renderer, with the glow images it keeps between frames.
        let metal = try #require(LCMPDefaultGEQMetal.shared)
        let glow = try #require(LCMPDefaultGEQGlow(layout: LCMPDefaultGEQLayout(size: CGSize(width: 360, height: 144), axisLabelSize: 9),
                                                   scale: 1, device: metal.device))
        let scratch = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LCMPDefaultGEQMetal.colorFormat, width: 360, height: 144, mipmapped: false)
        scratch.usage = .renderTarget; scratch.storageMode = .private
        let target = try #require(metal.device.makeTexture(descriptor: scratch))
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
            let frame = LCMPDefaultGEQFrame(snapshot: snapshot, now: time)
            let success = autoreleasepool {
                // Listing the rectangles alone, into a pass that is never committed.
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                if let buffer = metal.queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
                    let began = VisualizationClock.now()
                    metal.encode(frame, glow: glow, into: encoder, scale: 1)
                    commands.add(VisualizationClock.now() - began)
                    encoder.endEncoding()
                }
                return metal.image(frame, glow: glow) != nil
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
            "estimatedOutputLatencyMs": outputLatency * 1000,
            "received": inputs, "adopted": adopted, "rasterized": rasterized, "uniqueRendered": unique,
            "renderFPS": Double(rasterized) / elapsed, "offscreenRenderP95Ms": render.percentile(0.95) * 1000,
            "drawingCommandsP95Ms": commands.percentile(0.95) * 1000,
            "offscreenRenderMaxMs": render.maximum * 1000,
            "analysisP95Ms": compute.percentile(0.95) * 1000, "windowAgeP95Ms": age.percentile(0.95) * 1000,
            "producedToRasterP95Ms": handoff.percentile(0.95) * 1000,
            "estimatedPresentationLatenessP50Ms": late.percentile(0.5) * 1000,
            "estimatedPresentationLatenessP95Ms": late.percentile(0.95) * 1000,
            "estimatedPresentationLatenessMaxMs": late.maximum * 1000,
            "estimatedPresentationEarlinessP95Ms": early.percentile(0.95) * 1000,
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
        #expect(early.maximum < VisualizationClock.presentationLead + 0.002)
        #expect(highWater <= SpectrumPresentation.capacity && drops == 0 && cpu < 50)
        if seconds >= 600 {
            let warmed = rss.filter { $0["elapsed", default: 0] >= 60 }.compactMap { $0["rssMB"] }
            #expect((warmed.max() ?? 0) - (warmed.min() ?? 0) < 15)
        }
    }
}

@Observable @MainActor private final class OnScreenTicker { var tick = 0 }

/// The two ways `LCMPDefaultGEQView` draws, fed the comparison frames in turn.
private struct OnScreenLED: View {
    let ticker: OnScreenTicker
    let states: [LCMPDefaultGEQFrame]
    let metal: Bool
    var body: some View {
        let frame = states[ticker.tick % states.count]
        if metal, let renderer = LCMPDefaultGEQMetal.shared {
            FrameStageView(metal: renderer, frame: frame).overlay { LCMPDefaultGEQLabels(axisLabelSize: 9) }
        } else {
            Canvas { context, size in LCMPDefaultGEQRenderer.draw(context: context, size: size, snapshot: frame.snapshot, now: frame.now) }
        }
    }
}

/// The Metal view shown a given frame rather than following a driver.
struct FrameStageView: NSViewRepresentable {
    let metal: LCMPDefaultGEQMetal
    let frame: LCMPDefaultGEQFrame
    func makeCoordinator() -> LCMPDefaultGEQStageCoordinator { LCMPDefaultGEQStageCoordinator(metal: metal) }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateNSView(_ view: MTKView, context: Context) { context.coordinator.show(frame) }
}

/// Generated test sources. Each repeats one second of the same stereo tones.
enum SourceCondition: String, CaseIterable, Sendable {
    case wav48k = "wav-48k-float", aac44k = "aac-44k", flac96k = "flac-96k-24bit",
         wav192k = "wav-192k-24bit", flac96kNormalized = "flac-96k-24bit-normalized"

    var fileExtension: String {
        switch self {
        case .wav48k, .wav192k: "wav"
        case .aac44k: "m4a"
        case .flac96k, .flac96kNormalized: "flac"
        }
    }
    var normalized: Bool { self == .flac96kNormalized }
    private var sampleRate: Double {
        switch self {
        case .wav48k: 48000
        case .aac44k: 44100
        case .flac96k, .flac96kNormalized: 96000
        case .wav192k: 192000
        }
    }

    func write(_ url: URL, seconds: Int) throws {
        let rate = sampleRate, frames = AVAudioFrameCount(rate)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            data[0][i] = Float(0.08 * sin(2 * .pi * 90 * t) + 0.04 * sin(2 * .pi * 1000 * t))
            data[1][i] = Float(0.07 * sin(2 * .pi * 440 * t) + 0.03 * sin(2 * .pi * 6000 * t))
        }
        switch self {
        case .wav48k:
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<seconds { try file.write(from: buffer) }
        case .wav192k:
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                           AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            for _ in 0..<seconds { try file.write(from: buffer) }
        case .aac44k:
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                           AVEncoderBitRateKey: 256_000]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            for _ in 0..<seconds { try file.write(from: buffer) }
        case .flac96k, .flac96kNormalized:
            // AVAudioFile wraps FLAC in a CAF container; Extended Audio File Services write a FLAC file.
            var flac = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatFLAC, mFormatFlags: kAppleLosslessFormatFlag_24BitSourceData,
                                                   mBytesPerPacket: 0, mFramesPerPacket: 4096, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            var file: ExtAudioFileRef?
            try #require(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &flac, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr)
            var client = format.streamDescription.pointee
            try #require(ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr)
            for _ in 0..<seconds { try #require(ExtAudioFileWrite(file!, frames, buffer.audioBufferList) == noErr) }
            try #require(ExtAudioFileDispose(file!) == noErr)
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
/// The process's CPU energy (all cores) and wakeups, readable without privileges.
private func energy() -> (nanojoules: UInt64, wakeups: UInt64) {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    return result == 0 ? (info.ri_energy_nj, info.ri_pkg_idle_wkups + info.ri_interrupt_wkups) : (0, 0)
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
