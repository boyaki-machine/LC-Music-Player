import Foundation
import PlaybackCore
import PreprocessingCore

/// Lets Music library songs keep their measurements across launches, as files do.
/// Files are identified by `LocalMeasurementSourceIdentity`.
public struct MediaLibraryMeasurementSourceIdentity: MeasurementSourceIdentifying {
    private let mediaLibrary: any MediaLibraryLookup
    private let files: any MeasurementSourceIdentifying
    public init(mediaLibrary: any MediaLibraryLookup = SystemMediaLibrary(),
                files: any MeasurementSourceIdentifying = LocalMeasurementSourceIdentity()) {
        self.mediaLibrary = mediaLibrary; self.files = files
    }
    public func identity(for url: URL) throws -> MeasurementSourceIdentity? {
        guard url.scheme == SupportedAudio.mediaLibraryScheme else { return try files.identity(for: url) }
        // The library has no file revision. A song replaced under the same ID with the same length
        // and date added cannot be told apart; it is then corrected with the old song's levels.
        guard let id = TrackReference(bookmark: nil, lastKnownURL: url).mediaItemID,
              let song = mediaLibrary.song(forPersistentID: id), song.assetURL == url,
              song.duration.isFinite, song.duration > 0 else { return nil }
        return MeasurementSourceIdentity(locator: url.absoluteString, resource: "media-library/\(id)",
            revision: "\(song.duration.bitPattern)/\(song.dateAdded.timeIntervalSince1970.bitPattern)",
            size: max(1, Int64((song.duration * 1000).rounded())))
    }
}
