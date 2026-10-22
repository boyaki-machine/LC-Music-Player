import Foundation
import LibraryCore

/// The grouped library with each track's search text, built once per change of the track list so
/// that typing a query only scans prepared bytes. Thousands of tracks filter in about a millisecond.
struct SourceCatalog {
    let groups: [SourceFolderGroup]
    /// The search text of each track, in the same order as `groups` and their tracks.
    private let keys: [[[UInt8]]]

    init(_ tracks: [LibraryTrack]) {
        groups = SourceFolderGroup.groups(tracks)
        keys = groups.map { $0.tracks.map { Array(Self.searchText($0).utf8) } }
    }

    /// The title, file name with its extension, folder path, album, artist and album artist, one per
    /// line so that a term never matches across two of them.
    static func searchText(_ track: LibraryTrack) -> String {
        var fields = [track.name]
        if track.reference.mediaItemID == nil {
            let url = track.reference.lastKnownURL
            fields += [url.lastPathComponent, url.deletingLastPathComponent().path]
        } else {
            fields.append(track.reference.lastKnownURL.pathExtension)
        }
        fields += [track.tags?.album, track.tags?.artist, track.tags?.albumArtist].compactMap { $0 }
        return fold(fields.joined(separator: "\n"))
    }

    /// Ignores case and full or half width, and composes characters: file names on macOS keep
    /// voiced kana decomposed, while typed text arrives composed.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// The words of a query; a track must contain every one of them.
    static func terms(_ query: String) -> [[UInt8]] {
        fold(query).split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
    }

    /// Leaves out hidden tracks and tracks that do not match, keeping every other track in its own
    /// group. A group with no track left is left out. An empty query matches every track.
    func groups(matching query: String, hiding hidden: Set<UUID> = []) -> [SourceFolderGroup] {
        let terms = Self.terms(query)
        guard !terms.isEmpty || !hidden.isEmpty else { return groups }
        return zip(groups, keys).compactMap { group, keys in
            let tracks = zip(group.tracks, keys).compactMap { track, key in
                !hidden.contains(track.id) && terms.allSatisfy({ Self.contains(key, $0) }) ? track : nil
            }
            return tracks.isEmpty ? nil : SourceFolderGroup(kind: group.kind, tracks: tracks, showsArtist: group.showsArtist)
        }
    }

    private static func contains(_ text: [UInt8], _ term: [UInt8]) -> Bool {
        text.withUnsafeBytes { text in
            term.withUnsafeBytes { term in memmem(text.baseAddress, text.count, term.baseAddress, term.count) != nil }
        }
    }
}

/// Keeps the catalog and the last result across view updates, which happen on every playback tick.
@MainActor final class SourceCatalogCache {
    private var tracks: [LibraryTrack] = []
    private var catalog = SourceCatalog([])
    private var last: (query: String, hidden: Set<UUID>, groups: [SourceFolderGroup])?

    func groups(_ tracks: [LibraryTrack], matching query: String, hiding hidden: Set<UUID>) -> [SourceFolderGroup] {
        // Comparing an unchanged array is immediate: both share one buffer.
        if tracks != self.tracks { self.tracks = tracks; catalog = SourceCatalog(tracks); last = nil }
        if let last, last.query == query, last.hidden == hidden { return last.groups }
        let groups = catalog.groups(matching: query, hiding: hidden)
        last = (query, hidden, groups)
        return groups
    }
}

/// Which of the shown tracks are chosen for removal.
enum SourceSelection {
    enum State: Equatable { case none, some, all }
    static func state(of tracks: [LibraryTrack], in selected: Set<UUID>) -> State {
        let count = tracks.count { selected.contains($0.id) }
        return count == 0 ? .none : count == tracks.count ? .all : .some
    }
    /// Choosing a group chooses all its shown tracks, unless all are chosen already: then it clears them.
    static func toggle(_ tracks: [LibraryTrack], in selected: inout Set<UUID>) {
        let ids = tracks.map(\.id)
        if state(of: tracks, in: selected) == .all { selected.subtract(ids) } else { selected.formUnion(ids) }
    }
}
