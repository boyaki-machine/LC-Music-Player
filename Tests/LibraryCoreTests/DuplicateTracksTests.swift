import AVFoundation
import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

private func track(_ path: String, name: String? = nil, album: String? = nil, artist: String? = "A", disc: Int? = nil, number: Int? = nil) -> LibraryTrack {
    let url = URL(fileURLWithPath: "/music/\(path)")
    var track = LibraryTrack(name: name ?? url.deletingPathExtension().lastPathComponent, reference: TrackReference(bookmark: nil, lastKnownURL: url))
    if album != nil { track.tags = TrackTags(album: album, artist: artist, disc: disc, track: number) }
    return track
}

@MainActor struct DuplicateTracksTests {
    @Test func copiesOfASongMatchByAlbumAndNumberOrByTitleOrByFolderAndTitle() {
        let flac = track("Music/Blue/01 Song.flac", album: "Blue", number: 1)
        let aac = track("aac/Blue/Song.m4a", name: "Song", album: "ＢＬＵＥ", number: 1)
        let otherNumber = track("Music/Blue/02 Other.flac", album: "Blue", number: 2)
        let otherDisc = track("Music/Blue/2-01 Song.flac", album: "Blue", disc: 2, number: 1)
        let otherArtist = track("Music/Blue B/01 Song.flac", album: "Blue", artist: "B", number: 1)
        let unnumbered = [track("x/Live.flac", album: "Live"), track("y/live.mp3", name: "LIVE", album: "Live")]
        let untagged = [track("Music/Red/01 Song.wav"), track("aac/Red/01 Song.m4a"), track("aac/Green/01 Song.m4a")]
        var song = track("ignored.m4a"); song.reference = TrackReference(bookmark: nil, lastKnownURL: URL(string: "ipod-library://item/item.m4a?id=1")!)
        var twin = song; twin.id = UUID()
        let tracks = [flac, otherNumber, aac, otherDisc, otherArtist] + unnumbered + untagged + [song, twin]
        #expect(DuplicateTracks.sets(tracks) == [[flac.id, aac.id], unnumbered.map(\.id), [untagged[0].id, untagged[1].id]])
        #expect(DuplicateTracks.sets([flac, otherNumber]).isEmpty)
    }

    @Test func surplusKeepsTheChosenKindThenTheMostListedThenTheFirst() {
        let a = UUID(), b = UUID(), c = UUID()
        let lossless = [a: true, b: false, c: false]
        #expect(DuplicateTracks.surplus([[a, b]], keep: .lossless, lossless: lossless, memberships: [:]) == [b])
        #expect(DuplicateTracks.surplus([[a, b]], keep: .lossy, lossless: lossless, memberships: [a: 3]) == [a])
        // Two lossy copies: the one in a playlist stays, otherwise the first registered.
        #expect(DuplicateTracks.surplus([[a, b, c]], keep: .lossy, lossless: lossless, memberships: [c: 1]) == [a, b])
        #expect(DuplicateTracks.surplus([[a, b, c]], keep: .lossy, lossless: lossless, memberships: [:]) == [a, c])
        // A copy of unknown kind is never preferred over a known one.
        #expect(DuplicateTracks.surplus([[c, a]], keep: .lossless, lossless: [a: true], memberships: [c: 5]) == [c])
        #expect(DuplicateTracks.surplus([[a, b]], keep: .lossless, lossless: [:], memberships: [:]) == [b])
    }

    @Test func membershipsCountPlaylistsNotEntries() {
        var document = LibraryDocument()
        let x = track("x.flac"), y = track("y.flac")
        document.tracks = [x, y]
        document.playlists[0].entries = [PlaylistEntry(trackID: x.id), PlaylistEntry(trackID: x.id)]
        document.playlists.append(MusicPlaylist(name: "別", entries: [PlaylistEntry(trackID: x.id)]))
        #expect(document.playlistMemberships == [x.id: 2])
    }

    @Test func m4aFilesAreToldApartByCodecAndOthersByExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lcmp-codec-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ codec: AudioFormatID) throws -> URL {
            let url = root.appendingPathComponent(name)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)); buffer.frameLength = 8192
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: codec, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2])
            try file.write(from: buffer)
            return url
        }
        #expect(AudioEncoding.isLossless(try write("alac.m4a", kAudioFormatAppleLossless)) == true)
        #expect(AudioEncoding.isLossless(try write("aac.m4a", kAudioFormatMPEG4AAC)) == false)
        #expect(AudioEncoding.isLossless(root.appendingPathComponent("missing.m4a")) == nil)
        #expect(AudioEncoding.isLossless(URL(fileURLWithPath: "/x.FLAC")) == true)
        #expect(AudioEncoding.isLossless(URL(fileURLWithPath: "/x.aiff")) == true)
        #expect(AudioEncoding.isLossless(URL(fileURLWithPath: "/x.mp3")) == false)
    }

    @Test func excludingCopiesMovesTheirPlaylistEntriesToTheCopyThatStays() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = CountingStore()
        let library = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: store, references: TestReferences())
        let first = try #require(library.document.currentPlaylistID)
        let kept = try f.file("Music/Blue/01 Song.wav"), copy = try f.file("aac/Blue/01 Song.m4a"), lone = try f.file("Other/x.wav")
        await library.importFiles([kept, copy, lone])
        let ids = library.document.tracks.map(\.id)
        #expect(DuplicateTracks.sets(library.document.tracks) == [[ids[0], ids[1]]])
        // The first list holds only the copy, the second both copies and the lone track.
        library.addTracks([ids[1], ids[2]], to: first)
        let second = try #require(library.createPlaylist("両方"))
        library.addTracks([ids[1], ids[0], ids[2]], to: second)
        let copyEntry = try #require(library.playlist(first)?.entries.first)
        let saves = store.saves
        library.excludeDuplicates([ids[1], ids[2]])
        #expect(store.saves == saves + 1)
        #expect(library.document.tracks.map(\.id) == [ids[0]])
        let firstEntries = try #require(library.playlist(first)).entries
        #expect(firstEntries.map(\.id) == [copyEntry.id] && firstEntries.map(\.trackID) == [ids[0]])
        #expect(try #require(library.playlist(second)).entries.map(\.trackID) == [ids[0]])
        #expect(library.message == "2曲を除外しました。リストの1曲は残した方に付け替えました。")
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func losslessFlagsOpenOnlyM4AFiles() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let library = LibraryController(playback: PlaybackController(makeBackend: { _ in TestBackend() }), store: CountingStore(), references: TestReferences())
        // The fixture's M4A holds no audio, so its kind stays unknown.
        await library.importFiles([try f.file("a.flac"), try f.file("b.mp3"), try f.file("c.m4a")])
        let ids = library.document.tracks.map(\.id)
        #expect(await library.losslessFlags(ids + [UUID()]) == [ids[0]: true, ids[1]: false])
    }
}
