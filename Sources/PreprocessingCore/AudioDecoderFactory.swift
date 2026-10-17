import AVFAudio
import AudioToolbox
import Foundation
import SFBAudioEngine

public enum AudioDecoderFactory {
    /// Each accepted extension maps to exactly one decoder. SFBAudioEngine's default
    /// content detection would let a renamed file reach any parser it bundles, so a
    /// file whose content does not match its extension fails instead.
    /// PCM containers use Core Audio, which receives fixes through OS updates.
    static func decoderName(for url: URL) -> AudioDecoder.Name? {
        switch url.pathExtension.lowercased() {
        case "mp3": .MPEG
        case "flac": .FLAC
        case "m4a", "wav", "aif", "aiff": .coreAudio
        default: nil
        }
    }

    public static func open(_ url: URL) throws -> any PCMDecoding {
        guard let name = decoderName(for: url) else { throw PreprocessingFailure.invalidAudio }
        do {
            let decoder = try AudioDecoder(url: url, decoderName: name)
            try decoder.open()
            return decoder
        } catch {
            // SFBAudioEngine 0.14.0's Core Audio callback can report eofErr
            // when opening a valid short M4A, WAV or AIFF. Keep playback in SFBAudioEngine,
            // but let AVAudioFile (also Core Audio) stream PCM for this specific read failure.
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            guard name == .coreAudio,
                  underlying?.domain == NSOSStatusErrorDomain,
                  underlying?.code == Int(kAudioFileEndOfFileError) else { throw error }
            let formats: Set<AudioFormatID> = url.pathExtension.lowercased() == "m4a"
                ? [kAudioFormatMPEG4AAC, kAudioFormatAppleLossless] : [kAudioFormatLinearPCM]
            return try AudioFileDecoder(url: url, formats: formats)
        }
    }
}

/// Used exclusively by SFBAudioEngine's decoding thread after enqueue.
private final class AudioFileDecoder: NSObject, PCMDecoding {
    let inputSource: InputSource
    let sourceFormat: AVAudioFormat
    let processingFormat: AVAudioFormat
    let length: AVAudioFramePosition
    let decodingIsLossless: Bool
    let supportsSeeking = true
    let properties: [AudioDecodingPropertiesKey: Any] = [:]
    var isOpen: Bool { file != nil }
    var position: AVAudioFramePosition { file?.framePosition ?? 0 }
    private let url: URL
    private var file: AVAudioFile?

    init(url: URL, formats: Set<AudioFormatID>) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let formatID = file.fileFormat.streamDescription.pointee.mFormatID
        guard formats.contains(formatID) else { throw PreprocessingFailure.invalidAudio }
        self.url = url
        self.file = file
        sourceFormat = file.fileFormat
        processingFormat = file.processingFormat
        length = file.length
        decodingIsLossless = formatID != kAudioFormatMPEG4AAC
        inputSource = try InputSource(for: url)
    }

    func open() throws {
        if file == nil { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
    }

    func close() throws { file = nil }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { throw PreprocessingFailure.invalidAudio }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        guard let file else { throw PreprocessingFailure.invalidAudio }
        if file.framePosition >= file.length { buffer.frameLength = 0; return }
        try file.read(into: buffer, frameCount: min(length, buffer.frameCapacity))
    }

    func seek(to frame: AVAudioFramePosition) throws {
        guard let file, frame >= 0, frame <= length else { throw PreprocessingFailure.invalidAudio }
        file.framePosition = frame
    }
}
