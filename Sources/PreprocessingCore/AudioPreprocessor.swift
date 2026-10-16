import AVFAudio
import AudioToolbox
import Foundation
import SFBAudioEngine
import AudioProcessingCore

/// One utility queue, shared by prefix preparation and incremental full-track scans.
public final class AudioPreprocessor: Sendable {
    public static let shared = AudioPreprocessor()
    private let queue = DispatchQueue(label: "local.lcmp.preprocessing", qos: .utility)
    public init() { LoudnessMeter.cleanAbandonedFiles() }

    public func measureLevels(_ url: URL, profile: MeasurementProfile,
                              cancellation: PreparationCancellation = .init()) async throws -> TrackAudioMetrics {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try cancellation.check()
                    let scan = try LevelScan(url: url, profile: profile, cancellation: cancellation, continuation: continuation)
                    self.stepLevels(scan)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func stepLevels(_ scan: LevelScan) {
        do {
            if let result = try scan.read() { scan.finish(.success(result)) }
            else { queue.async { self.stepLevels(scan) } }
        } catch { scan.finish(.failure(error)) }
    }

    public func prepare(_ url: URL, cancellation: PreparationCancellation = .init(),
                        seconds: Double = 2, byteLimit: Int = 32 * 1024 * 1024) async throws -> PreparedAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try cancellation.check()
                    let source = try SourceFingerprint(url: url)
                    let base = try AudioDecoderFactory.open(url)
                    var handedOff = false
                    defer { if !handedOff { try? base.close() } }
                    try cancellation.check()
                    let format = base.processingFormat
                    let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame) * (format.isInterleaved ? 1 : Int(format.channelCount))
                    guard base.length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
                          seconds.isFinite, seconds > 0, seconds <= 2, bytesPerFrame > 0, byteLimit >= bytesPerFrame else {
                        throw PreprocessingFailure.invalidAudio
                    }
                    let frames = UInt32(min(Double(base.length), seconds * format.sampleRate,
                                            Double(min(byteLimit, 32 * 1024 * 1024) / bytesPerFrame)))
                    guard frames > 0, let prefix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                          let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(frames, 8192)) else {
                        throw PreprocessingFailure.invalidAudio
                    }
                    var filled: UInt32 = 0
                    while filled < frames {
                        try cancellation.check()
                        try base.decode(into: chunk, length: min(chunk.frameCapacity, frames - filled))
                        if chunk.frameLength == 0 { break }
                        let src = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
                        let dst = UnsafeMutableAudioBufferListPointer(prefix.mutableAudioBufferList)
                        let stride = Int(format.streamDescription.pointee.mBytesPerFrame)
                        for i in src.indices {
                            guard let from = src[i].mData, let to = dst[i].mData else { throw PreprocessingFailure.invalidAudio }
                            memcpy(to.advanced(by: Int(filled) * stride), from, Int(chunk.frameLength) * stride)
                        }
                        filled += chunk.frameLength
                    }
                    prefix.frameLength = filled
                    guard filled > 0 else { throw PreprocessingFailure.invalidAudio }
                    try cancellation.check(); try source.validate()
                    let wrapper = try PrefixDecoder(base: base, prefix: prefix)
                    let result = PreparedAudio(source: source, decoder: wrapper, bytes: Int(frames) * bytesPerFrame)
                    handedOff = true
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func measure(_ url: URL, cancellation: PreparationCancellation = .init()) async throws -> TrackPeak {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try cancellation.check()
                    let scan = try PeakScan(url: url, cancellation: cancellation, continuation: continuation)
                    self.step(scan)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func step(_ scan: PeakScan) {
        do {
            if let result = try scan.read() { scan.finish(.success(result)) }
            else { queue.async { self.step(scan) } }
        } catch { scan.finish(.failure(error)) }
    }
}

/// Exclusive to the utility queue; each continuation is resumed exactly once.
private final class PeakScan: @unchecked Sendable {
    let source: SourceFingerprint
    let decoder: any PCMDecoding
    let buffer: AVAudioPCMBuffer
    let analysisBuffer: AVAudioPCMBuffer
    let converter: AVAudioConverter
    let cancellation: PreparationCancellation
    let continuation: CheckedContinuation<TrackPeak, any Error>
    var peak: Double = 0
    var frames: Int64 = 0
    init(url: URL, cancellation: PreparationCancellation, continuation: CheckedContinuation<TrackPeak, any Error>) throws {
        source = try SourceFingerprint(url: url)
        decoder = try AudioDecoderFactory.open(url)
        self.cancellation = cancellation; self.continuation = continuation
        guard let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192) else {
            try? decoder.close(); throw PreprocessingFailure.invalidAudio
        }
        self.buffer = buffer
        guard let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: decoder.processingFormat.sampleRate,
                                               channels: decoder.processingFormat.channelCount, interleaved: false),
              let analysisBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 8192),
              let converter = AVAudioConverter(from: decoder.processingFormat, to: floatFormat) else {
            try? decoder.close(); throw PreprocessingFailure.invalidAudio
        }
        self.analysisBuffer = analysisBuffer; self.converter = converter
    }
    func read() throws -> TrackPeak? {
        try cancellation.check()
        try decoder.decode(into: buffer, length: buffer.frameCapacity)
        if buffer.frameLength == 0 {
            guard frames > 0, decoder.length < 0 || frames == decoder.length else { throw PreprocessingFailure.invalidAudio }
            try source.validate()
            return TrackPeak(source: source, samplePeak: peak, frameCount: frames,
                             sampleRate: buffer.format.sampleRate, channelCount: buffer.format.channelCount)
        }
        peak = max(peak, try NativeSamplePeak.read(buffer, analysisBuffer: analysisBuffer, converter: converter))
        frames += Int64(buffer.frameLength)
        return nil
    }
    func finish(_ result: Result<TrackPeak, any Error>) {
        try? decoder.close(); continuation.resume(with: result)
    }
}

/// Shared exact native sample reading; normalization also retains the legacy source peak.
enum NativeSamplePeak {
    static func read(_ buffer: AVAudioPCMBuffer, analysisBuffer: AVAudioPCMBuffer, converter: AVAudioConverter) throws -> Double {
        var peak = 0.0
        let numeric: AVAudioPCMBuffer
        let input = buffer.format.streamDescription.pointee
        let nativeInteger = input.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
            && input.mBitsPerChannel > 0 && input.mBitsPerChannel <= 32
        if buffer.format.commonFormat == .otherFormat && !nativeInteger {
            try converter.convert(to: analysisBuffer, from: buffer)
            guard analysisBuffer.frameLength == buffer.frameLength else { throw PreprocessingFailure.invalidAudio }
            numeric = analysisBuffer
        } else { numeric = buffer }
        let format = numeric.format
        let buffers = UnsafeMutableAudioBufferListPointer(numeric.mutableAudioBufferList)
        let commonFormat = format.commonFormat
        let interleaved = format.isInterleaved
        let sampleStride = numeric.stride
        let frameCount = Int(numeric.frameLength)
        let description = format.streamDescription.pointee
        let width = Int(description.mBytesPerFrame) / (interleaved ? Int(format.channelCount) : 1)
        let bits = Int(description.mBitsPerChannel)
        let denominator = bits > 0 && bits <= 32 ? Double(Int64(1) << (bits - 1)) : 1
        for channel in 0..<Int(format.channelCount) {
            guard let raw = buffers[interleaved ? 0 : channel].mData else { throw PreprocessingFailure.invalidAudio }
            for frame in 0..<frameCount {
                let index = frame * sampleStride + (interleaved ? channel : 0)
                let value: Double
                switch commonFormat {
                case .pcmFormatFloat32: value = Double(raw.assumingMemoryBound(to: Float.self)[index])
                case .pcmFormatFloat64: value = raw.assumingMemoryBound(to: Double.self)[index]
                case .pcmFormatInt16: value = Double(raw.assumingMemoryBound(to: Int16.self)[index]) / 32768
                case .pcmFormatInt32: value = Double(raw.assumingMemoryBound(to: Int32.self)[index]) / 2147483648
                case .otherFormat:
                    guard width > 0, width <= 4, description.mBitsPerChannel <= width * 8 else { throw PreprocessingFailure.invalidAudio }
                    let sample = raw.advanced(by: frame * Int(description.mBytesPerFrame) + (interleaved ? channel * width : 0))
                    let bytes = sample.assumingMemoryBound(to: UInt8.self)
                    var integer: UInt64 = 0
                    for byte in 0..<width {
                        let shift = description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 ? (width - 1 - byte) * 8 : byte * 8
                        integer |= UInt64(bytes[byte]) << shift
                    }
                    if description.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 { integer >>= width * 8 - bits }
                    integer &= (UInt64(1) << bits) - 1
                    let signed = integer & (UInt64(1) << (bits - 1)) != 0 ? Int64(integer) - (Int64(1) << bits) : Int64(integer)
                    value = Double(signed) / denominator
                default: throw PreprocessingFailure.invalidAudio
                }
                guard value.isFinite else { throw PreprocessingFailure.nonFiniteSample }
                peak = max(peak, abs(value))
            }
        }
        return peak
    }
}
