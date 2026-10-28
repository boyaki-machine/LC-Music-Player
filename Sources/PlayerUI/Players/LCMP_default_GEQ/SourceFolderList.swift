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
    /// Shows only the tracks that match, with their groups open.
    var query = ""
    /// The tracks chosen in selection mode; nil outside it. Rows then choose instead of opening.
    var selection: Binding<Set<UUID>>? = nil
    /// Shared with the screen, which counts the matches from the same result.
    var catalog: SourceCatalogCache? = nil
    var marks = SourceMarks()
    let select: (UUID) -> Void
    var removeFolder: (SourceFolderGroup) -> Void = { _ in }
    var removeTrack: (LibraryTrack) -> Void = { _ in }
    /// Room kept free at the right for the scroll bar, so that scrolling never presses a remove button.
    /// The overlay scroller of macOS draws thin but takes clicks across its whole width.
    #if os(macOS)
    static let scrollerClearance = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) + 2
    #else
    static let scrollerClearance: CGFloat = 12
    #endif
    /// The width of the disclosure chevron at the right of a track; group rows keep the same room so
    /// that every remove button lines up.
    static let chevronWidth: CGFloat = 12
    var body: some View {
        SourceFolderSections(tracks: tracks, removeFolder: canRemove && selection == nil ? removeFolder : nil, query: query,
                             selection: selection, catalog: catalog, trailing: Self.chevronWidth) { track in
            if let selection {
                let chosen = selection.wrappedValue.contains(track.id)
                Button {
                    if chosen { selection.wrappedValue.remove(track.id) } else { selection.wrappedValue.insert(track.id) }
                } label: {
                    HStack(spacing: 8) { SourceCheckbox(state: chosen ? .all : .none); details(track); Spacer(minLength: 4) }
                        .frame(minHeight: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(track.name).accessibilityAddTraits(chosen ? .isSelected : [])
            } else {
                HStack(spacing: 0) {
                    Button { select(track.id) } label: {
                        HStack { details(track); Spacer(minLength: 4) }.frame(minHeight: 40).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if canRemove { SourceRemoveButton(label: "「\(track.name)」を除外") { removeTrack(track) } }
                    Button { select(track.id) } label: {
                        Image(systemName: "chevron.right").font(.ui(11)).foregroundStyle(.secondary)
                            .frame(width: Self.chevronWidth, height: 40, alignment: .trailing).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHidden(true)
                }
            }
        }
        .padding(.trailing, Self.scrollerClearance)
    }
    private func details(_ track: LibraryTrack) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            OverflowTitle(name: track.name)
            if let reason = unavailable[track.id] {
                Text(reason).font(.ui(11)).foregroundStyle(.orange).lineLimit(1)
            } else {
                HStack(spacing: 4) {
                    Text(track.reference.lastKnownURL.pathExtension.uppercased())
                    if let count = marks.memberships[track.id] {
                        Text("· \(Image(systemName: "music.note.list"))\(count)").accessibilityLabel("\(count)つのリストに入っています")
                            .help("\(count)つのプレイリストに入っています")
                    }
                    if marks.duplicates.contains(track.id) {
                        Text("· 重複").foregroundStyle(Self.duplicateColor).help("同じ曲が別のファイルでも登録されています")
                    }
                }.font(.ui(11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
    }
    static let duplicateColor = Color(red: 0.93, green: 0.8, blue: 0.45).opacity(0.85)
}

/// The trash button of a group or a track.
struct SourceRemoveButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "trash").font(.ui(11)).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).accessibilityLabel(label).help(label)
    }
}

/// A checkbox that can also show a group whose tracks are only partly chosen.
struct SourceCheckbox: View {
    let state: SourceSelection.State
    var body: some View {
        Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
            .font(.ui(13)).foregroundStyle(state == .none ? Color.white.opacity(0.5) : ShuffleToggle.litColor)
    }
}

/// Share folder identity, order and disclosure behavior across source and add screens. Rows are laid
/// out lazily one by one, so that a search opening groups of thousands of tracks stays smooth.
struct SourceFolderSections<Row: View>: View {
    let tracks: [LibraryTrack]
    /// Shows a remove button on real folders. The default group has none against mistaken taps.
    var removeFolder: ((SourceFolderGroup) -> Void)? = nil
    /// Tracks left out of the list, such as those already in the playlist being added to.
    var hidden: Set<UUID> = []
    /// Shows only the tracks that match. Groups open while searching, until closed by hand.
    var query = ""
    /// Puts a checkbox before each group that chooses all its shown tracks.
    var selection: Binding<Set<UUID>>? = nil
    var catalog: SourceCatalogCache? = nil
    /// Room after the remove button, matching what the rows put there.
    var trailing: CGFloat = 0
    @ViewBuilder var row: (LibraryTrack) -> Row
    @State private var expanded: Set<String> = []
    @State private var closedWhileSearching: Set<String> = []
    @State private var ownCatalog = SourceCatalogCache()
    private enum Item: Identifiable {
        case group(SourceFolderGroup, open: Bool, first: Bool)
        case track(LibraryTrack, group: String)
        var id: String {
            switch self {
            case .group(let group, _, _): "g:" + group.id
            case .track(let track, let group): "t:\(group):\(track.id)"
            }
        }
    }
    var body: some View {
        let searching = !SourceCatalog.terms(query).isEmpty
        let groups = (catalog ?? ownCatalog).groups(tracks, matching: query, hiding: hidden)
        var items: [Item] = []
        for (index, group) in groups.enumerated() {
            let open = searching ? !closedWhileSearching.contains(group.id) : expanded.contains(group.id)
            items.append(.group(group, open: open, first: index == 0))
            if open { items += group.tracks.map { .track($0, group: group.id) } }
        }
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .group(let group, let open, let first): header(group, open: open, searching: searching).padding(.top, first ? 0 : 10)
                case .track(let track, _): row(track).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26)
                }
            }
            if tracks.isEmpty { Text("ファイルやフォルダを登録してください。").foregroundStyle(.secondary).padding(.vertical, 16) }
            else if groups.isEmpty {
                Text(searching ? "一致する曲はありません。" : "未追加の曲はありません。").foregroundStyle(.secondary).padding(.vertical, 16)
            }
        }
        .onChange(of: query) { closedWhileSearching = [] }
    }
    private func header(_ group: SourceFolderGroup, open: Bool, searching: Bool) -> some View {
        HStack(spacing: 6) {
            if let selection {
                Button { SourceSelection.toggle(group.tracks, in: &selection.wrappedValue) } label: {
                    SourceCheckbox(state: SourceSelection.state(of: group.tracks, in: selection.wrappedValue)).frame(width: 20, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(group.kindName)「\(group.name)」の\(group.tracks.count)曲を選択")
            }
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.ui(10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 14)
                Image(systemName: group.isAlbum ? "opticaldisc" : "folder").foregroundStyle(.white.opacity(0.6))
                OverflowTitle(name: group.name).fontWeight(.medium)
                Spacer(minLength: 4)
                Text("\(group.tracks.count)曲").font(.ui(11)).foregroundStyle(.secondary)
            }
            .frame(minHeight: 24).contentShape(Rectangle())
            .onTapGesture { toggle(group, open: open, searching: searching) }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? "開いています" : "閉じています")
            .accessibilityAction { toggle(group, open: open, searching: searching) }
            if let removeFolder, group.isRemovable {
                SourceRemoveButton(label: "\(group.kindName)「\(group.name)」を除外") { removeFolder(group) }
            }
        }.padding(.trailing, trailing)
    }
    private func toggle(_ group: SourceFolderGroup, open: Bool, searching: Bool) {
        if searching {
            if open { closedWhileSearching.insert(group.id) } else { closedWhileSearching.remove(group.id) }
        } else {
            if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
        }
    }
}
