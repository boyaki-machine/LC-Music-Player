import AVFAudio
import Foundation
import Testing
import LevelDSP
@testable import AudioProcessingCore

private let rate = 48000.0

/// Runs the stage over non-interleaved channels in blocks of 512, as a render does. `change`
/// sets another strength before the block that holds that frame.
private func process(_ input: [[Float]], _ strength: BassEnhancement,
                     change: (frame: Int, to: BassEnhancement)? = nil) throws -> [[Float]] {
    let punch = try #require(lcmp_bass_punch_create(rate, UInt32(input.count)))
    defer { lcmp_bass_punch_destroy(punch) }
    lcmp_bass_punch_set_strength(punch, Int32(strength.rawValue))
    lcmp_bass_punch_reset(punch)
    let frames = input[0].count
    let channels = input.map { samples in
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
        _ = buffer.initialize(from: samples)
        return buffer
    }
    defer { channels.forEach { $0.deallocate() } }
    for start in stride(from: 0, to: frames, by: 512) {
        if let change, change.frame >= start, change.frame < start + 512 {
            lcmp_bass_punch_set_strength(punch, Int32(change.to.rawValue))
        }
        // In place, as the unit does when the output has no buffer of its own.
        let targets: [UnsafeMutablePointer<Float>?] = channels.map { $0.baseAddress! + start }
        let sources: [UnsafePointer<Float>?] = targets.map { UnsafePointer($0) }
        lcmp_bass_punch_process(punch, sources, targets, UInt32(min(512, frames - start)))
    }
    return channels.map { Array($0) }
}
private func sine(_ frequency: Double, amplitude: Double, seconds: Double) -> [Float] {
    (0..<Int(seconds*rate)).map { Float(amplitude*sin(2 * .pi*frequency*Double($0)/rate)) }
}
private func rms(_ samples: ArraySlice<Float>) -> Double {
    (samples.reduce(0) { $0 + Double($1)*Double($1) }/Double(samples.count)).squareRoot()
}
private func db(_ ratio: Double) -> Double { 20*log10(ratio) }
/// A kick-like hit every half second: a falling 90→50Hz sweep with an 80ms decay.
private func kicks(seconds: Double, amplitude: Double) -> [Float] {
    var phase = 0.0
    return (0..<Int(seconds*rate)).map { n in
        let t = Double(n % Int(rate/2))/rate
        if t == 0 { phase = 0 }
        phase += 2 * .pi*(50 + 40*exp(-t/0.03))/rate
        return Float(amplitude*exp(-t/0.08)*sin(phase))
    }
}
/// Deterministic noise in −1…1.
private func noise(_ count: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 1_000_000)/1_000_000
    }
}

@Suite struct BassPunchTests {
    @Test func offPassesTheSamplesThroughUnchanged() throws {
        let input = [noise(48000, seed: 1), noise(48000, seed: 2)]
        #expect(try process(input, .off) == input)
        // Turning it off returns to the very input once the glide and the release have settled.
        let back = try process(input, .strong, change: (frame: 4800, to: .off))
        #expect(back[0][24000...] == input[0][24000...] && back[1][24000...] == input[1][24000...])
    }

    @Test func aHeldBassNoteIsRaisedOnlyByTheFixedPartAndHighFrequenciesAreLeft() throws {
        func gain(_ frequency: Double, _ strength: BassEnhancement) throws -> Double {
            let input = sine(frequency, amplitude: 0.1, seconds: 2)
            let output = try process([input], strength)[0]
            return db(rms(output[48000...])/rms(input[48000...]))
        }
        for (strength, level, fixed) in [(BassEnhancement.light, -0.5, 0.30), (.strong, -1.0, 0.55)] {
            let low = try gain(60, strength), high = try gain(3000, strength)
            // The fixed part at 60Hz is a little under 1+fixed: the band's filters turn the phase.
            #expect(abs(high - level) < 0.1)
            #expect(low - level > db(1 + fixed) - 1 && low - level < db(1 + fixed) + 0.3)
            #expect(try gain(15, strength) - level < 1, "subsonic rumble is not raised much")
        }
    }

    @Test func kicksAreRaisedMoreThanAHeldNote() throws {
        for strength in [BassEnhancement.light, .strong] {
            let kick = kicks(seconds: 2, amplitude: 0.2), held = sine(55, amplitude: 0.1, seconds: 2)
            let kicked = try process([kick], strength)[0], sustained = try process([held], strength)[0]
            // The first 40ms of the third hit, against the settled note.
            let hit = 48000..<(48000 + 1920)
            let kickGain = db(rms(kicked[hit])/rms(kick[hit])), heldGain = db(rms(sustained[48000...])/rms(held[48000...]))
            #expect(kickGain - heldGain > (strength == .light ? 2 : 3), "\(strength): \(kickGain) vs \(heldGain)")
        }
    }

    @Test func peaksStayUnderTheCeiling() throws {
        let loud = zip(kicks(seconds: 2, amplitude: 0.95), noise(96000, seed: 3)).map { $0 + 0.05*$1 }
        for strength in [BassEnhancement.light, .strong] {
            let output = try process([loud, loud], strength)
            let peak = output.flatMap { $0 }.map { abs($0) }.max() ?? 0
            #expect(Double(peak) <= 0.8912509381337456 + 1e-6)
        }
    }

    @Test func changingTheStrengthGlidesWithoutAStep() throws {
        let input = sine(60, amplitude: 0.5, seconds: 1)
        func largestStep(_ samples: ArraySlice<Float>) -> Float {
            zip(samples.dropFirst(), samples).map { abs($0 - $1) }.max() ?? 0
        }
        let steady = try process([input], .strong)[0]
        for (from, to) in [(BassEnhancement.off, BassEnhancement.strong), (.strong, .off), (.light, .strong)] {
            let output = try process([input], from, change: (frame: 24000, to: to))[0]
            #expect(largestStep(output[23000..<30000]) <= largestStep(steady[24000...])*1.05)
        }
    }

    @Test func theInputIsNotDelayed() throws {
        // An impulse comes out at the same frame; the band adds only after it.
        var impulse = [Float](repeating: 0, count: 4800)
        impulse[1000] = 0.5
        for strength in BassEnhancement.allCases {
            let output = try process([impulse], strength)[0]
            #expect(output[..<1000].allSatisfy { $0 == 0 })
            let peak = output.indices.max { abs(output[$0]) < abs(output[$1]) }
            #expect(peak == 1000)
        }
        // The 60Hz note comes out at most a few milliseconds later: the phase the band adds.
        let input = sine(60, amplitude: 0.1, seconds: 1)
        let output = try process([input], .strong)[0]
        let window = 24000..<48000
        var real = 0.0, imaginary = 0.0, inputReal = 0.0, inputImaginary = 0.0
        for n in window {
            let angle = 2 * .pi*60*Double(n)/rate
            real += Double(output[n])*cos(angle); imaginary += Double(output[n])*sin(angle)
            inputReal += Double(input[n])*cos(angle); inputImaginary += Double(input[n])*sin(angle)
        }
        let lag = (atan2(inputReal, inputImaginary) - atan2(real, imaginary))/(2 * .pi*60)
        #expect(abs(lag) < 0.005, "60Hz lag \(lag*1000)ms")
    }
}

/// The stage in a graph, offline: player → level → bass → main mixer.
@MainActor private func renderGraph(_ input: [[Float]], bass: BassEnhancement?) throws -> [[Float]] {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: UInt32(input.count)))
    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), chain = AudioProcessingChain(plan: nil, bass: bass ?? .off)
    let last: AVAudioNode = bass == nil ? chain.levelNode : chain.bassNode
    for node in [player, chain.levelNode] + (bass == nil ? [] : [chain.bassNode]) as [AVAudioNode] { engine.attach(node) }
    engine.connect(player, to: chain.levelNode, format: format)
    if bass != nil { engine.connect(chain.levelNode, to: chain.bassNode, format: format) }
    engine.connect(last, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(input[0].count)))
    buffer.frameLength = buffer.frameCapacity
    for channel in input.indices { for n in input[channel].indices { buffer.floatChannelData![channel][n] = input[channel][n] } }
    player.scheduleBuffer(buffer)
    try engine.start(); defer { engine.stop() }
    player.play()
    let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    var output = input.map { _ in [Float]() }
    while output[0].count < input[0].count {
        let requested = UInt32(min(1024, input[0].count - output[0].count))
        #expect(try engine.renderOffline(requested, to: block) == .success)
        for channel in output.indices {
            output[channel].append(contentsOf: UnsafeBufferPointer(start: block.floatChannelData![channel], count: Int(requested)))
        }
    }
    return output
}

@Suite(.serialized) @MainActor struct BassStageGraphTests {
    /// The tests run outside the sandbox, where the unflagged unit would be made all the same.
    @Test func theUnitIsRegisteredAsSandboxSafe() {
        #expect(BassPunchUnit.description.componentFlags & AudioComponentFlags.sandboxSafe.rawValue != 0)
    }

    @Test func theStageReportsNoLatency() {
        let chain = AudioProcessingChain(plan: nil, bass: .strong)
        #expect(chain.bassNode.latency == 0 && chain.bassNode.auAudioUnit.latency == 0)
    }

    @Test(arguments: [1, 2]) func offInTheGraphIsTheGraphWithoutTheStage(channels: Int) throws {
        let input = (0..<channels).map { noise(9000, seed: UInt64(10 + $0)) }.map { $0.map { $0*0.5 } }
        let without = try renderGraph(input, bass: nil)
        #expect(try renderGraph(input, bass: .off) == without)
        let strong = try renderGraph(input, bass: .strong)
        #expect(strong != without)
    }

    @Test func theGraphRendersTheStageWithoutDelay() throws {
        var impulse = [Float](repeating: 0, count: 4096)
        impulse[777] = 0.5
        for bass in BassEnhancement.allCases {
            let output = try renderGraph([impulse, impulse], bass: bass)
            for channel in output {
                #expect(channel[..<777].allSatisfy { $0 == 0 })
                #expect(channel.indices.max { abs(channel[$0]) < abs(channel[$1]) } == 777)
            }
        }
    }

    @Test func aChangeReachesTheRunningStage() throws {
        let chain = AudioProcessingChain(plan: nil, bass: .off)
        chain.bassEnhancement = .light
        #expect(chain.bassEnhancement == .light)
        let unit = try #require(chain.bassNode.auAudioUnit as? BassPunchUnit)
        #expect(unit.strength == .light)
    }
}
