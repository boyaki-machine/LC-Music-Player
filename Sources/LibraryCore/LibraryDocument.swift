import Foundation
import PlaybackCore

public struct TrackReference: Codable, Equatable, Sendable {
    public var bookmark: Data?
    public var lastKnownURL: URL
    public init(bookmark: Data?, lastKnownURL: URL) { self.bookmark = bookmark; self.lastKnownURL = lastKnownURL }
    /// The persistent ID of a Music library song. Such a reference has no bookmark; its URL is the
    /// song's asset URL, which carries the ID.
    public var mediaItemID: UInt64? {
        guard lastKnownURL.scheme == SupportedAudio.mediaLibraryScheme,
              let value = URLComponents(url: lastKnownURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value else { return nil }
        return UInt64(value)
    }
}
public enum TrackRegistration: String, Codable, Sendable { case file, folder }
public struct LibraryTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var reference: TrackReference
    public var registration: TrackRegistration?
    /// The album tags, or nil until they have been read. Older files without them still load.
    public var tags: TrackTags?
    public init(id: UUID = UUID(), name: String, reference: TrackReference, registration: TrackRegistration? = nil, tags: TrackTags? = nil) {
        self.id = id; self.name = name; self.reference = reference; self.registration = registration; self.tags = tags
    }
}
public struct PlaylistEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trackID: UUID
    public init(id: UUID = UUID(), trackID: UUID) { self.id = id; self.trackID = trackID }
}
public struct MusicPlaylist: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var entries: [PlaylistEntry]
    public init(id: UUID = UUID(), name: String, entries: [PlaylistEntry] = []) { self.id = id; self.name = name; self.entries = entries }
}
public struct LibraryDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var tracks: [LibraryTrack] = []
    public var playlists: [MusicPlaylist]
    public var currentPlaylistID: UUID?
    public var currentEntryID: UUID?
    /// The shuffle cycle of each playlist. Optional, so older files without it still load.
    public var shuffleCycles: [ShuffleCycle]?
    public init() {
        let list = MusicPlaylist(name: "ひと息")
        playlists = [list]; currentPlaylistID = list.id
    }
    /// Drops what no longer exists: cycles of deleted playlists and entries removed from a playlist.
    /// A stale cycle is never a reason to reject the document.
    public func prunedShuffleCycles() -> LibraryDocument {
        guard let cycles = shuffleCycles else { return self }
        var next = self, seen = Set<UUID>()
        next.shuffleCycles = cycles.compactMap { cycle in
            guard let list = playlists.first(where: { $0.id == cycle.playlistID }), seen.insert(list.id).inserted else { return nil }
            var cycle = cycle; cycle.reconcile(with: list)
            return cycle.played.isEmpty ? nil : cycle
        }
        if next.shuffleCycles?.isEmpty == true { next.shuffleCycles = nil }
        return next
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw LibraryFailure.futureVersion }
        let tracks = Set(tracks.map(\.id)), lists = Set(playlists.map(\.id))
        let entries = playlists.flatMap(\.entries)
        guard tracks.count == self.tracks.count, lists.count == playlists.count,
              Set(entries.map(\.id)).count == entries.count,
              self.tracks.allSatisfy({ $0.reference.lastKnownURL.isFileURL || $0.reference.mediaItemID != nil }),
              playlists.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              entries.allSatisfy({ tracks.contains($0.trackID) }),
              currentPlaylistID.map({ lists.contains($0) }) ?? (currentEntryID == nil),
              currentEntryID.map({ id in playlists.first(where: { $0.id == currentPlaylistID })?.entries.contains(where: { $0.id == id }) == true }) ?? true else {
            throw LibraryFailure.invalidDocument
        }
    }
}
public enum LibraryFailure: LocalizedError {
    case futureVersion, invalidDocument, inaccessible, unavailable, storeChanged, invalidPlaylist(String), busy
    public var errorDescription: String? {
        switch self {
        case .futureVersion: "新しい形式のライブラリです。このアプリでは上書きできません。"
        case .invalidDocument: "ライブラリのデータが壊れているか、参照が不正です。"
        case .inaccessible: "ファイルにアクセスできません。音源から選び直してください。"
        case .unavailable: "ファイルが見つからないか、アクセスできません。"
        case .storeChanged: "保存データが別の処理で変更されました。上書きせず停止しました。アプリを開き直してください。"
        case .invalidPlaylist(let reason): "M3U8を読み込めません。\(reason)"
        case .busy: "音源の登録が終わるまでお待ちください。"
        }
    }
}
