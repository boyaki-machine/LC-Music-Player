import SwiftUI
import PlaybackCore
import LibraryCore

@MainActor public struct LibraryActions {
    public var files: (UUID?) -> Void
    public var folder: () -> Void
    public var repair: (UUID) -> Void
    public var importPlaylist: () -> Void
    public var exportPlaylist: (UUID) -> Void
    public init(files: @escaping (UUID?) -> Void, folder: @escaping () -> Void, repair: @escaping (UUID) -> Void,
                importPlaylist: @escaping () -> Void, exportPlaylist: @escaping (UUID) -> Void) {
        self.files = files; self.folder = folder; self.repair = repair
        self.importPlaylist = importPlaylist; self.exportPlaylist = exportPlaylist
    }
}

public struct ExtensionView: View {
    let playback: PlaybackController
    let library: LibraryController
    @Bindable var presentation: PlayerPresentation
    let actions: LibraryActions
    let showAcknowledgements: () -> Void
    let resizeExtension: (CGFloat) -> Void
    @State private var screen: Screen = .list
    @State private var browsingID: UUID?
    @State private var sourceID: UUID?
    @State private var originID: UUID?
    @State private var name = ""
    @State private var checked: Set<UUID> = []
    @State private var confirmPlaylist: UUID?
    @State private var confirmSource: UUID?
    @State private var confirmFolder: SourceFolderGroup?
    @State private var rowDrag: RowDrag?
    @State private var reveal = UUID()
    private enum Screen { case list, chooser, manage, create, rename, add }
    private struct RowDrag { let entryID: UUID; let index: Int; var offset: CGFloat }
    public init(playback: PlaybackController, presentation: PlayerPresentation, library: LibraryController, actions: LibraryActions,
                resizeExtension: @escaping (CGFloat) -> Void = { _ in }, showAcknowledgements: @escaping () -> Void = {}) {
        self.playback = playback; self.presentation = presentation; self.library = library; self.actions = actions
        self.resizeExtension = resizeExtension
        self.showAcknowledgements = showAcknowledgements
    }
    /// One card per visualization design: thumbnail, title and tagline. The chosen card is outlined in green.
    private func designCard(_ design: VisualizationDesign) -> some View {
        let selected = presentation.visualizationDesign == design
        let accent = Color(red: 0.45, green: 0.95, blue: 0.36)
        return Button { presentation.setVisualizationDesign(design) } label: {
            HStack(spacing: 10) {
                VisualizationThumbnail(design: design).frame(width: 64, height: 48).clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 3) {
                    Text(design.title).font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? accent : Color.white.opacity(0.92))
                    // The tagline may wrap to a second line.
                    Text(design.tagline).font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(selected ? accent.opacity(0.9) : Color.white.opacity(0.72))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.16, green: 0.28, blue: 0.38)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accent : Color.white.opacity(0.1), lineWidth: selected ? 2.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(design.title).accessibilityValue(design.tagline)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var viewed: MusicPlaylist? { library.playlist(browsingID) ?? library.currentPlaylist ?? library.document.playlists.first }
    private var indicator: Color {
        playback.state == .playing ? Color(red: 0.62, green: 0.91, blue: 0.74) : playback.state == .paused ? Color(red: 0.88, green: 0.76, blue: 0.55) : Color(white: 0.7)
    }
    private var currentWord: String { playback.state == .playing ? "再生中" : playback.state == .paused ? "一時停止" : "選択中" }
    public var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(ExtensionSection.allCases, id: \.self) { section in
                    Button {
                        presentation.section = section
                        if section == .playlist { openCurrent() }
                        else if section == .source { sourceID = nil; originID = nil }
                    } label: {
                        Text(section.rawValue).font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 6)
                            .overlay(alignment: .bottom) { if presentation.section == section { Rectangle().fill(Color(red: 0.66, green: 0.85, blue: 0.74)).frame(height: 1) } }
                    }.buttonStyle(.plain).foregroundStyle(presentation.section == section ? Color.white.opacity(0.9) : Color.white.opacity(0.6))
                        .accessibilityLabel(section.rawValue).accessibilityAddTraits(presentation.section == section ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                switch presentation.section {
                case .playlist: playlistContent
                case .source: sourceContent
                case .visualization:
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(VisualizationDesign.allCases, id: \.self) { designCard($0) }
                        }.padding(.vertical, 2).padding(.horizontal, 1)
                    }.accessibilityIdentifier("visualizationDesign")
                case .settings:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("再生と表示")
                            Toggle("曲ごとの音量をそろえる", isOn: Binding(get: { library.normalizesVolume },
                                set: { library.setNormalizesVolume($0) }))
                            Text("曲全体の音量とピークを測定して補正します。未測定の曲は再生前に待ちます。設定変更時は一時停止します。")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if library.normalizesVolume {
                                Picker("目標音量", selection: Binding(get: { library.normalizationSettings.targetLUFS },
                                    set: { library.setNormalizationTarget($0) })) {
                                    Text("基準 −23 LUFS").tag(-23.0)
                                    Text("−18 LUFS").tag(-18.0)
                                    Text("−16 LUFS").tag(-16.0)
                                }
                                switch library.levelMeasurement {
                                case .disabled: EmptyView()
                                case .pending: Text("音量補正：未測定／準備待ち").foregroundStyle(.secondary)
                                case .failed: Text("音量を測定できません。対象曲を選び直して再試行してください。").foregroundStyle(.orange)
                                case .complete(let result):
                                    Text(result.levels.loudness.value.map { String(format: "全曲音量：%.1f LUFS", $0) } ?? "全曲音量：無音／測定対象外")
                                    Text(result.levels.truePeak == 0 ? "ピーク：無音" : String(format: "ピーク：%.1f dBTP", result.levels.truePeakDBTP))
                                }
                                if let plan = playback.normalizationPlan {
                                    Text(String(format: "補正：%+.1f dB", plan.gainDB))
                                    if plan.constraint == .peakLimited || plan.constraint == .boostLimited {
                                        Text("ピークまたは増幅上限により、目標より小さく再生します。")
                                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            Toggle("最大音量を測定", isOn: Binding(get: { library.measuresMaximumVolume },
                                set: { library.setMeasuresMaximumVolume($0) }))
                            Text("最大サンプル音量を表示します。リストの曲は背景でも測定し、再生音量は変更しません。")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            switch library.peakMeasurement {
                            case .disabled: EmptyView()
                            case .pending: Text("最大音量：未測定／測定待ち").foregroundStyle(.secondary)
                            case .complete(let peak):
                                Text(peak.samplePeak == 0 ? "最大音量：無音" : String(format: "最大音量：%.1f dBFS", peak.peakDBFS))
                            case .failed: Text("最大音量を測定できませんでした。").foregroundStyle(.secondary)
                            }
                            Text("音量はアプリ内の再生音量です。出力はmacOSの既定デバイスを使用します。")
                                .fixedSize(horizontal: false, vertical: true)
                            Text("⌘O 音源登録 · Space 再生／一時停止\n⌘M 最小化 · ⌘W 閉じる · ⌘Q 終了")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Divider()
                            Text("このアプリについて")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppVersion.displayName)
                                Text("バージョン \(AppVersion.text())").foregroundStyle(.secondary)
                            }.textSelection(.enabled).accessibilityElement(children: .combine).accessibilityIdentifier("appVersion")
                            AcknowledgementsButton(action: showAcknowledgements)
                                .frame(height: 24)

                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if library.isPreparing { Text(library.preparationStage ?? "再生を準備しています…").font(.system(size: 11)) }
            if library.isBusy { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("音源を登録しています…").font(.system(size: 11)) } }
            if let notice = library.error ?? library.message ?? playback.error?.localizedDescription {
                HStack(alignment: .top, spacing: 4) {
                    Text(notice).font(.system(size: 11)).foregroundStyle(library.error == nil ? Color.white.opacity(0.6) : .orange).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if library.editsEnabled, library.error != nil || library.message != nil {
                        Button { library.clearNotice() } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).accessibilityLabel("通知を閉じる")
                    }
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PlayerGlassBackground()).foregroundStyle(.white.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
            .overlay(alignment: .bottom) { ExtensionResizeHandle(resize: resizeExtension).frame(height: 10).padding(.horizontal, 12) }
            .preferredColorScheme(.dark)
            .onChange(of: presentation.extensionVisible) { _, visible in if visible { openCurrent() } }
            .confirmationDialog("プレイリストを削除しますか？音源は残ります。", isPresented: Binding(get: { confirmPlaylist != nil }, set: { if !$0 { confirmPlaylist = nil } })) {
                Button("プレイリストを削除", role: .destructive) { if let id = confirmPlaylist { library.deletePlaylist(id) }; confirmPlaylist = nil }
            }
            .confirmationDialog("ライブラリと各プレイリストから除外します。元ファイルは削除しません。", isPresented: Binding(get: { confirmSource != nil }, set: { if !$0 { confirmSource = nil } })) {
                Button("ライブラリから除外", role: .destructive) { if let id = confirmSource { library.excludeTrack(id) }; confirmSource = nil; sourceID = nil }
            }
            .confirmationDialog("「\(confirmFolder?.name ?? "")」の\(confirmFolder?.tracks.count ?? 0)曲を、ライブラリと各プレイリストから除外します。元ファイルは削除しません。",
                                isPresented: Binding(get: { confirmFolder != nil }, set: { if !$0 { confirmFolder = nil } })) {
                Button("フォルダを除外", role: .destructive) { if let group = confirmFolder { library.excludeTracks(group.tracks.map(\.id)) }; confirmFolder = nil }
            }
        }
    }
    private func openCurrent() {
        browsingID = library.document.currentPlaylistID ?? library.document.playlists.first?.id
        screen = .list; sourceID = nil; reveal = UUID()
    }
    private func scrolled<Content: View>(revealID: UUID? = nil, rowIndex: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        ScrollView { content().frame(maxWidth: .infinity, alignment: .leading).background(RefinedScrollStyle(revealID: revealID, rowIndex: rowIndex)) }
    }
    private func header(_ title: String, back: @escaping () -> Void) -> some View {
        HStack(spacing: 14) { Button(action: back) { Label("戻る", systemImage: "chevron.left") }.buttonStyle(.plain); Text(title).fontWeight(.medium).lineLimit(1); Spacer(minLength: 0) }
    }
    @ViewBuilder private var playlistContent: some View {
        switch screen {
        case .list:
            HStack(spacing: 0) {
                Text(viewed?.id == library.document.currentPlaylistID ? "現在の再生リスト" : "プレイリスト").fontWeight(.medium); Spacer()
                // Playback mode toggles (a future repeat joins here), spaced apart against mistaken taps.
                HStack(spacing: 12) {
                    ShuffleToggle(isOn: library.shufflesPlayback) { library.setShufflesPlayback(!library.shufflesPlayback) }
                }.padding(.trailing, 14)
                Text("\(viewed?.entries.count ?? 0)曲").foregroundStyle(.secondary)
            }
            HStack {
                Button { screen = .chooser } label: { HStack { Text(viewed?.name ?? "リストを選択").lineLimit(1); Spacer(); Image(systemName: "chevron.right") } }.buttonStyle(.plain)
                Button("管理") { screen = .manage }.buttonStyle(.plain)
            }.padding(.vertical, 5)
                scrolled(revealID: reveal, rowIndex: viewed?.id == library.document.currentPlaylistID ? library.currentIndex : nil) {
                    LazyVStack(spacing: 2) {
                        if let list = viewed {
                            ForEach(Array(list.entries.enumerated()), id: \.element.id) { i, entry in
                                if let track = library.track(entry.trackID) { playlistRow(track, entry: entry, index: i, list: list).id(entry.id) }
                            }
                            if list.entries.isEmpty { Text("曲がありません。「曲を追加」から登録できます。").foregroundStyle(.secondary).padding(.vertical, 16) }
                        } else { Text("管理からプレイリストを作成してください。").foregroundStyle(.secondary).padding(.vertical, 16) }
                    }
                }
            HStack(spacing: 8) {
                Button { checked = []; screen = .add } label: { Label("曲を追加", systemImage: "plus") }.disabled(viewed == nil || !library.canEdit)
                if let list = viewed, !list.entries.isEmpty, list.id != library.document.currentPlaylistID || library.currentEntry == nil {
                    Button { library.playPlaylist(list.id) } label: { Label("このリストを再生", systemImage: "play.fill") }.disabled(!library.canEdit)
                }
            }.buttonStyle(SoftGlassButtonStyle())
        case .chooser:
            header("プレイリストを選択") { screen = .list }
            scrolled {
                VStack(spacing: 0) {
                    ForEach(library.document.playlists) { list in
                        Button { browsingID = list.id; screen = .list } label: { HStack { Text(list.name).lineLimit(1); Spacer(); Text("\(list.entries.count)曲").foregroundStyle(.secondary) }.padding(.vertical, 10) }.buttonStyle(.plain)
                        Divider().overlay(.white.opacity(0.08))
                    }
                }
            }
        case .manage:
            header("プレイリストを管理") { screen = .list }
            scrolled {
                VStack(spacing: 6) {
                    ForEach(library.document.playlists) { list in
                        HStack {
                            Button { browsingID = list.id; screen = .list } label: { Text(list.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                            smallButton("pencil", "\(list.name)の名前を変更") { browsingID = list.id; name = list.name; screen = .rename }
                            smallButton("trash", "\(list.name)を削除") { confirmPlaylist = list.id }
                        }.padding(.vertical, 5).disabled(!library.canEdit)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button { name = ""; screen = .create } label: { Label("プレイリストを作成", systemImage: "text.badge.plus") }.disabled(!library.canEdit)
                HStack(spacing: 8) {
                    Button("M3U8を読み込む…", action: actions.importPlaylist).disabled(!library.canEdit)
                    Button("書き出す…") { if let id = viewed?.id { actions.exportPlaylist(id) } }.disabled(viewed == nil || !library.canEdit)
                }
            }.buttonStyle(SoftGlassButtonStyle())
        case .create, .rename:
            header(screen == .create ? "新しいプレイリスト" : "名前を変更") { screen = .manage }
            VStack(alignment: .leading, spacing: 12) {
                Text("プレイリスト名").foregroundStyle(.secondary)
                TextField("例：週末のドライブ", text: $name).textFieldStyle(.roundedBorder).onSubmit(saveName)
                HStack {
                    Button("キャンセル") { screen = .manage }
                    Button(screen == .create ? "作成" : "変更", action: saveName).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !library.canEdit)
                }.buttonStyle(SoftGlassButtonStyle())
            }.padding(.top, 12)
            Spacer(minLength: 0)
        case .add:
            header("「\(viewed?.name ?? "")」へ曲を追加") { screen = .list }
            Text("ライブラリから選択").foregroundStyle(.secondary)
            scrolled {
                SourceFolderSections(tracks: library.document.tracks) { track in
                    let added = viewed?.entries.contains(where: { $0.trackID == track.id }) == true
                    PlaylistTrackChoice(name: track.name, added: added,
                        selected: Binding(get: { checked.contains(track.id) }, set: { if $0 { checked.insert(track.id) } else { checked.remove(track.id) } }))
                        .frame(minHeight: 32)
                        .disabled(library.unavailable[track.id] != nil || !library.canEdit)
                }.padding(.vertical, 3)
            }
            HStack(spacing: 8) {
                Button { actions.files(viewed?.id) } label: { Label("ファイルから…", systemImage: "folder") }.disabled(!library.canEdit)
                Button("選んだ\(checked.count)曲を追加") {
                    if let id = viewed?.id { library.addTracks(library.document.tracks.filter { checked.contains($0.id) }.map(\.id), to: id); if library.error == nil { screen = .list } }
                }.disabled(checked.isEmpty || !library.canEdit)
            }.buttonStyle(SoftGlassButtonStyle())
        }
    }
    private func saveName() {
        if screen == .create {
            if let id = library.createPlaylist(name) { browsingID = id; screen = .list }
        } else if let id = viewed?.id { library.renamePlaylist(id, name: name); if library.error == nil { screen = .list } }
    }
    private func smallButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
    private func playlistRow(_ track: LibraryTrack, entry: PlaylistEntry, index: Int, list: MusicPlaylist) -> some View {
        let current = entry.id == library.document.currentEntryID
        let missing = library.unavailable[track.id] != nil
        let dragged = rowDrag?.entryID == entry.id
        let target = rowDrag.map { PlaylistReorder.target(from: $0.index, offset: $0.offset, count: list.entries.count) }
        let insertion: Alignment? = rowDrag.flatMap { drag in
            guard !dragged, target == index else { return nil }
            return drag.index < index ? .bottom : .top
        }
        return HStack(spacing: 6) {
            Text(current ? (playback.state == .playing ? "▸" : playback.state == .paused ? "Ⅱ" : "•") : String(format: "%02d", index + 1)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Button {
                activatePlaylistRow(track, entry: entry, list: list, clickCount: 1)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    OverflowTitle(name: track.name).foregroundStyle(current ? indicator : .white.opacity(0.85))
                        .shadow(color: current && playback.state == .playing ? indicator.opacity(0.45) : .clear, radius: 4)
                    HStack(spacing: 5) {
                        Text(missing ? "ファイルが見つからないか、アクセスできません" : track.reference.lastKnownURL.pathExtension.uppercased())
                            .foregroundStyle(missing ? Color.orange.opacity(0.85) : .white.opacity(0.55)).lineLimit(1)
                        if current { Text(currentWord).foregroundStyle(indicator).fixedSize() }
                    }.font(.system(size: 11))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("\(track.name)\(current ? "、\(currentWord)" : "")\(missing ? "、音源を確認" : "")")
                .overlay(PlaylistClickSurface(entryID: entry.id, drag: library.canEdit && list.entries.count > 1 ? { phase in
                    dragRow(phase, entry: entry, index: index, list: list)
                } : nil) { count in
                    activatePlaylistRow(track, entry: entry, list: list, clickCount: count)
                }.accessibilityHidden(true))
            PlaylistRowActions(name: track.name, canMoveUp: index > 0 && library.canEdit,
                               canMoveDown: index + 1 < list.entries.count && library.canEdit, canRemove: library.canEdit,
                               moveUp: { library.moveEntry(entry.id, in: list.id, offset: -1) },
                               moveDown: { library.moveEntry(entry.id, in: list.id, offset: 1) },
                               remove: { library.removeEntry(entry.id, from: list.id) })
                .frame(width: 72, height: 32)
        }.frame(height: 44).padding(.horizontal, 3)
            .overlay(alignment: .leading) { if current { RoundedRectangle(cornerRadius: 1).fill(indicator.opacity(playback.state == .playing ? 0.55 : 0.3)).frame(width: 2, height: 22) } }
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
            // The lifted row is opaque so the row it passes over does not show through.
            .background { if dragged { RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.27)).shadow(color: .black.opacity(0.4), radius: 6, y: 2) } }
            .overlay(alignment: insertion ?? .top) {
                // The insertion line sits in the 2pt gap between rows.
                if insertion != nil {
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.66, green: 0.85, blue: 0.74)).frame(height: 2)
                        .offset(y: insertion == .bottom ? 2 : -2).allowsHitTesting(false)
                }
            }
            .offset(y: dragged ? rowDrag?.offset ?? 0 : 0).zIndex(dragged ? 1 : 0)
    }
    private func dragRow(_ phase: PlaylistRowDrag, entry: PlaylistEntry, index: Int, list: MusicPlaylist) {
        switch phase {
        case .moved(let offset): rowDrag = RowDrag(entryID: entry.id, index: index, offset: offset)
        case .cancelled: rowDrag = nil
        case .ended(let offset):
            rowDrag = nil
            let target = PlaylistReorder.target(from: index, offset: offset, count: list.entries.count)
            if target != index { library.moveEntry(entry.id, in: list.id, to: PlaylistReorder.destination(from: index, target: target)) }
        }
    }
    private func activatePlaylistRow(_ track: LibraryTrack, entry: PlaylistEntry, list: MusicPlaylist, clickCount: Int) {
        if library.unavailable[track.id] != nil {
            originID = list.id; sourceID = track.id; presentation.section = .source
        } else { library.clickEntry(entry.id, in: list.id, clickCount: clickCount) }
    }
    @ViewBuilder private var sourceContent: some View {
        if let sourceID, let track = library.track(sourceID) {
            header("音源の確認") { self.sourceID = nil }
            scrolled {
                VStack(alignment: .leading, spacing: 10) {
                    Text(track.name).fontWeight(.medium).textSelection(.enabled)
                    Text(library.unavailable[sourceID] ?? "ファイルを参照できます").foregroundStyle(library.unavailable[sourceID] == nil ? Color.white.opacity(0.6) : .orange)
                    Text(track.reference.lastKnownURL.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 6) {
                        Button { actions.repair(sourceID) } label: { Label("ファイルを再選択…", systemImage: "folder") }
                        Button { confirmSource = sourceID } label: { Label("ライブラリから除外", systemImage: "trash") }
                    }.buttonStyle(SoftGlassButtonStyle()).disabled(!library.canEdit)
                    Text("除外すると各リストの参照も外れます。元ファイルは削除しません。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if originID != nil {
                Button { browsingID = originID; self.sourceID = nil; presentation.section = .playlist; screen = .list } label: { Label("リストへ戻る", systemImage: "chevron.left") }.buttonStyle(SoftGlassButtonStyle())
            }
        } else {
            HStack { Text("ライブラリ").fontWeight(.medium); Spacer(); Text("\(library.document.tracks.count)曲").foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                Button { actions.files(nil) } label: { Label("ファイルを登録…", systemImage: "doc.badge.plus") }
                Button(action: actions.folder) { Label("フォルダを登録…", systemImage: "folder.badge.plus") }
            }.buttonStyle(SoftGlassButtonStyle()).disabled(!library.canEdit)
            scrolled {
                SourceFolderList(tracks: library.document.tracks, unavailable: library.unavailable, canRemove: library.canEdit,
                                 select: { id in sourceID = id; originID = nil }, removeFolder: { confirmFolder = $0 })
            }
        }
    }
}
