import Foundation
import PlaybackCore

public struct ResolvedTrack {
    public var url: URL
    public var reference: TrackReference
    public var lease: FileLease
    public init(url: URL, reference: TrackReference, lease: FileLease) { self.url = url; self.reference = reference; self.lease = lease }
}
@MainActor public protocol FileReferenceProvider {
    func beginAccess(_ url: URL) -> FileLease
    func makeReference(_ url: URL) throws -> TrackReference
    func resolve(_ reference: TrackReference) throws -> ResolvedTrack
}
@MainActor public struct BookmarkFileReferences: FileReferenceProvider {
    public init() {}
    public func beginAccess(_ url: URL) -> FileLease {
        let started = url.startAccessingSecurityScopedResource()
        return FileLease { if started { url.stopAccessingSecurityScopedResource() } }
    }
    public func makeReference(_ url: URL) throws -> TrackReference {
        guard url.isFileURL else { throw LibraryFailure.inaccessible }
        let lease = beginAccess(url)
        defer { withExtendedLifetime(lease) {} }
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else { throw LibraryFailure.inaccessible }
        let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        return TrackReference(bookmark: data, lastKnownURL: url.standardizedFileURL)
    }
    public func resolve(_ reference: TrackReference) throws -> ResolvedTrack {
        guard let data = reference.bookmark else { throw LibraryFailure.unavailable }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let lease = beginAccess(url)
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else { throw LibraryFailure.unavailable }
        var updated = reference; updated.lastKnownURL = url.standardizedFileURL
        if stale { updated = try makeReference(url) }
        return ResolvedTrack(url: url, reference: updated, lease: lease)
    }
}

public enum AudioDiscovery {
    /// Scans only explicitly selected roots. Does not follow directory links or packages.
    public static func files(in selections: [URL]) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for url in selections {
            try Task.checkCancellation()
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v.isDirectory == true, v.isSymbolicLink != true {
                var scanError: (any Error)?
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else { throw LibraryFailure.inaccessible }
                for case let child as URL in enumerator {
                    try Task.checkCancellation()
                    let childValues = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    // DirectoryEnumerator does not traverse links. Calling skipDescendants
                    // on a link would skip the next real directory instead.
                    if childValues.isSymbolicLink == true { continue }
                    if childValues.isRegularFile == true && SupportedAudio.accepts(child) { result.append(child) }
                }
                if let scanError { throw scanError }
            } else if SupportedAudio.accepts(url) { result.append(url) }
        }
        return Array(Set(result.map(\.standardizedFileURL))).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
