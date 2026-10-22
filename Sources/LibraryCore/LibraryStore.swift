import Foundation
import Darwin

@MainActor public protocol LibraryPersistence {
    func load() throws -> LibraryDocument
    func save(_ document: LibraryDocument) throws
    var recoveryMessage: String? { get }
}

/// One main-actor writer. All edits are published only after an atomic save succeeds.
///
/// A save that changes only what changes with every song (the current playlist and entry and the
/// shuffle cycles) writes them to a small state file beside the library; any other change writes
/// the whole library, which then holds that state too. The state file records the library file it
/// belongs to and is applied only to that file, so a library written by another version or brought
/// back from its backup never takes a stale state.
@MainActor public final class JSONLibraryStore: LibraryPersistence {
    public let url: URL
    public private(set) var recoveryMessage: String?
    /// The document as last loaded or saved, to tell a change of state from an edit.
    private var saved: LibraryDocument?
    /// The files as last loaded or written. Another writer changes them.
    private var expectedMain: FileStamp?
    private var expectedState: FileStamp?
    private var damagedMain = false
    private let write: (Data, URL) throws -> Void
    /// Damaged libraries kept for inspection; older ones are removed.
    static let damagedLimit = 3
    public init(url: URL, write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url; self.write = write
    }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCMP", isDirectory: true).appendingPathComponent("library.json")
    }
    public var backupURL: URL { url.appendingPathExtension("backup") }
    public var stateURL: URL { url.deletingLastPathComponent().appendingPathComponent("library-state.json") }
    /// Library files hold music paths and bookmarks: owner read/write only.
    private static func restrict(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func decode(_ data: Data) throws -> LibraryDocument {
        // Future documents must never fall back to an older backup and be overwritten.
        struct Version: Decodable { var schemaVersion: Int }
        guard try JSONDecoder().decode(Version.self, from: data).schemaVersion == 1 else { throw LibraryFailure.futureVersion }
        let doc = try JSONDecoder().decode(LibraryDocument.self, from: data)
        try doc.validate(); return doc
    }
    public func load() throws -> LibraryDocument {
        let fm = FileManager.default
        recoveryMessage = nil; saved = nil; damagedMain = false
        expectedMain = FileStamp(url); expectedState = FileStamp(stateURL)
        if !fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backupURL.path) { return LibraryDocument() }
        do {
            let doc = try decode(Data(contentsOf: url))
            let current = applyingState(to: doc)
            saved = current; return current
        } catch LibraryFailure.futureVersion { throw LibraryFailure.futureVersion }
        catch {
            let doc: LibraryDocument
            do { doc = try decode(Data(contentsOf: backupURL)) }
            catch LibraryFailure.futureVersion { throw LibraryFailure.futureVersion }
            catch { throw LibraryFailure.invalidDocument }
            damagedMain = fm.fileExists(atPath: url.path)
            recoveryMessage = "正常なバックアップを読み込みました。元の保存データは保持します。"
            // The backup is not the library the state file belongs to.
            saved = nil; return doc
        }
    }
    /// The saved state, when it belongs to this very library file and fits it.
    private func applyingState(to doc: LibraryDocument) -> LibraryDocument {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(LibraryState.self, from: data),
              state.schemaVersion == 1, state.library == FileStamp(url) else { return doc }
        var next = doc
        state.apply(to: &next)
        return (try? next.validate()) == nil ? doc : next
    }
    public func save(_ document: LibraryDocument) throws {
        try document.validate()
        let fm = FileManager.default
        guard FileStamp(url) == expectedMain, FileStamp(stateURL) == expectedState else { throw LibraryFailure.storeChanged }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        if let saved, let main = expectedMain, LibraryState.differsOnly(saved, document) {
            try writeState(document, library: main)
        } else {
            try writeLibrary(document)
        }
        saved = document
    }
    private func writeState(_ document: LibraryDocument, library: FileStamp) throws {
        // A library that is only played still gets its backup once.
        if !FileManager.default.fileExists(atPath: backupURL.path) { try backUpLibrary() }
        var state = LibraryState(document); state.library = library
        try write(try JSONEncoder().encode(state), stateURL)
        try Self.restrict(stateURL)
        expectedState = FileStamp(stateURL)
    }
    private func writeLibrary(_ document: LibraryDocument) throws {
        let fm = FileManager.default
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        if damagedMain {
            let preserved = url.appendingPathExtension("damaged-\(UUID().uuidString)")
            try fm.copyItem(at: url, to: preserved)
            try Self.restrict(preserved)
            removeOldDamagedCopies()
        } else if expectedMain != nil { try backUpLibrary() }
        try write(data, url)
        try Self.restrict(url)
        damagedMain = false
        expectedMain = FileStamp(url)
        // The library now holds the state; a state file left behind would belong to the old one.
        if fm.fileExists(atPath: stateURL.path) { try fm.removeItem(at: stateURL) }
        expectedState = nil
    }
    /// Copies the library, which is the last good one, to the backup. A clone on APFS writes no data.
    private func backUpLibrary() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: backupURL.path) { try fm.removeItem(at: backupURL) }
        guard copyfile(url.path, backupURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try Self.restrict(backupURL)
    }
    private func removeOldDamagedCopies() {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".damaged-"
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let copies = names.filter { $0.hasPrefix(prefix) }.map { directory.appendingPathComponent($0) }
            .sorted { (FileStamp($0)?.modified ?? 0) > (FileStamp($1)?.modified ?? 0) }
        for old in copies.dropFirst(Self.damagedLimit) { try? fm.removeItem(at: old) }
    }
}

/// What tells one version of a file from another without reading it: inode, size and modification time.
struct FileStamp: Codable, Equatable {
    var inode: UInt64
    var size: Int64
    /// Nanoseconds since 1970.
    var modified: Int64
    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        inode = UInt64(info.st_ino); size = Int64(info.st_size)
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}

/// What changes with every song, saved apart from the library.
struct LibraryState: Codable, Equatable {
    var schemaVersion = 1
    /// The library file this state was written for.
    var library: FileStamp?
    var currentPlaylistID: UUID?
    var currentEntryID: UUID?
    var shuffleCycles: [ShuffleCycle]?
    init(_ document: LibraryDocument) {
        currentPlaylistID = document.currentPlaylistID; currentEntryID = document.currentEntryID; shuffleCycles = document.shuffleCycles
    }
    func apply(to document: inout LibraryDocument) {
        document.currentPlaylistID = currentPlaylistID; document.currentEntryID = currentEntryID; document.shuffleCycles = shuffleCycles
    }
    /// Whether `document` differs from `saved` in this state alone. Unchanged arrays share their
    /// storage, so the comparison does not walk an unchanged library.
    static func differsOnly(_ saved: LibraryDocument, _ document: LibraryDocument) -> Bool {
        var same = document
        LibraryState(saved).apply(to: &same)
        return same == saved
    }
}
