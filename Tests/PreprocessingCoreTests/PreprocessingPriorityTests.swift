import AVFAudio
import Foundation
import AudioProcessingCore
import Testing
@testable import PreprocessingCore

/// A listener's request runs at its own priority; background preparation stays at utility.
@Suite struct PreprocessingPriorityTests {
    @Test func requestsKeepTheirTaskPriority() async {
        let urgent = await detached(.userInitiated) { AudioPreprocessor.requestedQoS }
        let high = await detached(.high) { AudioPreprocessor.requestedQoS }
        let background = await detached(.utility) { AudioPreprocessor.requestedQoS }
        let lowest = await detached(.background) { AudioPreprocessor.requestedQoS }
        #expect(urgent == .userInitiated && high == .userInitiated)
        #expect(background == .utility && lowest == .background)
    }

    /// Runs `body` in a task of `priority` without awaiting the task, which would raise it.
    private func detached<T: Sendable>(_ priority: TaskPriority, _ body: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { c in Task.detached(priority: priority) { c.resume(returning: await body()) } }
    }

    /// The queue has no QoS of its own, which would be a floor under background work.
    @Test func backgroundRequestsRunAtBackgroundQoS() async {
        let processor = AudioPreprocessor()
        #expect(await detached(.background) { await processor.executionQoS() } == QOS_CLASS_BACKGROUND)
        #expect(await detached(.utility) { await processor.executionQoS() } == QOS_CLASS_UTILITY)
        #expect(await detached(.userInitiated) { await processor.executionQoS() } == QOS_CLASS_USER_INITIATED)
    }

    /// A sweep's scan that a listener takes over continues at user-initiated QoS. The scan starts at utility, as the
    /// sweep's scans of the current track and its neighbours do: one at background may not start for minutes on a
    /// loaded iOS simulator, and the raise is the same from either.
    @Test func promotingRaisesTheRunningScan() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-promote-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)); buffer.frameLength = 48000
        for channel in 0..<2 { for n in 0..<48000 { buffer.floatChannelData![channel][n] = Float(n % 97) / 200 } }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); for _ in 0..<120 { try file.write(from: buffer) } }
        let processor = AudioPreprocessor(), cancellation = PreparationCancellation(), other = PreparationCancellation()
        let profile = try MeasurementProfile(sampleRate: 48000, channels: 2)
        Task.detached(priority: .utility) { _ = try? await processor.measureLevels(url, profile: profile, cancellation: cancellation) }
        let deadline = ContinuousClock.now + .seconds(10)
        while await processor.scanQoS(cancellation).isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await processor.scanQoS(cancellation) == [.utility])
        processor.promote(other)
        #expect(await processor.scanQoS(cancellation) == [.utility])
        processor.promote(cancellation)
        #expect(await processor.scanQoS(cancellation) == [.userInitiated])
        cancellation.cancel()
    }
}
