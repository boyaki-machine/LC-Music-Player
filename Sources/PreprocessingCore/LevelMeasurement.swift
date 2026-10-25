import AVFAudio
import Foundation
import AudioProcessingCore

public struct TrackAudioMetrics: Equatable, Sendable {
    public let source: SourceFingerprint
    public let profile: MeasurementProfile
    public let levels: AudioLevelMetrics
    public let sourceFrameCount: Int64
    public let sourcePeak: TrackPeak
}
public enum LevelMeasurementState: Equatable, Sendable {
    case disabled, pending, complete(TrackAudioMetrics), failed(String)
}

/// Exclusive to AudioPreprocessor's utility queue. Streaming converter drains at EOF.
final class LevelScan: @unchecked Sendable {
    let source: SourceFingerprint
    let profile: MeasurementProfile
    let decoder: any PCMDecoding
    let input: AVAudioPCMBuffer
    let output: AVAudioPCMBuffer
    let converter: AVAudioConverter
    let meter: LoudnessMeter
    let nativeAnalysis: AVAudioPCMBuffer
    let nativeConverter: AVAudioConverter
    private var nativePeak = 0.0
    let cancellation: PreparationCancellation
    private var readFrames: Int64 = 0
    private var eof = false
    let collectTimings: Bool
    private(set) var workSeconds = 0.0
    private(set) var nativePeakSeconds = 0.0
    /// The track's map found from the same converted PCM, so that a scan for levels also maps the track.
    /// A failure of the analyzers leaves the levels measured and the map missing.
    private var analyzers: TrackAnalyzers.Session?
    private(set) var trackMap: TrackMap?
    var mapsTrack: Bool { analyzers != nil || trackMap != nil }
    init(url: URL, profile: MeasurementProfile, cancellation: PreparationCancellation, collectTimings: Bool = false,
         maps: TrackAnalyzers? = nil) throws {
        source = try SourceFingerprint(url: url); self.profile = profile
        self.cancellation = cancellation
        self.collectTimings = collectTimings
        decoder = try AudioDecoderFactory.open(url)
        do {
            guard (1...2).contains(decoder.processingFormat.channelCount),
                  let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192),
                  let output = AVAudioPCMBuffer(pcmFormat: profile.format, frameCapacity: 8192) else {
                throw AudioProcessingFailure.unsupportedProfile
            }
            self.input = input; self.output = output
            converter = try ProfileConversion.make(from: decoder.processingFormat, profile: profile)
            guard let nativeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: input.format.sampleRate,
                                                   channels: input.format.channelCount, interleaved: false),
                  let nativeAnalysis = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: 8192),
                  let nativeConverter = AVAudioConverter(from: input.format, to: nativeFormat) else { throw AudioProcessingFailure.unsupportedProfile }
            self.nativeAnalysis = nativeAnalysis; self.nativeConverter = nativeConverter
            meter = try LoudnessMeter(profile: profile)
            analyzers = try? maps?.make(sampleRate: profile.sampleRate)
        } catch { try? decoder.close(); throw error }
    }
    func read(checkActive: @escaping () throws -> Void = {}) throws -> TrackAudioMetrics? {
        let started = collectTimings ? ContinuousClock.now : nil
        defer { if let started { workSeconds += durationSeconds(started.duration(to: .now)) } }
        try cancellation.check(); try checkActive()
        var failure: Error?, conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] requested, state in
            do {
                try cancellation.check(); try checkActive()
                if eof { state.pointee = .endOfStream; return nil }
                try decoder.decode(into: input, length: min(requested, input.frameCapacity))
                if input.frameLength == 0 { eof = true; state.pointee = .endOfStream; return nil }
                readFrames += Int64(input.frameLength)
                let peakStarted = collectTimings ? ContinuousClock.now : nil
                nativePeak = max(nativePeak, try NativeSamplePeak.read(input, analysisBuffer: nativeAnalysis, converter: nativeConverter))
                if let peakStarted { nativePeakSeconds += durationSeconds(peakStarted.duration(to: .now)) }
                state.pointee = .haveData; return input
            } catch { failure = error; state.pointee = .endOfStream; return nil }
        }
        if let failure { throw failure }
        if let conversionError { throw conversionError }
        guard status != .error else { throw AudioProcessingFailure.invalidMeasurement }
        if output.frameLength > 0 {
            guard let channels = output.floatChannelData else { throw AudioProcessingFailure.invalidMeasurement }
            try meter.consume(left: channels[0], right: profile.channels == 2 ? channels[1] : nil, frames: output.frameLength)
            analyzers?.consume(left: channels[0], right: profile.channels == 2 ? channels[1] : nil, frames: Int(output.frameLength))
        }
        if status == .endOfStream {
            guard eof, readFrames > 0, decoder.length < 0 || readFrames == decoder.length else { throw PreprocessingFailure.invalidAudio }
            let levels = try meter.finish { try self.cancellation.check(); try checkActive() }
            trackMap = try? analyzers?.finish(); analyzers = nil
            try cancellation.check(); try checkActive(); try source.validate()
            return TrackAudioMetrics(source: source, profile: profile, levels: levels, sourceFrameCount: readFrames,
                sourcePeak: TrackPeak(source: source, samplePeak: nativePeak, frameCount: readFrames,
                    sampleRate: input.format.sampleRate, channelCount: input.format.channelCount))
        }
        return nil
    }
    func close() { try? decoder.close() }
}

private func durationSeconds(_ value: Duration) -> Double {
    Double(value.components.seconds) + Double(value.components.attoseconds)/1e18
}

/// Exclusive to AudioPreprocessor's queue: the map of a track whose levels are already known, read
/// in the source's own rate.
final class MapScan: @unchecked Sendable {
    let source: SourceFingerprint
    let decoder: any PCMDecoding
    let input: AVAudioPCMBuffer
    let output: AVAudioPCMBuffer
    let converter: AVAudioConverter
    let analyzers: TrackAnalyzers.Session
    private var readFrames: Int64 = 0
    init(url: URL, analyzers make: TrackAnalyzers) throws {
        source = try SourceFingerprint(url: url)
        decoder = try AudioDecoderFactory.open(url)
        do {
            let format = decoder.processingFormat
            guard (1...2).contains(format.channelCount),
                  let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                                  channels: format.channelCount, interleaved: false),
                  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
                  let output = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 8192),
                  let converter = AVAudioConverter(from: format, to: floatFormat) else { throw AudioProcessingFailure.unsupportedProfile }
            self.input = input; self.output = output; self.converter = converter
            analyzers = try make.make(sampleRate: format.sampleRate)
        } catch { try? decoder.close(); throw error }
    }
    /// One chunk; the map at the end of the track.
    func read() throws -> TrackMap? {
        try decoder.decode(into: input, length: input.frameCapacity)
        if input.frameLength == 0 {
            guard readFrames > 0, decoder.length < 0 || readFrames == decoder.length else { throw PreprocessingFailure.invalidAudio }
            try source.validate()
            return try analyzers.finish()
        }
        readFrames += Int64(input.frameLength)
        try converter.convert(to: output, from: input)
        guard output.frameLength == input.frameLength, let channels = output.floatChannelData else { throw PreprocessingFailure.invalidAudio }
        analyzers.consume(left: channels[0], right: output.format.channelCount == 2 ? channels[1] : nil, frames: Int(output.frameLength))
        return nil
    }
    func close() { try? decoder.close() }
}
