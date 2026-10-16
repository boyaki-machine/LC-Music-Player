import AVFAudio
import Foundation
import SFBAudioEngine

/// The lock transfers exclusive ownership, never makes a decoder safe for concurrent use.
public final class PreparedAudio: @unchecked Sendable {
    public let source: SourceFingerprint
    public let duration: TimeInterval
    public let supportsSeeking: Bool
    public let bufferedFrames: UInt32
    public let bufferedBytes: Int
    private let lock = NSLock()
    private var decoder: PrefixDecoder?

    init(source: SourceFingerprint, decoder: PrefixDecoder, bytes: Int) {
        self.source = source
        self.supportsSeeking = decoder.supportsSeeking
        self.duration = Double(decoder.length) / decoder.processingFormat.sampleRate
        self.bufferedFrames = decoder.prefixFrames
        self.bufferedBytes = bytes
        self.decoder = decoder
    }
    public func takeDecoder() throws -> any PCMDecoding {
        try source.validate()
        return try lock.withLock {
            guard let decoder else { throw PreprocessingFailure.consumed }
            self.decoder = nil
            return decoder
        }
    }
    deinit { if let decoder { try? decoder.close() } }
}

/// First replays native-format PCM verbatim, then continues the same already-open decoder.
final class PrefixDecoder: NSObject, PCMDecoding {
    let base: any PCMDecoding
    private var prefix: AVAudioPCMBuffer?
    private let scratch: AVAudioPCMBuffer
    let prefixFrames: UInt32
    private(set) var position: Int64 = 0
    var inputSource: InputSource { base.inputSource }
    var sourceFormat: AVAudioFormat { base.sourceFormat }
    var processingFormat: AVAudioFormat { base.processingFormat }
    var length: Int64 { base.length }
    var decodingIsLossless: Bool { base.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { base.properties }
    var supportsSeeking: Bool { base.supportsSeeking }
    var isOpen: Bool { base.isOpen }
    init(base: any PCMDecoding, prefix: AVAudioPCMBuffer) throws {
        self.base = base; self.prefix = prefix; prefixFrames = prefix.frameLength
        guard let scratch = AVAudioPCMBuffer(pcmFormat: base.processingFormat, frameCapacity: 8192) else {
            throw PreprocessingFailure.invalidAudio
        }
        self.scratch = scratch
    }
    func open() throws { guard isOpen else { throw PreprocessingFailure.consumed } }
    func close() throws { prefix = nil; try base.close() }
    deinit { try? base.close() }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { throw PreprocessingFailure.invalidAudio }
        try decode(into: pcm, length: pcm.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length requested: UInt32) throws {
        guard isOpen, buffer.format == processingFormat else { throw PreprocessingFailure.invalidAudio }
        let count = min(requested, buffer.frameCapacity)
        var filled: UInt32 = 0
        buffer.frameLength = count
        if let prefix, position < Int64(prefixFrames) {
            let copied = min(count, prefixFrames - UInt32(position))
            copyPCM(prefix, offset: UInt32(position), to: buffer, count: copied)
            filled = copied
            position += Int64(copied)
        }
        // SFB treats any short read as EOF. Fill the same caller buffer across the
        // prefix boundary, rather than reporting an intermediate short read.
        while filled < count {
            try base.decode(into: scratch, length: min(scratch.frameCapacity, count - filled))
            if scratch.frameLength == 0 { break }
            copyPCM(scratch, offset: 0, to: buffer, targetOffset: filled, count: scratch.frameLength)
            filled += scratch.frameLength
            position += Int64(scratch.frameLength)
        }
        buffer.frameLength = filled
    }

    func seek(to frame: Int64) throws {
        guard frame >= 0, frame <= length, supportsSeeking else { throw PreprocessingFailure.invalidAudio }
        // Keeping base at the end of the prefix allows seeks within the cached region.
        if prefix != nil && frame < Int64(prefixFrames) {
            if base.position != Int64(prefixFrames) { try base.seek(to: Int64(prefixFrames)) }
        } else { try base.seek(to: frame) }
        position = frame
    }
}

func copyPCM(_ source: AVAudioPCMBuffer, offset: UInt32, to target: AVAudioPCMBuffer, targetOffset: UInt32 = 0, count: UInt32) {
    let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let targetBuffers = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
    let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
    for index in sourceBuffers.indices {
        guard let src = sourceBuffers[index].mData, let dst = targetBuffers[index].mData else { continue }
        memcpy(dst.advanced(by: Int(targetOffset) * bytesPerFrame), src.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame)
    }
}
