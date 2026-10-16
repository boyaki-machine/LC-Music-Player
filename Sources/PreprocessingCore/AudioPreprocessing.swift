import Foundation
import AudioProcessingCore

/// Async worker boundary; callers retain scoped file access until each call returns.
public protocol AudioPreprocessing: Sendable {
    func prepare(_ url: URL, cancellation: PreparationCancellation,
                 seconds: Double, byteLimit: Int) async throws -> PreparedAudio
    func measure(_ url: URL, cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackPeak
    func measureLevels(_ url: URL, profile: MeasurementProfile,
                       cancellation: PreparationCancellation, ownerID: UUID?) async throws -> TrackAudioMetrics
    func reconcileCacheOwners(_ owners: Set<UUID>) async
}
