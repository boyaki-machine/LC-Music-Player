import AVFAudio
import AudioToolbox
import Foundation
import AudioProcessingCore
import LevelDSP

/// One utility queue, shared by prefix preparation and incremental full-track scans. Work requested
/// from a task of user-initiated priority or higher (a listener waiting for a song) runs at that
/// priority; background preparation runs in utility tasks and stays at utility.
public final class AudioPreprocessor: AudioPreprocessing {
    public static let shared = AudioPreprocessor()
    /// No QoS of its own: a queue's QoS is a floor under its work, which would keep background
    /// requests off the efficiency cores. Each request brings its QoS (`requestedQoS`).
    private let queue = DispatchQueue(label: "io.github.boyaki-machine.LC-Music-Player.preprocessing")
    private let state: PreprocessingState
    /// A standalone instance has no persistent side effects unless configured.
    /// The priority of work requested by the current task.
    /// Background requests run at background QoS, which Apple silicon keeps on the efficiency cores.
    static var requestedQoS: DispatchQoS {
        let priority = Task.currentPriority
        return priority >= .userInitiated ? .userInitiated : priority <= .background ? .background : .utility
    }
    public init(cache: MeasurementCacheConfiguration? = nil, collectMeasurementTimings: Bool = false) {
        state = PreprocessingState(cache: cache.map(MeasurementCache.init), collectTimings: collectMeasurementTimings,
                                   maps: cache?.trackAnalyzers ?? .standard)
        LoudnessMeter.cleanAbandonedFiles()
    }
    public func statistics() async -> MeasurementStatistics {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.state.statistics) } }
    }
    public func reconcileCacheOwners(_ owners: Set<UUID>) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { try? self.state.cache?.reconcile(owners); c.resume() }
        }
    }
    /// Scans already running for this cancellation continue at user-initiated QoS. A request that has
    /// not reached the queue yet reads the raised priority of the task that a listener now awaits.
    public func promote(_ cancellation: PreparationCancellation) {
        queue.async(qos: .userInitiated) {
            for job in self.state.levels.values where job.waiters.contains(where: { $0.cancellation === cancellation }) { job.raise(.userInitiated) }
            for job in self.state.peaks.values where job.waiters.contains(where: { $0.cancellation === cancellation }) { job.raise(.userInitiated) }
            for job in self.state.mapJobs.values where job.waiters.contains(where: { $0.cancellation === cancellation }) { job.raise(.userInitiated) }
        }
    }
    /// The QoS class a request from the current task runs at, for tests.
    func executionQoS() async -> qos_class_t {
        let qos = Self.requestedQoS
        return await withCheckedContinuation { c in queue.async(qos: qos, flags: .enforceQoS) { c.resume(returning: qos_class_self()) } }
    }
    /// The QoS of the running scans this cancellation waits for, for tests.
    func scanQoS(_ cancellation: PreparationCancellation) async -> [DispatchQoS.QoSClass] {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.state.levels.values.filter { $0.waiters.contains { $0.cancellation === cancellation } }.map(\.qos.qosClass)) }
        }
    }
    public func measureLevels(_ url: URL, profile: MeasurementProfile,
                              cancellation: PreparationCancellation = .init(), ownerID: UUID? = nil) async throws -> TrackAudioMetrics {
        let qos = Self.requestedQoS
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async(qos: qos, flags: .enforceQoS) {
                    do {
                        try cancellation.check()
                        let source = try SourceFingerprint(url: url)
                        let key = MeasurementJobKey(source: source, profile: profile)
                        let waiter = MeasurementWaiter(cancellation: cancellation, owner: ownerID, continuation: continuation)
                        if let job = self.state.levels[key] {
                            job.waiters.append(waiter); job.raise(qos); self.state.statistics.coalescedRequests += 1; return
                        }
                        let request = try? self.state.cache?.request(url, profile: profile)
                        if let request, let value = try? self.state.cache?.load(request, owner: ownerID),
                           let result = try? value.metrics(source: source, profile: profile) {
                            try self.state.cache?.validate(request, for: url)
                            try source.validate(); try cancellation.check()
                            try? self.state.cache?.associateNativePeak(for: url, owner: ownerID)
                            self.state.statistics.cacheHits += 1; continuation.resume(returning: result); return
                        }
                        self.state.statistics.cacheMisses += 1
                        let scan = try LevelScan(url: url, profile: profile, cancellation: .init(), collectTimings: self.state.collectTimings,
                                                 maps: self.state.maps)
                        let job = LevelJob(scan: scan, request: request, waiters: [waiter], qos: qos)
                        self.state.levels[key] = job; self.state.statistics.levelScans += 1
                        self.stepLevels(job, key: key)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func stepLevels(_ job: LevelJob, key: MeasurementJobKey) {
        do {
            guard job.isActive else { throw CancellationError() }
            if let result = try job.scan.read(checkActive: { guard job.isActive else { throw CancellationError() } }) {
                try key.source.validate()
                if let request = job.request { try state.cache?.validate(request, for: result.source.url) }
                guard result.source == key.source else { throw PreprocessingFailure.sourceChanged }
                if let request = job.request {
                    do { try state.cache?.save(CachedMeasurement(peak: result.sourcePeak, levels: result), request: request,
                        owners: job.waiters.filter { (try? $0.cancellation.check()) != nil }.map(\.owner), validating: result.source.url,
                        isCurrent: { job.waiters.contains { (try? $0.cancellation.check()) != nil } })
                        if let native = try state.cache?.request(result.source.url, profile: nil) {
                            try state.cache?.save(CachedMeasurement(peak: result.sourcePeak), request: native,
                                owners: job.waiters.filter { (try? $0.cancellation.check()) != nil }.map(\.owner), validating: result.source.url,
                                isCurrent: { job.waiters.contains { (try? $0.cancellation.check()) != nil } })
                        }
                    } catch { state.statistics.cacheWriteFailures += 1 }
                }
                state.statistics.measurementWorkSeconds += job.scan.workSeconds
                state.statistics.nativePeakWorkSeconds += job.scan.nativePeakSeconds
                job.scan.close(); state.levels[key] = nil
                if let map = job.scan.trackMap {
                    saveMap(map, url: result.source.url, owners: job.waiters.map(\.owner) + job.mapWaiters.map(\.owner),
                              isCurrent: { job.isActive })
                    for waiter in job.mapWaiters { waiter.finish(.success(map)) }
                } else { for waiter in job.mapWaiters { waiter.finish(.failure(PreprocessingFailure.invalidAudio)) } }
                for waiter in job.waiters { waiter.finish(.success(result)) }
            } else { queue.async(qos: job.qos, flags: .enforceQoS) { self.stepLevels(job, key: key) } }
        } catch {
            job.scan.close(); state.levels[key] = nil
            for waiter in job.waiters { waiter.finish(.failure(error)) }
            for waiter in job.mapWaiters { waiter.finish(.failure(error)) }
        }
    }

    /// The map of a track: a stored map of the configured analyzers, the map made by a level scan of
    /// the same source already under way, or a scan of its own.
    public func trackMap(_ url: URL, cancellation: PreparationCancellation = .init(), ownerID: UUID? = nil) async throws -> TrackMap {
        let qos = Self.requestedQoS
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async(qos: qos, flags: .enforceQoS) {
                    do {
                        try cancellation.check()
                        let source = try SourceFingerprint(url: url)
                        let key = MeasurementJobKey(source: source, profile: nil)
                        let waiter = MeasurementWaiter(cancellation: cancellation, owner: ownerID, continuation: continuation)
                        if let job = self.state.mapJobs[key] {
                            job.waiters.append(waiter); job.raise(qos); self.state.statistics.coalescedRequests += 1; return
                        }
                        let request = try? self.state.cache?.mapRequest(url)
                        if let request, let map = try? self.state.cache?.loadMap(request, owner: ownerID) {
                            try self.state.cache?.validate(request, for: url)
                            try source.validate(); try cancellation.check()
                            self.state.statistics.cacheHits += 1; continuation.resume(returning: map); return
                        }
                        if let job = self.state.levels.first(where: { $0.key.source == source && $0.value.scan.mapsTrack })?.value {
                            job.mapWaiters.append(waiter); job.raise(qos); self.state.statistics.coalescedRequests += 1; return
                        }
                        self.state.statistics.cacheMisses += 1
                        let scan = try MapScan(url: url, analyzers: self.state.maps)
                        let job = MapJob(scan: scan, waiters: [waiter], qos: qos)
                        self.state.mapJobs[key] = job; self.state.statistics.mapScans += 1
                        self.stepMap(job, key: key)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func stepMap(_ job: MapJob, key: MeasurementJobKey) {
        do {
            guard job.isActive else { throw CancellationError() }
            if let map = try job.scan.read() {
                try key.source.validate()
                job.scan.close(); state.mapJobs[key] = nil
                saveMap(map, url: key.source.url, owners: job.waiters.map(\.owner), isCurrent: { job.isActive })
                for waiter in job.waiters { waiter.finish(.success(map)) }
            } else { queue.async(qos: job.qos, flags: .enforceQoS) { self.stepMap(job, key: key) } }
        } catch {
            job.scan.close(); state.mapJobs[key] = nil
            for waiter in job.waiters { waiter.finish(.failure(error)) }
        }
    }
    private func saveMap(_ map: TrackMap, url: URL, owners: [UUID?], isCurrent: () -> Bool) {
        guard let cache = state.cache else { return }
        do {
            guard let request = try cache.mapRequest(url) else { return }
            try cache.saveMap(map, request: request, owners: owners, validating: url, isCurrent: isCurrent)
        } catch { state.statistics.cacheWriteFailures += 1 }
    }

    public func prepare(_ url: URL, cancellation: PreparationCancellation = .init(),
                        seconds: Double = PreparedAudio.prefixSeconds, byteLimit: Int = PreparedAudio.prefixByteLimit) async throws -> PreparedAudio {
        let qos = Self.requestedQoS
        return try await withCheckedThrowingContinuation { continuation in
            queue.async(qos: qos, flags: .enforceQoS) {
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
                          seconds.isFinite, seconds > 0, seconds <= PreparedAudio.prefixSeconds, bytesPerFrame > 0, byteLimit >= bytesPerFrame else {
                        throw PreprocessingFailure.invalidAudio
                    }
                    let frames = UInt32(min(Double(base.length), seconds * format.sampleRate,
                                            Double(min(byteLimit, PreparedAudio.prefixByteLimit) / bytesPerFrame)))
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

    public func measure(_ url: URL, cancellation: PreparationCancellation = .init(), ownerID: UUID? = nil) async throws -> TrackPeak {
        let qos = Self.requestedQoS
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async(qos: qos, flags: .enforceQoS) {
                    do {
                        try cancellation.check()
                        let source = try SourceFingerprint(url: url)
                        let key = MeasurementJobKey(source: source, profile: nil)
                        let waiter = MeasurementWaiter(cancellation: cancellation, owner: ownerID, continuation: continuation)
                        if let job = self.state.peaks[key] {
                            job.waiters.append(waiter); job.raise(qos); self.state.statistics.coalescedRequests += 1; return
                        }
                        let request = try? self.state.cache?.request(url, profile: nil)
                        if let request, let value = try? self.state.cache?.load(request, owner: ownerID),
                           let result = try? value.peak(source: source) {
                            try self.state.cache?.validate(request, for: url)
                            try source.validate(); try cancellation.check()
                            self.state.statistics.cacheHits += 1; continuation.resume(returning: result); return
                        }
                        self.state.statistics.cacheMisses += 1
                        let scan = try PeakScan(url: url, cancellation: .init())
                        let job = PeakJob(scan: scan, request: request, waiters: [waiter], qos: qos)
                        self.state.peaks[key] = job; self.state.statistics.peakScans += 1
                        self.step(job, key: key)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func step(_ job: PeakJob, key: MeasurementJobKey) {
        do {
            guard job.waiters.contains(where: { (try? $0.cancellation.check()) != nil }) else { throw CancellationError() }
            if let result = try job.scan.read() {
                try key.source.validate()
                if let request = job.request { try state.cache?.validate(request, for: result.source.url) }
                guard result.source == key.source else { throw PreprocessingFailure.sourceChanged }
                if let request = job.request {
                    do { try state.cache?.save(CachedMeasurement(peak: result), request: request,
                        owners: job.waiters.filter { (try? $0.cancellation.check()) != nil }.map(\.owner), validating: result.source.url,
                        isCurrent: { job.waiters.contains { (try? $0.cancellation.check()) != nil } }) }
                    catch { state.statistics.cacheWriteFailures += 1 }
                }
                job.scan.close(); state.peaks[key] = nil
                for waiter in job.waiters { waiter.finish(.success(result)) }
            } else { queue.async(qos: job.qos, flags: .enforceQoS) { self.step(job, key: key) } }
        } catch {
            job.scan.close(); state.peaks[key] = nil
            for waiter in job.waiters { waiter.finish(.failure(error)) }
        }
    }
}

public struct MeasurementStatistics: Sendable {
    public internal(set) var levelScans = 0
    public internal(set) var peakScans = 0
    public internal(set) var mapScans = 0
    public internal(set) var coalescedRequests = 0
    public internal(set) var cacheHits = 0
    public internal(set) var cacheMisses = 0
    public internal(set) var cacheWriteFailures = 0
    public internal(set) var measurementWorkSeconds = 0.0
    public internal(set) var nativePeakWorkSeconds = 0.0
}
private struct MeasurementJobKey: Hashable {
    let source: SourceFingerprint
    let rate: Double?
    let channels: UInt32?
    init(source: SourceFingerprint, profile: MeasurementProfile?) { self.source = source; rate = profile?.sampleRate; channels = profile?.channels }
}
private struct MeasurementWaiter<Value: Sendable> {
    let cancellation: PreparationCancellation
    let owner: UUID?
    let continuation: CheckedContinuation<Value, any Error>
    var isActive: Bool { (try? cancellation.check()) != nil }
    func finish(_ result: Result<Value, any Error>) {
        do { try cancellation.check(); continuation.resume(with: result) }
        catch { continuation.resume(throwing: error) }
    }
}
/// A scan continues at the highest priority any of its waiters asked for.
private final class LevelJob: @unchecked Sendable {
    let scan: LevelScan
    let request: MeasurementRequest?
    var waiters: [MeasurementWaiter<TrackAudioMetrics>]
    /// Requests for the map this scan also makes. They keep the scan going on their own.
    var mapWaiters: [MeasurementWaiter<TrackMap>] = []
    var isActive: Bool { waiters.contains { $0.isActive } || mapWaiters.contains { $0.isActive } }
    private(set) var qos: DispatchQoS
    init(scan: LevelScan, request: MeasurementRequest?, waiters: [MeasurementWaiter<TrackAudioMetrics>], qos: DispatchQoS) {
        self.scan = scan; self.request = request; self.waiters = waiters; self.qos = qos
    }
    func raise(_ requested: DispatchQoS) { if requested.qosClass.rawValue.rawValue > qos.qosClass.rawValue.rawValue { qos = requested } }
}
private final class PeakJob: @unchecked Sendable {
    let scan: PeakScan
    let request: MeasurementRequest?
    var waiters: [MeasurementWaiter<TrackPeak>]
    private(set) var qos: DispatchQoS
    init(scan: PeakScan, request: MeasurementRequest?, waiters: [MeasurementWaiter<TrackPeak>], qos: DispatchQoS) {
        self.scan = scan; self.request = request; self.waiters = waiters; self.qos = qos
    }
    func raise(_ requested: DispatchQoS) { if requested.qosClass.rawValue.rawValue > qos.qosClass.rawValue.rawValue { qos = requested } }
}
private final class MapJob: @unchecked Sendable {
    let scan: MapScan
    var waiters: [MeasurementWaiter<TrackMap>]
    var isActive: Bool { waiters.contains { $0.isActive } }
    private(set) var qos: DispatchQoS
    init(scan: MapScan, waiters: [MeasurementWaiter<TrackMap>], qos: DispatchQoS) { self.scan = scan; self.waiters = waiters; self.qos = qos }
    func raise(_ requested: DispatchQoS) { if requested.qosClass.rawValue.rawValue > qos.qosClass.rawValue.rawValue { qos = requested } }
}
private final class PreprocessingState: @unchecked Sendable {
    let cache: MeasurementCache?
    let collectTimings: Bool
    let maps: TrackAnalyzers
    var statistics = MeasurementStatistics()
    var levels: [MeasurementJobKey: LevelJob] = [:]
    var peaks: [MeasurementJobKey: PeakJob] = [:]
    var mapJobs: [MeasurementJobKey: MapJob] = [:]
    init(cache: MeasurementCache?, collectTimings: Bool, maps: TrackAnalyzers) {
        self.cache = cache; self.collectTimings = collectTimings; self.maps = maps
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
    var peak: Double = 0
    var frames: Int64 = 0
    init(url: URL, cancellation: PreparationCancellation) throws {
        source = try SourceFingerprint(url: url)
        decoder = try AudioDecoderFactory.open(url)
        self.cancellation = cancellation
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
    func close() { try? decoder.close() }
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
        for channel in 0..<Int(format.channelCount) {
            guard let raw = buffers[interleaved ? 0 : channel].mData else { throw PreprocessingFailure.invalidAudio }
            // The sample format is fixed per buffer: dispatch once, then scan the channel in C.
            let first = interleaved ? channel : 0
            var channelPeak = 0.0
            switch commonFormat {
            case .pcmFormatFloat32:
                guard lcmp_peak_f32(raw.assumingMemoryBound(to: Float.self) + first, frameCount, sampleStride, &channelPeak) != 0 else {
                    throw PreprocessingFailure.nonFiniteSample
                }
            case .pcmFormatFloat64:
                guard lcmp_peak_f64(raw.assumingMemoryBound(to: Double.self) + first, frameCount, sampleStride, &channelPeak) != 0 else {
                    throw PreprocessingFailure.nonFiniteSample
                }
            case .pcmFormatInt16: channelPeak = lcmp_peak_i16(raw.assumingMemoryBound(to: Int16.self) + first, frameCount, sampleStride)
            case .pcmFormatInt32: channelPeak = lcmp_peak_i32(raw.assumingMemoryBound(to: Int32.self) + first, frameCount, sampleStride)
            case .otherFormat: channelPeak = try packedIntegerPeak(raw, format: format, channel: channel, frames: frameCount)
            default: if frameCount > 0 { throw PreprocessingFailure.invalidAudio }
            }
            peak = max(peak, channelPeak)
        }
        return peak
    }

    /// Native signed integers that have no AVAudioCommonFormat, such as packed 24-bit PCM
    /// or 16-bit samples aligned high in 32-bit words.
    private static func packedIntegerPeak(_ raw: UnsafeMutableRawPointer, format: AVAudioFormat,
                                          channel: Int, frames frameCount: Int) throws -> Double {
        guard frameCount > 0 else { return 0 }
        let interleaved = format.isInterleaved
        let description = format.streamDescription.pointee
        let width = Int(description.mBytesPerFrame) / (interleaved ? Int(format.channelCount) : 1)
        guard width > 0, width <= 4, description.mBitsPerChannel <= width * 8 else { throw PreprocessingFailure.invalidAudio }
        return lcmp_peak_packed(raw.assumingMemoryBound(to: UInt8.self) + (interleaved ? channel * width : 0), frameCount,
                                Int(description.mBytesPerFrame), UInt32(width), description.mBitsPerChannel,
                                description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 ? 1 : 0,
                                description.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 ? 1 : 0)
    }
}
