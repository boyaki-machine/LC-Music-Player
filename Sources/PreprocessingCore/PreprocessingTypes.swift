import Foundation

public enum PreprocessingFailure: Error, Sendable {
    case invalidAudio, sourceChanged, consumed, nonFiniteSample
}

/// Cancellation is checked between bounded reads. An underlying decoder open cannot be interrupted.
public final class PreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

public struct SourceFingerprint: Hashable, Sendable {
    public let url: URL
    public let size: Int
    public let modified: Date
    private let identity: String
    private let persistentRevision: MeasurementSourceIdentity?
    public init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { throw PreprocessingFailure.invalidAudio }
        self.url = url.standardizedFileURL
        persistentRevision = try? LocalMeasurementSourceIdentity().identity(for: url)
        self.size = size.intValue
        self.modified = modified
        identity = "\(attributes[.systemNumber] ?? "")/\(attributes[.systemFileNumber] ?? "")"
    }
    public func validate() throws {
        guard try SourceFingerprint(url: url) == self else { throw PreprocessingFailure.sourceChanged }
    }
}

public struct TrackPeak: Equatable, Sendable {
    public let source: SourceFingerprint
    public let samplePeak: Double
    public var peakDBFS: Double { samplePeak == 0 ? -.infinity : 20 * log10(samplePeak) }
    public let frameCount: Int64
    public let sampleRate: Double
    public let channelCount: UInt32
    public let analysisVersion = 1
}

public enum PeakMeasurementState: Equatable, Sendable {
    case disabled, pending, complete(TrackPeak), failed(String)
}
