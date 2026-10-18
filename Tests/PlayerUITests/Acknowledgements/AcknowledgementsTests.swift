import AppKit
import QuartzCore
import SwiftUI
import Testing
import PlaybackCore
import LibraryCore
@testable import PlayerUI

private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-notices-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("example"), withIntermediateDirectories: true)
    try "Copyright Example\nPermission is granted.\n".write(to: root.appendingPathComponent("example/LICENSE"), atomically: true, encoding: .utf8)
    let json = #"{"schemaVersion":1,"packages":[{"id":"example","name":"Example","version":"1.0","revision":"abc","url":"https://example.org","documents":[{"title":"LICENSE","path":"example/LICENSE"}]}]}"#
    try json.write(to: root.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
    return root
}
/// LCMP's own documents, as the app build bundles them in Resources/LCMPLicense.
private func licenseFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-license-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "Copyright Own\nApache License text.\n".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
    try "Own NOTICE\n".write(to: root.appendingPathComponent("NOTICE"), atomically: true, encoding: .utf8)
    return root
}

@Suite(.serialized) @MainActor struct AcknowledgementsTests {
    @Test func catalogueAndTextRejectMissingCorruptAndEscapingDocuments() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalogue = try AcknowledgementCatalogue.load(from: root)
        let doc = try #require(catalogue.packages.first?.documents.first)
        #expect(try AcknowledgementCatalogue.text(doc, root: root) == "Copyright Example\nPermission is granted.\n")
        for path in ["../outside", "/etc/passwd", "example//LICENSE", "example/./LICENSE"] {
            #expect(throws: (any Error).self) { try AcknowledgementCatalogue.documentURL(.init(title: "bad", path: path), root: root) }
        }
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try AcknowledgementCatalogue.documentURL(.init(title: "bad", path: "escape/other"), root: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("example/LICENSE"))
        #expect(throws: (any Error).self) { try AcknowledgementCatalogue.text(doc, root: root) }
        // No third-party library is a valid catalogue; a malformed one is not.
        try Data(#"{"schemaVersion":1,"packages":[]}"#.utf8).write(to: root.appendingPathComponent("index.json"))
        #expect(try AcknowledgementCatalogue.load(from: root).packages.isEmpty)
        try Data("{}".utf8).write(to: root.appendingPathComponent("index.json"))
        #expect(throws: (any Error).self) { try AcknowledgementCatalogue.load(from: root) }
        let own = try licenseFixture(); defer { try? FileManager.default.removeItem(at: own) }
        let entry = try LicenseEntry.lcmp(root: own, version: "1.2.3")
        #expect(entry.package.name == "LC Music Player (LCMP)" && entry.package.version == "1.2.3")
        #expect(try entry.package.documents.map { try AcknowledgementCatalogue.text($0, root: own) } == ["Copyright Own\nApache License text.\n", "Own NOTICE\n"])
        try FileManager.default.removeItem(at: own.appendingPathComponent("NOTICE"))
        #expect(throws: (any Error).self) { try LicenseEntry.lcmp(root: own) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("index.json"))
        #expect(throws: (any Error).self) { try AcknowledgementCatalogue.load(from: root) }
    }

    @Test func singleWindowReopensAndSelectableTextFitsMinimumSize() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let own = try licenseFixture(); defer { try? FileManager.default.removeItem(at: own) }
        let controller = AcknowledgementsWindowController(resourceRoot: root, licenseRoot: own)
        controller.show()
        let window = try #require(controller.window)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.show(); #expect(controller.window === window)
        let host = try #require(window.contentView)
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if textViews(host).contains(where: { $0.string.contains("Copyright Own") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        var text = try #require(textViews(host).first { $0.string.contains("Copyright Own") })
        #expect(text.isSelectable && !text.isEditable && !text.isRichText)
        #expect(window.contentMinSize == NSSize(width: 560, height: 360))
        window.setContentSize(window.contentMinSize); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded(); host.display()
        text = try #require(textViews(host).first { $0.string.contains("Copyright Own") })
        #expect(host.fittingSize.width <= 560 && host.fittingSize.height <= 360)
        #expect(text.bounds.width > 100)
        text.setSelectedRange(NSRange(location: 0, length: 9))
        let clipboard = NSPasteboard(name: .init("lcmp-test-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        #expect(text.writeSelection(to: clipboard, types: text.writablePasteboardTypes))
        #expect(clipboard.string(forType: .string) == "Copyright")
        // LCMP comes first; the third-party rows follow it.
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let table = try #require(all(host).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 2)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for _ in 0..<100 {
            if textViews(host).contains(where: { $0.string.contains("Copyright Example") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(textViews(host).contains { $0.string.contains("Copyright Example") })
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("acknowledgements-minimum.png"))
        }
        window.performClose(nil); #expect(!window.isVisible)
        controller.show(); #expect(controller.window === window && window.isVisible)
    }

    /// LCMP_NOTICE_RESOURCES is a built app's Contents/Resources directory.
    @Test func builtCatalogueRendersOriginalsAndLongText() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LCMP_NOTICE_RESOURCES"] else { return }
        let resources = URL(fileURLWithPath: directory)
        let root = resources.appendingPathComponent("ThirdPartyLicenses"), own = resources.appendingPathComponent("LCMPLicense")
        let catalogue = try AcknowledgementCatalogue.load(from: root)
        // The index lists exactly the resolved dependencies: none while Package.resolved is absent.
        let resolved = root.appendingPathComponent("Package.resolved")
        if FileManager.default.fileExists(atPath: resolved.path) {
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as? [String: Any])
            let pins = try #require(json["pins"] as? [[String: Any]])
            #expect(Set(catalogue.packages.map(\.id)) == Set(pins.compactMap { $0["identity"] as? String }))
        } else {
            #expect(catalogue.packages.isEmpty)
        }
        let entry = try LicenseEntry.lcmp(root: own)
        let license = try AcknowledgementCatalogue.text(entry.package.documents[0], root: own)
        let notice = try AcknowledgementCatalogue.text(entry.package.documents[1], root: own)
        #expect(license.contains("Apache License") && license.count > 10000)
        let controller = AcknowledgementsWindowController(resourceRoot: root, licenseRoot: own)
        controller.show()
        let window = try #require(controller.window), host = try #require(window.contentView)
        defer { window.orderOut(nil); window.contentView = nil }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func shows(_ text: String) async throws -> Bool {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if all(host).compactMap({ $0 as? NSTextView }).contains(where: { $0.string == text }) { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        #expect(try await shows(license))
        // Only LCMP's own documents: one page without the list.
        let tables = all(host).compactMap { $0 as? NSTableView }
        if catalogue.packages.isEmpty { #expect(tables.isEmpty) } else { #expect(tables.first?.numberOfRows == 1 + catalogue.packages.count) }
        let picker = try #require(all(host).compactMap { $0 as? NSPopUpButton }.first)
        picker.selectItem(at: 1)
        #expect(picker.sendAction(picker.action, to: picker.target))
        #expect(try await shows(notice))
        if let output = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            picker.selectItem(at: 0)
            _ = picker.sendAction(picker.action, to: picker.target)
            _ = try await shows(license)
            window.displayIfNeeded(); host.display()
            CATransaction.flush()
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            if let frame = host.superview {
                frame.display()
                let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("acknowledgements-window.png"))
            }
        }
        // The full license text scrolls in the plain-text viewer.
        let longView = try #require(all(host).compactMap { $0 as? NSTextView }.first { $0.string == license })
        longView.layoutManager?.ensureLayout(for: try #require(longView.textContainer))
        longView.scrollToEndOfDocument(nil)
        #expect(longView.visibleRect.minY > 0)
    }

    @Test func settingsButtonOpensWindowWithoutChangingPlaybackOrLibrary() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let own = try licenseFixture(); defer { try? FileManager.default.removeItem(at: own) }
        let controller = AcknowledgementsWindowController(resourceRoot: root, licenseRoot: own)
        defer { controller.window?.orderOut(nil); controller.window?.contentView = nil }
        let playback = PlaybackController(), store = NoticeTestStore()
        let library = LibraryController(playback: playback, store: store)
        defer { library.shutdown() }
        let presentation = PlayerPresentation(); presentation.section = .settings
        let actions = LibraryActions(files: { _ in }, folder: {}, repair: { _ in }, importPlaylist: {}, exportPlaylist: { _ in })
        let host = NSHostingView(rootView: ExtensionView(playback: playback, presentation: presentation, library: library,
            actions: actions, showAcknowledgements: { controller.show() }))
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "showAcknowledgements" { return button }
            return view.subviews.compactMap(find).first
        }
        let button = try #require(find(host))
        #expect(button.sendAction(button.action, to: button.target))
        #expect(controller.window?.isVisible == true)
        #expect(playback.state == .empty && store.saves == 0)
        #expect(presentation.section == .settings && presentation.visualizationVisible)
        host.frame.size.height = 240; host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 360 && host.fittingSize.height <= 240)
        try await Task.sleep(for: .milliseconds(80))
        _ = button.scrollToVisible(button.bounds)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let rect = button.convert(button.bounds, to: host)
        #expect(host.bounds.intersects(rect))
        if let output = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            host.display()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("acknowledgements-settings.png"))
        }

    }
}
@MainActor private final class NoticeTestStore: LibraryPersistence {
    var recoveryMessage: String? { nil }
    var saves = 0
    func load() throws -> LibraryDocument { LibraryDocument() }
    func save(_ document: LibraryDocument) throws { saves += 1 }
}
