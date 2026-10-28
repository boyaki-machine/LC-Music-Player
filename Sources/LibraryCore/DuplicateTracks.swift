import AVFoundation
import Foundation
import PlaybackCore

/// The same song registered more than once, such as an album kept both as FLAC and as AAC.
/// Tagged tracks are the same song when their album (name and album artist), disc and track
/// number agree, or, without a track number, their album and title. Tracks without an album tag
/// are the same song when their folder name and title agree. Nothing is removed automatically:
/// the list marks the copies, and the user chooses which to remove.
public enum DuplicateTracks {
    /// Sets of two or more track IDs, each in library order, in the order of their first track.
    public static func sets(_ tracks: [LibraryTrack]) -> [[UUID]] {
        var order: [String] = [], members: [String: [UUID]] = [:]
        for track in tracks {
            guard let key = key(track) else { continue }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(track.id)
        }
        return order.compactMap { members[$0]!.count > 1 ? members[$0] : nil }
    }
    static func key(_ track: LibraryTrack) -> String? {
        let title = fold(track.name)
        if let album = track.tags?.albumKey {
            let disc = track.tags?.disc ?? 1
            return track.tags?.track.map { "a\u{1F}\(album)\u{1F}\(disc)\u{1F}\($0)" } ?? "t\u{1F}\(album)\u{1F}\(title)"
        }
        // Music library songs carry no folder; untagged ones are left alone.
        guard track.reference.mediaItemID == nil else { return nil }
        let folder = track.reference.lastKnownURL.deletingLastPathComponent().lastPathComponent
        return "f\u{1F}\(fold(folder))\u{1F}\(title)"
    }
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// Which copy of each song to keep.
    public enum Keep: Sendable { case lossless, lossy }
    /// The copies to remove, leaving one of each set: a copy of the kind to keep, then the one in
    /// the most playlists, then the first registered. A copy of unknown kind matches neither kind.
    public static func surplus(_ sets: [[UUID]], keep: Keep, lossless: [UUID: Bool], memberships: [UUID: Int]) -> [UUID] {
        sets.flatMap { set -> [UUID] in
            let kept = set.enumerated().min { a, b in
                func rank(_ item: (offset: Int, element: UUID)) -> (Int, Int, Int) {
                    let wanted = lossless[item.element].map { $0 == (keep == .lossless) } ?? false
                    return (wanted ? 0 : 1, -(memberships[item.element] ?? 0), item.offset)
                }
                return rank(a) < rank(b)
            }!.element
            return set.filter { $0 != kept }
        }
    }
}

/// Whether a file stores its audio without loss: FLAC, WAV and AIFF always, MP3 never, and an
/// M4A file when it holds Apple Lossless rather than AAC.
public enum AudioEncoding {
    public static func isLosslessByExtension(_ url: URL) -> Bool? {
        switch url.pathExtension.lowercased() {
        case "flac", "wav", "aif", "aiff": true
        case "mp3": false
        default: nil
        }
    }
    /// Opens M4A files to read their codec; nil when the file cannot be read.
    public static func isLossless(_ url: URL) -> Bool? {
        if let known = isLosslessByExtension(url) { return known }
        guard url.pathExtension.lowercased() == "m4a", let file = try? AVAudioFile(forReading: url) else { return nil }
        return file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless
    }
}

extension LibraryDocument {
    /// How many playlists hold each track; a track in none is left out.
    public var playlistMemberships: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for list in playlists { for id in Set(list.entries.map(\.trackID)) { counts[id, default: 0] += 1 } }
        return counts
    }
}
