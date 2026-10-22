import Foundation
import Testing
import LibraryCore
@testable import PlayerUI

@Suite struct SourceSearchTests {
    private func track(_ url: String, name: String? = nil, tags: TrackTags? = nil) -> LibraryTrack {
        let url = URL(string: url)!
        return LibraryTrack(name: name ?? url.deletingPathExtension().lastPathComponent,
                            reference: TrackReference(bookmark: nil, lastKnownURL: url), registration: .folder, tags: tags)
    }
    private func names(_ groups: [SourceFolderGroup]) -> [String] { groups.flatMap(\.tracks).map(\.name) }

    @Test func eachFieldMatchesAndNothingElseDoes() {
        let tagged = track("file:///Music/aac/Night/01.m4a", name: "Opening", tags: TrackTags(album: "Midnight Drive", albumArtist: "Various", artist: "Luna"))
        let flac = track("file:///Rips/Other/song.flac", name: "Closing")
        let song = track("ipod-library://item/item.mp3?id=7", name: "Library Song")
        let catalog = SourceCatalog([tagged, flac, song])
        #expect(names(catalog.groups(matching: "opening")) == ["Opening"])
        #expect(names(catalog.groups(matching: "01.m4a")) == ["Opening"])
        #expect(names(catalog.groups(matching: "flac")) == ["Closing"])
        #expect(names(catalog.groups(matching: "/music/aac")) == ["Opening"])
        #expect(names(catalog.groups(matching: "midnight")) == ["Opening"])
        #expect(names(catalog.groups(matching: "luna")) == ["Opening"])
        #expect(names(catalog.groups(matching: "various")) == ["Opening"])
        // A Music library song matches by its title and kind, never by its asset URL.
        #expect(names(catalog.groups(matching: "mp3")) == ["Library Song"])
        #expect(catalog.groups(matching: "ipod").isEmpty)
        #expect(catalog.groups(matching: "id=7").isEmpty)
        #expect(catalog.groups(matching: "nothing here").isEmpty)
    }

    @Test func caseWidthAndDecomposedKanaAreIgnored() {
        // Folder names from macOS keep voiced kana decomposed (NFD); typed text is composed.
        let decomposed = "ガレージ".decomposedStringWithCanonicalMapping
        let tracks = [track("file:///Music/\(decomposed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)/a.mp3", name: "Ｂｌｕｅ Ｓｋｙ"),
                      track("file:///Music/Plain/b.mp3", name: "Red")]
        let catalog = SourceCatalog(tracks)
        #expect(names(catalog.groups(matching: "ガレージ")) == ["Ｂｌｕｅ Ｓｋｙ"])
        #expect(names(catalog.groups(matching: "blue")) == ["Ｂｌｕｅ Ｓｋｙ"])
        #expect(names(catalog.groups(matching: "ＲＥＤ")) == ["Red"])
    }

    @Test func everyWordMustMatchInAnyField() {
        let tracks = [track("file:///Music/aac/Luna/a.m4a", name: "Moon"), track("file:///Music/mp3/Luna/b.mp3", name: "Moon"),
                      track("file:///Music/aac/Sol/c.m4a", name: "Sun")]
        let catalog = SourceCatalog(tracks)
        #expect(catalog.groups(matching: "aac moon").flatMap(\.tracks).map(\.id) == [tracks[0].id])
        #expect(catalog.groups(matching: "  moon\u{3000}luna ").flatMap(\.tracks).count == 2)
        #expect(catalog.groups(matching: "").map(\.id) == catalog.groups.map(\.id))
        #expect(catalog.groups(matching: " \u{3000}").map(\.id) == catalog.groups.map(\.id))
    }

    @Test func matchesStayInTheirGroupsAndHiddenTracksStayOut() throws {
        let album = TrackTags(album: "Night", albumArtist: "Band")
        let a = track("file:///One/a.mp3", name: "Alpha", tags: album), b = track("file:///Two/b.mp3", name: "Beta", tags: album)
        let c = track("file:///Folder/c.mp3", name: "Alpha Bonus"), d = track("file:///Folder/d.mp3", name: "Delta")
        let catalog = SourceCatalog([a, b, c, d])
        let groups = catalog.groups(matching: "alpha")
        // A lone match keeps its album and folder; the groups are not rebuilt from the matches.
        #expect(groups.map(\.name) == ["Night", "Folder"])
        #expect(groups.map { $0.tracks.map(\.id) } == [[a.id], [c.id]])
        #expect(try #require(groups.first).isAlbum)
        #expect(catalog.groups(matching: "alpha", hiding: [a.id]).map(\.name) == ["Folder"])
        #expect(catalog.groups(matching: "", hiding: [c.id, d.id]).map(\.name) == ["Night"])
        #expect(catalog.groups(matching: "", hiding: [a.id]).map(\.id) == SourceFolderGroup.groups([a, b, c, d], hiding: [a.id]).map(\.id))
    }

    @MainActor @Test func cacheRebuildsOnlyWhenTheTracksChange() {
        let a = track("file:///Folder/a.mp3", name: "Alpha"), b = track("file:///Folder/b.mp3", name: "Beta")
        let cache = SourceCatalogCache()
        var tracks = [a, b]
        #expect(names(cache.groups(tracks, matching: "a", hiding: [])) == ["Alpha", "Beta"])
        #expect(names(cache.groups(tracks, matching: "alpha", hiding: [])) == ["Alpha"])
        #expect(names(cache.groups(tracks, matching: "alpha", hiding: [a.id])).isEmpty)
        tracks[0].name = "Gamma"
        #expect(names(cache.groups(tracks, matching: "gamma", hiding: [])) == ["Gamma"])
        tracks.removeLast()
        #expect(names(cache.groups(tracks, matching: "", hiding: [])) == ["Gamma"])
    }

    @Test func groupCheckboxChoosesAllShownTracksOrClearsThem() {
        let a = track("file:///F/a.mp3"), b = track("file:///F/b.mp3"), other = UUID()
        var selected: Set<UUID> = [other]
        #expect(SourceSelection.state(of: [a, b], in: selected) == .none)
        selected.insert(a.id)
        #expect(SourceSelection.state(of: [a, b], in: selected) == .some)
        SourceSelection.toggle([a, b], in: &selected)
        #expect(selected == [other, a.id, b.id])
        #expect(SourceSelection.state(of: [a, b], in: selected) == .all)
        SourceSelection.toggle([a, b], in: &selected)
        // Clearing a group keeps what was chosen elsewhere.
        #expect(selected == [other])
        #expect(SourceSelection.state(of: [], in: selected) == .none)
    }

    /// A library of several thousand tracks, as on the developer's machine, filters without a wait.
    @Test func thousandsOfTracksFilterQuickly() {
        let tracks = (0..<7356).map { i in
            track("file:///Users/someone/Library/CloudStorage/OneDrive/Music/\(i % 3 == 0 ? "aac" : "Music")/Artist%20\(i % 300)/Album%20\(i % 700)/\(i).m4a",
                  name: "Track \(i) 曲名", tags: i % 2 == 0 ? TrackTags(album: "Album \(i % 700)", albumArtist: "Artist \(i % 300)") : nil)
        }
        let clock = ContinuousClock()
        var catalog: SourceCatalog?
        let build = clock.measure { catalog = SourceCatalog(tracks) }
        guard let catalog else { return }
        var counts: [Int] = []
        var slowest = Duration.zero
        for query in ["a", "aa", "aac", "aac track 12", "曲名", "zzz"] {
            slowest = max(slowest, clock.measure { counts.append(catalog.groups(matching: query).reduce(0) { $0 + $1.tracks.count }) })
        }
        #expect(counts == [7356, 2452, 2452, 191, 7356, 0])
        // Debug builds under parallel tests; a keystroke measured about 3ms alone.
        #expect(slowest < .milliseconds(100), "slowest query \(slowest)")
        #expect(build < .seconds(3), "build \(build)")
    }
}
