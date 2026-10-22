import SwiftUI
import PlaybackCore
import LibraryCore
import PlayerUI
import ControlSurfaces

@main
struct LCMPiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "LCMPControlSurfaces") { ControlSurfaceGallery() } else { root }
            #else
            root
            #endif
        }
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
    }

    private var root: some View {
        RootView(model: model)
            .preferredColorScheme(.dark)
            .onOpenURL { model.open($0) }
    }
}

/// Owns the shared playback, library and presentation objects for the app's lifetime.
@MainActor @Observable final class AppModel {
    let playback = PlaybackController()
    let library: LibraryController
    let presentation = PlayerPresentation(alwaysOnDisplay: .device())
    @ObservationIgnored private var session: AudioSessionController?
    @ObservationIgnored private var surfaces: ControlSurfaceController?
    @ObservationIgnored private var deviceVolume: DeviceVolumeMemory?

    init() {
        // Music library songs keep their measurements too, identified by the library's values.
        var cache = MeasurementCacheConfiguration.application
        cache.sourceIdentity = MediaLibraryMeasurementSourceIdentity()
        #if DEBUG
        // UI tests: `-LCMPLibraryFile <path>` keeps their library apart from the one in use.
        let store = JSONLibraryStore(url: UserDefaults.standard.string(forKey: "LCMPLibraryFile")
            .map { URL(fileURLWithPath: $0) } ?? JSONLibraryStore.defaultURL)
        #else
        let store = JSONLibraryStore(url: JSONLibraryStore.defaultURL)
        #endif
        library = LibraryController(playback: playback, store: store, preprocessingEnabled: true, playlistPreprocessingEnabled: true,
                                    preprocessor: AudioPreprocessor(cache: cache), tagReader: AssetTagReader())
        session = AudioSessionController(playback: playback, library: library)
        deviceVolume = DeviceVolumeMemory(playback: playback, system: AudioSessionOutputVolume(setter: SystemVolumeSlider.shared.set))
        library.restore()
        #if DEBUG
        // Device checks of the output latency. Runs with a library of their own (UI tests) leave it
        // off unless `-LCMPLatencyProbe YES` asks for it.
        AudioEngineBackend.recordsLatency = UserDefaults.standard.string(forKey: "LCMPLibraryFile") == nil
            || UserDefaults.standard.bool(forKey: "LCMPLatencyProbe")
        #endif
        surfaces = ControlSurfaceController(playback: playback)
        // The buttons of the widgets run here, even with the app in the background.
        TransportIntentHandler.handle = { [weak self] command in self?.perform(command) }
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

    /// A button of the widgets, handled like the same button of the player.
    func perform(_ command: TransportCommand) {
        switch command {
        case .playPause: library.togglePlayPause()
        case .previous: if library.canPrevious { library.previous() }
        case .next: if library.canNext { library.next() }
        case .stop: library.stop()
        case .menu: if !presentation.extensionVisible { toggleExtension() }
        }
    }

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

    /// `lcmp://extension` (the ☰ of the widgets) opens the extension.
    func open(_ url: URL) {
        guard url.scheme == "lcmp" else { return }
        if url.host() == "extension", !presentation.extensionVisible { toggleExtension() }
    }
}
