import PlaybackCore
import ControlSurfaces

public extension TransportState {
    /// The state the widgets show. `ready` (a song selected or being switched)
    /// keeps what they show, so changing songs does not blink them; nil means "no change".
    init?(_ state: PlaybackState) {
        switch state {
        case .playing: self = .playing
        case .paused: self = .paused
        case .stopped, .finished, .empty, .failed: self = .stopped
        case .ready: return nil
        }
    }
}
