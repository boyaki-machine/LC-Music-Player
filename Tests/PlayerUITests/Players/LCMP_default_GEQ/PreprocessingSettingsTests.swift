#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import PlaybackCore
import LibraryCore
@testable import PlayerUI

@Suite(.serialized) @MainActor struct PreprocessingSettingsTests {
    @Test func measurementSettingsRenderWithinMinimumExtension() async throws {
        let defaults = MemoryPreferences()
        let playback = PlaybackController()
        let library = LibraryController(playback: playback, store: SettingsStore(),
                                        preprocessingEnabled: true, preferences: defaults)
        defer { library.shutdown() }
        let presentation = PlayerPresentation(); presentation.section = .settings
        let actions = LibraryActions(files: { _ in }, folder: {}, repair: { _ in }, importPlaylist: {}, exportPlaylist: { _ in })
        let host = NSHostingView(rootView: ExtensionView(playback: playback, presentation: presentation, library: library, actions: actions))
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        for enabled in [false, true] {
            library.setMeasuresMaximumVolume(enabled)
            library.setNormalizesVolume(enabled)
            host.layoutSubtreeIfNeeded(); host.display()
            try await Task.sleep(for: .milliseconds(60))
            #expect(host.fittingSize.width <= 360 && host.fittingSize.height <= 240)
            if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("preprocessing-settings-\(enabled).png"))
            }
        }
    }
}

@MainActor private final class SettingsStore: LibraryPersistence {
    var recoveryMessage: String? { nil }
    func load() throws -> LibraryDocument { LibraryDocument() }
    func save(_ document: LibraryDocument) throws {}
}
#endif
