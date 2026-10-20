import SwiftUI
import LibraryCore
import PlaybackCore

struct SourceFolderGroup: Identifiable {
    enum Kind: Equatable {
        /// Tracks that fit no album or folder.
        case unsorted
        /// A parent folder, or all Music library songs that fit no album.
        case folder(URL)
        /// Tracks with the same album name and album artist, files and library songs alike.
        case album(key: String, title: String, artist: String?)
    }
    let kind: Kind
    let tracks: [LibraryTrack]
    /// Set when another album has the same title, so the two can be told apart.
    var showsArtist = false
    var id: String {
        switch kind {
        case .unsorted: "default"
        case .folder(let url): url.absoluteString
        case .album(let key, _, _): "album:" + key
        }
    }
    var directory: URL? { if case .folder(let url) = kind { url } else { nil } }
    var isAlbum: Bool { if case .album = kind { true } else { false } }
    /// What the group is called in the remove button and its confirmation.
    var kindName: String { isAlbum ? "アルバム" : "フォルダ" }
    /// The default group cannot be removed at once, against mistaken taps.
    var isRemovable: Bool { kind != .unsorted }
    var name: String {
        switch kind {
        case .unsorted: return "デフォルト"
        case .album(_, let title, let artist): return showsArtist ? artist.map { "\(title) — \($0)" } ?? title : title
        case .folder(let directory):
            if directory.scheme == SupportedAudio.mediaLibraryScheme { return "ミュージック" }
            return directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent
        }
    }
    /// An album with two or more tracks becomes a group first. The remaining tracks group by
    /// parent folder: a folder holding a folder-registered track or two or more tracks becomes a
    /// group, and a file registered alone stays in the default group until another track from its
    /// folder arrives. All remaining Music library songs share one group; their asset URLs differ
    /// only in the ID query. Only the display changes; the stored registration does not.
    private static let mediaLibraryFolder = URL(string: "\(SupportedAudio.mediaLibraryScheme)://item/")!
    private static func folder(of track: LibraryTrack) -> URL {
        track.reference.mediaItemID != nil ? mediaLibraryFolder : track.reference.lastKnownURL.deletingLastPathComponent().standardizedFileURL
    }
    static func groups(_ tracks: [LibraryTrack]) -> [Self] {
        let albums = Dictionary(grouping: tracks.filter { $0.tags?.albumKey != nil }) { $0.tags!.albumKey! }.filter { $0.value.count > 1 }
        let rest = tracks.filter { $0.tags?.albumKey.map { albums[$0] == nil } ?? true }
        let byFolder = Dictionary(grouping: rest, by: folder(of:))
        // Music library songs always form their own group, even a single one.
        let folders = Set(byFolder.filter { folder, members in
            folder.scheme == SupportedAudio.mediaLibraryScheme || members.count > 1 || members.contains { $0.registration == .folder }
        }.keys)
        let byPlace = Dictionary(grouping: rest) { track -> URL? in
            let folder = folder(of: track)
            return folders.contains(folder) ? folder : nil
        }
        var albumGroups = albums.map { key, members in
            let tags = members[0].tags!
            return Self(kind: .album(key: key, title: tags.album!, artist: tags.albumArtist ?? tags.artist), tracks: albumOrder(members))
        }
        let titles = Dictionary(grouping: albumGroups.map(\.name), by: Self.fold)
        for i in albumGroups.indices where titles[fold(albumGroups[i].name)]!.count > 1 { albumGroups[i].showsArtist = true }
        // The default group, the Music library, albums by name, then folders by path.
        func rank(_ group: Self) -> (Int, String) {
            switch group.kind {
            case .unsorted: (0, "")
            case .folder(let url) where url.scheme == SupportedAudio.mediaLibraryScheme: (1, "")
            case .album: (2, group.name)
            case .folder(let url): (3, url.path)
            }
        }
        return (byPlace.map { Self(kind: $0.key.map(Kind.folder) ?? .unsorted, tracks: $0.value) } + albumGroups)
            .sorted { a, b in
                let (ra, sa) = rank(a), (rb, sb) = rank(b)
                if ra != rb { return ra < rb }
                let order = sa.localizedStandardCompare(sb)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
    }
    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) }
    /// Disc, then track number; tracks without numbers follow in their registered order.
    private static func albumOrder(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        tracks.enumerated().sorted { a, b in
            let x = (a.element.tags?.disc ?? 1, a.element.tags?.track ?? Int.max, a.offset)
            let y = (b.element.tags?.disc ?? 1, b.element.tags?.track ?? Int.max, b.offset)
            return x < y
        }.map(\.element)
    }
    /// Groups every track first and then leaves out the hidden ones, so hiding tracks never moves
    /// the rest into another group. A group with no visible track is left out.
    static func groups(_ tracks: [LibraryTrack], hiding hidden: Set<UUID>) -> [Self] {
        guard !hidden.isEmpty else { return groups(tracks) }
        return groups(tracks).compactMap { group in
            let visible = group.tracks.filter { !hidden.contains($0.id) }
            return visible.isEmpty ? nil : Self(kind: group.kind, tracks: visible, showsArtist: group.showsArtist)
        }
    }
}

struct SourceFolderList: View {
    let tracks: [LibraryTrack]
    let unavailable: [UUID: String]
    var canRemove = true
    let select: (UUID) -> Void
    var removeFolder: (SourceFolderGroup) -> Void = { _ in }
    var body: some View {
        SourceFolderSections(tracks: tracks, removeFolder: canRemove ? removeFolder : nil) { track in
            Button { select(track.id) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        OverflowTitle(name: track.name)
                        Text(unavailable[track.id] ?? track.reference.lastKnownURL.pathExtension.uppercased())
                            .font(.ui(11)).foregroundStyle(unavailable[track.id] == nil ? Color.white.opacity(0.55) : .orange).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.ui(11)).foregroundStyle(.secondary)
                }.frame(minHeight: 40).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

/// Share folder identity, order and disclosure behavior across source and add screens.
struct SourceFolderSections<Row: View>: View {
    let tracks: [LibraryTrack]
    /// Shows a remove button on real folders. The default group has none against mistaken taps.
    var removeFolder: ((SourceFolderGroup) -> Void)? = nil
    /// Tracks left out of the list, such as those already in the playlist being added to.
    var hidden: Set<UUID> = []
    @ViewBuilder var row: (LibraryTrack) -> Row
    @State private var expanded: Set<String> = []
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(SourceFolderGroup.groups(tracks, hiding: hidden)) { group in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group.id) }, set: { open in
                    if open { expanded.insert(group.id) } else { expanded.remove(group.id) }
                })) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.tracks) { track in
                            row(track)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.isAlbum ? "opticaldisc" : "folder").foregroundStyle(.white.opacity(0.6))
                        OverflowTitle(name: group.name).fontWeight(.medium)
                        Spacer(minLength: 4)
                        Text("\(group.tracks.count)曲").font(.ui(11)).foregroundStyle(.secondary)
                        if let removeFolder, group.isRemovable {
                            Button { removeFolder(group) } label: {
                                Image(systemName: "trash").font(.ui(11)).frame(width: 24, height: 24).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.55))
                                .accessibilityLabel("\(group.kindName)「\(group.name)」を除外").help("\(group.kindName)「\(group.name)」を除外")
                                .padding(.vertical, -4)
                        }
                    }
                }.tint(.white.opacity(0.6))
            }
            if tracks.isEmpty { Text("ファイルやフォルダを登録してください。").foregroundStyle(.secondary).padding(.vertical, 16) }
            else if tracks.allSatisfy({ hidden.contains($0.id) }) { Text("未追加の曲はありません。").foregroundStyle(.secondary).padding(.vertical, 16) }
        }
    }
}
