import Foundation

public struct TrackReference: Codable, Equatable, Sendable {
    public var bookmark: Data?
    public var lastKnownURL: URL
    public init(bookmark: Data?, lastKnownURL: URL) { self.bookmark = bookmark; self.lastKnownURL = lastKnownURL }
}
public enum TrackRegistration: String, Codable, Sendable { case file, folder }
public struct LibraryTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var reference: TrackReference
    public var registration: TrackRegistration?
    public init(id: UUID = UUID(), name: String, reference: TrackReference, registration: TrackRegistration? = nil) {
        self.id = id; self.name = name; self.reference = reference; self.registration = registration
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
    public init() {
        let list = MusicPlaylist(name: "ひと息")
        playlists = [list]; currentPlaylistID = list.id
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw LibraryFailure.futureVersion }
        let tracks = Set(tracks.map(\.id)), lists = Set(playlists.map(\.id))
        let entries = playlists.flatMap(\.entries)
        guard tracks.count == self.tracks.count, lists.count == playlists.count,
              Set(entries.map(\.id)).count == entries.count,
              self.tracks.allSatisfy({ $0.reference.lastKnownURL.isFileURL }),
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
