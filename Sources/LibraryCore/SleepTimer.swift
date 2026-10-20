import Foundation

/// Ends playback after a number of songs and lowers the volume on the way, for falling asleep.
/// The song playing when the timer starts is the first; every change of song counts one more.
public struct SleepTimer: Equatable, Sendable {
    /// The song counts offered by a long press on the timer.
    public static let choices = [1, 2, 3, 5, 10]
    public static let defaultCount = 3
    /// The fade reaches this attenuation as the last song ends, then playback stops.
    public static let finalAttenuationDB = 30.0

    public private(set) var count: Int
    /// Songs left behind since the timer started.
    public private(set) var finishedSongs = 0
    /// How far the first song had played when the timer started, so the fade begins at full volume.
    let startFraction: Double

    public init(count: Int, startFraction: Double = 0) {
        self.count = max(1, count)
        self.startFraction = Self.clamped(startFraction)
    }

    /// Songs still to be played, the current one included.
    public var remainingSongs: Int { max(1, count - finishedSongs) }
    /// True while the current song is the last one.
    public var isOnLastSong: Bool { finishedSongs + 1 >= count }

    mutating func songChanged() { finishedSongs += 1 }
    /// A new count keeps the songs already played; the current song always finishes.
    mutating func setCount(_ count: Int) { self.count = max(finishedSongs + 1, count) }

    /// 0 when the timer starts, 1 when the last song ends. `fraction` is the current song's position.
    public func progress(currentFraction fraction: Double) -> Double {
        let total = Double(count) - startFraction
        let elapsed = Double(finishedSongs) + Self.clamped(fraction) - startFraction
        return total > 0 ? Self.clamped(elapsed / total) : 1
    }

    /// The factor on the app volume. It falls evenly in decibels, which sounds like a steady fade.
    public func gain(currentFraction fraction: Double) -> Float {
        Float(pow(10, -Self.finalAttenuationDB * progress(currentFraction: fraction) / 20))
    }

    private static func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}
