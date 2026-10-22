import Foundation
import AnalysisCore
import AudioProcessingCore

public enum PlaybackEvent: Sendable {
    case finished
    case failed(PlaybackError)
    case outputChanged
}

/// The UI and controller do not depend on a particular decoder or output API.
@MainActor
public protocol PlaybackBackend: AnyObject {
    var duration: TimeInterval { get }
    var supportsSeeking: Bool { get }
    var currentTime: TimeInterval { get }
    var volume: Float { get set }
    var onEvent: (@MainActor (PlaybackEvent) -> Void)? { get set }
    var normalizationPlan: NormalizationPlan? { get }
    func clearNormalization()
    func play() throws
    func pause() throws
    func resume() throws
    func seek(to seconds: TimeInterval) throws
    func stop()
    /// Stops because another track takes over. It may finish releasing the output elsewhere.
    func retire()
    func configureAnalysis(_ configuration: AnalysisConfiguration?,
                           receive: (@MainActor (AnalysisFrame) -> Void)?)
}

public extension PlaybackBackend {
    var normalizationPlan: NormalizationPlan? { nil }
    func clearNormalization() {}
    func retire() { stop() }
    func configureAnalysis(_ configuration: AnalysisConfiguration?,
                           receive: (@MainActor (AnalysisFrame) -> Void)?) {}
}
