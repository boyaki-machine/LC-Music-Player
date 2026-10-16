import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PlaybackCore
import LibraryCore
import PlayerUI
import OSLog

@main
@MainActor
enum LCMPApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let playback = PlaybackController()
    private lazy var library = LibraryController(playback: playback, preprocessingEnabled: true, preprocessor: AudioPreprocessor(cache: .application))
    private let presentation = PlayerPresentation()
    private var mainWindow: NSWindow!
    private var extensionWindow: NSWindow!
    private var arranging = false
    private var activePanel: NSSavePanel?
    private let shutdownLog = Logger(subsystem: "local.lcmp.player", category: "shutdown")
    private var quitRequestedAt: ContinuousClock.Instant?
    private var preferredExtensionHeight = WindowLayout.extensionSize.height

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindow = makeWindow(size: WindowLayout.mainSize, title: "LCMP")
        extensionWindow = makeWindow(size: WindowLayout.extensionSize, title: "LCMP 拡張")
        mainWindow.contentView = NSHostingView(rootView: PlayerView(playback: playback, presentation: presentation, library: library,
                                            chooseFile: chooseFile, toggleExtension: toggleExtension))
        extensionWindow.contentView = NSHostingView(rootView: ExtensionView(playback: playback, presentation: presentation, library: library, actions: LibraryActions(files: { [weak self] id in self?.selectSources(folder: false, target: id) }, folder: { [weak self] in self?.selectSources(folder: true) }, repair: { [weak self] id in self?.repairSource(id) }, importPlaylist: importPlaylist, exportPlaylist: exportPlaylist), resizeExtension: { [weak self] height in self?.resizeExtension(to: height) }))
        mainWindow.delegate = self
        extensionWindow.delegate = self
        mainWindow.center()
        installMenus()
        library.restore()
        showPlayer()
    }
    private func makeWindow(size: CGSize, title: String) -> NSWindow {
        let window = PlayerWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        return window
    }
    private func arrange() {
        guard !arranging, let mainWindow, let screen = mainWindow.screen ?? NSScreen.main else { return }
        arranging = true
        defer { arranging = false }
        let frames = WindowLayout.frames(main: mainWindow.frame, visible: screen.visibleFrame, expanded: presentation.extensionVisible,
                                         extensionHeight: preferredExtensionHeight)
        mainWindow.setFrame(frames.main, display: true)
        extensionWindow.setFrame(frames.extensionWindow, display: true)
    }
    private func resizeExtension(to height: CGFloat) {
        guard presentation.extensionVisible, let screen = mainWindow.screen ?? NSScreen.main else { return }
        preferredExtensionHeight = WindowLayout.resizedExtensionHeight(height, main: mainWindow.frame, visible: screen.visibleFrame)
        arrange()
    }
    private func showPlayer() {
        if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
        arrange()
        mainWindow.makeKeyAndOrderFront(nil)
        setVisualizationVisible(true)
        if presentation.extensionVisible { mainWindow.addChildWindow(extensionWindow, ordered: .above); extensionWindow.orderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleExtension() {
        presentation.toggleExtension()
        if presentation.extensionVisible {
            library.refreshAvailability()
            arrange()
            mainWindow.addChildWindow(extensionWindow, ordered: .above)
            extensionWindow.makeKeyAndOrderFront(nil)
        } else {
            mainWindow.removeChildWindow(extensionWindow)
            extensionWindow.orderOut(nil)
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }
    func windowDidMove(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow { arrange() }
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) { arrange() }
    func windowWillMiniaturize(_ notification: Notification) { extensionWindow.orderOut(nil); presentation.closeOverlays(); setVisualizationVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { showPlayer() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === extensionWindow { if presentation.extensionVisible { toggleExtension() }; return false }
        extensionWindow.orderOut(nil)
        setVisualizationVisible(false)
        presentation.closeOverlays()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPlayer(); return true }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow { presentation.scheduleSeekHide() }
    }
    func applicationDidResignActive(_ notification: Notification) { presentation.volumeVisible = false; presentation.scheduleSeekHide() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shutdownLog.notice("Application accepted termination request")
        activePanel?.cancel(nil)
        presentation.closeOverlays()
        setVisualizationVisible(false)
        library.shutdown()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        setVisualizationVisible(false)
        library.shutdown()
        if let quitRequestedAt { shutdownLog.notice("Application will terminate after \(String(describing: quitRequestedAt.duration(to: .now)), privacy: .public)") }
    }
    @objc private func quitPlayer() {
        quitRequestedAt = .now
        shutdownLog.notice("Quit command received")
        NSApp.terminate(self)
    }

    private func setVisualizationVisible(_ visible: Bool) {
        presentation.visualizationVisible = visible
        let configuration = visible ? LCMPDefaultGEQ.configuration : nil
        if playback.analysisConfiguration != configuration { playback.configureAnalysis(configuration) }
    }

    @objc private func chooseFile() { selectSources(folder: false) }
    private func selectSources(folder: Bool, target: UUID? = nil) {
        guard !presentation.selectingFile, library.canEdit else { return }
        presentation.selectingFile = true
        Task { @MainActor in
            defer { presentation.selectingFile = false; activePanel = nil }
            let panel = NSOpenPanel()
            activePanel = panel
            panel.title = folder ? "音楽フォルダを登録" : "音楽ファイルを登録"; panel.prompt = "登録"
            panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.allowsMultipleSelection = !folder
            if !folder { panel.allowedContentTypes = SupportedAudio.extensions.compactMap { UTType(filenameExtension: $0) } }
            if await panel.beginSheetModal(for: presentation.extensionVisible ? extensionWindow : mainWindow) == .OK {
                await library.importFiles(panel.urls, into: target)
            }
        }
    }
    private func repairSource(_ id: UUID) {
        guard !presentation.selectingFile, library.canEdit else { return }
        presentation.selectingFile = true
        Task { @MainActor in
            defer { presentation.selectingFile = false; activePanel = nil }
            let panel = NSOpenPanel(); panel.title = "音源ファイルを選び直す"; panel.prompt = "選択"
            activePanel = panel
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.allowedContentTypes = SupportedAudio.extensions.compactMap { UTType(filenameExtension: $0) }
            if await panel.beginSheetModal(for: extensionWindow) == .OK, let url = panel.url { library.repairTrack(id, using: url) }
        }
    }
    @objc private func importPlaylist() {
        guard !presentation.selectingFile, library.canEdit else { return }
        presentation.selectingFile = true
        Task { @MainActor in
            defer { presentation.selectingFile = false; activePanel = nil }
            let panel = NSOpenPanel(); panel.title = "M3U8を読み込む"; panel.canChooseDirectories = false
            activePanel = panel
            panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
            if await panel.beginSheetModal(for: presentation.extensionVisible ? extensionWindow : mainWindow) == .OK, let url = panel.url { await library.importM3U8(url) }
        }
    }
    private func exportPlaylist(_ id: UUID) {
        guard !presentation.selectingFile, library.canEdit, let list = library.playlist(id) else { return }
        presentation.selectingFile = true
        Task { @MainActor in
            defer { presentation.selectingFile = false; activePanel = nil }
            let panel = NSSavePanel(); panel.title = "M3U8を書き出す"
            activePanel = panel
            panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
            panel.nameFieldStringValue = list.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") + ".m3u8"
            if await panel.beginSheetModal(for: extensionWindow) == .OK, let url = panel.url { library.exportM3U8(id, to: url) }
        }
    }
    @objc private func playPause() { library.togglePlayPause() }
    @objc private func stopPlayback() { library.stop() }
    @objc private func toggleSeek() { mainWindow.makeKeyAndOrderFront(nil); presentation.seekVisible.toggle() }
    @objc private func toggleVolume() { mainWindow.makeKeyAndOrderFront(nil); presentation.volumeVisible.toggle() }
    @objc private func closePlayer() { mainWindow.performClose(nil) }
    @objc private func minimizePlayer() { mainWindow.miniaturize(nil) }
    @objc private func revealPlayer() { showPlayer() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(chooseFile), #selector(importPlaylist): return !presentation.selectingFile && library.canEdit
        case #selector(playPause): return playback.canPlay
        case #selector(stopPlayback): return playback.canStop || library.isPreparing
        default: return true
        }
    }
    private func installMenus() {
        let bar = NSMenu()
        func menu(_ title: String, items: [(String, Selector, String)]) {
            let root = NSMenuItem(); root.title = title
            let submenu = NSMenu(title: title)
            for (name, action, key) in items {
                let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
                item.target = self
                submenu.addItem(item)
            }
            root.submenu = submenu; bar.addItem(root)
        }
        menu("LCMP", items: [("LCMPを終了", #selector(quitPlayer), "q")])
        menu("ファイル", items: [("音楽ファイルを登録…", #selector(chooseFile), "o"), ("M3U8を読み込む…", #selector(importPlaylist), "i"), ("閉じる", #selector(closePlayer), "w")])
        menu("再生", items: [("再生／一時停止", #selector(playPause), " "), ("停止", #selector(stopPlayback), ".")])
        bar.items.last?.submenu?.items.first?.keyEquivalentModifierMask = []
        menu("表示", items: [("シークバー", #selector(toggleSeek), "s"), ("音量", #selector(toggleVolume), "u"), ("拡張画面", #selector(toggleExtension), "e")])
        menu("ウィンドウ", items: [("最小化", #selector(minimizePlayer), "m"), ("プレイヤーを表示", #selector(revealPlayer), "0")])
        NSApp.mainMenu = bar
    }
}
