import SwiftUI
import AppIntents
import ControlSurfaces

/// Turns a glyph of the widgets into its button: an App Intent that the app
/// runs, or for the menu a link that opens the app with the extension shown.
struct ControlSurfaceButton: View {
    let command: TransportCommand
    let glyph: TransportGlyph

    var body: some View {
        switch command {
        case .menu: Link(destination: TransportCommand.menuURL) { label }
        case .playPause: Button(intent: PlayPauseIntent()) { label }.buttonStyle(.plain)
        case .previous: Button(intent: PreviousTrackIntent()) { label }.buttonStyle(.plain)
        case .next: Button(intent: NextTrackIntent()) { label }.buttonStyle(.plain)
        case .stop: Button(intent: StopIntent()) { label }.buttonStyle(.plain)
        }
    }
    private var label: some View {
        glyph.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }
}
