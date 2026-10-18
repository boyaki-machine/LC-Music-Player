import AVFAudio
import AudioToolbox
import Foundation

/// Sequential PCM source used by preprocessing and playback.
/// A read shorter than requested, or of zero frames, means the end of the audio.
/// Implementations are not thread-safe: one owner uses a decoder at a time.
public protocol PCMDecoding: AnyObject {
    var processingFormat: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }
    var position: AVAudioFramePosition { get }
    var supportsSeeking: Bool { get }
    var isOpen: Bool { get }
    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws
    func seek(to frame: AVAudioFramePosition) throws
    func close() throws
}

public enum AudioDecoderFactory {
    /// Every format is decoded by Core Audio, which receives fixes through OS updates.
    /// Each extension accepts only its own encodings, so a renamed file whose content
    /// does not match its extension fails instead of reaching another parser.
    static func formats(for url: URL) -> Set<AudioFormatID>? {
        switch url.pathExtension.lowercased() {
        case "mp3": [kAudioFormatMPEGLayer3, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer1]
        case "flac": [kAudioFormatFLAC]
        case "m4a": [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
                     kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
                     kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatAppleLossless]
        case "wav", "aif", "aiff": [kAudioFormatLinearPCM, kAudioFormatULaw, kAudioFormatALaw]
        default: nil
        }
    }

    public static func open(_ url: URL) throws -> any PCMDecoding {
        guard let formats = formats(for: url) else { throw PreprocessingFailure.invalidAudio }
        return try AudioFileDecoder(url: url, formats: formats)
    }
}

/// Float32 non-interleaved PCM from AVAudioFile (ExtAudioFile). Core Audio applies the
/// encoder delay and padding recorded in LAME/Xing headers, iTunSMPB and MP4 edit lists.
final class AudioFileDecoder: PCMDecoding {
    let processingFormat: AVAudioFormat
    let length: AVAudioFramePosition
    let supportsSeeking = true
    var isOpen: Bool { file != nil }
    var position: AVAudioFramePosition { file?.framePosition ?? 0 }
    private var file: AVAudioFile?

    init(url: URL, formats: Set<AudioFormatID>) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard formats.contains(file.fileFormat.streamDescription.pointee.mFormatID),
              file.length > 0 else { throw PreprocessingFailure.invalidAudio }
        self.file = file
        processingFormat = file.processingFormat
        length = file.length
    }

    func close() throws { file = nil }

    func decode(into buffer: AVAudioPCMBuffer, length requested: AVAudioFrameCount) throws {
        guard let file, buffer.format == processingFormat else { throw PreprocessingFailure.invalidAudio }
        if file.framePosition >= file.length { buffer.frameLength = 0; return }
        try file.read(into: buffer, frameCount: min(requested, buffer.frameCapacity))
    }

    func seek(to frame: AVAudioFramePosition) throws {
        guard let file, frame >= 0, frame <= length else { throw PreprocessingFailure.invalidAudio }
        file.framePosition = frame
    }
}
