import Foundation
import Testing
import AudioProcessingCore
import PlaybackCore

/// Measurements are kept across builds of the app, so a change of the code that measures must raise
/// `MeasurementVersions`: otherwise earlier results stay in use. These are the exact results of each
/// version for lossless fixtures, which Core Audio decodes the same on every OS version, and for
/// longer PCM files written here from integer triangle waves (no floating-point math library), whose
/// loud, quieter and nearly silent parts take the loudness through both gates.
///
/// When this test fails:
/// - The measuring or converting code changed the results: raise `MeasurementVersions.algorithm`
///   (LevelDSP, LoudnessMeter, peaks) or `.conversion` (decoding, ProfileConversion), and add the
///   printed results under the new version. Never edit the results of an earlier version.
/// - Nothing in that code changed and only the OS changed: the OS major version is part of the key,
///   so listeners measure again anyway; record the new results under the current version.
@Suite struct MeasurementVersionTests {
    static let cases: [(file: String, rate: Double, channels: UInt32)] = [
        ("tone.wav", 48000, 2), ("tone.wav", 44100, 1), ("tone.aiff", 48000, 2), ("tone.flac", 48000, 2),
        ("tone-alac.m4a", 48000, 2), ("tone-96k-24bit.flac", 48000, 2), ("tone-96k-24bit.wav", 44100, 2),
    ]

    /// Written in place: (name, rate, channels, bits) and the profile measured.
    static let synthesized: [(name: String, rate: Int, channels: Int, bits: Int, profileRate: Double, profileChannels: UInt32)] = [
        ("triangle-48k-2ch-16.wav", 48000, 2, 16, 48000, 2), ("triangle-44k-1ch-16.wav", 44100, 1, 16, 48000, 2),
        ("triangle-96k-2ch-24.wav", 96000, 2, 24, 48000, 2), ("triangle-48k-2ch-16.wav", 48000, 2, 16, 44100, 1),
    ]

    /// Results by "algorithm.conversion".
    static let expected: [String: [String: String]] = [
        "1.1": [
            "tone-96k-24bit.flac@48000x2": "tooShort sample:3fa9999780000000 true:3fa9999780000000 frames:12000 blocks:0 source:3fa9999800000000 sourceFrames:24000",
            "tone-96k-24bit.wav@44100x2": "tooShort sample:3fa9999640000000 true:3fa999972e4c0496 frames:11025 blocks:0 source:3fa9999800000000 sourceFrames:24000",
            "tone-alac.m4a@48000x2": "tooShort sample:3fa998a340000000 true:3fa9994a8d8f25f8 frames:12000 blocks:0 source:3fa9980000000000 sourceFrames:11025",
            "tone.aiff@48000x2": "tooShort sample:3fa998a340000000 true:3fa9994a8d8f25f8 frames:12000 blocks:0 source:3fa9980000000000 sourceFrames:11025",
            "tone.flac@48000x2": "tooShort sample:3fa998a340000000 true:3fa9994a8d8f25f8 frames:12000 blocks:0 source:3fa9980000000000 sourceFrames:11025",
            "tone.wav@44100x1": "tooShort sample:3fa9980000000000 true:3fa999245989a370 frames:11025 blocks:0 source:3fa9980000000000 sourceFrames:11025",
            "tone.wav@48000x2": "tooShort sample:3fa998a340000000 true:3fa9994a8d8f25f8 frames:12000 blocks:0 source:3fa9980000000000 sourceFrames:11025",
            "triangle-44k-1ch-16.wav@48000x2": "measured:c0218579c4b2bec3 sample:3fe08cf960000000 true:3fe26ba842dce2c1 frames:240000 blocks:47 source:3fdfff8000000000 sourceFrames:220500",
            "triangle-48k-2ch-16.wav@44100x1": "measured:c027620094c0c43d sample:3fe04c9e20000000 true:3fe1e287575fa5de frames:220500 blocks:47 source:3fdfff8000000000 sourceFrames:240000",
            "triangle-48k-2ch-16.wav@48000x2": "measured:c020afb206a6eb97 sample:3fdfff8000000000 true:3fe1e62be865ab72 frames:240000 blocks:47 source:3fdfff8000000000 sourceFrames:240000",
            "triangle-96k-2ch-24.wav@48000x2": "measured:c020c5eb37504f7c sample:3fe0d329c0000000 true:3fe100fb6e111227 frames:240000 blocks:47 source:3fdfffff80000000 sourceFrames:480000",
        ],
    ]

    @Test func resultsMatchTheCurrentVersions() async throws {
        let version = "\(MeasurementVersions.algorithm).\(MeasurementVersions.conversion)"
        let processor = AudioPreprocessor()
        var actual: [String: String] = [:]
        for item in Self.cases {
            let url = try #require(Bundle.module.url(forResource: item.file, withExtension: nil, subdirectory: "Fixtures"))
            let profile = try MeasurementProfile(sampleRate: item.rate, channels: item.channels)
            let metrics = try await processor.measureLevels(url, profile: profile)
            actual["\(item.file)@\(Int(item.rate))x\(item.channels)"] = Self.signature(metrics)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-measurement-version-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for item in Self.synthesized {
            let url = root.appendingPathComponent(item.name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Self.triangleWave(rate: item.rate, channels: item.channels, bits: item.bits).write(to: url)
            }
            let profile = try MeasurementProfile(sampleRate: item.profileRate, channels: item.profileChannels)
            let metrics = try await processor.measureLevels(url, profile: profile)
            actual["\(item.name)@\(Int(item.profileRate))x\(item.profileChannels)"] = Self.signature(metrics)
        }
        let listing = actual.keys.sorted().map { "            \"\($0)\": \"\(actual[$0]!)\"," }.joined(separator: "\n")
        guard let pinned = Self.expected[version] else {
            Issue.record("No results for measurement version \(version). Add them:\n        \"\(version)\": [\n\(listing)\n        ],")
            return
        }
        for key in actual.keys.sorted() {
            #expect(pinned[key] == actual[key], "\(key) changed under measurement version \(version). Current results:\n\(listing)")
        }
        #expect(Set(pinned.keys) == Set(actual.keys))
    }

    /// A PCM WAV file of 5 seconds: 2 loud, 2 at a tenth (-20 dB, under the relative gate) and 1 at
    /// -90 dB (under the absolute gate). Each channel is a triangle wave of its own period.
    static func triangleWave(rate: Int, channels: Int, bits: Int) -> Data {
        let full = (1 << (bits - 1)) - 1, bytes = bits / 8, frames = rate * 5
        var data = Data()
        func append(_ value: Int, _ count: Int) { for i in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) } }
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        let length = frames * channels * bytes
        ascii("RIFF"); append(36 + length, 4); ascii("WAVE")
        ascii("fmt "); append(16, 4); append(1, 2); append(channels, 2); append(rate, 4)
        append(rate * channels * bytes, 4); append(channels * bytes, 2); append(bits, 2)
        ascii("data"); append(length, 4)
        for n in 0..<frames {
            let second = n / rate
            let amplitude = second < 2 ? full / 2 : second < 4 ? full / 20 : max(1, full / 63246)
            for channel in 0..<channels {
                let period = rate / (channel == 0 ? 440 : 1000)
                let phase = n % period, half = period / 2
                let shape = phase < half ? 2 * phase - half : 3 * half - 2 * phase
                append(amplitude * shape / half, bytes)
            }
        }
        return data
    }

    /// Doubles as their bit patterns, so that any change shows.
    static func signature(_ metrics: TrackAudioMetrics) -> String {
        func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
        let levels = metrics.levels
        let loudness: String
        switch levels.loudness {
        case .measured(let value): loudness = "measured:" + bits(value)
        case .silent: loudness = "silent"
        case .tooShort: loudness = "tooShort"
        case .belowGate: loudness = "belowGate"
        }
        return [loudness, "sample:" + bits(levels.samplePeak), "true:" + bits(levels.truePeak),
                "frames:\(levels.frameCount)", "blocks:\(levels.blockCount)",
                "source:" + bits(metrics.sourcePeak.samplePeak), "sourceFrames:\(metrics.sourceFrameCount)"].joined(separator: " ")
    }
}
