import Foundation

public enum PlaybackState: Equatable, Sendable {
    case empty, ready, playing, paused, stopped, finished, failed
}

public enum PlaybackError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case inaccessibleFile
    case loadingFailed(String)
    case playbackFailed(String)

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
        }
    }
}

public enum SupportedAudio {
    public static let extensions = ["mp3", "m4a", "wav", "aif", "aiff", "flac"]

    public static func accepts(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }
}
