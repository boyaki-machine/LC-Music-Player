import AVFoundation
import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

/// Returns tags a test chose, counts the reads, and fails for URLs it does not know.
final class FakeTagReader: TrackTagReading, @unchecked Sendable {
    private let lock = NSLock()
    private var tagsByFile: [String: TrackTags] = [:]
    private var reads: [String] = []
    func set(_ name: String, _ tags: TrackTags) { lock.withLock { tagsByFile[name] = tags } }
    func readCount(_ name: String) -> Int { lock.withLock { reads.filter { $0 == name }.count } }
    func tags(for url: URL) async -> TrackTags? {
        lock.withLock { reads.append(url.lastPathComponent); return tagsByFile[url.lastPathComponent] }
    }
}

// MARK: - Tagged test files

/// An ID3v2.4 tag with UTF-8 text frames.
private func id3(_ frames: [(String, String)]) -> Data {
    func syncsafe(_ n: Int) -> Data { Data([UInt8(n >> 21 & 0x7f), UInt8(n >> 14 & 0x7f), UInt8(n >> 7 & 0x7f), UInt8(n & 0x7f)]) }
    var body = Data()
    for (id, value) in frames {
        let text = Data([3]) + Data(value.utf8)
        body += Data(id.utf8) + syncsafe(text.count) + Data([0, 0]) + text
    }
    return Data("ID3".utf8) + Data([4, 0, 0]) + syncsafe(body.count) + body
}
private let id3Frames = [("TALB", "夜の\u{0007}アルバム"), ("TPE2", "Album Artist"), ("TPE1", "Artist"), ("TRCK", "3/10"), ("TPOS", "2/2")]
private let expectedID3 = TrackTags(album: "夜の アルバム", albumArtist: "Album Artist", artist: "Artist", disc: 2, track: 3)

private func writePCM(_ url: URL, settings extra: [String: Any] = [:]) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)); buffer.frameLength = 4410
    var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    settings.merge(extra) { $1 }
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
}
/// AVAudioFile wraps FLAC in a CAF container; Extended Audio File Services write a FLAC file.
private func writeFLAC(_ url: URL) throws {
    var flac = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatFLAC, mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData,
                                           mBytesPerPacket: 0, mFramesPerPacket: 4096, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    var file: ExtAudioFileRef?
    try #require(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &flac, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr)
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true))
    var client = format.streamDescription.pointee
    try #require(ExtAudioFileSetProperty(file!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)); buffer.frameLength = 8192
    try #require(ExtAudioFileWrite(file!, buffer.frameLength, buffer.audioBufferList) == noErr)
    try #require(ExtAudioFileDispose(file!) == noErr)
}
private func uint32(_ n: Int, bigEndian: Bool) -> Data {
    withUnsafeBytes(of: bigEndian ? UInt32(n).bigEndian : UInt32(n).littleEndian) { Data($0) }
}
/// Appends a chunk to a RIFF (WAV) or FORM (AIFF) file and corrects the container size.
private func appendChunk(_ url: URL, id: String, _ payload: Data, bigEndian: Bool) throws {
    var data = try Data(contentsOf: url)
    data += Data(id.utf8) + uint32(payload.count, bigEndian: bigEndian) + payload
    if payload.count % 2 == 1 { data.append(0) }
    data.replaceSubrange(4..<8, with: uint32(data.count - 8, bigEndian: bigEndian))
    try data.write(to: url)
}
/// Replaces a FLAC file's metadata after STREAMINFO with one Vorbis comment block.
private func addVorbisComments(_ url: URL, _ comments: [String]) throws {
    let data = try Data(contentsOf: url)
    try #require(data.prefix(4) == Data("fLaC".utf8))
    var i = 4, streamInfo = Data()
    while true {
        let header = data[i], length = Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
        if header & 0x7f == 0 { streamInfo = data[i + 4 ..< i + 4 + length] }
        i += 4 + length
        if header & 0x80 != 0 { break }
    }
    var vorbis = uint32(1, bigEndian: false) + Data("x".utf8) + uint32(comments.count, bigEndian: false)
    for comment in comments { vorbis += uint32(comment.utf8.count, bigEndian: false) + Data(comment.utf8) }
    func block(_ type: UInt8, _ body: Data) -> Data {
        Data([type, UInt8(body.count >> 16 & 0xff), UInt8(body.count >> 8 & 0xff), UInt8(body.count & 0xff)]) + body
    }
    try (Data("fLaC".utf8) + block(0, streamInfo) + block(0x84, vorbis) + data[i...]).write(to: url)
}

@Suite struct TrackTagsTests {
    private let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-tags-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func tagsAreCleanedAsUntrustedInput() {
        let long = String(repeating: "あ", count: 500)
        let tags = TrackTags(album: "  A\nB\u{0}C  ", albumArtist: "   ", artist: long, disc: 0, track: 10_000)
        #expect(tags.album == "A B C")
        #expect(tags.albumArtist == nil)
        #expect(tags.artist?.count == TrackTags.maximumLength)
        #expect(tags.disc == nil && tags.track == nil)
        #expect(TrackTags(disc: 1, track: 9999) == TrackTags(disc: 1, track: 9999))
    }

    @Test func albumKeyIgnoresCaseAndWidthAndFallsBackToTheArtist() {
        #expect(TrackTags(album: "Ａｌｂｕｍ", albumArtist: "BAND").albumKey == TrackTags(album: "album", albumArtist: "band").albumKey)
        #expect(TrackTags(album: "Album", artist: "Band").albumKey == TrackTags(album: "Album", albumArtist: "Band").albumKey)
        #expect(TrackTags(album: "Album", albumArtist: "One").albumKey != TrackTags(album: "Album", albumArtist: "Two").albumKey)
        #expect(TrackTags(artist: "Band").albumKey == nil)
    }

    @Test func numbersAreReadFromTextAndTheITunesForm() {
        #expect(AssetTagReader.number("3/10") == 3)
        #expect(AssetTagReader.number(" 7 ") == 7)
        #expect(AssetTagReader.number(Data([0, 0, 0, 5, 0, 9, 0, 0])) == 5)
        #expect(AssetTagReader.number(Data([0, 0, 1, 2, 0, 0, 0, 0])) == 258)
        #expect(AssetTagReader.number(NSNumber(value: 4)) == 4)
        #expect(AssetTagReader.number("x") == nil)
        #expect(AssetTagReader.number(Data([0])) == nil)
    }

    @Test func readsID3TagsOfMP3WAVAndAIFF() async throws {
        let mp3 = root.appendingPathComponent("a.mp3")
        // Silent MPEG-1 Layer III frames (128 kbit/s, 44.1 kHz) after the tag.
        let frame = Data([0xff, 0xfb, 0x90, 0x64]) + Data(count: 413)
        try (id3(id3Frames) + Data((0..<40).flatMap { _ in frame })).write(to: mp3)
        let wav = root.appendingPathComponent("a.wav")
        try writePCM(wav); try appendChunk(wav, id: "id3 ", id3(id3Frames), bigEndian: false)
        let aiff = root.appendingPathComponent("a.aiff")
        try writePCM(aiff, settings: [AVLinearPCMIsBigEndianKey: true]); try appendChunk(aiff, id: "ID3 ", id3(id3Frames), bigEndian: true)
        let reader = AssetTagReader(mediaLibrary: FakeMediaLibrary())
        for url in [mp3, wav, aiff] {
            #expect(await reader.tags(for: url) == expectedID3, "\(url.lastPathComponent)")
        }
    }

    @Test func readsVorbisCommentsOfFLAC() async throws {
        let flac = root.appendingPathComponent("a.flac")
        try writeFLAC(flac)
        try addVorbisComments(flac, ["ALBUM=Flac Album", "ALBUMARTIST=Flac Artist", "ARTIST=Someone", "TRACKNUMBER=4/12", "DISCNUMBER=1"])
        let tags = await AssetTagReader(mediaLibrary: FakeMediaLibrary()).tags(for: flac)
        #expect(tags == TrackTags(album: "Flac Album", albumArtist: "Flac Artist", artist: "Someone", disc: 1, track: 4))
    }

    @Test func readsITunesTagsOfM4A() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }
        let plain = root.appendingPathComponent("plain.m4a"), m4a = root.appendingPathComponent("a.m4a")
        try writePCM(plain, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 64000])
        let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough))
        func item(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let item = AVMutableMetadataItem(); item.identifier = id; item.value = value; return item
        }
        export.metadata = [item(.iTunesMetadataAlbum, "M4A Album" as NSString), item(.iTunesMetadataAlbumArtist, "M4A Artist" as NSString),
                           item(.iTunesMetadataTrackNumber, Data([0, 0, 0, 6, 0, 9, 0, 0]) as NSData),
                           item(.iTunesMetadataDiscNumber, Data([0, 0, 0, 1, 0, 1]) as NSData)]
        try await export.export(to: m4a, as: .m4a)
        let tags = await AssetTagReader(mediaLibrary: FakeMediaLibrary()).tags(for: m4a)
        #expect(tags == TrackTags(album: "M4A Album", albumArtist: "M4A Artist", disc: 1, track: 6))
    }

    @Test func untaggedFilesReadAsEmptyAndMissingFilesAsUnreadable() async throws {
        let wav = root.appendingPathComponent("plain.wav"); try writePCM(wav)
        let reader = AssetTagReader(mediaLibrary: FakeMediaLibrary())
        #expect(await reader.tags(for: wav) == TrackTags())
        #expect(await reader.tags(for: root.appendingPathComponent("missing.wav")) == nil)
    }

    @Test func librarySongsAreReadFromTheLibrary() async throws {
        let library = FakeMediaLibrary()
        let url = library.add(5, tags: TrackTags(album: "Library Album", albumArtist: "Band", disc: 1, track: 2))
        let reader = AssetTagReader(mediaLibrary: library)
        #expect(await reader.tags(for: url) == TrackTags(album: "Library Album", albumArtist: "Band", disc: 1, track: 2))
        #expect(await reader.tags(for: URL(string: "ipod-library://item/item.m4a?id=6")!) == nil)
    }
}

// MARK: - Reading in the library

@Suite @MainActor struct LibraryTagReadingTests {
    private let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-tag-library-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name); try Data("x".utf8).write(to: url); return url
    }
    private func model(_ store: MemoryStore, _ reader: FakeTagReader) -> LibraryController {
        LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: TestReferences(), tagReader: reader)
    }

    @Test func importedTracksGetTheirTagsSaved() async throws {
        let reader = FakeTagReader(), store = MemoryStore()
        reader.set("a.mp3", TrackTags(album: "Album", track: 1)); reader.set("b.mp3", TrackTags())
        let model = model(store, reader)
        await model.importFiles([try file("a.mp3"), try file("b.mp3")])
        await model.waitForTags()
        func current(_ tags: TrackTags) -> TrackTags { var tags = tags; tags.version = TrackTags.currentVersion; return tags }
        #expect(model.document.tracks.map(\.tags) == [current(TrackTags(album: "Album", track: 1)), current(TrackTags())])
        #expect(store.document.tracks.map(\.tags) == model.document.tracks.map(\.tags))
        // Read tags, even empty ones, are not read again on the next launch.
        let again = self.model(store, reader)
        await again.waitForTags()
        #expect(reader.readCount("a.mp3") == 1 && reader.readCount("b.mp3") == 1)
    }

    @Test func olderLibrariesWithoutTagsLoadAndAreFilledIn() async throws {
        let url = try file("old.mp3")
        let json = """
        {"schemaVersion":1,"tracks":[{"id":"\(UUID())","name":"old","reference":{"bookmark":"\(Data(url.absoluteString.utf8).base64EncodedString())","lastKnownURL":"\(url.absoluteString)"}}],
         "playlists":[{"id":"\(UUID())","name":"list","entries":[]}]}
        """
        let store = MemoryStore()
        store.document = try JSONDecoder().decode(LibraryDocument.self, from: Data(json.utf8))
        #expect(store.document.tracks.first?.tags == nil)
        let reader = FakeTagReader(); reader.set("old.mp3", TrackTags(album: "Old Album"))
        let model = model(store, reader)
        await model.waitForTags()
        #expect(model.document.tracks.first?.tags?.album == "Old Album")
        #expect(store.document.tracks.first?.tags?.album == "Old Album")
    }

    @Test func unreadableTracksAreTriedOnlyOncePerLaunch() async throws {
        let reader = FakeTagReader(), store = MemoryStore()
        let model = model(store, reader)
        await model.importFiles([try file("x.mp3")])
        await model.waitForTags()
        await model.importFiles([try file("y.mp3")])
        await model.waitForTags()
        #expect(model.document.tracks.allSatisfy { $0.tags == nil })
        #expect(reader.readCount("x.mp3") == 1)
        // The next launch tries again.
        await self.model(store, reader).waitForTags()
        #expect(reader.readCount("x.mp3") == 2)
    }

    @Test func repairingATrackReadsItsTagsAgain() async throws {
        let reader = FakeTagReader(), store = MemoryStore()
        reader.set("first.mp3", TrackTags(album: "First")); reader.set("second.mp3", TrackTags(album: "Second"))
        let model = model(store, reader)
        await model.importFiles([try file("first.mp3")])
        await model.waitForTags()
        let id = try #require(model.document.tracks.first?.id)
        model.repairTrack(id, using: try file("second.mp3"))
        await model.waitForTags()
        #expect(model.track(id)?.tags?.album == "Second")
    }

    @Test func withoutAReaderNothingIsRead() async throws {
        let model = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: MemoryStore(), references: TestReferences())
        await model.importFiles([try file("a.mp3")])
        await model.waitForTags()
        #expect(model.document.tracks.first?.tags == nil)
    }

    @Test func tracksReadByAnOlderReaderWithoutAnAlbumAreReadOnceMore() async throws {
        let store = MemoryStore()
        let old = try file("old.wav"), found = try file("found.wav")
        var oldEmpty = LibraryTrack(name: "old", reference: TrackReference(bookmark: Data(old.absoluteString.utf8), lastKnownURL: old), tags: TrackTags())
        let withAlbum = LibraryTrack(name: "found", reference: TrackReference(bookmark: Data(found.absoluteString.utf8), lastKnownURL: found),
                                     tags: TrackTags(album: "Known"))
        oldEmpty.tags?.version = nil
        store.document.tracks = [oldEmpty, withAlbum]
        let reader = FakeTagReader(); reader.set("old.wav", TrackTags(album: "Info Album"))
        let model = model(store, reader)
        await model.waitForTags()
        #expect(model.track(oldEmpty.id)?.tags?.album == "Info Album")
        #expect(model.track(oldEmpty.id)?.tags?.version == TrackTags.currentVersion)
        // A track that already has an album is not read again.
        #expect(reader.readCount("found.wav") == 0)
        // Once read by the current reader, an empty result is final.
        reader.set("old.wav", TrackTags())
        store.document.tracks[0].tags = TrackTags(); store.document.tracks[0].tags?.version = TrackTags.currentVersion
        await self.model(store, reader).waitForTags()
        #expect(reader.readCount("old.wav") == 1)
    }
}
