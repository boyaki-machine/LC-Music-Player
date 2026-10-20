import Foundation
import PlaybackCore
#if os(iOS)
import MediaPlayer
#endif

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
/// A song of the Music library that is stored on the device and readable (no DRM).
public struct MediaLibrarySong: Equatable, Sendable {
    public var assetURL: URL
    /// The length and the date added tell a replaced recording from the one that was measured.
    public var duration: TimeInterval
    public var dateAdded: Date
    public init(assetURL: URL, duration: TimeInterval, dateAdded: Date) {
        self.assetURL = assetURL; self.duration = duration; self.dateAdded = dateAdded
    }
}
/// Finds songs of the Music library. Only iOS has one; tests supply their own.
public protocol MediaLibraryLookup: Sendable {
    func song(forPersistentID id: UInt64) -> MediaLibrarySong?
    /// The album of a song, or nil when the song cannot be found.
    func tags(forPersistentID id: UInt64) -> TrackTags?
}
extension MediaLibraryLookup {
    public func assetURL(forPersistentID id: UInt64) -> URL? { song(forPersistentID: id)?.assetURL }
    public func tags(forPersistentID id: UInt64) -> TrackTags? { nil }
}
public struct SystemMediaLibrary: MediaLibraryLookup {
    public init() {}
    public func song(forPersistentID id: UInt64) -> MediaLibrarySong? {
        #if os(iOS)
        guard let item = Self.item(id), !item.hasProtectedAsset, !item.isCloudItem, let url = item.assetURL else { return nil }
        return MediaLibrarySong(assetURL: url, duration: item.playbackDuration, dateAdded: item.dateAdded)
        #else
        return nil
        #endif
    }
    public func tags(forPersistentID id: UInt64) -> TrackTags? {
        #if os(iOS)
        guard let item = Self.item(id) else { return nil }
        return TrackTags(album: item.albumTitle, albumArtist: item.albumArtist, artist: item.artist,
                         disc: item.discNumber, track: item.albumTrackNumber)
        #else
        return nil
        #endif
    }
    #if os(iOS)
    private static func item(_ id: UInt64) -> MPMediaItem? {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID))
        return query.items?.first
    }
    #endif
}

@MainActor public struct BookmarkFileReferences: FileReferenceProvider {
    // macOS bookmarks carry an explicit read-only security scope. iOS bookmarks of picked
    // documents carry their access implicitly and still need start/stop around each use.
    #if os(macOS)
    private static let creation: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
    private static let resolution: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
    #else
    private static let creation: URL.BookmarkCreationOptions = []
    private static let resolution: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif
    private let mediaLibrary: any MediaLibraryLookup
    public init(mediaLibrary: any MediaLibraryLookup = SystemMediaLibrary()) { self.mediaLibrary = mediaLibrary }
    public func beginAccess(_ url: URL) -> FileLease {
        let started = url.startAccessingSecurityScopedResource()
        return FileLease { if started { url.stopAccessingSecurityScopedResource() } }
    }
    public func makeReference(_ url: URL) throws -> TrackReference {
        if url.scheme == SupportedAudio.mediaLibraryScheme {
            let reference = TrackReference(bookmark: nil, lastKnownURL: url)
            guard let id = reference.mediaItemID, mediaLibrary.assetURL(forPersistentID: id) != nil else { throw LibraryFailure.inaccessible }
            return reference
        }
        guard url.isFileURL else { throw LibraryFailure.inaccessible }
        let lease = beginAccess(url)
        defer { withExtendedLifetime(lease) {} }
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else { throw LibraryFailure.inaccessible }
        let data = try url.bookmarkData(options: Self.creation,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        return TrackReference(bookmark: data, lastKnownURL: url.standardizedFileURL)
    }
    public func resolve(_ reference: TrackReference) throws -> ResolvedTrack {
        // A library song is looked up by its ID each time; it needs no file access scope.
        if let id = reference.mediaItemID {
            guard let url = mediaLibrary.assetURL(forPersistentID: id) else { throw LibraryFailure.unavailable }
            var updated = reference; updated.lastKnownURL = url
            return ResolvedTrack(url: url, reference: updated, lease: FileLease())
        }
        guard let data = reference.bookmark else { throw LibraryFailure.unavailable }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: Self.resolution,
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
