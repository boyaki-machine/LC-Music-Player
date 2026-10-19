import WidgetKit
import Observation
import ControlSurfaces
import PlaybackCore
import PlayerUI

/// Shares the transport state with the home screen widgets when the App Group is available,
/// and reloads them when it changes. Without the App Group the widgets show a toggle and
/// nothing needs sharing. The lock screen and the Dynamic Island are the system "Now Playing".
@MainActor final class ControlSurfaceController {
    private let playback: PlaybackController
    private let store = SharedTransportStore.appGroup()
    private var pending: Task<Void, Never>?
    /// A finished song is followed by the next one through `stopped`/`finished`; a stop only
    /// counts once it lasts this long, so the widgets do not blink between songs.
    private static let stopSettling: Duration = .milliseconds(600)

    init(playback: PlaybackController) {
        self.playback = playback
        guard store.isShared else { return }
        track()
    }

    private func track() {
        withObservationTracking { _ = playback.state } onChange: { [weak self] in
            Task { @MainActor in self?.changed(); self?.track() }
        }
        changed()
    }

    private func changed() {
        guard let state = TransportState(playback.state) else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            if state == .stopped {
                try? await Task.sleep(for: Self.stopSettling)
                if Task.isCancelled { return }
            }
            self?.apply(state)
        }
    }

    private func apply(_ state: TransportState) {
        guard store.state != state else { return }
        store.write(state)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedTransportStore.widgetKind)
    }
}
