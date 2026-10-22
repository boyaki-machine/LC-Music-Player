import Foundation
import PlaybackCore

public struct M3U8Item: Equatable, Sendable {
    public var url: URL
    public var title: String?
    public init(url: URL, title: String? = nil) { self.url = url; self.title = title }
}
public enum M3U8 {
    /// Bounds for an untrusted playlist, far above any music library list.
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumItems = 50_000

    /// Reads at most `maximumBytes + 1` bytes, so an oversized file is never loaded whole.
    public static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw LibraryFailure.invalidPlaylist("ファイルが大きすぎます。") }
        return data
    }

    public static func decode(_ data: Data, relativeTo file: URL) throws -> [M3U8Item] {
        guard data.count <= maximumBytes else { throw LibraryFailure.invalidPlaylist("ファイルが大きすぎます。") }
        guard var text = String(data: data, encoding: .utf8) else { throw LibraryFailure.invalidPlaylist("UTF-8のファイルを選択してください。") }
        if text.first == "\u{feff}" { text.removeFirst() }
        var result: [M3U8Item] = [], title: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.uppercased().hasPrefix("#EXT-X-") { throw LibraryFailure.invalidPlaylist("HLS配信リストは対象外です。") }
            if line.hasPrefix("#EXTINF:") {
                title = line.firstIndex(of: ",").map { String(line[line.index(after: $0)...]) }; continue
            }
            if line.hasPrefix("#") { continue }
            let url: URL
            if let parsed = URL(string: line), parsed.scheme != nil {
                // Library songs keep their asset URL, so an exported list of them reads back on the iPhone.
                guard parsed.isFileURL && (parsed.host == nil || parsed.host == "" || parsed.host == "localhost")
                        || parsed.scheme == SupportedAudio.mediaLibraryScheme else {
                    throw LibraryFailure.invalidPlaylist("ローカル音源のリストを選択してください。")
                }
                url = parsed
            } else if line.hasPrefix("/") { url = URL(fileURLWithPath: line) }
            else { url = file.deletingLastPathComponent().appendingPathComponent(line) }
            guard result.count < maximumItems else { throw LibraryFailure.invalidPlaylist("曲数が多すぎます。") }
            result.append(M3U8Item(url: url.standardizedFileURL, title: title)); title = nil
        }
        return result
    }
    /// Files the list cannot reach by a path from its own folder; written as full paths they reveal
    /// the user name and the folder layout. Library songs keep their asset URL and are not counted.
    public static func outsideCount(_ items: [M3U8Item], relativeTo file: URL) -> Int {
        let base = baseDirectory(of: file)
        return items.filter { $0.url.isFileURL && relativePath($0.url, base: base) == nil }.count
    }
    public static func encode(_ items: [M3U8Item], relativeTo file: URL, outside: M3U8OutsidePaths = .fullPath) -> Data {
        let base = baseDirectory(of: file)
        var lines = ["#EXTM3U"]
        for item in items {
            if let title = item.title { lines.append("#EXTINF:-1," + singleLine(title)) }
            // Relative paths remain portable with their containing media directory.
            if let relative = relativePath(item.url, base: base) { lines.append(relative) }
            // `./` keeps a name starting with `#` or holding `:` from reading as a comment or a URL.
            else if item.url.isFileURL, outside == .fileName { lines.append("./" + singleLine(item.url.standardizedFileURL.lastPathComponent)) }
            else { lines.append(item.url.absoluteString) }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    private static func baseDirectory(of file: URL) -> String { file.deletingLastPathComponent().standardizedFileURL.path + "/" }
    private static func relativePath(_ url: URL, base: String) -> String? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base), !path.contains("\n"), !path.contains("\r") else { return nil }
        return "./" + String(path.dropFirst(base.count))
    }
    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

/// How a list writes the files outside its own folder.
public enum M3U8OutsidePaths: Sendable, CaseIterable {
    /// The file name alone: nothing of the user's folders, but the list no longer finds the file elsewhere.
    case fileName
    /// The full file URL, which reads back on this device.
    case fullPath

    public var label: String {
        switch self {
        case .fileName: "ファイル名だけで書く"
        case .fullPath: "フルパスで書く"
        }
    }
    /// The question asked before writing a list with such files.
    public static func question(count: Int) -> String { "\(count)曲はリストのフォルダの外にあります" }
    public static let explanation = "フルパスで書くと、フォルダの構成（Macではユーザ名を含む）がリストに入ります。ファイル名だけで書くと、読み込んだときに参照切れになることがあります。"
}
