import AVFAudio
import Foundation
import SFBAudioEngine
import AudioProcessingCore

enum ProfileConversion {
    static func make(from input: AVAudioFormat, profile: MeasurementProfile) throws -> AVAudioConverter {
        guard (1...2).contains(input.channelCount), let converter = AVAudioConverter(from: input, to: profile.format) else {
            throw AudioProcessingFailure.unsupportedProfile
        }
        if input.channelCount == 1, profile.channels == 2 { converter.channelMap = [0, 0] }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        return converter
    }
}

/// Uses exactly the measurement conversion before SFB owns/render-converts PCM.
/// The native prefix remains unchanged. All work is on SFB's decoder thread, not render.
public final class ProfileDecoder: NSObject, PCMDecoding {
    private let base: any PCMDecoding
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let converted: AVAudioPCMBuffer
    private var offset: UInt32 = 0
    private var eof = false
    private var drained = false
    public let processingFormat: AVAudioFormat
    public let length: Int64
    public private(set) var position: Int64 = 0
    public var inputSource: InputSource { base.inputSource }
    public var sourceFormat: AVAudioFormat { base.sourceFormat }
    public var decodingIsLossless: Bool { base.decodingIsLossless }
    public var properties: [AudioDecodingPropertiesKey: Any] { base.properties }
    public var supportsSeeking: Bool { base.supportsSeeking }
    public var isOpen: Bool { base.isOpen }
    public init(base: any PCMDecoding, profile: MeasurementProfile, frameLength: UInt64) throws {
        guard frameLength > 0, frameLength <= UInt64(Int64.max),
              let input = AVAudioPCMBuffer(pcmFormat: base.processingFormat, frameCapacity: 8192),
              let converted = AVAudioPCMBuffer(pcmFormat: profile.format, frameCapacity: 8192) else { throw PreprocessingFailure.invalidAudio }
        self.base = base; self.input = input; self.converted = converted
        converter = try ProfileConversion.make(from: base.processingFormat, profile: profile)
        processingFormat = profile.format; length = Int64(frameLength)
    }
    public func open() throws { guard isOpen else { throw PreprocessingFailure.consumed } }
    public func close() throws { try base.close() }
    deinit { try? base.close() }
    public func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { throw PreprocessingFailure.invalidAudio }
        try decode(into: pcm, length: pcm.frameCapacity)
    }
    public func decode(into buffer: AVAudioPCMBuffer, length requested: UInt32) throws {
        guard buffer.format == processingFormat, isOpen else { throw PreprocessingFailure.invalidAudio }
        buffer.frameLength = 0
        let wanted = min(requested, buffer.frameCapacity)
        while buffer.frameLength < wanted {
            if offset == converted.frameLength {
                if drained { break }
                var failure: Error?, error: NSError?
                let status = converter.convert(to: converted, error: &error) { [self] frames, state in
                    do {
                        if eof { state.pointee = .endOfStream; return nil }
                        try base.decode(into: input, length: min(frames, input.frameCapacity))
                        if input.frameLength == 0 { eof = true; state.pointee = .endOfStream; return nil }
                        state.pointee = .haveData; return input
                    } catch { failure = error; state.pointee = .endOfStream; return nil }
                }
                if let failure { throw failure }; if let error { throw error }
                guard status != .error else { throw PreprocessingFailure.invalidAudio }
                drained = status == .endOfStream; offset = 0
                if converted.frameLength == 0 {
                    if drained { break }
                    throw PreprocessingFailure.invalidAudio
                }
            }
            let count = min(wanted-buffer.frameLength, converted.frameLength-offset)
            for channel in 0..<Int(processingFormat.channelCount) {
                memcpy(buffer.floatChannelData![channel].advanced(by: Int(buffer.frameLength)),
                       converted.floatChannelData![channel].advanced(by: Int(offset)), Int(count)*4)
            }
            offset += count; buffer.frameLength += count; position += Int64(count)
        }
    }
    public func seek(to frame: Int64) throws {
        guard supportsSeeking, frame >= 0, frame < length else { throw PreprocessingFailure.invalidAudio }
        let sourceFrame = Int64(Double(frame) * base.processingFormat.sampleRate / processingFormat.sampleRate)
        try base.seek(to: min(sourceFrame, base.length-1))
        converter.reset(); converted.frameLength = 0; offset = 0; eof = false; drained = false; position = frame
    }
}
