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
        try Data("{}".utf8).write(to: root.appendingPathComponent("index.json"))
        #expect(throws: (any Error).self) { try AcknowledgementCatalogue.load(from: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("index.json"))
        #expect(throws: (any Error).self) { try AcknowledgementCatalogue.load(from: root) }
    }

    @Test func singleWindowReopensAndSelectableTextFitsMinimumSize() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = AcknowledgementsWindowController(resourceRoot: root)
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
            if textViews(host).contains(where: { $0.string.contains("Copyright Example") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        var text = try #require(textViews(host).first { $0.string.contains("Copyright Example") })
        #expect(text.isSelectable && !text.isEditable && !text.isRichText)
        #expect(window.contentMinSize == NSSize(width: 560, height: 360))
        window.setContentSize(window.contentMinSize); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded(); host.display()
        text = try #require(textViews(host).first { $0.string.contains("Copyright Example") })
        #expect(host.fittingSize.width <= 560 && host.fittingSize.height <= 360)
        #expect(text.bounds.width > 100)
        text.setSelectedRange(NSRange(location: 0, length: 9))
        let clipboard = NSPasteboard(name: .init("lcmp-test-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        #expect(text.writeSelection(to: clipboard, types: text.writablePasteboardTypes))
        #expect(clipboard.string(forType: .string) == "Copyright")
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("acknowledgements-minimum.png"))
        }
        window.performClose(nil); #expect(!window.isVisible)
        controller.show(); #expect(controller.window === window && window.isVisible)
    }

    @Test func builtCatalogueRendersOriginalsAndLongText() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LCMP_NOTICE_RESOURCES"] else { return }
        let root = URL(fileURLWithPath: directory)
        let catalogue = try AcknowledgementCatalogue.load(from: root)
        let expected = try AcknowledgementCatalogue.text(#require(catalogue.packages.first?.documents.first), root: root)
        let controller = AcknowledgementsWindowController(resourceRoot: root)
        controller.show()
        let window = try #require(controller.window), host = try #require(window.contentView)
        defer { window.orderOut(nil); window.contentView = nil }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if all(host).compactMap({ $0 as? NSTextView }).contains(where: { $0.string == expected }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let original = try #require(all(host).compactMap { $0 as? NSTextView }.first { $0.string == expected })
        #expect(original.isSelectable && original.string == expected)
        let resolved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Package.resolved"))) as? [String: Any])
        let pins = try #require(resolved["pins"] as? [[String: Any]])
        #expect(Set(catalogue.packages.map(\.id)) == Set(pins.compactMap { $0["identity"] as? String }))
        if let output = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            window.displayIfNeeded(); host.display(); original.display()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("acknowledgements-bundled.png"))
            if let frame = host.superview {
                frame.display()
                let frameRep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: frameRep)
                try frameRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("acknowledgements-window.png"))
            }
            let textRep = try #require(original.bitmapImageRepForCachingDisplay(in: original.visibleRect))
            original.cacheDisplay(in: original.visibleRect, to: textRep)
            try textRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("acknowledgements-original.png"))
        }
        if let table = all(host).compactMap({ $0 as? NSTableView }).first,
           let row = catalogue.packages.firstIndex(where: { $0.id == "sfbaudioengine" }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let selected = catalogue.packages[row]
            let firstText = try AcknowledgementCatalogue.text(#require(selected.documents.first), root: root)
            for _ in 0..<100 {
                if all(host).compactMap({ $0 as? NSTextView }).contains(where: { $0.string == firstText }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(all(host).compactMap { $0 as? NSTextView }.contains { $0.string == firstText })
            let picker = try #require(all(host).compactMap { $0 as? NSPopUpButton }.first)
            picker.selectItem(at: 1)
            #expect(picker.sendAction(picker.action, to: picker.target))
            let nextText = try AcknowledgementCatalogue.text(selected.documents[1], root: root)
            for _ in 0..<100 {
                if all(host).compactMap({ $0 as? NSTextView }).contains(where: { $0.string == nextText }) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(all(host).compactMap { $0 as? NSTextView }.contains { $0.string == nextText })
        } else {
            Issue.record("Native dependency table was not found")
        }
        // Every indexed original is readable offline, including nested acknowledgements.
        var longest = ""
        for package in catalogue.packages {
            for document in package.documents {
                let text = try AcknowledgementCatalogue.text(document, root: root)
                if text.count > longest.count { longest = text }
            }
        }
        let longView = try #require(all(host).compactMap { $0 as? NSTextView }.first { $0.isEditable == false && $0.enclosingScrollView != nil })
        longView.string = longest
        longView.layoutManager?.ensureLayout(for: try #require(longView.textContainer))
        #expect(longView.string == longest && longest.count > 10000)
        longView.scrollToEndOfDocument(nil)
        #expect(longView.visibleRect.minY > 0)
    }

    @Test func settingsButtonOpensWindowWithoutChangingPlaybackOrLibrary() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = AcknowledgementsWindowController(resourceRoot: root)
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
