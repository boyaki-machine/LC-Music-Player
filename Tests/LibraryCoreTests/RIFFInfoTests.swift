import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

/// RIFF files built byte by byte, so that broken ones can be made too.
private func chunk(_ id: String, _ body: Data, size: UInt32? = nil) -> Data {
    var data = Data(id.utf8)
    withUnsafeBytes(of: (size ?? UInt32(body.count)).littleEndian) { data += Data($0) }
    data += body
    if body.count % 2 == 1 { data.append(0) }
    return data
}
private func info(_ fields: [(String, Data)]) -> Data {
    chunk("LIST", Data("INFO".utf8) + fields.reduce(Data()) { $0 + chunk($1.0, $1.1) })
}
private func text(_ value: String) -> Data { Data(value.utf8) + Data([0]) }
private func riff(_ chunks: [Data], form: String = "WAVE") -> Data {
    let body = Data(form.utf8) + chunks.reduce(Data(), +)
    return chunk("RIFF", body)
}
private let format = chunk("fmt ", Data([1, 0, 1, 0, 0x44, 0xac, 0, 0, 0x88, 0x58, 1, 0, 2, 0, 16, 0]))
private let samples = chunk("data", Data(count: 882))

private func read(_ data: Data) -> RIFFInfo.Fields? {
    RIFFInfo.read(size: UInt64(data.count)) { offset, count in
        guard offset < UInt64(data.count) else { return Data() }
        return data.subdata(in: Int(offset) ..< min(data.count, Int(offset) + count))
    }
}

@Suite struct RIFFInfoTests {
    @Test func readsTheAlbumArtistAndTrackOfTheInfoList() {
        let file = riff([format, samples, info([("INAM", text("Title")), ("IPRD", text("Info Album")), ("IART", text("Info Artist")), ("ITRK", text("4/12"))])])
        #expect(read(file) == RIFFInfo.Fields(album: "Info Album", artist: "Info Artist", track: 4))
    }

    @Test func fallsBackToIPRTAndSkipsOtherLists() {
        let adtl = chunk("LIST", Data("adtl".utf8) + chunk("labl", Data(count: 9)))
        let file = riff([format, adtl, samples, info([("IPRT", text("7")), ("IPRD", Data("Odd".utf8))])])
        #expect(read(file) == RIFFInfo.Fields(album: "Odd", track: 7))
    }

    @Test func decodesUTF8ThenShiftJISThenLatin1() throws {
        #expect(RIFFInfo.text(Data("夜のアルバム".utf8)) == "夜のアルバム")
        // "夜のアルバム" in Shift_JIS (CP932), which is not valid UTF-8.
        let shiftJIS = Data([0x96, 0xe9, 0x82, 0xcc, 0x83, 0x41, 0x83, 0x8b, 0x83, 0x6f, 0x83, 0x80])
        #expect(RIFFInfo.text(shiftJIS) == "夜のアルバム")
        // Neither UTF-8 nor Shift_JIS (0xE9 needs a second byte of 0x40 or more): read as Windows-1252.
        #expect(RIFFInfo.text(Data([0x43, 0x61, 0x66, 0xe9, 0x21])) == "Café!")
        #expect(RIFFInfo.text(Data([0, 0x41])) == nil)
        #expect(RIFFInfo.text(Data("Album".utf8) + Data([0, 0x42])) == "Album")
    }

    @Test func malformedFilesReadAsNoInfoList() {
        let good = info([("IPRD", text("Album"))])
        // Not RIFF/WAVE, or too short.
        #expect(read(riff([format, good], form: "AVI ")) == nil)
        #expect(read(Data("RIFF".utf8)) == nil)
        #expect(read(Data()) == nil)
        // A chunk claims more bytes than the file has: nothing after it is trusted.
        #expect(read(riff([chunk("data", Data(count: 4), size: 0xffff_fff0), good])) == nil)
        // Cut off in the middle of the INFO list.
        let whole = riff([format, good])
        #expect(read(whole.prefix(whole.count - 3)) == nil)
        // An INFO list over the size limit is not read.
        let huge = info([("ICMT", Data(repeating: 0x41, count: RIFFInfo.maximumListSize)), ("IPRD", text("Album"))])
        #expect(read(riff([format, huge])) == nil)
        // An entry whose size runs past the list ends the list; earlier entries stay.
        let broken = chunk("LIST", Data("INFO".utf8) + chunk("IART", text("Artist")) + chunk("IPRD", Data("A".utf8), size: 1000))
        #expect(read(riff([format, broken])) == RIFFInfo.Fields(artist: "Artist"))
        // More chunks than the walk allows before the INFO list.
        let filler = Array(repeating: chunk("junk", Data(count: 2)), count: RIFFInfo.maximumChunks)
        #expect(read(riff(filler + [good])) == nil)
        #expect(read(riff(Array(filler.dropLast(2)) + [good])) == RIFFInfo.Fields(album: "Album"))
    }

    @Test func readerFillsWhatID3LeavesOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-riff-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reader = AssetTagReader(mediaLibrary: FakeMediaLibrary())
        let infoOnly = root.appendingPathComponent("info.wav")
        try riff([format, samples, info([("IPRD", text("Info Album")), ("IART", text("Info Artist")), ("ITRK", text("2"))])]).write(to: infoOnly)
        #expect(await reader.tags(for: infoOnly) == TrackTags(album: "Info Album", artist: "Info Artist", track: 2))
        // An ID3 chunk names the album; INFO only adds the track number it lacks.
        var id3 = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 17])
        id3 += Data("TALB".utf8) + Data([0, 0, 0, 7, 0, 0, 3]) + Data("ID3 Alb".utf8).prefix(6)
        let both = root.appendingPathComponent("both.wav")
        try riff([format, samples, info([("IPRD", text("Info Album")), ("ITRK", text("5"))]), chunk("id3 ", id3)]).write(to: both)
        let tags = await reader.tags(for: both)
        #expect(tags?.album == "ID3 Al" && tags?.track == 5)
    }

    @MainActor @Test func wavFilesTaggedOnlyByInfoShareAnAlbum() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-riff-library-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = try (1...2).map { n in
            let url = root.appendingPathComponent("\(n).wav")
            try riff([format, samples, info([("IPRD", text("Info Album")), ("IART", text("Info Artist")), ("ITRK", text("\(n)"))])]).write(to: url)
            return url
        }
        let model = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: MemoryStore(),
                                      references: TestReferences(), tagReader: AssetTagReader(mediaLibrary: FakeMediaLibrary()))
        await model.importFiles(urls)
        await model.waitForTags()
        let keys = model.document.tracks.map { $0.tags?.albumKey }
        #expect(keys.count == 2 && keys[0] != nil && keys[0] == keys[1])
        #expect(model.document.tracks.map { $0.tags?.track } == [1, 2])
    }
}
