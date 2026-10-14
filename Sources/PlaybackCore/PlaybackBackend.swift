import Foundation

public enum PlaybackEvent: Sendable {
    case finished
    case failed(PlaybackError)
    case outputChanged
}

/// The UI and controller do not depend on a particular decoder or output API.
@MainActor
public protocol PlaybackBackend: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    var volume: Float { get set }
    var onEvent: (@MainActor (PlaybackEvent) -> Void)? { get set }
    func play() throws
    func pause() throws
    func resume() throws
    func stop()
}
