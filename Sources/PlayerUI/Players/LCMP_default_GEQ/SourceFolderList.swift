import SwiftUI
import LibraryCore
import PlaybackCore

struct SourceFolderGroup: Identifiable {
    var id: String { directory?.absoluteString ?? "default" }
    let directory: URL?
    let tracks: [LibraryTrack]
    var name: String {
        guard let directory else { return "デフォルト" }
        if directory.scheme == SupportedAudio.mediaLibraryScheme { return "ミュージック" }
        return directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent
    }
    /// A parent folder becomes a group when it holds a folder-registered track or two or more
    /// tracks. A file registered alone stays in the default group until another track from its
    /// folder arrives. Only the display changes; the stored registration does not.
    /// All Music library songs share one group; their asset URLs differ only in the ID query.
    private static let mediaLibraryFolder = URL(string: "\(SupportedAudio.mediaLibraryScheme)://item/")!
    private static func folder(of track: LibraryTrack) -> URL {
        track.reference.mediaItemID != nil ? mediaLibraryFolder : track.reference.lastKnownURL.deletingLastPathComponent().standardizedFileURL
    }
    static func groups(_ tracks: [LibraryTrack]) -> [Self] {
        let byFolder = Dictionary(grouping: tracks, by: folder(of:))
        // Music library songs always form their own group, even a single one.
        let folders = Set(byFolder.filter { folder, members in
            folder.scheme == SupportedAudio.mediaLibraryScheme || members.count > 1 || members.contains { $0.registration == .folder }
        }.keys)
        return Dictionary(grouping: tracks) { track -> URL? in
            let folder = folder(of: track)
            return folders.contains(folder) ? folder : nil
        }
            .map { Self(directory: $0.key, tracks: $0.value) }
            .sorted { ($0.directory?.path ?? "").localizedStandardCompare($1.directory?.path ?? "") == .orderedAscending }
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
    @ViewBuilder var row: (LibraryTrack) -> Row
    @State private var expanded: Set<String> = []
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(SourceFolderGroup.groups(tracks)) { group in
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
                        Image(systemName: "folder").foregroundStyle(.white.opacity(0.6))
                        OverflowTitle(name: group.name).fontWeight(.medium)
                        Spacer(minLength: 4)
                        Text("\(group.tracks.count)曲").font(.ui(11)).foregroundStyle(.secondary)
                        if let removeFolder, group.directory != nil {
                            Button { removeFolder(group) } label: {
                                Image(systemName: "trash").font(.ui(11)).frame(width: 24, height: 24).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.55))
                                .accessibilityLabel("フォルダ「\(group.name)」を除外").help("フォルダ「\(group.name)」を除外")
                                .padding(.vertical, -4)
                        }
                    }
                }.tint(.white.opacity(0.6))
            }
            if tracks.isEmpty { Text("ファイルやフォルダを登録してください。").foregroundStyle(.secondary).padding(.vertical, 16) }
        }
    }
}
