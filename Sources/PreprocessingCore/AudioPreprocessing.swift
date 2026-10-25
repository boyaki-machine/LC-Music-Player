import Foundation
import AudioProcessingCore

/// Async worker boundary; callers retain scoped file access until each call returns.
public protocol AudioPreprocessing: Sendable {
    func prepare(_ url: URL, cancellation: PreparationCancellation,
                 seconds: Double, byteLimit: Int) async throws -> PreparedAudio
    func measure(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackPeak
    func measureLevels(_ url: URL, profile: MeasurementProfile,
                       cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackAudioMetrics
    /// The beats and lead vocal of the whole track, kept with the measurements (see `TrackMap`).
    func trackMap(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackMap
    func reconcileCacheOwners(_ owners: Set<UUID>) async
    /// A listener now waits for the work this cancellation belongs to: what is left runs at user-initiated QoS.
    func promote(_ cancellation: PreparationCancellation)
}

public extension AudioPreprocessing {
    func promote(_ cancellation: PreparationCancellation) {}
    /// Workers that do not map tracks leave the visualizations to estimate the beat while playing.
    func trackMap(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackMap {
        throw PreprocessingFailure.invalidAudio
    }
    /// The start of a track that playback begins from: up to `PreparedAudio.prefixSeconds` and `prefixByteLimit`.
    func preparePrefix(_ url: URL, cancellation: PreparationCancellation) async throws -> PreparedAudio {
        try await prepare(url, cancellation: cancellation, seconds: PreparedAudio.prefixSeconds, byteLimit: PreparedAudio.prefixByteLimit)
    }
}
