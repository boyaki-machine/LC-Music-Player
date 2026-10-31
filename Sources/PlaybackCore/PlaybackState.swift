import Foundation
import AudioProcessingCore

public enum PlaybackState: Equatable, Sendable {
    case empty, ready, playing, paused, stopped, finished, failed
}

public enum PlaybackError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case inaccessibleFile
    case loadingFailed(String)
    case playbackFailed(String)
    /// The output's format differs from the one the track's levels were measured for: the output is
    /// another device, or is still changing to one. Preparing the track again measures it for the new output.
    case outputChanged

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "対応していない音源形式です。MP3、M4A、WAV、AIFF、FLACを選択してください。"
        case .inaccessibleFile:
            "音楽ファイルにアクセスできません。ファイルの場所とアクセス権を確認してください。"
        case .loadingFailed(let reason):
            "音楽ファイルを読み込めませんでした。\(reason)"
        case .playbackFailed(let reason):
            "再生できませんでした。\(reason)"
        case .outputChanged:
            "再生できませんでした。出力形式が変わりました。再生を準備し直してください。"
        }
    }

    /// A playback error for any error: a change of the output keeps its own case.
    public init(_ error: any Error) {
        if let error = error as? PlaybackError { self = error }
        else if (error as? AudioProcessingFailure) == .outputChanged { self = .outputChanged }
        else { self = .playbackFailed(error.localizedDescription) }
    }
}

public enum SupportedAudio {
    public static let extensions = ["mp3", "m4a", "wav", "aif", "aiff", "flac"]
    /// Songs of the iPhone's Music library: `ipod-library://item/item.<ext>?id=<persistent ID>`.
    /// Core Audio reads them like files.
    public static let mediaLibraryScheme = "ipod-library"

    public static func accepts(_ url: URL) -> Bool {
        (url.isFileURL || url.scheme == mediaLibraryScheme) && extensions.contains(url.pathExtension.lowercased())
    }
}
