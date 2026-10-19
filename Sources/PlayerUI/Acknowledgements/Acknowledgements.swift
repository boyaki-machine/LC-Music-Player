#if os(macOS)
import AppKit
#endif
import SwiftUI

struct AcknowledgementDocument: Codable, Identifiable, Hashable, Sendable {
    let title: String
    let path: String
    var id: String { path }
}
struct AcknowledgementPackage: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String?
    let revision: String
    let url: String?
    let documents: [AcknowledgementDocument]
}
/// One row of the license window: LCMP itself, then any third-party package.
/// Each row reads its documents from its own bundled directory.
struct LicenseEntry: Identifiable, Sendable {
    let package: AcknowledgementPackage
    let root: URL
    var id: String { package.id }

    /// LCMP's own LICENSE and NOTICE, bundled in Resources/LCMPLicense by the app build.
    static func lcmp(root: URL, version: String = AppVersion.text()) throws -> Self {
        let documents = ["LICENSE", "NOTICE"].map { AcknowledgementDocument(title: $0, path: $0) }
        for document in documents {
            let url = try AcknowledgementCatalogue.documentURL(document, root: root)
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        }
        return Self(package: AcknowledgementPackage(id: "lcmp", name: AppVersion.displayName, version: version,
                                                    revision: "", url: nil, documents: documents), root: root)
    }
}
struct AcknowledgementCatalogue: Codable, Sendable {
    let schemaVersion: Int
    let packages: [AcknowledgementPackage]

    static func load(from root: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
        // An empty list is valid: the app currently bundles no third-party library.
        guard value.schemaVersion == 1,
              Set(value.packages.map(\.id)).count == value.packages.count else { throw CocoaError(.fileReadCorruptFile) }
        for package in value.packages {
            guard !package.documents.isEmpty, URL(string: package.url ?? "")?.scheme == "https" else { throw CocoaError(.fileReadCorruptFile) }
            for document in package.documents { _ = try documentURL(document, root: root) }
        }
        return value
    }
    static func documentURL(_ document: AcknowledgementDocument, root: URL) throws -> URL {
        let parts = document.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CocoaError(.fileReadInvalidFileName) }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var url = base
        for part in parts {
            url = url.appendingPathComponent(String(part)).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(base.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        }
        return url
    }
    static func text(_ document: AcknowledgementDocument, root: URL) throws -> String {
        try String(contentsOf: documentURL(document, root: root), encoding: .utf8)
    }
}

struct AcknowledgementsView: View {
    let root: URL
    let licenseRoot: URL
    @State private var entries: [LicenseEntry]?
    @State private var error: String?
    @State private var selected: String?
    @State private var document: AcknowledgementDocument?
    @State private var text = ""
    private var entry: LicenseEntry? { entries?.first { $0.id == selected } }
    private var package: AcknowledgementPackage? { entry?.package }

    @ViewBuilder private func documentView(_ package: AcknowledgementPackage) -> some View {
        HStack {
            Text("収録文書")
            NoticeDocumentPicker(documents: package.documents, selection: $document)
                .frame(height: 24)
        }
        NoticeText(text: text).accessibilityLabel("ライセンス原文")
            .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.07)))
    }

    var body: some View {
        GeometryReader { _ in
        VStack(alignment: .leading, spacing: 12) {
            // Only LCMP's own documents: one page, no list. Third-party rows bring the list back.
            if let entries, entries.count > 1 {
                Text("ライセンス").font(.title2)
                Text("LCMPは次のオープンソースソフトウェアも利用しています。開発と公開に携わる皆さまに感謝します。")
                    .fixedSize(horizontal: false, vertical: true)
                HSplitView {
                    List(entries, selection: $selected) { entry in
                        let item = entry.package
                        Text(item.name).tag(item.id)
                            .listRowBackground(selected == item.id
                                ? Color(red: 0.62, green: 0.91, blue: 0.74).opacity(0.12) : Color.clear)
                    }.scrollContentBackground(.hidden)
                    .frame(minWidth: 150, idealWidth: 200, maxWidth: 260)
                        .accessibilityLabel("ライセンスの対象")
                    VStack(alignment: .leading, spacing: 8) {
                        if let package {
                            Text(package.name).font(.headline).textSelection(.enabled)
                            Text("バージョン：\(package.version ?? package.revision)").textSelection(.enabled)
                            if let link = package.url, let url = URL(string: link) { Link(link, destination: url).lineLimit(2) }
                            documentView(package)
                        }
                    }.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("LC Music Playerのライセンス").font(.title2)
                if let package { documentView(package) }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }.padding(16)
        }
        .background(PlayerGlassBackground())
        .foregroundStyle(.white.opacity(0.85))
        .tint(Color(red: 0.66, green: 0.85, blue: 0.74))
        .preferredColorScheme(.dark)
        .task {
            do {
                let root = root, licenseRoot = licenseRoot, version = AppVersion.text()
                let result = try await Task.detached {
                    let own = try LicenseEntry.lcmp(root: licenseRoot, version: version)
                    let others = try AcknowledgementCatalogue.load(from: root).packages.map { LicenseEntry(package: $0, root: root) }
                    return [own] + others
                }.value
                entries = result
                selected = result.first?.id
            } catch { self.error = "同梱のライセンス情報を読み込めません。アプリのビルド・同梱内容を確認してください。" }
        }
        .onChange(of: selected) { _, _ in document = package?.documents.first }
        .task(id: document) {
            text = ""
            guard let document, let root = entry?.root else { return }
            do {
                let result = try await Task.detached { try AcknowledgementCatalogue.text(document, root: root) }.value
                guard !Task.isCancelled else { return }
                text = result
            } catch {
                guard !Task.isCancelled else { return }
                text = "この文書を読み込めません。アプリの同梱内容を確認してください。"
            }
        }
    }
}

#if os(macOS)
struct NoticeText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textColor = NSColor.white.withAlphaComponent(0.85)
        view.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.25, green: 0.4, blue: 0.32, alpha: 0.8),
                                       .foregroundColor: NSColor.white]
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}

/// The app owns one instance; this window has no playback or library callbacks.
@MainActor public final class AcknowledgementsWindowController {
    public private(set) var window: NSWindow?
    private let root: URL
    private let licenseRoot: URL
    public init(resourceRoot: URL? = nil, licenseRoot: URL? = nil) {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        root = resourceRoot ?? resources.appendingPathComponent("ThirdPartyLicenses")
        self.licenseRoot = licenseRoot ?? resources.appendingPathComponent("LCMPLicense")
    }
    public func show() {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "LCMP — ライセンス"
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.isOpaque = false
            window.backgroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.14, alpha: 1)
            window.contentMinSize = NSSize(width: 560, height: 360)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AcknowledgementsView(root: root, licenseRoot: licenseRoot).frame(minWidth: 560, minHeight: 360))
            host.sizingOptions = [.minSize]
            host.frame = CGRect(x: 0, y: 0, width: 760, height: 520)
            window.contentView = host
            window.setContentSize(NSSize(width: 760, height: 520))
            window.center()
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AcknowledgementsButton: NSViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "ライセンス…", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityIdentifier("showAcknowledgements")
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.action = action }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func clicked(_ sender: NSButton) { action() }
    }
}

struct NoticeDocumentPicker: NSViewRepresentable {
    let documents: [AcknowledgementDocument]
    @Binding var selection: AcknowledgementDocument?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel("収録文書")
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemArray.compactMap({ $0.representedObject as? String }) != documents.map(\.path) {
            button.removeAllItems()
            for document in documents {
                button.addItem(withTitle: document.title)
                button.lastItem?.representedObject = document.path
            }
        }
        button.selectItem(at: documents.firstIndex(where: { $0 == selection }) ?? -1)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: NoticeDocumentPicker
        init(_ parent: NoticeDocumentPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            parent.selection = parent.documents.first { $0.path == sender.selectedItem?.representedObject as? String }
        }
    }
}
#endif

#if os(iOS)
struct NoticeText: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(verbatim: text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

struct NoticeDocumentPicker: View {
    let documents: [AcknowledgementDocument]
    @Binding var selection: AcknowledgementDocument?
    var body: some View {
        Picker("収録文書", selection: $selection) {
            ForEach(documents) { Text($0.title).tag(Optional($0)) }
        }.pickerStyle(.segmented)
    }
}

/// iOS has no split view for this sheet; the list and the document stack vertically.
struct HSplitView<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { VStack(alignment: .leading, spacing: 8) { content } }
}

struct AcknowledgementsButton: View {
    let action: () -> Void
    var body: some View {
        Button("ライセンス…", action: action).buttonStyle(SoftGlassButtonStyle()).accessibilityIdentifier("showAcknowledgements")
    }
}

/// The license page as a sheet. The app bundles the same LCMPLicense directory as macOS.
public struct AcknowledgementsSheet: View {
    private let root: URL
    private let licenseRoot: URL
    public init(resourceRoot: URL? = nil, licenseRoot: URL? = nil) {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        root = resourceRoot ?? resources.appendingPathComponent("ThirdPartyLicenses")
        self.licenseRoot = licenseRoot ?? resources.appendingPathComponent("LCMPLicense")
    }
    public var body: some View { AcknowledgementsView(root: root, licenseRoot: licenseRoot) }
}
#endif
