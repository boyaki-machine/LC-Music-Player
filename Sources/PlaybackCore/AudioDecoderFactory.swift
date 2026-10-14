import AVFAudio
import AudioToolbox
import Foundation
import SFBAudioEngine

enum AudioDecoderFactory {
    static func open(_ url: URL) throws -> any PCMDecoding {
        do {
            let decoder = try AudioDecoder(url: url)
            try decoder.open()
            return decoder
        } catch {
            // SFBAudioEngine 0.14.0's Core Audio callback can report eofErr
            // when opening a valid short M4A. Keep playback in SFBAudioEngine,
            // but let AVAudioFile stream PCM for this specific read failure.
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            guard url.pathExtension.lowercased() == "m4a",
                  underlying?.domain == NSOSStatusErrorDomain,
                  underlying?.code == Int(kAudioFileEndOfFileError) else { throw error }
            return try M4AFileDecoder(url: url)
        }
    }
}

/// Used exclusively by SFBAudioEngine's decoding thread after enqueue.
private final class M4AFileDecoder: NSObject, PCMDecoding {
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

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let formatID = file.fileFormat.streamDescription.pointee.mFormatID
        guard formatID == kAudioFormatMPEG4AAC || formatID == kAudioFormatAppleLossless else {
            throw PlaybackError.unsupportedFormat
        }
        self.url = url
        self.file = file
        sourceFormat = file.fileFormat
        processingFormat = file.processingFormat
        length = file.length
        decodingIsLossless = formatID == kAudioFormatAppleLossless
        inputSource = try InputSource(for: url)
    }

    func open() throws {
        if file == nil { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
    }

    func close() throws { file = nil }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { throw PlaybackError.unsupportedFormat }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        guard let file else { throw PlaybackError.inaccessibleFile }
        try file.read(into: buffer, frameCount: min(length, buffer.frameCapacity))
    }

    func seek(to frame: AVAudioFramePosition) throws {
        guard let file, frame >= 0, frame <= length else { throw PlaybackError.inaccessibleFile }
        file.framePosition = frame
    }
}
