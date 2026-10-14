import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PlaybackCore
import PlayerUI

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
    private let presentation = PlayerPresentation()
    private var mainWindow: NSWindow!
    private var extensionWindow: NSWindow!
    private var arranging = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindow = makeWindow(size: WindowLayout.mainSize, title: "LCMP")
        extensionWindow = makeWindow(size: WindowLayout.extensionSize, title: "LCMP 拡張")
        mainWindow.contentView = NSHostingView(rootView: PlayerView(playback: playback, presentation: presentation,
                                            chooseFile: chooseFile, toggleExtension: toggleExtension))
        extensionWindow.contentView = NSHostingView(rootView: ExtensionView(playback: playback, presentation: presentation, chooseFile: chooseFile))
        mainWindow.delegate = self
        extensionWindow.delegate = self
        mainWindow.center()
        installMenus()
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
        let frames = WindowLayout.frames(main: mainWindow.frame, visible: screen.visibleFrame, expanded: presentation.extensionVisible)
        mainWindow.setFrame(frames.main, display: true)
        extensionWindow.setFrame(frames.extensionWindow, display: true)
    }
    private func showPlayer() {
        if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
        arrange()
        mainWindow.makeKeyAndOrderFront(nil)
        if presentation.extensionVisible { mainWindow.addChildWindow(extensionWindow, ordered: .above); extensionWindow.orderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleExtension() {
        presentation.toggleExtension()
        if presentation.extensionVisible {
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
    func windowWillMiniaturize(_ notification: Notification) { extensionWindow.orderOut(nil); presentation.closeOverlays() }
    func windowDidDeminiaturize(_ notification: Notification) { showPlayer() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === extensionWindow { if presentation.extensionVisible { toggleExtension() }; return false }
        extensionWindow.orderOut(nil)
        presentation.closeOverlays()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPlayer(); return true }
    func applicationDidResignActive(_ notification: Notification) { presentation.volumeVisible = false }
    func applicationWillTerminate(_ notification: Notification) { playback.close() }

    @objc private func chooseFile() {
        guard !presentation.selectingFile else { return }
        presentation.selectingFile = true
        Task { @MainActor in
            defer { presentation.selectingFile = false }
            let panel = NSOpenPanel()
            panel.title = "音楽ファイルを選択"; panel.prompt = "選択"
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.allowedContentTypes = SupportedAudio.extensions.compactMap { UTType(filenameExtension: $0) }
            let response = await panel.beginSheetModal(for: mainWindow)
            if response == .OK, let url = panel.url { playback.select(url) }
            else { playback.selectionCancelled() }
        }
    }
    @objc private func playPause() { playback.togglePlayPause() }
    @objc private func stopPlayback() { playback.stop() }
    @objc private func toggleSeek() { mainWindow.makeKeyAndOrderFront(nil); presentation.seekVisible.toggle() }
    @objc private func toggleVolume() { mainWindow.makeKeyAndOrderFront(nil); presentation.volumeVisible.toggle() }
    @objc private func closePlayer() { mainWindow.performClose(nil) }
    @objc private func minimizePlayer() { mainWindow.miniaturize(nil) }
    @objc private func revealPlayer() { showPlayer() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(chooseFile): return !presentation.selectingFile
        case #selector(playPause): return playback.canPlay
        case #selector(stopPlayback): return playback.canStop
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
                item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
                submenu.addItem(item)
            }
            root.submenu = submenu; bar.addItem(root)
        }
        menu("LCMP", items: [("LCMPを終了", #selector(NSApplication.terminate(_:)), "q")])
        menu("ファイル", items: [("音楽ファイルを開く…", #selector(chooseFile), "o"), ("閉じる", #selector(closePlayer), "w")])
        menu("再生", items: [("再生／一時停止", #selector(playPause), " "), ("停止", #selector(stopPlayback), ".")])
        bar.items.last?.submenu?.items.first?.keyEquivalentModifierMask = []
        menu("表示", items: [("シークバー", #selector(toggleSeek), "s"), ("音量", #selector(toggleVolume), "u"), ("拡張画面", #selector(toggleExtension), "e")])
        menu("ウィンドウ", items: [("最小化", #selector(minimizePlayer), "m"), ("プレイヤーを表示", #selector(revealPlayer), "0")])
        NSApp.mainMenu = bar
    }
}
