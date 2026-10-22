import Foundation

/// Keeps the output latency of the estimated presentation time current while playing.
///
/// The latency is the observation node's `outputPresentationLatency` alone. It already holds the
/// route's latency: on macOS the device latency of Core Audio, and on iOS `AVAudioSession.outputLatency`,
/// Bluetooth included (measured on an iPhone: 15.8ms through the speaker, 240.6ms through Bluetooth
/// earphones, equal to the session's value each time). Adding the session's value would count it twice.
///
/// A route change that keeps the format keeps the engine running, so the latency bound at the
/// start would go stale (by about 225ms between the speaker and Bluetooth). The tracker reads it
/// again on each change and applies it when it moved. A change of format stops playback instead.
@MainActor final class OutputLatencyTracker {
    /// Changes smaller than this are noise of the report, not a new route.
    static let threshold = 0.0005
    private let read: () -> Double?
    private let apply: (Double) -> Void
    private let center: NotificationCenter
    private var token: NSObjectProtocol?
    private(set) var applied: Double?

    init(initial: Double, notification: Notification.Name?, center: NotificationCenter = .default,
         read: @escaping () -> Double?, apply: @escaping (Double) -> Void) {
        self.read = read; self.apply = apply; self.center = center
        applied = Self.valid(initial)
        token = notification.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    isolated deinit { cancel() }

    func cancel() {
        if let token { center.removeObserver(token) }
        token = nil
    }

    /// Reads the latency and applies a valid value that differs from the last one applied.
    func refresh() {
        guard let latency = read().flatMap(Self.valid) else { return }
        if let applied, abs(applied - latency) < Self.threshold { return }
        applied = latency
        apply(latency)
    }

    private static func valid(_ seconds: Double) -> Double? { seconds.isFinite && seconds >= 0 && seconds < 2 ? seconds : nil }
}
