import SwiftUI
import PlaybackCore
import LibraryCore
import PlayerUI

@main
struct LCMPiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
    }
}

/// Owns the shared playback, library and presentation objects for the app's lifetime.
@MainActor @Observable final class AppModel {
    let playback = PlaybackController()
    let library: LibraryController
    let presentation = PlayerPresentation()
    @ObservationIgnored private var session: AudioSessionController?

    init() {
        library = LibraryController(playback: playback, preprocessingEnabled: true, playlistPreprocessingEnabled: true,
                                    preprocessor: AudioPreprocessor(cache: .application))
        session = AudioSessionController(playback: playback, library: library)
        library.restore()
        // A normal launch shows the player with the extension below it.
        #if DEBUG
        // Simulator checks: `-LCMPExtension NO` starts with the extension closed.
        if UserDefaults.standard.string(forKey: "LCMPExtension") != "NO" { presentation.toggleExtension() }
        importForTesting()
        #else
        presentation.toggleExtension()
        #endif
    }

    #if DEBUG
    /// Simulator checks without the document picker: `-LCMPImportPaths <path>,<path>` registers
    /// files or folders of the Mac into the current playlist, and `-LCMPAutoplay YES` starts playback.
    private func importForTesting() {
        guard let paths = UserDefaults.standard.string(forKey: "LCMPImportPaths") else { return }
        let urls = paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        Task {
            guard let list = library.document.currentPlaylistID ?? library.document.playlists.first?.id else { return }
            // Register into the list only once, so repeated launches do not duplicate entries.
            await library.importFiles(urls, into: library.playlist(list)?.entries.isEmpty == true ? list : nil)
            if UserDefaults.standard.bool(forKey: "LCMPAutoplay"), playback.state != .playing { library.playPlaylist(list) }
        }
    }
    #endif

    func toggleExtension() {
        presentation.toggleExtension()
        if presentation.extensionVisible { library.refreshAvailability() }
    }

    /// Drawing and analysis stop in the background; playback continues.
    func sceneChanged(_ phase: ScenePhase) {
        let visible = phase == .active
        if !visible { presentation.closeOverlays() }
        presentation.visualizationVisible = visible
        let configuration = visible ? LCMPDefaultGEQ.configuration : nil
        if playback.analysisConfiguration != configuration { playback.configureAnalysis(configuration) }
    }

    /// `lcmp://extension` (the ☰ of the widgets and the Live Activity) opens the extension.
    func open(_ url: URL) {
        guard url.scheme == "lcmp" else { return }
        if url.host() == "extension", !presentation.extensionVisible { toggleExtension() }
    }
}
