#if os(macOS)
import AppKit
import AudioToolbox
import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import AnalysisCore
@testable import AudioProcessingCore
@testable import LibraryCore
@testable import PlayerUI
@testable import VisualizationKit

@Suite struct RadioCassetteTapeTests {
    @Test func reelsTurnFasterAsTheirPackEmpties() {
        #expect(abs(RadioCassetteTape.radius(filled: 0) - RadioCassetteTape.emptyRadius) < 1e-9)
        #expect(abs(RadioCassetteTape.radius(filled: 1) - RadioCassetteTape.fullRadius) < 1e-9)
        var tape = RadioCassetteTape()
        #expect(tape.position == 0.35 && !tape.reverse)
        // The left reel is fuller at the start, so it turns slower.
        #expect(tape.rpm[0] < tape.rpm[1])
        let speed = { (r: Double) in RadioCassetteTape.tapeSpeed / r / (2 * .pi) * 60 }
        #expect(abs(speed(RadioCassetteTape.emptyRadius) - 45.5) < 1e-9)
        #expect(abs(speed(RadioCassetteTape.fullRadius) - 18.9) < 1e-9)
        // Forward turns both reels anticlockwise: negative angles on a y-down drawing.
        tape.advance(seconds: 0.1)
        #expect(tape.angles.allSatisfy { $0 < 0 } && tape.flow > 0)
        #expect(abs(tape.angles[0]) < abs(tape.angles[1]))
    }

    @Test func oneSideTakesTenMinutesAndTheDeckReversesAtTheEnd() {
        var tape = RadioCassetteTape()
        for _ in 0..<Int(0.65 * 600 * 30 - 30) { tape.advance(seconds: 1.0 / 30) }
        #expect(!tape.reverse && tape.position > 0.99)
        for _ in 0..<60 { tape.advance(seconds: 1.0 / 30) }
        #expect(tape.reverse && tape.position < 1)
        #expect(abs(tape.radii[1] - RadioCassetteTape.fullRadius) < 0.2)
        // Reverse turns the reels clockwise and runs the tape back.
        let angles = tape.angles, flow = tape.flow
        tape.advance(seconds: 0.01)
        #expect(zip(tape.angles, angles).allSatisfy { $0 > $1 } && tape.flow < flow)
    }

    @Test func aNewTrackKeepsThePlaceAndReversesTheTape() {
        var tape = RadioCassetteTape()
        tape.advance(seconds: 30)
        let place = tape.position
        tape.nextTrack()
        #expect(tape.reverse && tape.position == place)
        tape.advance(seconds: 30)
        #expect(abs(tape.position - 0.35) < 1e-9)
    }
}

@Suite struct RadioCassetteIndicatorTests {
    @Test func lampsNameTheDeviceSettingsAndTrack() {
        var status = RadioCassetteStatus(power: .battery, output: OutputDevice(kind: "blue", identifier: "x", name: "WF-1000XM6"),
                                         format: RadioCassetteFormat(codec: "AAC", lossless: false, sampleRate: 44100, bitRate: 256_000),
                                         levellingTarget: -16, bass: .light)
        #expect(status.indicators.map(\.text) == ["BATTERY", "WF-1000XM6", "AAC 256kbps", "ALC mode 16", "B-BOOST mode 1"])
        #expect(status.indicators[0].inverted && status.indicators.dropFirst().allSatisfy { $0.lit && !$0.inverted })
        status.power = .external; status.levellingTarget = nil; status.bass = .off
        status.output = OutputDevice(kind: "bltn", identifier: "y", name: "MacBook Pro Speakers", isBuiltInSpeaker: true)
        #expect(status.indicators.map(\.text) == ["AC POWER", "SPEAKER", "AAC 256kbps", "ALC OFF", "B-BOOST OFF"])
        #expect(!status.indicators[0].inverted && !status.indicators[3].lit && !status.indicators[4].lit)
        status.levellingTarget = -23; status.bass = .strong
        #expect(status.indicators[3].text == "ALC mode 23" && status.indicators[4].text == "B-BOOST mode 2")
        status.output = OutputDevice(kind: "hdpn", identifier: "z", name: "  ")
        #expect(status.indicators[1].text == "HEADPHONES")
        #expect(RadioCassetteStatus.direction(reverse: false).text == "FORWARD ▶")
        #expect(RadioCassetteStatus.direction(reverse: true).text == "◀ REVERSE")
        #expect(RadioCassetteStatus().indicators.map(\.lit) == [false, false, false, false, false])
    }

    @Test func formatsShowBitRateWhenLossyAndSampleRateWhenLossless() {
        let label = { (id: AudioFormatID, rate: Double, bits: Double?, ext: String) in
            RadioCassetteFormat(formatID: id, sampleRate: rate, bitRate: bits, pathExtension: ext).label
        }
        #expect(label(kAudioFormatMPEG4AAC, 44100, 255_800, "m4a") == "AAC 256kbps")
        #expect(label(kAudioFormatMPEGLayer3, 44100, 320_000, "mp3") == "MP3 320kbps")
        #expect(label(kAudioFormatFLAC, 96000, 2_000_000, "flac") == "FLAC 96kHz")
        #expect(label(kAudioFormatAppleLossless, 44100, 900_000, "m4a") == "ALAC 44.1kHz")
        #expect(label(kAudioFormatLinearPCM, 48000, 1_536_000, "wav") == "WAV 48kHz")
        #expect(label(kAudioFormatLinearPCM, 44100, nil, "aiff") == "AIFF 44.1kHz")
        #expect(label(0, 0, nil, "flac") == "FLAC")
    }

    @Test func readsTheCodingOfARealFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-radio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                                                                     AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            try file.write(from: buffer)
        }
        let read = try #require(await RadioCassetteFormat.read(url))
        #expect(read.label == "WAV 48kHz")
    }

    @Test func readsTheAverageBitRateOfACompressedFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-radio-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                                                     AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 3))
            buffer.frameLength = buffer.frameCapacity
            // Noise keeps the encoder near its bit rate.
            var seed: UInt32 = 1
            for channel in 0..<2 {
                for i in 0..<Int(buffer.frameLength) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    buffer.floatChannelData![channel][i] = Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.3
                }
            }
            try file.write(from: buffer)
        }
        let read = try #require(await RadioCassetteFormat.read(url))
        let rate = try #require(read.bitRate)
        #expect(read.codec == "AAC" && !read.lossless && rate > 90_000 && rate < 170_000, "\(read)")
        #expect(read.label.hasPrefix("AAC ") && read.label.hasSuffix("kbps"))
    }

    @Test func longTextIsSqueezedThenCut() {
        let font = NSFont.systemFont(ofSize: 7, weight: .semibold) as CTFont
        let short = RadioCassetteLayers.fit("AAC 256kbps", font: font, width: 58)
        #expect(short.text == "AAC 256kbps" && short.squeeze == 1)
        let medium = RadioCassetteLayers.fit("B-BOOST mode 2", font: font, width: 50)
        #expect(medium.text == "B-BOOST mode 2" && medium.squeeze < 1 && medium.width * medium.squeeze <= 50.5)
        let long = RadioCassetteLayers.fit("Very Long Bluetooth Headphones Name", font: font, width: 58)
        #expect(long.text.hasSuffix("…") && long.squeeze == RadioCassetteGeometry.minimumTextSqueeze)
        #expect(long.width * long.squeeze <= 58.5)
    }
}

@Suite struct RadioCassetteMeterTests {
    @Test func rmsPlus3dBFillsTheColumnFromMinus30dBAndFallsWithin300ms() {
        #expect(RadioCassetteMeter.level(rms: 0) == 0 && RadioCassetteMeter.level(rms: .nan) == 0)
        #expect(RadioCassetteMeter.level(rms: 1) == 1)
        // −15dB RMS reads −12dB: 18 of 30dB, 0.6 of the column.
        #expect(abs(RadioCassetteMeter.level(rms: pow(10, -15.0 / 20)) - 0.6) < 1e-5)
        var meter = RadioCassetteMeter()
        meter.follow([0.5, 1], dt: 1.0 / 30, reduceMotion: false)
        #expect(meter.litCells == [12, 24])
        meter.follow([0, 0], dt: 0.15, reduceMotion: false)
        #expect(meter.litCells == [0, 12])
        meter.follow(nil, dt: 0.15, reduceMotion: false)
        #expect(meter.litCells == [0, 0])
        meter.follow([1, 1], dt: 0.03, reduceMotion: true)
        meter.follow([0, 0.25], dt: 0.03, reduceMotion: true)
        #expect(meter.litCells == [0, 6])
    }
}

@MainActor private final class FrameSink: RadioCassetteRendering {
    var frames: [RadioCassetteFrame] = []
    func render(_ frame: RadioCassetteFrame) { frames.append(frame) }
}

private func analysis(rms: Float, sequence: UInt64, generation: UUID) -> AnalysisFrame {
    let now = VisualizationClock.now()
    return AnalysisFrame(generation: generation, sequence: sequence,
        timing: AnalysisTiming(windowStartSample: 0, windowFrameCount: 2048, sampleRate: 48000,
            windowCenterHostTime: now - 0.02, estimatedOutputLatency: 0.01, appliedAudioDelay: 0, producedHostTime: now),
        bandEdgesHz: (0...16).map { 20 * pow(1000, Double($0) / 16) }, bandDBFS: Array(repeating: -40, count: 16),
        levels: Array(repeating: 0.6, count: 16), leftRMS: rms, rightRMS: rms / 4, leftPeak: rms, rightPeak: rms,
        droppedBuffers: 0, queuedBufferHighWatermark: 1, computationSeconds: 0.001)
}

@MainActor @Suite struct RadioCassetteDriverTests {
    @Test func runsOnlyWhileVisibleAndPlaying() {
        let driver = RadioCassetteDriver()
        driver.synchronize(activity: .playing, visible: false)
        #expect(!driver.isRunning)
        driver.synchronize(activity: .playing, visible: true)
        #expect(driver.isRunning)
        driver.synchronize(activity: .paused, visible: true)
        #expect(!driver.isRunning)
        driver.synchronize(activity: .playing, visible: true)
        driver.synchronize(activity: .inactive, visible: true)
        #expect(!driver.isRunning)
    }

    @Test func meterFollowsTheMusicHoldsOnPauseAndEmptiesOnStop() throws {
        let driver = RadioCassetteDriver(), sink = FrameSink(), generation = UUID()
        driver.attach(sink)
        driver.synchronize(activity: .playing, visible: true)
        let start = VisualizationClock.now()
        driver.step(now: start)
        driver.receive(analysis(rms: 1, sequence: 1, generation: generation))
        driver.step(now: start + 0.05)
        #expect(driver.frame.litCells == [24, 16])
        let place = driver.frame.tape
        driver.synchronize(activity: .paused, visible: true)
        driver.step(now: start + 1)
        #expect(driver.frame.litCells == [24, 16] && driver.frame.tape == place)
        driver.synchronize(activity: .inactive, visible: true)
        #expect(try #require(sink.frames.last).litCells == [0, 0])
        driver.synchronize(activity: .inactive, visible: false)
    }

    @Test func tapeMovesOnlyWhilePlayingAndReversesForEachNewTrack() {
        let driver = RadioCassetteDriver(), sink = FrameSink()
        driver.attach(sink)
        let first = UUID()
        driver.receive(status: RadioCassetteStatus(), selection: first)
        #expect(!driver.frame.tape.reverse && driver.frame.indicators.last?.text == "FORWARD ▶")
        driver.receive(status: RadioCassetteStatus(), selection: first)
        #expect(!driver.frame.tape.reverse)
        driver.synchronize(activity: .playing, visible: true)
        let start = VisualizationClock.now()
        driver.step(now: start); driver.step(now: start + 0.1)
        #expect(driver.frame.tape.position > 0.35)
        driver.receive(status: RadioCassetteStatus(), selection: UUID())
        #expect(driver.frame.tape.reverse && sink.frames.last?.indicators.last?.text == "◀ REVERSE")
        driver.synchronize(activity: .inactive, visible: false)
        let hidden = sink.frames.count
        driver.receive(status: RadioCassetteStatus(power: .battery), selection: nil)
        #expect(sink.frames.count == hidden)
        #expect(driver.frame.indicators.first?.text == "BATTERY")
    }
}

@MainActor @Suite struct RadioCassetteRenderingTests {
    private func render(_ frame: RadioCassetteFrame, size: CGSize = RadioCassetteGeometry.designSize, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let layers = RadioCassetteLayers()
        layers.layout(size: size, screenScale: scale)
        layers.render(frame)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        // On screen the flipped host view's layer runs top to bottom; stand in for it here, drawing
        // into the bottom-up bitmap, so shapes and text both come out as they do on screen.
        let host = CALayer(); host.isGeometryFlipped = true; host.addSublayer(layers.root)
        context.translateBy(x: 0, y: size.height * scale); context.scaleBy(x: scale, y: -scale)
        host.render(in: context)
        return bitmap
    }
    private func darkness(_ bitmap: NSBitmapImageRep, _ point: CGPoint, scale: CGFloat = 2) -> CGFloat {
        guard let color = bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)) else { return 0 }
        return 1 - (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
    private func save(_ bitmap: NSBitmapImageRep, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"],
              let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test func drawsTheLampsMeterAndTapeOnTheLCD() throws {
        var frame = RadioCassetteFrame()
        frame.litCells = [18, 6]
        frame.indicators = RadioCassetteStatus(power: .battery, output: OutputDevice(kind: "blue", identifier: "x", name: "WF-1000XM6"),
                                               format: RadioCassetteFormat(codec: "AAC", lossless: false, sampleRate: 44100, bitRate: 256_000),
                                               levellingTarget: -16, bass: .off).indicators + [RadioCassetteStatus.direction(reverse: false)]
        let bitmap = try render(frame)
        save(bitmap, "radio-cassette.png")
        // The glass, away from every line.
        #expect(darkness(bitmap, CGPoint(x: 210, y: 6)) < 0.6)
        // The battery lamp is inverted: dark inside its box.
        let battery = RadioCassetteGeometry.indicatorFrame(0)
        #expect(darkness(bitmap, CGPoint(x: battery.minX + 2, y: battery.midY)) > 0.8)
        // An ordinary lamp keeps the glass inside; B-BOOST OFF is unlit (paler outline).
        let output = RadioCassetteGeometry.indicatorFrame(1), bass = RadioCassetteGeometry.indicatorFrame(4)
        #expect(darkness(bitmap, CGPoint(x: output.minX + 2, y: output.midY)) < 0.6)
        #expect(darkness(bitmap, CGPoint(x: output.minX + 0.25, y: output.midY)) > darkness(bitmap, CGPoint(x: bass.minX + 0.25, y: bass.midY)))
        // Lit cells are dark, unlit cells pale: 18 lit on the left, 6 on the right.
        let lit = RadioCassetteGeometry.meterCell(column: 0, row: 17), unlit = RadioCassetteGeometry.meterCell(column: 0, row: 18)
        let right = RadioCassetteGeometry.meterCell(column: 1, row: 6)
        #expect(darkness(bitmap, CGPoint(x: lit.midX, y: lit.midY)) > 0.8)
        #expect(darkness(bitmap, CGPoint(x: unlit.midX, y: unlit.midY)) < 0.6)
        #expect(darkness(bitmap, CGPoint(x: right.midX, y: right.midY)) < 0.6)
        // The left pack is drawn at its radius.
        let r = CGFloat(frame.tape.radii[0]), c = RadioCassetteGeometry.leftReel
        #expect(darkness(bitmap, CGPoint(x: c.x, y: c.y - r)) > 0.5)
    }

    @Test func meterCellsFollowRisesAndFallsAcrossFrames() throws {
        let layers = RadioCassetteLayers()
        layers.layout(size: RadioCassetteGeometry.designSize, screenScale: 2)
        let host = CALayer(); host.isGeometryFlipped = true; host.addSublayer(layers.root)
        var frame = RadioCassetteFrame()
        for levels in [[18, 6], [4, 20], [4, 20], [24, 0]] {
            frame.litCells = levels
            layers.render(frame)
            let cells = (layers.root.sublayers ?? []).flatMap { $0.sublayers ?? [] }.filter { !($0 is CATextLayer) && !($0 is CAShapeLayer) }
            #expect(cells.count == 48)
            for column in 0..<2 {
                let lit = cells[column * 24..<column * 24 + 24].map { $0.backgroundColor == RadioCassetteGeometry.Ink.dark }
                #expect(lit == (0..<24).map { $0 < levels[column] }, "\(levels)")
            }
        }
    }

    @Test func spreadsTheBlocksOnAWideScreen() throws {
        let size = CGSize(width: 560, height: 196)
        let bitmap = try render(RadioCassetteFrame(), size: size, scale: 1)
        save(bitmap, "radio-cassette-wide.png")
        let layout = RadioCassetteGeometry.Layout(size: size)
        #expect(abs(layout.scale - 196.0 / 144) < 1e-9 && layout.gap > 0)
        // The meter keeps to the right edge, inside the view.
        let cell = RadioCassetteGeometry.meterCell(column: 1, row: 0)
        let x = (layout.origin.x + layout.meterOffset + cell.maxX) * layout.scale
        #expect(x < size.width && x > size.width - 60)
    }

    @Test func theMacViewRunsTopToBottomWhateverItsSuperviewsDo() {
        let view = RadioCassetteHostView()
        // A flipped, layer-backed view; the design's root layer itself is not flipped again.
        #expect(view.isFlipped && view.wantsLayer && view.layers.root.superlayer === view.layer)
        #expect(!view.layers.root.isGeometryFlipped)
    }

    @Test func changedLampsAreRedrawnAtOnce() {
        let layers = RadioCassetteLayers()
        layers.layout(size: RadioCassetteGeometry.designSize, screenScale: 2)
        var frame = RadioCassetteFrame()
        frame.indicators[3] = RadioCassetteIndicator(text: "ALC mode 16")
        layers.render(frame)
        frame.indicators[3] = RadioCassetteIndicator(text: "ALC OFF", lit: false)
        layers.render(frame)
        let texts = (layers.root.sublayers ?? []).flatMap { $0.sublayers ?? [] }.compactMap { $0 as? CATextLayer }
        let lamp = texts.first { $0.string as? String == "ALC OFF" }
        // The new size applies at once; the text must not wait for a later redraw to match it.
        #expect(lamp != nil && lamp?.needsDisplay() == false)
    }

    @Test func hubsTurnWithTheTape() throws {
        var frame = RadioCassetteFrame()
        let before = try render(frame)
        frame.tape.advance(seconds: 0.2)
        let after = try render(frame)
        let hub = RadioCassetteGeometry.leftReel, r = CGFloat(RadioCassetteTape.hubRadius) - 1.5
        // A tooth on the right of the hub moves away.
        #expect(darkness(before, CGPoint(x: hub.x + r, y: hub.y)) > darkness(after, CGPoint(x: hub.x + r, y: hub.y)) + 0.2)
    }
}
#endif
