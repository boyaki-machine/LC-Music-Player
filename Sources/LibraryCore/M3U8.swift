import Foundation

public struct M3U8Item: Equatable, Sendable {
    public var url: URL
    public var title: String?
    public init(url: URL, title: String? = nil) { self.url = url; self.title = title }
}
public enum M3U8 {
    public static func decode(_ data: Data, relativeTo file: URL) throws -> [M3U8Item] {
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
                guard parsed.isFileURL, parsed.host == nil || parsed.host == "" || parsed.host == "localhost" else {
                    throw LibraryFailure.invalidPlaylist("ローカル音源のリストを選択してください。")
                }
                url = parsed
            } else if line.hasPrefix("/") { url = URL(fileURLWithPath: line) }
            else { url = file.deletingLastPathComponent().appendingPathComponent(line) }
            result.append(M3U8Item(url: url.standardizedFileURL, title: title)); title = nil
        }
        return result
    }
    public static func encode(_ items: [M3U8Item], relativeTo file: URL) -> Data {
        let base = file.deletingLastPathComponent().standardizedFileURL.path + "/"
        var lines = ["#EXTM3U"]
        for item in items {
            if let title = item.title { lines.append("#EXTINF:-1," + title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")) }
            let path = item.url.standardizedFileURL.path
            // Relative paths remain portable with their containing media directory.
            if path.hasPrefix(base), !path.contains("\n"), !path.contains("\r") { lines.append("./" + String(path.dropFirst(base.count))) }
            else { lines.append(item.url.absoluteString) }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
