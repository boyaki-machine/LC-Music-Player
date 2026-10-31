import AudioProcessingCore
import AudioToolbox
import AVFoundation
import Foundation
import LibraryCore

/// What the six indicators show, gathered from the device, the settings and the track.
struct RadioCassetteStatus: Equatable, Sendable {
    enum Power: Equatable, Sendable { case battery, external, unknown }
    var power = Power.unknown
    var output: OutputDevice?
    var format: RadioCassetteFormat?
    /// The volume levelling target in LUFS, or nil when levelling is off.
    var levellingTarget: Double?
    var bass = BassEnhancement.off
}

/// One lamp: its text, whether it is lit, and whether it is inverted to stand out (battery).
struct RadioCassetteIndicator: Equatable, Sendable {
    var text: String
    var lit = true
    var inverted = false
}

extension RadioCassetteStatus {
    var indicators: [RadioCassetteIndicator] {
        [powerIndicator, outputIndicator, formatIndicator, levellingIndicator, bassIndicator]
    }
    private var powerIndicator: RadioCassetteIndicator {
        switch power {
        case .battery: RadioCassetteIndicator(text: "BATTERY", inverted: true)
        case .external: RadioCassetteIndicator(text: "AC POWER")
        case .unknown: RadioCassetteIndicator(text: "POWER", lit: false)
        }
    }
    private var outputIndicator: RadioCassetteIndicator {
        guard let output else { return RadioCassetteIndicator(text: "NO OUTPUT", lit: false) }
        if output.isBuiltInSpeaker { return RadioCassetteIndicator(text: "SPEAKER") }
        let name = output.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RadioCassetteIndicator(text: name.isEmpty ? "HEADPHONES" : name)
    }
    private var formatIndicator: RadioCassetteIndicator {
        format.map { RadioCassetteIndicator(text: $0.label) } ?? RadioCassetteIndicator(text: "NO TAPE", lit: false)
    }
    private var levellingIndicator: RadioCassetteIndicator {
        guard let levellingTarget else { return RadioCassetteIndicator(text: "ALC OFF", lit: false) }
        return RadioCassetteIndicator(text: "ALC mode \(Int((-levellingTarget).rounded()))")
    }
    private var bassIndicator: RadioCassetteIndicator {
        switch bass {
        case .off: RadioCassetteIndicator(text: "B-BOOST OFF", lit: false)
        case .light: RadioCassetteIndicator(text: "B-BOOST mode 1")
        case .strong: RadioCassetteIndicator(text: "B-BOOST mode 2")
        }
    }
    static func direction(reverse: Bool) -> RadioCassetteIndicator {
        RadioCassetteIndicator(text: reverse ? "◀ REVERSE" : "FORWARD ▶")
    }
}

/// The coding of the track being played: lossy codecs show their bit rate (kbps), lossless ones the
/// file's sample rate (kHz, not the output's).
struct RadioCassetteFormat: Equatable, Sendable {
    var codec: String
    var lossless: Bool
    var sampleRate: Double
    /// Bits per second; nil when unknown.
    var bitRate: Double?

    var label: String {
        if lossless || bitRate == nil {
            guard sampleRate > 0 else { return codec }
            let kHz = sampleRate / 1000
            let text = kHz == kHz.rounded() ? String(Int(kHz)) : String(format: "%.1f", kHz)
            return "\(codec) \(text)kHz"
        }
        return "\(codec) \(Int((bitRate! / 1000).rounded()))kbps"
    }

    /// The rate and bit rate come from the file's header: values outside these ranges (infinite, NaN,
    /// absurdly large) are taken as unknown, so a damaged or crafted file shows only its codec.
    static let sampleRates = 1.0...10_000_000, bitRates = 1.0...100_000_000

    init(codec: String, lossless: Bool, sampleRate: Double, bitRate: Double?) {
        self.codec = codec; self.lossless = lossless
        self.sampleRate = Self.sampleRates.contains(sampleRate) ? sampleRate : 0
        self.bitRate = bitRate.flatMap { Self.bitRates.contains($0) ? $0 : nil }
    }

    /// Names the coding from the stream's format ID; PCM is named by its container.
    init(formatID: AudioFormatID, sampleRate: Double, bitRate: Double?, pathExtension: String) {
        let ext = pathExtension.lowercased()
        switch formatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:
            self.init(codec: "AAC", lossless: false, sampleRate: sampleRate, bitRate: bitRate)
        case kAudioFormatMPEGLayer3: self.init(codec: "MP3", lossless: false, sampleRate: sampleRate, bitRate: bitRate)
        case kAudioFormatFLAC: self.init(codec: "FLAC", lossless: true, sampleRate: sampleRate, bitRate: bitRate)
        case kAudioFormatAppleLossless: self.init(codec: "ALAC", lossless: true, sampleRate: sampleRate, bitRate: bitRate)
        case kAudioFormatLinearPCM:
            let codec = ext == "wav" ? "WAV" : ext.hasPrefix("aif") ? "AIFF" : "PCM"
            self.init(codec: codec, lossless: true, sampleRate: sampleRate, bitRate: bitRate)
        default:
            self.init(codec: ext.isEmpty ? "AUDIO" : ext.uppercased(), lossless: false, sampleRate: sampleRate, bitRate: bitRate)
        }
    }

    /// Reads the coding of `url` (a file, or a music library item), off the main actor. A file is read
    /// through Core Audio, as the player reads it, and needs the player's access to it; the bit rate is
    /// the audio data's average, without tags or artwork.
    static func read(_ url: URL) async -> RadioCassetteFormat? {
        guard url.isFileURL else { return await readAsset(url) }
        return await Task.detached(priority: .utility) { readFile(url) }.value
    }

    private static func readFile(_ url: URL) -> RadioCassetteFormat? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        func property<T>(_ id: AudioFilePropertyID, _ initial: T) -> T? {
            var value = initial, size = UInt32(MemoryLayout<T>.size)
            return AudioFileGetProperty(file, id, &size, &value) == noErr ? value : nil
        }
        guard let stream = property(kAudioFilePropertyDataFormat, AudioStreamBasicDescription()) else { return nil }
        let bytes = property(kAudioFilePropertyAudioDataByteCount, UInt64(0)) ?? 0
        let seconds = property(kAudioFilePropertyEstimatedDuration, Float64(0)) ?? 0
        let average = bytes > 0 && seconds > 0 ? Double(bytes) * 8 / seconds : nil
        let nominal = property(kAudioFilePropertyBitRate, UInt32(0)).flatMap { $0 > 0 ? Double($0) : nil }
        return RadioCassetteFormat(formatID: stream.mFormatID, sampleRate: stream.mSampleRate, bitRate: average ?? nominal,
                                   pathExtension: url.pathExtension)
    }

    private static func readAsset(_ url: URL) async -> RadioCassetteFormat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let (descriptions, rate) = try? await track.load(.formatDescriptions, .estimatedDataRate),
              let description = descriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        // A music library item names its container in the path (item.m4a).
        let pathExtension = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.split(separator: ".").last.map(String.init) ?? ""
        return RadioCassetteFormat(formatID: stream.mFormatID, sampleRate: stream.mSampleRate,
                                   bitRate: rate > 0 ? Double(rate) : nil, pathExtension: pathExtension)
    }
}
