import AVFAudio
import Foundation
import Testing
@testable import PreprocessingCore

/// The buffer-level peak must equal the previous per-sample reading bit for bit.
@Suite struct NativeSamplePeakTests {
    private static let frames: AVAudioFrameCount = 1031

    struct Layout: Sendable { let interleaved: Bool; let channels: UInt32 }
    private static let layouts = [Layout(interleaved: false, channels: 1), Layout(interleaved: false, channels: 2),
                                  Layout(interleaved: true, channels: 1), Layout(interleaved: true, channels: 2)]

    @Test(arguments: [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32], layouts)
    func matchesPerSampleReading(_ common: AVAudioCommonFormat, layout: Layout) throws {
        let interleaved = layout.interleaved, channels = layout.channels
        let format = try #require(AVAudioFormat(commonFormat: common, sampleRate: 48000, channels: channels, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frames))
        buffer.frameLength = Self.frames
        var generator = SystemRandomNumberGenerator()
        let samples = Int(Self.frames) * Int(channels)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, audio) in list.enumerated() {
            let raw = try #require(audio.mData)
            let count = interleaved ? samples : Int(Self.frames)
            for i in 0..<count {
                // Include both integer extremes; |Int.min| must not overflow.
                let extreme = i == 17 + index ? -1.0 : i == 29 + index ? 1.0 : Double.random(in: -0.9...0.9, using: &generator)
                switch common {
                case .pcmFormatFloat32: raw.assumingMemoryBound(to: Float.self)[i] = Float(extreme * 1.5)
                case .pcmFormatFloat64: raw.assumingMemoryBound(to: Double.self)[i] = extreme * 1.5
                case .pcmFormatInt16: raw.assumingMemoryBound(to: Int16.self)[i] = extreme == -1 ? .min : Int16(extreme * 32767)
                default: raw.assumingMemoryBound(to: Int32.self)[i] = extreme == -1 ? .min : Int32(extreme * 2147483647)
                }
            }
        }
        #expect(try Self.peak(buffer) == Self.referencePeak(buffer))
    }

    struct Packed: Sendable { let bits: UInt32; let width: UInt32; let flags: AudioFormatFlags; let interleaved: Bool }
    /// Layouts decoders deliver as .otherFormat: Core Audio AIFF (big-endian packed 24-bit),
    /// Integer layouts such as 16 bits aligned high in 32-bit words, and less common variants.
    private static let packed = [
        Packed(bits: 24, width: 3, flags: kAudioFormatFlagIsPacked, interleaved: true),
        Packed(bits: 24, width: 3, flags: kAudioFormatFlagIsPacked | kAudioFormatFlagIsBigEndian, interleaved: true),
        Packed(bits: 16, width: 4, flags: kAudioFormatFlagIsAlignedHigh, interleaved: false),
        Packed(bits: 16, width: 4, flags: kAudioFormatFlagIsAlignedHigh | kAudioFormatFlagIsBigEndian, interleaved: true),
        Packed(bits: 20, width: 4, flags: 0, interleaved: true),
        Packed(bits: 24, width: 4, flags: kAudioFormatFlagIsAlignedHigh, interleaved: false),
    ]

    @Test(arguments: packed)
    func packedIntegersMatchPerSampleReading(_ layout: Packed) throws {
        let channels: UInt32 = 2
        let bytesPerFrame = layout.width * (layout.interleaved ? channels : 1)
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | layout.flags | (layout.interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: layout.bits, mReserved: 0)
        let format = try #require(AVAudioFormat(streamDescription: &description))
        #expect(format.commonFormat == .otherFormat)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 257))
        buffer.frameLength = 257
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, audio) in list.enumerated() {
            let bytes = try #require(audio.mData).assumingMemoryBound(to: UInt8.self)
            for i in 0..<Int(audio.mDataByteSize) { bytes[i] = UInt8((i * 37 + 11 + index * 5) & 0xff) }
        }
        #expect(try Self.peak(buffer) == Self.referencePeak(buffer))
        #expect(try Self.peak(buffer) > 0)
    }

    @Test func packedFullScaleNegativeIsOne() throws {
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 6,
            mFramesPerPacket: 1, mBytesPerFrame: 6, mChannelsPerFrame: 2, mBitsPerChannel: 24, mReserved: 0)
        let format = try #require(AVAudioFormat(streamDescription: &description))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let bytes = try #require(buffer.audioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: UInt8.self)
        memset(bytes, 0, 24)
        bytes[3] = 0; bytes[4] = 0; bytes[5] = 0x80 // -2^23 in the right channel
        #expect(try Self.peak(buffer) == 1)
        #expect(try Self.referencePeak(buffer) == 1)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity], [false, true])
    func nonFiniteSamplesAreRejected(_ value: Float, interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audio in list { memset(audio.mData, 0, Int(audio.mDataByteSize)) }
        try #require(list.last?.mData).assumingMemoryBound(to: Float.self)[interleaved ? 13 : 5] = value
        #expect(throws: PreprocessingFailure.nonFiniteSample) { try Self.peak(buffer) }
    }

    @Test func emptyBufferHasNoPeak() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        #expect(try Self.peak(buffer) == 0)
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) throws -> Double {
        let analysis = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: buffer.format.sampleRate,
                                                  channels: buffer.format.channelCount, interleaved: false))
        let target = try #require(AVAudioPCMBuffer(pcmFormat: analysis, frameCapacity: buffer.frameCapacity))
        let converter = try #require(AVAudioConverter(from: buffer.format, to: analysis))
        return try NativeSamplePeak.read(buffer, analysisBuffer: target, converter: converter)
    }

    /// The per-sample reading used before buffer-level peaks, kept verbatim as the oracle.
    private static func referencePeak(_ numeric: AVAudioPCMBuffer) throws -> Double {
        var peak = 0.0
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
