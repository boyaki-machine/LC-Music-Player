#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import AnalysisCore
@testable import VisualizationKit
@testable import PlayerUI
import PlaybackCore

@Suite struct PresentationTests {
    @Test func ledUsesBandDBFSWithAQuietFloorAndEqualDBSteps() {
        #expect(LCMPDefaultGEQ.id == "LCMP_default_GEQ")
        #expect(LCMPDefaultGEQ.name == "LCMP_default_GEQ")
        let db: [Float] = [-100, -90, -80, -70, -60, -40, -20, -10, 0, 6, -80.1, -76.7, -76.5, -40.1, -39.9, -2.5]
        // Deliberately different generic levels ensure the adapter uses bandDBFS.
        let input = frame(levels: Array(repeating: 1, count: 16), bandDBFS: db)
        var model = SpectrumPresentation()
        let adapted = SpectrumSample(defaultGEQFrame: input)
        #expect(model.receive(adapted, now: input.timing.producedHostTime) == true)
        model.tick(now: input.timing.producedHostTime, playing: true)
        #expect(model.snapshot.counts == [0, 0, 0, 3, 6, 12, 18, 21, 24, 24, 0, 0, 1, 11, 12, 23])
        #expect(input.levels.allSatisfy { $0 == 1 } && input.bandDBFS == db)
        let invalid = SpectrumSample(defaultGEQFrame: frame(levels: Array(repeating: 1, count: 16), bandDBFS: Array(repeating: .nan, count: 16)))
        #expect(model.receive(invalid, now: invalid.producedAt) == false)
    }

    @Test func pcmAmplitudeSweepFallsBelowGreenMidpointAndThenExtinguishes() throws {
        let analyzer = try SpectrumAnalyzer(configuration: LCMPDefaultGEQ.configuration)
        let amplitudes: [Float] = [1, 0.1, 0.01, 0.001, 0.0001, 0]
        var counts: [Int] = [], previousCounts: [Int] = []
        for amplitude in amplitudes {
            // FFT-bin-centered 1125 Hz sine, all Hann main-lobe bins in one band.
            let pcm = (0..<2048).map { amplitude * Float(sin(2 * .pi * 48 * Double($0) / 2048)) }
            let result = try #require(analyzer.analyze(left: pcm, right: pcm, sampleRate: 48000))
            let input = frame(levels: result.levels, bandDBFS: result.db)
            var model = SpectrumPresentation()
            _ = model.receive(SpectrumSample(defaultGEQFrame: input), now: input.timing.producedHostTime)
            model.tick(now: input.timing.producedHostTime, playing: true)
            counts.append(try #require(model.snapshot.counts.max()))
            previousCounts.append(Int((try #require(result.levels.max()) * 24).rounded(.down)))
            #expect(model.snapshot.counts.filter { $0 > 0 }.count <= 1)
        }
        #expect(counts == [23, 17, 11, 5, 0, 0])
        #expect(previousCounts == [23, 18, 13, 8, 4, 0])
        print("LED amplitude sweep \(amplitudes): previous cells \(previousCounts), current cells \(counts)")
    }

    @Test func quantizesWholeCellsAndOnlyOffCellsCarryResidual() {
        var model = SpectrumPresentation()
        let id = UUID()
        #expect(model.receive(sample(id, 1, level: 0.51), now: 10) == true)
        model.tick(now: 10, playing: true)
        #expect(model.snapshot.counts.allSatisfy { $0 == 12 })
        #expect(model.snapshot.residual(column: 0, row: 11, now: 10) == 0)
        #expect(model.receive(sample(id, 2, level: 0.25), now: 10.1) == true)
        model.tick(now: 10.1, playing: true)
        #expect(model.snapshot.counts.allSatisfy { $0 == 6 })
        #expect(model.snapshot.residual(column: 0, row: 5, now: 10.15) == 0)
        #expect(model.snapshot.residual(column: 0, row: 6, now: 10.1) == 0.25)
        #expect(model.snapshot.residual(column: 0, row: 6, now: 10.2) < 0.1)
        model.tick(now: 10.31, playing: false)
        #expect(!model.hasAfterglow(at: 10.31))
        #expect(model.snapshot.extinguishedAt.allSatisfy { $0 == nil })
        #expect(model.receive(sample(id, 3, level: 2), now: 10.32) == true)
        model.tick(now: 10.32, playing: true)
        #expect(model.snapshot.counts.allSatisfy { $0 == 24 })
        #expect(model.snapshot.extinguishedAt.allSatisfy { $0 == nil })
    }

    @Test func futureFramesKeepTheirDeadlineAndTickChoosesOnlyLatestDue() {
        var model = SpectrumPresentation()
        let id = UUID()
        for i in 0..<6 {
            #expect(model.receive(sample(id, UInt64(i + 1), level: Float(i + 1) / 10,
                                         produced: 10 + Double(i) * 0.01, due: 10.1 + Double(i) * 0.01),
                                  now: 10 + Double(i) * 0.01) == true)
        }
        // Adopted `presentationLead` before the presentation time, never earlier.
        let lead = VisualizationClock.presentationLead
        model.tick(now: 10.099 - lead, playing: true)
        #expect(model.adoptionCount == 0)
        model.tick(now: 10.101 - lead, playing: true)
        #expect(model.lastAdoption?.sequence == 1 && model.pendingCount == 5)
        model.tick(now: 10.2, playing: true)
        #expect(model.lastAdoption?.sequence == 6 && model.adoptionCount == 2 && model.pendingCount == 0)
        #expect(model.snapshot.counts[0] == 14)
    }

    @Test func boundsQueueRejectsInvalidAndOldSequenceAndResetsOnGeneration() {
        var model = SpectrumPresentation()
        let id = UUID()
        #expect(model.receive(sample(id, 1, level: .nan), now: 10) == false)
        #expect(model.receive(SpectrumSample(generation: id, sequence: 1, levels: [1], producedAt: 10), now: 10) == false)
        #expect(model.receive(sample(id, 1, produced: 7), now: 10) == false)
        #expect(model.receive(sample(id, 1, produced: .infinity), now: 10) == false)
        for i in 1...1000 { #expect(model.receive(sample(id, UInt64(i), due: 11), now: 10) == true) }
        #expect(model.pendingCount == 64 && model.pendingHighWatermark == 64 && model.discardedSamples == 936)
        #expect(model.receive(sample(id, 999), now: 10) == false)
        model.tick(now: 11, playing: true)
        #expect(model.lastAdoption?.sequence == 1000 && model.adoptionCount == 1)
        #expect(model.receive(sample(UUID(), 1, level: 0, produced: 11), now: 11) == true)
        #expect(model.snapshot.counts.allSatisfy { $0 == 0 } && model.pendingCount == 1)
    }

    @Test func missingDataAndSilenceDifferAndPauseCancelsFutureFrames() {
        var model = SpectrumPresentation()
        let id = UUID()
        model.begin(now: 10)
        model.tick(now: 10.3, playing: true)
        #expect(model.snapshot.waitingForData)
        _ = model.receive(sample(id, 1, level: 0, produced: 10.3), now: 10.3)
        model.tick(now: 10.3, playing: true)
        #expect(!model.snapshot.waitingForData && model.snapshot.counts[0] == 0)
        _ = model.receive(sample(id, 2, level: 1, produced: 10.4), now: 10.4)
        model.tick(now: 10.4, playing: true)
        model.tick(now: 10.7, playing: true)
        #expect(model.snapshot.waitingForData && model.snapshot.counts[0] == 0 && model.hasAfterglow(at: 10.7))
        _ = model.receive(sample(id, 3, level: 0.5, produced: 10.71), now: 10.71)
        model.tick(now: 10.71, playing: true)
        #expect(!model.snapshot.waitingForData && model.snapshot.counts[0] == 12)
        _ = model.receive(sample(id, 4, produced: 10.72, due: 11), now: 10.72)
        model.pause()
        model.tick(now: 12, playing: false)
        #expect(model.pendingCount == 0 && model.snapshot.counts[0] == 12 && !model.snapshot.waitingForData)
        model.reset()
        #expect(model.snapshot.counts[0] == 0 && model.pendingCount == 0)
    }

    @Test func unknownOrInvalidTimingDoesNotInventAClock() {
        var model = SpectrumPresentation()
        let id = UUID()
        for (i, time) in [nil, Double.nan, Double.infinity, 20.0].enumerated() {
            _ = model.receive(sample(id, UInt64(i + 1), due: time), now: 10)
            model.tick(now: 10, playing: true)
            #expect(model.lastAdoption?.sequence == UInt64(i + 1))
            #expect(model.lastAdoption?.presentationAt == nil)
        }
    }

    @Test func futureLastFrameIsShownBeforeMissingAndPauseDismissesWaiting() {
        var model = SpectrumPresentation()
        let id = UUID()
        _ = model.receive(sample(id, 1, due: 10.8), now: 10)
        model.tick(now: 10.5, playing: true)
        #expect(!model.snapshot.waitingForData && model.snapshot.counts[0] == 0)
        model.tick(now: 10.8, playing: true)
        #expect(!model.snapshot.waitingForData && model.snapshot.counts[0] == 24)
        model.tick(now: 11.1, playing: true)
        #expect(model.snapshot.waitingForData)
        model.pause()
        #expect(!model.snapshot.waitingForData)
    }

    @Test func overflowCannotPostponeTheFirstFutureDeadline() {
        var model = SpectrumPresentation()
        let id = UUID()
        for i in 0..<1000 {
            let time = 10 + Double(i) / 1000
            _ = model.receive(sample(id, UInt64(i + 1), produced: time, due: time + 2), now: time)
        }
        #expect(model.pendingCount == SpectrumPresentation.capacity)
        model.tick(now: 12, playing: true)
        #expect(model.lastAdoption?.sequence == 1)
        #expect(model.snapshot.counts[0] == 24)
    }
}

private func sample(_ id: UUID, _ sequence: UInt64, level: Float = 1,
                    produced: Double = 10, due: Double? = nil) -> SpectrumSample {
    SpectrumSample(generation: id, sequence: sequence, levels: Array(repeating: level, count: 16),
                   producedAt: produced, presentationAt: due)
}

@Suite(.serialized) @MainActor struct VisualizationLifecycleTests {
    @Test func driverStopsWhenHiddenOrPausedAndReleasesItsTask() async throws {
        var driver: VisualizationDriver? = VisualizationDriver()
        weak let weakDriver = driver
        driver?.synchronize(activity: .playing, visible: true)
        let generation = UUID()
        driver?.receive(frame(levels: Array(repeating: 0.6, count: 16), generation: generation))
        try await Task.sleep(for: .milliseconds(80))
        #expect(driver?.isRunning == true)
        // A loaded run can stretch the sleep past the 250ms missing interval, which clears the display by design.
        driver?.receive(frame(levels: Array(repeating: 0.6, count: 16), generation: generation, sequence: 2))
        #expect(driver?.snapshot.counts[0] == 12 && driver?.isRunning == true)
        driver?.synchronize(activity: .paused, visible: true)
        #expect(driver?.isRunning == false && driver?.snapshot.counts[0] == 12)
        driver?.synchronize(activity: .playing, visible: true)
        #expect(driver?.snapshot.counts[0] == 0)
        driver?.synchronize(activity: .playing, visible: false)
        #expect(driver?.isRunning == false && driver?.presentation.pendingCount == 0)
        driver?.synchronize(activity: .playing, visible: true)
        driver = nil
        try await Task.sleep(for: .milliseconds(50))
        #expect(weakDriver == nil)
    }

    @Test func controllerInvalidatesOldAnalysisOnStopSeekAndSubscriptionChanges() {
        let backend = AnalysisBackend()
        let controller = PlaybackController(fileAccess: TestAccess(), makeBackend: { _ in backend })
        controller.configureAnalysis(LCMPDefaultGEQ.configuration)
        controller.select(URL(fileURLWithPath: "/tmp/visualization.wav")); controller.togglePlayPause()
        let old = backend.receive
        old?(frame(levels: Array(repeating: 1, count: 16)))
        #expect(controller.analysisFrame != nil)
        let before = controller.analysisResetID
        controller.seek(to: 1)
        #expect(controller.analysisResetID != before && controller.analysisFrame == nil)
        old?(frame(levels: Array(repeating: 1, count: 16)))
        #expect(controller.analysisFrame == nil)
        backend.receive?(frame(levels: Array(repeating: 0.5, count: 16)))
        #expect(controller.analysisFrame != nil)
        let beforePause = controller.analysisResetID
        controller.togglePlayPause()
        #expect(controller.analysisResetID == beforePause && controller.analysisFrame == nil)
        controller.seek(to: 2)
        #expect(controller.analysisResetID != beforePause)
        controller.togglePlayPause(); controller.stop()
        let beforeRestart = backend.receive
        controller.togglePlayPause()
        beforeRestart?(frame(levels: Array(repeating: 1, count: 16)))
        #expect(controller.analysisFrame == nil)
        controller.configureAnalysis(nil)
        backend.receive?(frame(levels: Array(repeating: 1, count: 16)))
        // A backend honoring nil delivers no callback; a retired callback is gated.
        old?(frame(levels: Array(repeating: 1, count: 16)))
        #expect(controller.analysisFrame == nil)
        controller.close()
    }

    @Test func rendersNativeLEDStatesWithinCompactBounds() async throws {
        let driver = VisualizationDriver()
        driver.synchronize(activity: .playing, visible: true)
        driver.receive(frame(levels: (0..<16).map { 0.2 + 0.8 * Float($0 + 1) / 16 }))
        try await Task.sleep(for: .milliseconds(70))
        let host = NSHostingView(rootView: LCMPDefaultGEQView(driver: driver))
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 144)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 360 && host.fittingSize.height <= 144)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            // cacheDisplay does not capture the Metal view: draw the same frame off screen under the labels.
            let size = CGSize(width: 360, height: 144)
            let cells = try #require(LCMPDefaultGEQMetal.shared?.image(LCMPDefaultGEQFrame(snapshot: driver.snapshot, now: driver.drawTime),
                                                                       size: size, scale: 2))
            let renderer = ImageRenderer(content: ZStack {
                Image(decorative: cells, scale: 2)
                Canvas { context, size in LCMPDefaultGEQRenderer.drawLabels(context: context, size: size, axisLabelSize: 9) }
            }.frame(width: size.width, height: size.height))
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("fluorescent-native.png"))
        }
        driver.synchronize(activity: .inactive, visible: false)
        window.contentView = nil
    }
}

func frame(levels: [Float], generation: UUID = UUID(), sequence: UInt64 = 1, bandDBFS: [Float]? = nil) -> AnalysisFrame {
    let now = VisualizationClock.now()
    return AnalysisFrame(generation: generation, sequence: sequence,
        timing: AnalysisTiming(windowStartSample: 0, windowFrameCount: 2048, sampleRate: 48000,
            windowCenterHostTime: now - 0.02, estimatedOutputLatency: 0.01, appliedAudioDelay: 0, producedHostTime: now),
        bandEdgesHz: (0...16).map { 20 * pow(1000, Double($0) / 16) }, bandDBFS: bandDBFS ?? levels.map { $0 * 100 - 100 },
        levels: levels, leftRMS: 0.2, rightRMS: 0.2, leftPeak: 0.3, rightPeak: 0.3,
        droppedBuffers: 0, queuedBufferHighWatermark: 1, computationSeconds: 0.001)
}

@MainActor private struct TestAccess: FileAccess {
    func acquire(_ url: URL) throws -> FileLease { FileLease {} }
}
@MainActor private final class AnalysisBackend: PlaybackBackend {
    let duration = 10.0
    var currentTime = 0.0
    let supportsSeeking = true
    var volume: Float = 0
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var receive: (@MainActor (AnalysisFrame) -> Void)?
    func configureAnalysis(_ configuration: AnalysisConfiguration?, receive: (@MainActor (AnalysisFrame) -> Void)?) {
        self.receive = configuration == nil ? nil : receive
    }
    func play() throws {}
    func pause() throws {}
    func resume() throws {}
    func stop() {}
    func seek(to seconds: TimeInterval) throws { currentTime = seconds }
}
#endif
