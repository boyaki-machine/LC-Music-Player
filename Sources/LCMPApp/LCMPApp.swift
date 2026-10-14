import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlaybackCore

@main
struct LCMPApp: App {
    @State private var playback = PlaybackController()
    @State private var selectingFile = false

    var body: some Scene {
        Window("LC Music Player", id: "player") {
            PlayerView(playback: playback, selectingFile: selectingFile, chooseFile: chooseFile)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    playback.close()
                }
        }
        .defaultSize(width: 520, height: 270)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("音楽ファイルを開く…", action: chooseFile)
                    .keyboardShortcut("o")
                    .disabled(selectingFile)
            }
        }
    }

    private func chooseFile() {
        guard !selectingFile else { return }
        selectingFile = true
        Task { @MainActor in
            defer { selectingFile = false }
            let panel = NSOpenPanel()
            panel.title = "音楽ファイルを選択"
            panel.prompt = "選択"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = SupportedAudio.extensions.compactMap { UTType(filenameExtension: $0) }
            let response: NSApplication.ModalResponse
            if let window = NSApplication.shared.keyWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await panel.begin()
            }
            if response == .OK, let url = panel.url {
                playback.select(url)
            } else {
                playback.selectionCancelled()
            }
        }
    }
}
