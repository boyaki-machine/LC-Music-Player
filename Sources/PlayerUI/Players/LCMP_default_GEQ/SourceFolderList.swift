import SwiftUI
import LibraryCore

struct SourceFolderGroup: Identifiable {
    var id: String { directory?.absoluteString ?? "default" }
    let directory: URL?
    let tracks: [LibraryTrack]
    var name: String { directory.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent } ?? "デフォルト" }
    /// A parent folder becomes a group when it holds a folder-registered track or two or more
    /// tracks. A file registered alone stays in the default group until another track from its
    /// folder arrives. Only the display changes; the stored registration does not.
    static func groups(_ tracks: [LibraryTrack]) -> [Self] {
        let byFolder = Dictionary(grouping: tracks) { $0.reference.lastKnownURL.deletingLastPathComponent().standardizedFileURL }
        let folders = Set(byFolder.filter { _, members in members.count > 1 || members.contains { $0.registration == .folder } }.keys)
        return Dictionary(grouping: tracks) { track -> URL? in
            let folder = track.reference.lastKnownURL.deletingLastPathComponent().standardizedFileURL
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
                            .font(.system(size: 11)).foregroundStyle(unavailable[track.id] == nil ? Color.white.opacity(0.55) : .orange).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
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
                        Text("\(group.tracks.count)曲").font(.system(size: 11)).foregroundStyle(.secondary)
                        if let removeFolder, group.directory != nil {
                            Button { removeFolder(group) } label: {
                                Image(systemName: "trash").font(.system(size: 11)).frame(width: 24, height: 24).contentShape(Rectangle())
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
