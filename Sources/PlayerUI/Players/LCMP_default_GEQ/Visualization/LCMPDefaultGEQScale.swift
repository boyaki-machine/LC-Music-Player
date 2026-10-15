import Foundation

/// Display sensitivity only; the analyzer keeps its full -100...0 dBFS data.
enum LCMPDefaultGEQScale {
    static func level(dbFS: Float) -> Float {
        guard dbFS.isFinite else { return .nan }
        return min(1, max(0, (dbFS + 80) / 80))
    }
}
