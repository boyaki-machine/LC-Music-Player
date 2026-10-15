import Foundation
import Observation
import PlaybackCore
import OSLog

@Observable @MainActor public final class LibraryController {
    public private(set) var document = LibraryDocument()
    public private(set) var unavailable: [UUID: String] = [:]
    public private(set) var error: String?
    public private(set) var message: String?
    public private(set) var isBusy = false
    public private(set) var editsEnabled = true
    public let playback: PlaybackController
    @ObservationIgnored private let store: any LibraryPersistence
    @ObservationIgnored private let references: any FileReferenceProvider
    @ObservationIgnored private var pendingAdvance = false
    @ObservationIgnored private var shuttingDown = false

    public init(playback: PlaybackController, store: any LibraryPersistence = JSONLibraryStore(url: JSONLibraryStore.defaultURL),
                references: any FileReferenceProvider = BookmarkFileReferences()) {
        self.playback = playback; self.store = store; self.references = references
        do { document = try store.load(); message = store.recoveryMessage }
        catch { self.error = error.localizedDescription; editsEnabled = false }
        playback.onNaturalFinish = { [weak self] in
            guard let self else { return }
            if self.isBusy { self.pendingAdvance = true } else { self.move(1, autoPlay: true) }
        }
    }
    public var canEdit: Bool { editsEnabled && !isBusy }
    public var currentPlaylist: MusicPlaylist? { playlist(document.currentPlaylistID) }
    public var currentEntry: PlaylistEntry? { currentPlaylist?.entries.first { $0.id == document.currentEntryID } }
    public var currentTrack: LibraryTrack? { currentEntry.flatMap { track($0.trackID) } }
    public var currentIndex: Int? { currentPlaylist?.entries.firstIndex { $0.id == document.currentEntryID } }
    public var canPrevious: Bool { canEdit && (currentIndex ?? 0) > 0 }
    public var canNext: Bool { canEdit && currentIndex.map { $0 + 1 < (currentPlaylist?.entries.count ?? 0) } == true }
    public func playlist(_ id: UUID?) -> MusicPlaylist? { document.playlists.first { $0.id == id } }
    public func track(_ id: UUID) -> LibraryTrack? { document.tracks.first { $0.id == id } }
    public func clearNotice() { message = nil; if editsEnabled { error = nil } }

    @discardableResult private func commit(_ next: LibraryDocument) -> Bool {
        guard editsEnabled else { return false }
        do {
            try next.validate(); try store.save(next)
            let oldEntry = document.currentEntryID
            document = next; error = nil
            let trackIDs = Set(next.tracks.map(\.id))
            unavailable = unavailable.filter { id, _ in trackIDs.contains(id) }
            if oldEntry != nil && next.currentEntryID != oldEntry { playback.close() }
            return true
        } catch { self.error = "保存できませんでした。\(error.localizedDescription)"; return false }
    }
    @discardableResult public func createPlaylist(_ name: String) -> UUID? {
        guard canEdit, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var next = document
        let list = MusicPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines)); next.playlists.append(list)
        if next.currentPlaylistID == nil { next.currentPlaylistID = list.id }
        return commit(next) ? list.id : nil
    }
    public func renamePlaylist(_ id: UUID, name: String) {
        guard canEdit, let i = document.playlists.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
        var next = document; next.playlists[i].name = name; _ = commit(next)
    }
    public func deletePlaylist(_ id: UUID) {
        guard canEdit else { return }
        var next = document; next.playlists.removeAll { $0.id == id }
        if next.currentPlaylistID == id { next.currentPlaylistID = nil; next.currentEntryID = nil }
        _ = commit(next)
    }
    public func addTracks(_ ids: [UUID], to playlistID: UUID) {
        guard canEdit, let i = document.playlists.firstIndex(where: { $0.id == playlistID }),
              ids.allSatisfy({ track($0) != nil }) else { return }
        var next = document; next.playlists[i].entries += ids.map { PlaylistEntry(trackID: $0) }; _ = commit(next)
    }
    public func removeEntry(_ id: UUID, from playlistID: UUID) {
        guard canEdit, let i = document.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var next = document; next.playlists[i].entries.removeAll { $0.id == id }
        if next.currentEntryID == id { next.currentEntryID = nil }
        if commit(next) { message = "曲をリストから外しました。" }
    }
    public func moveEntry(_ id: UUID, in playlistID: UUID, offset: Int) {
        guard canEdit, let i = document.playlists.firstIndex(where: { $0.id == playlistID }),
              let from = document.playlists[i].entries.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset; guard document.playlists[i].entries.indices.contains(to) else { return }
        var next = document; next.playlists[i].entries.swapAt(from, to); _ = commit(next)
    }
    public func excludeTrack(_ id: UUID) {
        guard canEdit else { return }
        var next = document
        if currentTrack?.id == id { next.currentEntryID = nil }
        next.tracks.removeAll { $0.id == id }
        for i in next.playlists.indices { next.playlists[i].entries.removeAll { $0.trackID == id } }
        _ = commit(next)
    }
    public func repairTrack(_ id: UUID, using url: URL) {
        guard canEdit, let i = document.tracks.firstIndex(where: { $0.id == id }) else { return }
        do {
            guard SupportedAudio.accepts(url) else { throw PlaybackError.unsupportedFormat }
            var next = document; next.tracks[i].reference = try references.makeReference(url)
            if commit(next) {
                unavailable[id] = nil
                if currentTrack?.id == id, playback.state == .empty,
                   let list = document.currentPlaylistID, let entry = document.currentEntryID {
                    selectEntry(entry, in: list)
                }
                message = "ファイル参照を更新しました。"
            }
        } catch { self.error = error.localizedDescription }
    }
    public func restore() {
        refreshAvailability()
        if let list = document.currentPlaylistID, let entry = document.currentEntryID { selectEntry(entry, in: list) }
    }
    /// Readability is transient. A missing file never removes a persisted entry.
    public func refreshAvailability() {
        guard !isBusy else { return }
        var next = document
        for i in next.tracks.indices {
            let t = next.tracks[i]
            do {
                let resolved = try references.resolve(t.reference)
                next.tracks[i].reference = resolved.reference; unavailable[t.id] = nil
                withExtendedLifetime(resolved.lease) {}
            } catch { unavailable[t.id] = "ファイルが見つからないか、アクセスできません。" }
        }
        if next != document && editsEnabled { _ = commit(next) }
    }
    @discardableResult public func selectEntry(_ entryID: UUID, in playlistID: UUID, autoPlay: Bool = false) -> Bool {
        guard canEdit, let entry = playlist(playlistID)?.entries.first(where: { $0.id == entryID }), let track = track(entry.trackID) else { return false }
        do {
            let resolved = try references.resolve(track.reference)
            var next = document; next.currentPlaylistID = playlistID; next.currentEntryID = entryID
            if let i = next.tracks.firstIndex(where: { $0.id == track.id }) { next.tracks[i].reference = resolved.reference }
            // Decoder and file lease are prepared first; disk failure keeps the old audio intact.
            let success = playback.select(resolved.url, using: resolved.lease) { if next != document { try store.save(next) } }
            guard success else { self.error = playback.error?.localizedDescription; return false }
            document = next; unavailable[track.id] = nil; error = nil; message = nil
            if autoPlay { playback.togglePlayPause(using: resolved.lease) }
            return true
        } catch {
            unavailable[track.id] = "ファイルが見つからないか、アクセスできません。"
            self.error = error.localizedDescription; return false
        }
    }
    public func playPlaylist(_ id: UUID) {
        if let entry = playlist(id)?.entries.first { selectEntry(entry.id, in: id, autoPlay: true) }
    }
    public func togglePlayPause() {
        if playback.state == .playing || playback.state == .paused { playback.togglePlayPause(); return }
        guard let current = currentTrack, let list = document.currentPlaylistID, let entry = document.currentEntryID else { return }
        do {
            let resolved = try references.resolve(current.reference)
            if playback.selectedURL == resolved.url {
                // Keep an idle/paused seek that has already been prepared by PlaybackCore.
                playback.togglePlayPause(using: resolved.lease)
                error = playback.error?.localizedDescription
            } else { selectEntry(entry, in: list, autoPlay: true) }
        } catch {
            unavailable[current.id] = "ファイルが見つからないか、アクセスできません。"
            self.error = error.localizedDescription
        }
    }
    public func previous() { move(-1, autoPlay: playback.state == .playing) }
    public func next() { move(1, autoPlay: playback.state == .playing) }
    private func move(_ offset: Int, autoPlay: Bool) {
        guard let list = currentPlaylist, let i = currentIndex, list.entries.indices.contains(i + offset) else { return }
        selectEntry(list.entries[i + offset].id, in: list.id, autoPlay: autoPlay)
    }
    private func finishImport() {
        isBusy = false
        if pendingAdvance { pendingAdvance = false; if playback.state == .finished { move(1, autoPlay: true) } }
    }
    public func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        let logger = Logger(subsystem: "local.lcmp.player", category: "shutdown")
        let started = ContinuousClock.now
        logger.notice("Library shutdown: stopping playback")
        pendingAdvance = false; editsEnabled = false
        playback.onNaturalFinish = nil
        playback.close()
        logger.notice("Library shutdown finished after \(String(describing: started.duration(to: .now)), privacy: .public)")
    }
    public func importFiles(_ selections: [URL], into playlistID: UUID? = nil) async {
        guard canEdit else { return }; isBusy = true; error = nil
        let scopes = selections.map { references.beginAccess($0) }
        defer { withExtendedLifetime(scopes) {}; finishImport() }
        do {
            let urls = try await Task.detached(priority: .userInitiated) { try AudioDiscovery.files(in: selections) }.value
            let folderRoots = selections.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            var next = document
            let ids = try await stage(urls.map { M3U8Item(url: $0) }, in: &next, allowMissing: false, folderRoots: folderRoots)
            if let playlistID {
                guard let i = next.playlists.firstIndex(where: { $0.id == playlistID }) else { throw LibraryFailure.invalidDocument }
                next.playlists[i].entries += ids.map { PlaylistEntry(trackID: $0) }
            }
            let skipped = error
            if commit(next) { error = skipped; message = "\(ids.count)曲を登録しました。" }
        } catch { self.error = error.localizedDescription }
    }
    private func stage(_ items: [M3U8Item], in next: inout LibraryDocument, allowMissing: Bool, folderRoots: [URL] = []) async throws -> [UUID] {
        var paths: [URL: UUID] = [:]
        for i in next.tracks.indices {
            if i % 32 == 0 { await Task.yield(); guard editsEnabled else { throw CancellationError() } }
            let t = next.tracks[i]
            if let resolved = try? references.resolve(t.reference) {
                next.tracks[i].reference = resolved.reference; paths[resolved.url.standardizedFileURL.resolvingSymlinksInPath()] = t.id
            } else { paths[t.reference.lastKnownURL.standardizedFileURL.resolvingSymlinksInPath()] = t.id }
        }
        var ids: [UUID] = [], failed = 0
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard editsEnabled else { throw CancellationError() }
            guard SupportedAudio.accepts(item.url) else { failed += 1; continue }
            let path = item.url.standardizedFileURL.resolvingSymlinksInPath()
            let fromFolder = folderRoots.contains { path.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
            if let id = paths[path] {
                if fromFolder, let i = next.tracks.firstIndex(where: { $0.id == id }) { next.tracks[i].registration = .folder }
                ids.append(id); continue
            }
            let reference: TrackReference
            do { reference = try references.makeReference(item.url) }
            catch {
                if !allowMissing { failed += 1; continue }
                reference = TrackReference(bookmark: nil, lastKnownURL: item.url)
            }
            let name = item.title?.isEmpty == false ? item.title! : item.url.deletingPathExtension().lastPathComponent
            let track = LibraryTrack(name: name, reference: reference, registration: fromFolder ? .folder : .file)
            next.tracks.append(track); paths[path] = track.id; ids.append(track.id)
            if reference.bookmark == nil { unavailable[track.id] = "ファイルが見つからないか、アクセスできません。" }
            if index % 32 == 0 { await Task.yield() }
        }
        if failed > 0 { self.error = "\(failed)件は形式またはアクセスを確認できず、登録していません。" }
        return ids
    }
    public func importM3U8(_ url: URL) async {
        guard url.isFileURL else { error = LibraryFailure.inaccessible.localizedDescription; return }
        guard canEdit else { return }; isBusy = true; error = nil
        let scope = references.beginAccess(url)
        defer { withExtendedLifetime(scope) {}; finishImport() }
        do {
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            let items = try M3U8.decode(data, relativeTo: url)
            var next = document
            let ids = try await stage(items, in: &next, allowMissing: true)
            next.playlists.append(MusicPlaylist(name: url.deletingPathExtension().lastPathComponent, entries: ids.map { PlaylistEntry(trackID: $0) }))
            let skipped = error
            if commit(next) { error = skipped; message = "M3U8から\(ids.count)曲のリストを読み込みました。" }
        } catch { self.error = error.localizedDescription }
    }
    public func exportM3U8(_ playlistID: UUID, to url: URL) {
        guard url.isFileURL else { error = LibraryFailure.inaccessible.localizedDescription; return }
        guard let list = playlist(playlistID), canEdit else { return }
        let scope = references.beginAccess(url)
        defer { withExtendedLifetime(scope) {} }
        do {
            let items = list.entries.compactMap { entry -> M3U8Item? in
                guard let t = track(entry.trackID) else { return nil }
                let resolved = try? references.resolve(t.reference)
                return M3U8Item(url: resolved?.url ?? t.reference.lastKnownURL, title: t.name)
            }
            try M3U8.encode(items, relativeTo: url).write(to: url, options: .atomic)
            message = "M3U8を書き出しました。"; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
