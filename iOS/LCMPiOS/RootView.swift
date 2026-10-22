import SwiftUI
import UniformTypeIdentifiers
import PlaybackCore
import LibraryCore
import PlayerUI

/// Portrait: the player card above the extension, or the card alone in the middle.
/// Landscape: the player on the whole screen, or the player beside the extension.
struct RootView: View {
    let model: AppModel
    // The importer and mover clear `isPresented` before they call their completion, so what they
    // were opened for is kept separately and outlives the dismissal.
    @State private var importRequest: ImportRequest?
    @State private var importerShown = false
    @State private var exportFile: URL?
    @State private var moverShown = false
    @State private var showsLicense = false
    // The playlist that receives the picked songs; the outer optional is nil while the picker is closed.
    @State private var musicTarget: UUID?? = nil
    @State private var musicDenied = false

    private var presentation: PlayerPresentation { model.presentation }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color(red: 0.06, green: 0.07, blue: 0.08).ignoresSafeArea()
                if landscape { landscapeLayout } else { portraitLayout }
            }
        }
        .statusBarHidden(isFullScreenPlayer)
        .fileImporter(isPresented: $importerShown,
                      allowedContentTypes: importRequest?.contentTypes ?? [.audio],
                      allowsMultipleSelection: importRequest?.allowsMultipleSelection ?? false) { result in
            guard let request = importRequest else { return }
            importRequest = nil
            if case .success(let urls) = result, !urls.isEmpty { complete(request, urls) }
        }
        .fileMover(isPresented: $moverShown, file: exportFile) { _ in
            if let exportFile { try? FileManager.default.removeItem(at: exportFile.deletingLastPathComponent()) }
            exportFile = nil
        }
        .sheet(isPresented: $showsLicense) { AcknowledgementsSheet().presentationDragIndicator(.visible) }
        .sheet(isPresented: Binding(get: { musicTarget != nil }, set: { if !$0 { musicTarget = nil } })) {
            MusicLibraryPicker { items in
                let target = musicTarget ?? nil
                musicTarget = nil
                if !items.isEmpty { Task { await model.library.importMediaItems(items, into: target) } }
            }.ignoresSafeArea()
        }
        .alert("「ミュージック」のライブラリを読めません", isPresented: $musicDenied) {
            Button("設定を開く") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("設定のLCMPで「メディアとApple Music」へのアクセスを許可してください。")
        }
        #if DEBUG
        .task {
            // `-LCMPOrientationDelay <seconds>` turns the screen after playback has started.
            let delay = UserDefaults.standard.double(forKey: "LCMPOrientationDelay")
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            rotateForTesting()
        }
        #endif
    }

    #if DEBUG
    /// Simulator checks: `-LCMPOrientation landscape` turns the screen, as the simulator cannot be rotated from the shell.
    private func rotateForTesting() {
        guard UserDefaults.standard.string(forKey: "LCMPOrientation") == "landscape",
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
    }
    #endif

    @State private var orientationIsLandscape = false
    private var isFullScreenPlayer: Bool { orientationIsLandscape && !presentation.extensionVisible }

    private var player: some View {
        PlayerView(playback: model.playback, presentation: presentation, library: model.library,
                   chooseFile: { open(.files(target: nil)) }, toggleExtension: model.toggleExtension)
    }
    private var extensionView: some View {
        ExtensionView(playback: model.playback, presentation: presentation, library: model.library,
                      actions: LibraryActions(files: { open(.files(target: $0)) }, folder: { open(.folder) },
                                              repair: { open(.repair($0)) }, importPlaylist: { open(.playlist) },
                                              exportPlaylist: export, musicLibrary: pickMusic),
                      showAcknowledgements: { showsLicense = true })
    }

    private var portraitLayout: some View {
        VStack(spacing: 6) {
            if !presentation.extensionVisible { Spacer(minLength: 0) }
            player.environment(\.playerFrame, .card)
            if presentation.extensionVisible { extensionView } else { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 12).padding(.top, 8)
        .onAppear { orientationIsLandscape = false }
    }

    @ViewBuilder private var landscapeLayout: some View {
        Group {
            if presentation.extensionVisible {
                HStack(spacing: 8) {
                    player.environment(\.playerFrame, .panel)
                    extensionView.frame(width: 360)
                }.padding(.vertical, 8)
            } else {
                player.environment(\.playerFrame, .fullScreen)
            }
        }
        .onAppear { orientationIsLandscape = true }
    }

    private func open(_ request: ImportRequest) {
        guard !importerShown, !moverShown else { return }
        importRequest = request
        importerShown = true
    }

    private func pickMusic(into playlist: UUID?) {
        Task {
            if await MusicLibraryPicker.authorize() { musicTarget = .some(playlist) } else { musicDenied = true }
        }
    }

    private func complete(_ request: ImportRequest, _ urls: [URL]) {
        switch request {
        case .files(let target): Task { await model.library.importFiles(urls, into: target) }
        case .folder: Task { await model.library.importFiles(urls) }
        case .repair(let id): if let url = urls.first { model.library.repairTrack(id, using: url) }
        case .playlist: if let url = urls.first { Task { await model.library.importM3U8(url) } }
        }
    }

    /// Writes the playlist to a private temporary folder, then lets the user move it anywhere in Files.
    private func export(_ id: UUID) {
        guard let list = model.library.playlist(id) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = list.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + ".m3u8"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            Task {
                await model.library.exportM3U8(id, to: url)
                if FileManager.default.fileExists(atPath: url.path) { exportFile = url; moverShown = true }
            }
        } catch {}
    }
}

/// What the single file importer is open for.
enum ImportRequest {
    case files(target: UUID?)
    case folder
    case repair(UUID)
    case playlist

    var contentTypes: [UTType] {
        switch self {
        case .files, .repair: SupportedAudio.extensions.compactMap { UTType(filenameExtension: $0) }
        case .folder: [.folder]
        case .playlist: [UTType(filenameExtension: "m3u8") ?? .plainText]
        }
    }
    var allowsMultipleSelection: Bool {
        if case .files = self { true } else { false }
    }
}
