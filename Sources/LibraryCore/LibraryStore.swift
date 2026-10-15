import Foundation

@MainActor public protocol LibraryPersistence {
    func load() throws -> LibraryDocument
    func save(_ document: LibraryDocument) throws
    var recoveryMessage: String? { get }
}

/// One main-actor writer. All edits are published only after an atomic save succeeds.
@MainActor public final class JSONLibraryStore: LibraryPersistence {
    public let url: URL
    public private(set) var recoveryMessage: String?
    private var lastGood: Data?
    private var expectedMain: Data?
    private var damagedMain = false
    private let write: (Data, URL) throws -> Void
    public init(url: URL, write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url; self.write = write
    }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCMP", isDirectory: true).appendingPathComponent("library.json")
    }
    public var backupURL: URL { url.appendingPathExtension("backup") }
    private func decode(_ data: Data) throws -> LibraryDocument {
        // Future documents must never fall back to an older backup and be overwritten.
        struct Version: Decodable { var schemaVersion: Int }
        guard try JSONDecoder().decode(Version.self, from: data).schemaVersion == 1 else { throw LibraryFailure.futureVersion }
        let doc = try JSONDecoder().decode(LibraryDocument.self, from: data)
        try doc.validate(); return doc
    }
    public func load() throws -> LibraryDocument {
        let fm = FileManager.default
        recoveryMessage = nil; lastGood = nil; damagedMain = false
        expectedMain = try? Data(contentsOf: url)
        if !fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backupURL.path) { return LibraryDocument() }
        do {
            let data = try Data(contentsOf: url), doc = try decode(data)
            lastGood = data; return doc
        } catch LibraryFailure.futureVersion { throw LibraryFailure.futureVersion }
        catch {
            let data: Data
            let doc: LibraryDocument
            do { data = try Data(contentsOf: backupURL); doc = try decode(data) }
            catch LibraryFailure.futureVersion { throw LibraryFailure.futureVersion }
            catch { throw LibraryFailure.invalidDocument }
            lastGood = data; damagedMain = fm.fileExists(atPath: url.path)
            recoveryMessage = "正常なバックアップを読み込みました。元の保存データは保持します。"
            return doc
        }
    }
    public func save(_ document: LibraryDocument) throws {
        try document.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document), fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == expectedMain else { throw LibraryFailure.storeChanged }
        } else if expectedMain != nil { throw LibraryFailure.storeChanged }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if damagedMain {
            let preserved = url.appendingPathExtension("damaged-\(UUID().uuidString)")
            try fm.copyItem(at: url, to: preserved)
            damagedMain = false
        }
        if let lastGood { try write(lastGood, backupURL) }
        try write(data, url)
        lastGood = data
        expectedMain = data
    }
}
