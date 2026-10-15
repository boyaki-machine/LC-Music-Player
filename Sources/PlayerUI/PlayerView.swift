import SwiftUI
import PlaybackCore
import LibraryCore

/// App-facing entry point. Player-specific views live under Players/<design ID>/.
public struct PlayerView: View {
    let playback: PlaybackController
    let library: LibraryController?
    let presentation: PlayerPresentation
    let chooseFile: () -> Void
    let toggleExtension: () -> Void

    public init(playback: PlaybackController, presentation: PlayerPresentation, library: LibraryController? = nil,
                chooseFile: @escaping () -> Void, toggleExtension: @escaping () -> Void) {
        self.playback = playback; self.presentation = presentation; self.library = library
        self.chooseFile = chooseFile; self.toggleExtension = toggleExtension
    }

    public var body: some View {
        LCMPDefaultGEQPlayerView(playback: playback, presentation: presentation, library: library,
                                 chooseFile: chooseFile, toggleExtension: toggleExtension)
    }
}
