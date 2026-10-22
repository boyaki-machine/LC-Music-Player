#if DEBUG
import Foundation

/// Debug builds only: records what the system reports about output latency, for checking on a
/// device how the estimated presentation time relates to the sound. Off unless the app turns it
/// on. Lines of JSON go to `Library/Caches/lcmp-latency.jsonl`; no names of songs or devices.
public enum LatencyProbe {
    nonisolated(unsafe) public static var isEnabled = false
    private static let lock = NSLock()
    nonisolated(unsafe) private static var leads: [Double] = []
    nonisolated(unsafe) private static var lines = 0
    private static let maximumLines = 5000

    /// How far the render's host time lies after the render notification ran, in seconds.
    static func recordRenderLead(_ seconds: Double) {
        guard isEnabled, seconds.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        if leads.count < 10_000 { leads.append(seconds) }
    }

    /// Writes one line with the given values and a summary of the render leads since the last line.
    public static func write(_ event: String, _ values: [String: Any]) {
        guard isEnabled else { return }
        lock.lock()
        let sorted = leads.sorted(); leads.removeAll(keepingCapacity: true)
        guard lines < maximumLines else { lock.unlock(); return }
        lines += 1
        lock.unlock()
        var line = values
        line["event"] = event
        line["time"] = Date().timeIntervalSince1970
        if !sorted.isEmpty {
            line["renderLeadMs"] = ["count": sorted.count, "min": sorted[0] * 1000,
                                    "p50": sorted[sorted.count / 2] * 1000, "max": sorted[sorted.count - 1] * 1000]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = caches.appendingPathComponent("lcmp-latency.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}
#endif
