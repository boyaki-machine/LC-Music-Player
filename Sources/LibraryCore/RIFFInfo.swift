import CoreFoundation
import Foundation

/// Reads the INFO list of a RIFF/WAVE file, which AVFoundation reads only partly (it returns no
/// album). The file is untrusted: only chunk headers are walked, within fixed bounds, and anything
/// malformed reads as no INFO list.
enum RIFFInfo {
    struct Fields: Equatable {
        var album: String?
        var artist: String?
        var track: Int?
    }
    static let maximumChunks = 256
    static let maximumListSize = 64 * 1024

    static func read(_ url: URL) -> Fields? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        return read(size: size) { offset, count in
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }
    }

    /// `bytes(offset, count)` returns up to `count` bytes at `offset`.
    static func read(size: UInt64, bytes: (UInt64, Int) -> Data?) -> Fields? {
        func exactly(_ offset: UInt64, _ count: Int) -> Data? {
            guard let data = bytes(offset, count), data.count == count else { return nil }
            return Data(data)
        }
        guard let header = exactly(0, 12), header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else { return nil }
        var offset: UInt64 = 12
        for _ in 0..<maximumChunks {
            guard offset + 8 <= size, let chunk = exactly(offset, 8) else { return nil }
            let length = UInt64(littleEndian32(chunk, at: 4)), body = offset + 8
            // A size past the end of the file means the rest cannot be trusted.
            guard body + length <= size else { return nil }
            if chunk.prefix(4) == Data("LIST".utf8), length >= 4, length <= maximumListSize,
               let list = exactly(body, Int(length)), list.prefix(4) == Data("INFO".utf8) {
                return fields(Data(list.dropFirst(4)))
            }
            offset = body + length + length % 2
        }
        return nil
    }

    private static func fields(_ list: Data) -> Fields {
        var values: [String: String] = [:]
        var i = 0
        while i + 8 <= list.count {
            let id = String(decoding: list[i ..< i + 4], as: UTF8.self), length = Int(littleEndian32(list, at: i + 4))
            let start = i + 8
            guard length <= list.count - start else { break }
            if values[id] == nil, let text = text(list[start ..< start + length]) { values[id] = text }
            i = start + length + length % 2
        }
        return Fields(album: values["IPRD"], artist: values["IART"],
                      track: (values["ITRK"] ?? values["IPRT"]).flatMap { AssetTagReader.number($0) })
    }

    /// Windows tools write the INFO list in the system code page, so Japanese files are often
    /// Shift_JIS (CP932). UTF-8 is tried first, then CP932, then Windows-1252, which never fails.
    private static let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
    static func text(_ bytes: Data) -> String? {
        let value = Data(bytes.prefix { $0 != 0 })
        guard !value.isEmpty else { return nil }
        return String(data: value, encoding: .utf8) ?? String(data: value, encoding: cp932) ?? String(data: value, encoding: .windowsCP1252)
    }

    private static func littleEndian32(_ data: Data, at index: Int) -> UInt32 {
        let start = data.startIndex + index
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[start + $1]) << (8 * $1) }
    }
}
