import AVFoundation
import Foundation
import PlaybackCore

/// The album a track belongs to, read from its embedded tags or from the Music library.
/// A track whose tags were read but name no album keeps an empty value, so it is not read again.
public struct TrackTags: Codable, Equatable, Sendable {
    public var album: String?
    public var albumArtist: String?
    public var artist: String?
    public var disc: Int?
    public var track: Int?
    /// The reader version that produced these tags; nil for the first version. A track read by an
    /// older version without finding an album is read again, since a newer reader may find one.
    public var version: Int?
    /// 2: WAV files' INFO list.
    public static let currentVersion = 2
    /// Tags are untrusted input: text is trimmed, stripped of control characters and shortened,
    /// and numbers outside 1...9999 are dropped.
    public init(album: String? = nil, albumArtist: String? = nil, artist: String? = nil, disc: Int? = nil, track: Int? = nil) {
        self.album = Self.text(album); self.albumArtist = Self.text(albumArtist); self.artist = Self.text(artist)
        self.disc = Self.number(disc); self.track = Self.number(track)
    }
    static let maximumLength = 200
    private static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maximumLength))
    }
    private static func number(_ value: Int?) -> Int? { value.flatMap { (1...9999).contains($0) ? $0 : nil } }
    /// Tracks with the same album name and album artist (or artist, when no album artist is
    /// tagged) belong to one album, whether they are files or Music library songs.
    public var albumKey: String? {
        guard let album else { return nil }
        func fold(_ s: String?) -> String { (s ?? "").folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) }
        return fold(album) + "\u{1F}" + fold(albumArtist ?? artist)
    }
}

/// Reads the album tags of a track. Returns nil when the track cannot be read now; it is tried
/// again on a later launch.
public protocol TrackTagReading: Sendable {
    func tags(for url: URL) async -> TrackTags?
}

/// Reads files' embedded tags (ID3, iTunes, Vorbis comments) with AVFoundation, and Music library
/// songs' album from the library.
public struct AssetTagReader: TrackTagReading {
    private let mediaLibrary: any MediaLibraryLookup
    public init(mediaLibrary: any MediaLibraryLookup = SystemMediaLibrary()) { self.mediaLibrary = mediaLibrary }
    public func tags(for url: URL) async -> TrackTags? {
        if url.scheme == SupportedAudio.mediaLibraryScheme {
            guard let id = TrackReference(bookmark: nil, lastKnownURL: url).mediaItemID else { return nil }
            return mediaLibrary.tags(forPersistentID: id)
        }
        guard url.isFileURL else { return nil }
        let asset = AVURLAsset(url: url)
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        var items: [AVMetadataItem] = []
        for format in formats { items += (try? await asset.loadMetadata(for: format)) ?? [] }
        var fields: [Field: Any] = [:]
        for item in items {
            guard let field = Field(item), fields[field] == nil, let value = try? await item.load(.value) else { continue }
            fields[field] = value
        }
        var tags = TrackTags(album: fields[.album] as? String, albumArtist: fields[.albumArtist] as? String, artist: fields[.artist] as? String,
                             disc: fields[.disc].flatMap(Self.number), track: fields[.track].flatMap(Self.number))
        // AVFoundation returns no album from a WAV file's INFO list. Its values fill only what the
        // ID3 chunk, which takes precedence, leaves out.
        if url.pathExtension.lowercased() == "wav", tags.album == nil || tags.artist == nil || tags.track == nil,
           let info = RIFFInfo.read(url) {
            tags = TrackTags(album: tags.album ?? info.album, albumArtist: tags.albumArtist, artist: tags.artist ?? info.artist,
                             disc: tags.disc, track: tags.track ?? info.track)
        }
        return tags
    }
    private enum Field {
        case album, albumArtist, artist, disc, track
        init?(_ item: AVMetadataItem) {
            if item.commonKey == .commonKeyAlbumName { self = .album; return }
            if item.commonKey == .commonKeyArtist { self = .artist; return }
            switch item.identifier {
            case AVMetadataIdentifier.id3MetadataBand, .iTunesMetadataAlbumArtist: self = .albumArtist; return
            case AVMetadataIdentifier.id3MetadataTrackNumber, .iTunesMetadataTrackNumber: self = .track; return
            case AVMetadataIdentifier.id3MetadataPartOfASet, .iTunesMetadataDiscNumber: self = .disc; return
            default: break
            }
            // Vorbis comments (FLAC) have no identifier constants; their keys are free text.
            switch (item.key as? String)?.uppercased() {
            case "ALBUMARTIST", "ALBUM ARTIST": self = .albumArtist
            case "TRACKNUMBER": self = .track
            case "DISCNUMBER": self = .disc
            default: return nil
            }
        }
    }
    /// "3", "3/10" (ID3, Vorbis) or the iTunes binary form: 2 bytes of padding, then the number.
    static func number(_ value: Any) -> Int? {
        if let data = value as? Data { return data.count >= 4 ? Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3]) : nil }
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        return Int(text.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "")
    }
}
