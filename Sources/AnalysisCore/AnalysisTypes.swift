import Foundation

public struct AnalysisConfiguration: Equatable, Sendable {
    public let bandCount: Int
    public let framesPerSecond: Int
    public let fftSize: Int

    public init(bandCount: Int = 32, framesPerSecond: Int = 30, fftSize: Int = 2048) throws {
        guard (8...128).contains(bandCount), [15, 30, 60].contains(framesPerSecond),
              [1024, 2048, 4096, 8192].contains(fftSize) else {
            throw AnalysisError.invalidConfiguration
        }
        self.bandCount = bandCount
        self.framesPerSecond = framesPerSecond
        self.fftSize = fftSize
    }
}

public enum AnalysisError: Error { case invalidConfiguration, allocationFailed }

/// All host times are monotonic seconds derived from AVAudioTime.hostTime,
/// never Date or callback arrival time. Nil means unavailable, not zero latency.
public struct AnalysisTiming: Sendable {
    public let windowStartSample: Double?
    public let windowFrameCount: Int
    public let sampleRate: Double
    public let windowCenterHostTime: Double?
    /// Downstream latency EXCLUDING appliedAudioDelay. A future adapter must
    /// subtract its known compensation if the node's latency already includes it.
    public let estimatedOutputLatency: TimeInterval?
    /// Reserved for a future audio delay stage; currently always zero.
    public let appliedAudioDelay: TimeInterval
    public let producedHostTime: Double

    public var estimatedPresentationHostTime: Double? {
        guard let center = windowCenterHostTime, let latency = estimatedOutputLatency else { return nil }
        return center + latency + appliedAudioDelay
    }
}

/// Suggestions for a future compensator. Does not schedule or modify audio.
public enum SynchronizationEstimate {
    public static func additionalAudioDelay(visualLatency: Double, outputLatency: Double,
                                            margin: Double = 0) -> Double? {
        guard visualLatency.isFinite, outputLatency.isFinite, margin.isFinite,
              visualLatency >= 0, outputLatency >= 0, margin >= 0 else { return nil }
        let difference = visualLatency + margin - outputLatency
        return difference.isFinite ? max(0, difference) : nil
    }
}

public struct AnalysisFrame: Sendable {
    /// Changes after seek, pause/resume, route change, configuration or track change.
    public let generation: UUID
    public let sequence: UInt64
    public let timing: AnalysisTiming
    public let bandEdgesHz: [Double]
    /// Channel-averaged spectral power; 0dBFS is mean square 1, floor -100dBFS.
    public let bandDBFS: [Float]
    public let levels: [Float]
    public let leftRMS: Float
    public let rightRMS: Float
    public let leftPeak: Float
    public let rightPeak: Float
    public let droppedBuffers: UInt64
    public let queuedBufferHighWatermark: UInt32
    public let computationSeconds: Double
}
