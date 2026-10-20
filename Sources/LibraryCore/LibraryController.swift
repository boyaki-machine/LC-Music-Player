import Foundation
import Observation
import PlaybackCore
import OSLog
import PreprocessingCore
import AudioProcessingCore

@Observable @MainActor public final class LibraryController {
    public private(set) var document = LibraryDocument()
    /// Track positions in `document`; every assignment goes through `publish(_:)`.
    @ObservationIgnored private var trackIndex: [UUID: Int] = [:]
    public private(set) var unavailable: [UUID: String] = [:]
    public private(set) var error: String?
    public private(set) var message: String?
    public private(set) var isBusy = false
    public private(set) var editsEnabled = true
    public let playback: PlaybackController
    @ObservationIgnored private let store: any LibraryPersistence
    @ObservationIgnored private let references: any FileReferenceProvider
    public private(set) var isPreparing = false {
        didSet { if isPreparing != oldValue { schedulePreparationNotice() } }
    }
    /// The "preparing" notice appears only when preparation lasts longer than this, so a quick
    /// song change shows nothing. Stopping stays available for the whole preparation.
    public private(set) var showsPreparationNotice = false
    @ObservationIgnored private let preparationNoticeDelay: Duration
    @ObservationIgnored private var preparationNoticeTask: Task<Void, Never>?
    public private(set) var peakMeasurement: PeakMeasurementState = .disabled
    public private(set) var measuresMaximumVolume = false
    public private(set) var normalizesVolume = false
    public private(set) var normalizationSettings = NormalizationSettings.standard
    public private(set) var levelMeasurement: LevelMeasurementState = .disabled
    public private(set) var shufflesPlayback = false
    /// The entry picked to follow `after`, kept so that preparing the next entry and moving to it agree.
    @ObservationIgnored private var upcomingShuffle: (playlist: UUID, after: UUID, pick: UUID)?
    @ObservationIgnored private var random: AnyRandomNumberGenerator
    public private(set) var preparationStage: String?
    @ObservationIgnored private var measuredLevels: TrackAudioMetrics?
    @ObservationIgnored private var normalizationNeedsPreparation = false
    @ObservationIgnored private var backgroundRetirement: Task<Void, Never>?
    @ObservationIgnored private let preprocessingEnabled: Bool
    @ObservationIgnored private let preferences: any PreferenceStoring
    @ObservationIgnored private let preprocessor: any AudioPreprocessing
    @ObservationIgnored private var playlistPreprocessingMayStart = true
    @ObservationIgnored private var playlistPreprocessing: PlaylistPreprocessing?
    @ObservationIgnored private var cacheAuditTask: Task<Void, Never>?
    @ObservationIgnored private var selectionIntent: SelectionIntent?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var selectionCancellation: PreparationCancellation?
    @ObservationIgnored private var preparationID = UUID()
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    @ObservationIgnored private var nextCancellation: PreparationCancellation?
    @ObservationIgnored private var nextID: UUID?
    @ObservationIgnored private var nextPrepared: NextPreparation?
    @ObservationIgnored private var measurementTask: Task<Void, Never>?
    @ObservationIgnored private var measurementCancellation: PreparationCancellation?
    @ObservationIgnored private var measurementID = UUID()
    @ObservationIgnored private var measuredTrack: UUID?
    @ObservationIgnored private var pendingAdvance = false
    @ObservationIgnored private var shuttingDown = false

    public init(playback: PlaybackController, store: any LibraryPersistence = JSONLibraryStore(url: JSONLibraryStore.defaultURL),
                references: any FileReferenceProvider = BookmarkFileReferences(),
                preprocessingEnabled: Bool = false, playlistPreprocessingEnabled: Bool = false, preferences: any PreferenceStoring = UserDefaults.standard,
                preprocessor: any AudioPreprocessing = AudioPreprocessor.shared,
                random: any RandomNumberGenerator = SystemRandomNumberGenerator(),
                preparationNoticeDelay: Duration = .milliseconds(300)) {
        self.playback = playback; self.store = store; self.references = references
        self.preparationNoticeDelay = preparationNoticeDelay
        self.preprocessor = preprocessor; self.random = AnyRandomNumberGenerator(random)
        self.preprocessingEnabled = preprocessingEnabled; self.preferences = preferences
        if preprocessingEnabled && playlistPreprocessingEnabled {
            playlistPreprocessing = PlaylistPreprocessing(references: references, worker: preprocessor, profile: { try AudioEngineBackend.measurementProfile() })
            playlistPreprocessing?.onMeasured = { [weak self] id, metrics in
                guard let self, self.currentTrack?.id == id, self.playback.selectedURL == metrics.source.url else { return }
                self.measuredLevels = metrics
                if self.measuresMaximumVolume { self.measuredTrack = id; self.peakMeasurement = .complete(metrics.sourcePeak) }
            }
        }
        measuresMaximumVolume = preferences.bool(forKey: "measureMaximumVolume")
        normalizesVolume = preferences.bool(forKey: "normalizeVolume")
        shufflesPlayback = preferences.bool(forKey: "shufflePlayback")
        if let target = preferences.object(forKey: "normalizationTargetLUFS") as? Double,
           let settings = try? NormalizationSettings(targetLUFS: target) { normalizationSettings = settings }
        playback.requireNormalization(normalizesVolume)
        levelMeasurement = normalizesVolume ? .pending : .disabled
        if preprocessingEnabled { playback.onActivityChange = { [weak self] in self?.updatePreprocessing() } }
        do { publish(try store.load().prunedShuffleCycles()); message = store.recoveryMessage; auditMeasurementCache() }
        catch { self.error = error.localizedDescription; editsEnabled = false }
        if playlistPreprocessing != nil {
            Task { [weak self] in self?.resumePlaylistPreprocessing() }
        }
        playback.onNaturalFinish = { [weak self] in
            guard let self else { return }
            if self.isPreparing { return }
            if self.isBusy { self.pendingAdvance = true } else { self.move(1, autoPlay: true) }
        }
    }
    public var canEdit: Bool { editsEnabled && !isBusy }
    public var currentPlaylist: MusicPlaylist? { playlist(document.currentPlaylistID) }
    public var currentEntry: PlaylistEntry? { currentPlaylist?.entries.first { $0.id == document.currentEntryID } }
    public var currentTrack: LibraryTrack? { currentEntry.flatMap { track($0.trackID) } }
    public var currentIndex: Int? { currentPlaylist?.entries.firstIndex { $0.id == document.currentEntryID } }
    public var canPrevious: Bool { canEdit && adjacentEntry(-1) != nil }
    public var canNext: Bool { canEdit && adjacentEntry(1) != nil }

    // MARK: Document lookup

    public func playlist(_ id: UUID?) -> MusicPlaylist? { document.playlists.first { $0.id == id } }
    public func track(_ id: UUID) -> LibraryTrack? { trackIndex[id].map { document.tracks[$0] } }
    private func publish(_ next: LibraryDocument) {
        document = next
        trackIndex = Self.positions(next.tracks)
    }
    /// The first occurrence wins, matching a linear search; validated documents have unique IDs.
    private static func positions(_ tracks: [LibraryTrack]) -> [UUID: Int] {
        Dictionary(tracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    public func clearNotice() { message = nil; if editsEnabled { error = nil } }


    // MARK: Persistence

    private func auditMeasurementCache() {
        guard preprocessingEnabled else { return }
        let owners = Set(document.tracks.map(\.id)), previous = cacheAuditTask
        cacheAuditTask = Task { [preprocessor] in
            await previous?.value
            await preprocessor.reconcileCacheOwners(owners)
        }
    }
    @discardableResult private func commit(_ next: LibraryDocument) -> Bool {
        guard editsEnabled else { return false }
        let next = next.prunedShuffleCycles()
        do {
            try next.validate(); try store.save(next)
            let oldEntry = document.currentEntryID
            publish(next); error = nil
            auditMeasurementCache()
            let trackIDs = Set(next.tracks.map(\.id))
            unavailable = unavailable.filter { id, _ in trackIDs.contains(id) }
            if oldEntry != nil && next.currentEntryID != oldEntry { playback.close() }
            if preprocessingEnabled { restartNextPreparation() }
            return true
        } catch { self.error = "保存できませんでした。\(error.localizedDescription)"; return false }
    }

    // MARK: Playlist editing (each edit is one validated, saved commit)

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
    /// Moves an entry so that it lands at `destination`, an index in the list before the move
    /// (`entries.count` puts it last), like `Array.move(fromOffsets:toOffset:)`.
    public func moveEntry(_ id: UUID, in playlistID: UUID, to destination: Int) {
        guard canEdit, let i = document.playlists.firstIndex(where: { $0.id == playlistID }),
              let from = document.playlists[i].entries.firstIndex(where: { $0.id == id }),
              (0...document.playlists[i].entries.count).contains(destination),
              destination != from, destination != from + 1 else { return }
        var next = document
        let entry = next.playlists[i].entries.remove(at: from)
        next.playlists[i].entries.insert(entry, at: destination > from ? destination - 1 : destination)
        _ = commit(next)
    }
    public func excludeTrack(_ id: UUID) { excludeTracks([id]) }
    /// Removes tracks from the library and every playlist in one saved commit. Audio files stay.
    public func excludeTracks(_ ids: [UUID]) {
        let ids = Set(ids)
        guard canEdit, !ids.isEmpty else { return }
        var next = document
        if let current = currentTrack?.id, ids.contains(current) { next.currentEntryID = nil }
        next.tracks.removeAll { ids.contains($0.id) }
        for i in next.playlists.indices { next.playlists[i].entries.removeAll { ids.contains($0.trackID) } }
        let removed = document.tracks.count - next.tracks.count
        if commit(next), removed > 1 { message = "\(removed)曲をライブラリから除外しました。" }
    }

    // MARK: File references and availability

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

    // MARK: Selection and transport

    @discardableResult public func selectEntry(_ entryID: UUID, in playlistID: UUID, autoPlay: Bool = false) -> Bool {
        selectEntry(entryID, in: playlistID, autoPlay: autoPlay, shuffle: .keep)
    }
    @discardableResult private func selectEntry(_ entryID: UUID, in playlistID: UUID, autoPlay: Bool, shuffle: ShuffleStep) -> Bool {
        guard canEdit, let entry = playlist(playlistID)?.entries.first(where: { $0.id == entryID }), let track = track(entry.trackID) else { return false }
        if preprocessingEnabled {
            beginPreparedSelection(entryID, playlistID: playlistID, autoPlay: autoPlay, shuffle: shuffle)
            return true
        }
        do {
            let resolved = try references.resolve(track.reference)
            var next = document
            recordShuffle(&next, entry: entryID, playlist: playlistID, step: shuffle)
            next.currentPlaylistID = playlistID; next.currentEntryID = entryID
            if let i = next.tracks.firstIndex(where: { $0.id == track.id }) { next.tracks[i].reference = resolved.reference }
            // Decoder and file lease are prepared first; disk failure keeps the old audio intact.
            let success = playback.select(resolved.url, using: resolved.lease) { if next != document { try store.save(next) } }
            guard success else { self.error = playback.error?.localizedDescription; return false }
            publish(next); unavailable[track.id] = nil; error = nil; message = nil
            if autoPlay { playback.togglePlayPause(using: resolved.lease) }
            return true
        } catch {
            unavailable[track.id] = "ファイルが見つからないか、アクセスできません。"
            self.error = error.localizedDescription; return false
        }
    }
    /// A second click upgrades the pending selection instead of opening another decoder.
    public func clickEntry(_ entryID: UUID, in playlistID: UUID, clickCount: Int) {
        guard canEdit, !shuttingDown, clickCount == 1 || clickCount == 2,
              let reference = currentReference(entryID, in: playlistID) else { return }
        let play = playback.state == .playing || clickCount == 2
        if let intent = selectionIntent, intent.entry == entryID, intent.playlist == playlistID,
           intent.reference == reference {
            if play { intent.autoPlay = true }
            return
        }
        if document.currentPlaylistID == playlistID, document.currentEntryID == entryID {
            if clickCount == 2, playback.state != .playing { togglePlayPause() }
            return
        }
        // Choosing a row continues the cycle: the row joins the played entries.
        selectEntry(entryID, in: playlistID, autoPlay: play, shuffle: .add)
    }

    public func playPlaylist(_ id: UUID) {
        guard let list = playlist(id) else { return }
        let first = shufflesPlayback ? list.entries.randomElement(using: &random) : list.entries.first
        guard let first else { return }
        selectEntry(first.id, in: id, autoPlay: true, shuffle: .restart)
    }
    public func togglePlayPause() {
        if playback.state == .playing || (playback.state == .paused && !normalizationNeedsPreparation) {
            playback.togglePlayPause(); return
        }
        guard let current = currentTrack, let list = document.currentPlaylistID, let entry = document.currentEntryID else { return }
        if preprocessingEnabled {
            beginPreparedSelection(entry, playlistID: list, autoPlay: true, position: playback.currentTime == playback.duration ? 0 : playback.currentTime)
            return
        }
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
        guard let list = currentPlaylist, let entry = adjacentEntry(offset) else { return }
        selectEntry(entry.id, in: list.id, autoPlay: autoPlay, shuffle: .keep)
    }

    // MARK: Shuffle

    /// Turning shuffle on or off forgets every cycle; turning it on starts a new cycle from the current entry.
    public func setShufflesPlayback(_ enabled: Bool) {
        guard !shuttingDown, shufflesPlayback != enabled else { return }
        shufflesPlayback = enabled; preferences.set(enabled, forKey: "shufflePlayback")
        upcomingShuffle = nil
        var next = document
        next.shuffleCycles = nil
        if enabled, let list = next.currentPlaylistID, let entry = next.currentEntryID {
            next.shuffleCycles = [ShuffleCycle(playlistID: list, first: entry)]
        }
        if next != document, editsEnabled, commit(next) { return }
        if preprocessingEnabled { restartNextPreparation() }
    }
    /// The played entries of the current playlist's cycle.
    var shufflePlayed: [UUID]? { shufflesPlayback ? currentPlaylist.flatMap { shuffleCycle(in: document, list: $0)?.played } : nil }
    /// The saved cycle of `list`, with the current entry counted as played. A list without a
    /// saved cycle (an older file) starts one from its current entry.
    private func shuffleCycle(in document: LibraryDocument, list: MusicPlaylist) -> ShuffleCycle? {
        let stored = document.shuffleCycles?.first { $0.playlistID == list.id }
        guard document.currentPlaylistID == list.id, let current = document.currentEntryID,
              list.entries.contains(where: { $0.id == current }) else { return stored }
        var cycle = stored ?? ShuffleCycle(playlistID: list.id, first: current)
        cycle.record(current, keepsPosition: true)
        return cycle
    }
    /// Records the entry about to become current in its playlist's cycle. `document` still holds
    /// the entry that was current, which a list without a saved cycle starts from.
    private func recordShuffle(_ next: inout LibraryDocument, entry: UUID, playlist playlistID: UUID, step: ShuffleStep) {
        guard shufflesPlayback, let list = playlist(playlistID) else { return }
        var cycle = step == .restart ? ShuffleCycle(playlistID: playlistID, first: entry)
            : shuffleCycle(in: document, list: list) ?? ShuffleCycle(playlistID: playlistID, first: entry)
        cycle.record(entry, keepsPosition: step != .add)
        var cycles = next.shuffleCycles ?? []
        if let i = cycles.firstIndex(where: { $0.playlistID == playlistID }) { cycles[i] = cycle } else { cycles.append(cycle) }
        next.shuffleCycles = cycles
    }
    /// The entry `offset` steps away in the playback order: the playlist order, or the shuffle cycle.
    /// Going back walks the played entries; going on picks an unplayed entry. When every entry of
    /// the cycle has been played, there is no next entry and playback stops.
    private func adjacentEntry(_ offset: Int) -> PlaylistEntry? {
        guard let list = currentPlaylist, let current = document.currentEntryID, let i = currentIndex else { return nil }
        guard shufflesPlayback else { return list.entries.indices.contains(i + offset) ? list.entries[i + offset] : nil }
        guard let cycle = shuffleCycle(in: document, list: list) else { return nil }
        func entry(_ id: UUID) -> PlaylistEntry? { list.entries.first { $0.id == id } }
        if let id = cycle.neighbor(of: current, offset: offset) { return entry(id) }
        guard offset == 1 else { return nil }
        if let upcoming = upcomingShuffle, upcoming.playlist == list.id, upcoming.after == current,
           cycle.unplayed(in: list).contains(upcoming.pick) { return entry(upcoming.pick) }
        guard let pick = cycle.randomUnplayed(in: list, using: &random) else { upcomingShuffle = nil; return nil }
        upcomingShuffle = (list.id, current, pick)
        return entry(pick)
    }

    // MARK: Import, export and shutdown

    private func retirePlaylistWorkForImport() async {
        guard let playlistPreprocessing else { return }
        playlistPreprocessing.suspend()
        let selecting = selectionTask, retiring = playlistPreprocessing.retirement
        await selecting?.value
        await retiring?.value
        await backgroundRetirement?.value
    }
    private func finishImport() {
        isBusy = false
        if playlistPreprocessing != nil { resumePlaylistPreprocessing(retryFailures: true) }
        if pendingAdvance { pendingAdvance = false; if playback.state == .finished { move(1, autoPlay: true) } }
    }
    public func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        let logger = Logger(subsystem: "local.lcmp.player", category: "shutdown")
        let started = ContinuousClock.now
        logger.notice("Library shutdown: stopping playback")
        cancelPreparation()
        playback.onActivityChange = nil
        pendingAdvance = false; editsEnabled = false
        playback.onNaturalFinish = nil
        playback.close()
        logger.notice("Library shutdown finished after \(String(describing: started.duration(to: .now)), privacy: .public)")
    }
    public func importFiles(_ selections: [URL], into playlistID: UUID? = nil) async {
        guard canEdit else { return }; isBusy = true; error = nil
        defer { finishImport() }
        await retirePlaylistWorkForImport()
        guard editsEnabled, !shuttingDown else { return }
        let scopes = selections.map { references.beginAccess($0) }
        defer { withExtendedLifetime(scopes) {} }
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
    /// Registers songs of the Music library. Each item's URL is the song's asset URL and its title the song title.
    public func importMediaItems(_ items: [M3U8Item], into playlistID: UUID? = nil) async {
        guard canEdit else { return }; isBusy = true; error = nil
        defer { finishImport() }
        await retirePlaylistWorkForImport()
        guard editsEnabled, !shuttingDown else { return }
        do {
            var next = document
            let ids = try await stage(items, in: &next, allowMissing: false)
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
        var positions = Self.positions(next.tracks)
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard editsEnabled else { throw CancellationError() }
            guard SupportedAudio.accepts(item.url) else { failed += 1; continue }
            let path = item.url.standardizedFileURL.resolvingSymlinksInPath()
            let fromFolder = folderRoots.contains { path.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
            if let id = paths[path] {
                if fromFolder, let i = positions[id] { next.tracks[i].registration = .folder }
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
            positions[track.id] = next.tracks.count
            next.tracks.append(track); paths[path] = track.id; ids.append(track.id)
            if reference.bookmark == nil && reference.mediaItemID == nil { unavailable[track.id] = "ファイルが見つからないか、アクセスできません。" }
            if index % 32 == 0 { await Task.yield() }
        }
        if failed > 0 { self.error = "\(failed)件は形式またはアクセスを確認できず、登録していません。" }
        return ids
    }
    public func importM3U8(_ url: URL) async {
        guard url.isFileURL else { error = LibraryFailure.inaccessible.localizedDescription; return }
        guard canEdit else { return }; isBusy = true; error = nil
        defer { finishImport() }
        await retirePlaylistWorkForImport()
        guard editsEnabled, !shuttingDown else { return }
        let scope = references.beginAccess(url)
        defer { withExtendedLifetime(scope) {} }
        do {
            let data = try await Task.detached { try M3U8.read(url) }.value
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

// MARK: - Volume measurement and normalization

extension LibraryController {
    public var currentTrackMetrics: TrackAudioMetrics? {
        guard normalizesVolume, let result = measuredLevels, result.source.url == playback.selectedURL,
              (try? result.source.validate()) != nil else { return nil }
        return result
    }
    public func setNormalizesVolume(_ enabled: Bool) {
        guard !shuttingDown, normalizesVolume != enabled else { return }
        if playback.state == .playing { playback.togglePlayPause() }
        cancelPreparation()
        normalizesVolume = enabled; preferences.set(enabled, forKey: "normalizeVolume")
        playback.requireNormalization(enabled); normalizationNeedsPreparation = true
        levelMeasurement = enabled ? .pending : .disabled
    }
    public func setNormalizationTarget(_ target: Double) {
        guard !shuttingDown else { return }
        guard let settings = try? NormalizationSettings(targetLUFS: target), settings != normalizationSettings else { return }
        if playback.state == .playing { playback.togglePlayPause() }
        let previous = measuredLevels
        cancelPreparation(); measuredLevels = previous
        normalizationSettings = settings
        preferences.set(target, forKey: "normalizationTargetLUFS")
        playback.requireNormalization(normalizesVolume); normalizationNeedsPreparation = true
        levelMeasurement = normalizesVolume ? previous.map { .complete($0) } ?? .pending : .disabled
    }
    public var currentTrackPeak: TrackPeak? {
        guard measuresMaximumVolume, case .complete(let peak) = peakMeasurement,
              peak.source.url == playback.selectedURL, (try? peak.source.validate()) != nil else { return nil }
        return peak
    }
    var playlistWorkRetirement: Task<Void, Never>? { playlistPreprocessing?.retirement }
    var preparedNextHasLevels: Bool { (playlistPreprocessing?.active ?? nextPrepared)?.levels != nil }
    var preparedNextEntryID: UUID? {
        let request = playlistPreprocessing?.active ?? nextPrepared
        return request?.audio == nil ? nil : request?.entry
    }
    var preparedNextByteCount: Int { (playlistPreprocessing?.active ?? nextPrepared)?.audio?.bufferedBytes ?? 0 }

    public func stop() { cancelPreparation(); playback.stop() }

    public func setMeasuresMaximumVolume(_ enabled: Bool) {
        measuresMaximumVolume = enabled
        preferences.set(enabled, forKey: "measureMaximumVolume")
        cancelMeasurement(); cancelNext()
        measuredTrack = nil
        peakMeasurement = enabled ? .pending : .disabled
        if playback.state == .playing {
            prepareNext()
            if playlistPreprocessing == nil || playlistPreprocessing?.supportsProfile == false { measureCurrent() }
            else if let metrics = measuredLevels, (try? metrics.source.validate()) != nil, enabled {
                peakMeasurement = .complete(metrics.sourcePeak); measuredTrack = currentTrack?.id
            }
        }
    }


    // MARK: Background preparation
    // Ownership of a prepared prefix, measurement and file lease moves only on the main actor;
    // every cancelled Task is chained into backgroundRetirement before new scoped access begins.

    private func schedulePreparationNotice() {
        preparationNoticeTask?.cancel(); preparationNoticeTask = nil
        guard isPreparing else { showsPreparationNotice = false; return }
        let delay = preparationNoticeDelay
        preparationNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.isPreparing else { return }
            self.showsPreparationNotice = true
        }
    }
    private func cancelMeasurement() {
        measurementCancellation?.cancel(); measurementCancellation = nil
        measurementTask?.cancel(); measurementTask = nil; measurementID = UUID()
    }
    private func cancelNext() {
        // Keep cancelled work alive until its decoder and scoped access have retired.
        if let task = nextTask {
            let previous = backgroundRetirement
            backgroundRetirement = Task { await previous?.value; await task.value }
        }
        nextCancellation?.cancel(); nextCancellation = nil
        nextTask?.cancel(); nextTask = nil; nextID = nil; nextPrepared = nil
    }
    private func cancelPreparation() {
        playlistPreprocessingMayStart = false
        playlistPreprocessing?.suspend()
        let previous = backgroundRetirement, selection = selectionTask, next = nextTask, measurement = measurementTask
        if selection != nil || next != nil || measurement != nil {
            backgroundRetirement = Task {
                await previous?.value
                await selection?.value
                await next?.value
                await measurement?.value
            }
        }
        selectionCancellation?.cancel(); selectionCancellation = nil
        selectionTask?.cancel(); selectionTask = nil; selectionIntent = nil; preparationID = UUID(); isPreparing = false
        cancelNext(); cancelMeasurement()
        measuredTrack = nil; peakMeasurement = measuresMaximumVolume ? .pending : .disabled
        measuredLevels = nil; levelMeasurement = normalizesVolume ? .pending : .disabled; preparationStage = nil
    }
    /// Selects an entry through the worker: reuses a matching speculative result when its
    /// source is unchanged, otherwise resolves, prepares a prefix and (for normalized
    /// playback) measures. Only the latest preparationID may commit the selection.
    private func beginPreparedSelection(_ entryID: UUID, playlistID: UUID, autoPlay: Bool, position: Double = 0, shuffle: ShuffleStep = .keep) {
        guard !shuttingDown else { return }
        playlistPreprocessingMayStart = true
        let requestedReference = currentReference(entryID, in: playlistID)
        let intent = SelectionIntent(entry: entryID, playlist: playlistID, reference: requestedReference, autoPlay: autoPlay)
        selectionIntent = intent
        let sweepTransfer = autoPlay && normalizesVolume ? trackForEntry(entryID, in: playlistID).flatMap { playlistPreprocessing?.take($0) } : nil
        playlistPreprocessing?.suspend()
        let sweepRetirement = playlistPreprocessing?.retirement
        let candidate = sweepTransfer?.0 ?? nextPrepared.flatMap { request in
            request.entry == entryID && request.reference == requestedReference ? request : nil
        }
        // Transfer the existing waiter and lease, including a still-pending prefix.
        // OFF/metadata selections keep their cancellation path and never wait for a full scan.
        let promoted = autoPlay && normalizesVolume ? candidate : nil
        let promotedTask = sweepTransfer?.1 ?? (promoted == nil ? nil : nextTask)
        let retiringSelection = selectionTask, retiringNext = promoted == nil ? nextTask : nil
        selectionCancellation?.cancel(); selectionTask?.cancel()
        let id = UUID(); preparationID = id
        let cancellation = promoted?.cancellation ?? PreparationCancellation(); selectionCancellation = cancellation
        let cached = candidate
        let previousLevels = measuredLevels
        let retiringBackground = backgroundRetirement
        if promoted != nil {
            nextTask = nil; nextCancellation = nil; nextID = nil; nextPrepared = nil
        } else { cancelNext() }
        cancelMeasurement(); measuredTrack = nil
        peakMeasurement = measuresMaximumVolume ? .pending : .disabled
        isPreparing = true
        preparationStage = "音声を準備しています…"
        selectionTask = Task { [weak self] in
            defer {
                if let self, self.preparationID == id, self.isPreparing {
                    let retiring = self.selectionTask, previous = self.backgroundRetirement
                    self.backgroundRetirement = Task { await previous?.value; await retiring?.value }
                    self.isPreparing = false; self.selectionTask = nil; self.selectionCancellation = nil; self.selectionIntent = nil
                    self.preparationStage = nil
                    if self.playback.state == .playing { self.resumePlaylistPreprocessing() }
                }
            }
            do {
                await sweepRetirement?.value
                await retiringBackground?.value
                await retiringSelection?.value
                await retiringNext?.value
                await promotedTask?.value
                try cancellation.check()
                if let failure = promoted?.failure { throw failure }
                guard let self, let entry = self.playlist(playlistID)?.entries.first(where: { $0.id == entryID }),
                      let track = self.track(entry.trackID), track.reference == requestedReference else { return }
                let resolved: ResolvedTrack
                let prepared: PreparedAudio
                if let cached, let audio = cached.audio, let access = cached.resolved,
                   (try? audio.source.validate()) != nil, cached.reference == track.reference {
                    resolved = access; prepared = audio
                } else if sweepTransfer != nil, let cached, cached.audio == nil,
                          let access = cached.resolved, cached.reference == track.reference,
                          cached.levels?.profile == (try? AudioEngineBackend.measurementProfile()),
                          (try? cached.levels?.source.validate()) != nil {
                    resolved = access
                    prepared = try await self.preprocessor.prepare(access.url, cancellation: cancellation, seconds: 2, byteLimit: 32 * 1024 * 1024)
                } else {
                    // A changed source cannot keep an obsolete lease while reopening it.
                    cached?.audio = nil; cached?.resolved = nil; cached?.levels = nil; cached?.peak = nil
                    do { resolved = try self.references.resolve(track.reference) }
                    catch {
                        self.unavailable[track.id] = "ファイルが見つからないか、アクセスできません。"
                        throw error
                    }
                    prepared = try await self.preprocessor.prepare(resolved.url, cancellation: cancellation, seconds: 2, byteLimit: 32 * 1024 * 1024)
                }
                var levels: TrackAudioMetrics?
                if intent.autoPlay, self.normalizesVolume {
                    let profile = try AudioEngineBackend.measurementProfile()
                    let candidate = cached?.levels ?? previousLevels
                    if let candidate, candidate.source == prepared.source, candidate.profile == profile,
                       (try? candidate.source.validate()) != nil { levels = candidate }
                    else {
                        self.preparationStage = "曲全体の音量を測定しています…"
                        levels = try await self.preprocessor.measureLevels(resolved.url, profile: profile, cancellation: cancellation, ownerID: track.id)
                    }
                    guard try AudioEngineBackend.measurementProfile() == profile else { throw AudioProcessingFailure.outputChanged }
                }
                try cancellation.check()
                guard self.preparationID == id, self.editsEnabled,
                      let latest = self.playlist(playlistID)?.entries.first(where: { $0.id == entryID }),
                      latest.trackID == track.id, self.track(track.id)?.reference == track.reference else { return }
                var next = self.document
                self.recordShuffle(&next, entry: entryID, playlist: playlistID, step: shuffle)
                next.currentPlaylistID = playlistID; next.currentEntryID = entryID
                if let i = next.tracks.firstIndex(where: { $0.id == track.id }) { next.tracks[i].reference = resolved.reference }
                if intent.autoPlay {
                    guard self.playback.selectPrepared(prepared, using: resolved.lease, metrics: levels,
                        settings: self.normalizationSettings, committing: {
                        if next != self.document { try self.store.save(next) }
                    }) else { throw self.playback.error ?? PlaybackError.inaccessibleFile }
                } else {
                    // Keep metadata only while idle; do not retain a decoder or a scoped lease.
                    guard self.playback.selectMetadata(url: resolved.url, duration: prepared.duration,
                        supportsSeeking: prepared.supportsSeeking, committing: {
                            if next != self.document { try self.store.save(next) }
                        }) else { throw self.playback.error ?? PlaybackError.inaccessibleFile }
                }
                self.publish(next); self.unavailable[track.id] = nil; self.error = nil; self.message = nil
                self.isPreparing = false; self.selectionTask = nil; self.selectionCancellation = nil; self.selectionIntent = nil
                self.preparationStage = nil
                if position > 0 { self.playback.seek(to: position) }
                self.measuredLevels = levels
                self.levelMeasurement = self.normalizesVolume ? levels.map { .complete($0) } ?? .pending : .disabled
                self.normalizationNeedsPreparation = false
                if self.measuresMaximumVolume, let peak = levels?.sourcePeak ?? cached?.peak, peak.source == prepared.source {
                    self.measuredTrack = track.id; self.peakMeasurement = .complete(peak)
                }
                if intent.autoPlay { self.playback.togglePlayPause(using: resolved.lease) }
                else if self.playlistPreprocessing != nil { self.resumePlaylistPreprocessing() }
            } catch {
                guard let self, self.preparationID == id else { return }
                let retiring = self.selectionTask, previous = self.backgroundRetirement
                self.backgroundRetirement = Task { await previous?.value; await retiring?.value }
                self.isPreparing = false; self.selectionTask = nil; self.selectionCancellation = nil; self.selectionIntent = nil
                self.preparationStage = nil
                if !(error is CancellationError) {
                    self.error = "再生を準備できませんでした。\(error.localizedDescription)"
                    if self.normalizesVolume { self.levelMeasurement = .failed(error.localizedDescription) }
                }
                self.updatePreprocessing()
            }
        }
    }

    private func trackForEntry(_ entryID: UUID, in playlistID: UUID) -> LibraryTrack? {
        playlist(playlistID)?.entries.first { $0.id == entryID }.flatMap { track($0.trackID) }
    }
    private func resumePlaylistPreprocessing(retryFailures: Bool = false) {
        guard !shuttingDown, editsEnabled, !isBusy, !isPreparing, playlistPreprocessingMayStart else { return }
        let audit = cacheAuditTask, previous = backgroundRetirement
        let barrier = Task { await previous?.value; await audit?.value }
        playlistPreprocessing?.update(document, playback: playback, after: barrier,
                                      completed: measuredLevels, retryFailures: retryFailures,
                                      adjacent: (adjacentEntry(1), adjacentEntry(-1)))
    }
    private func restartNextPreparation() {
        if playlistPreprocessing != nil {
            playlistPreprocessingMayStart = true
            resumePlaylistPreprocessing(retryFailures: true)
            return
        }
        cancelNext()
        if playback.state == .playing { prepareNext() }
    }
    /// Speculatively prepares the following entry while playing (without playlist sweeps).
    private func prepareNext() {
        if playlistPreprocessing != nil { resumePlaylistPreprocessing(); return }
        guard !shuttingDown, !isPreparing, playback.state == .playing, let entry = adjacentEntry(1) else { return }
        guard nextID != entry.id, let track = track(entry.trackID) else { return }
        let retiringNext = nextTask
        let retiringBackground = backgroundRetirement
        cancelNext(); nextID = entry.id
        let request = NextPreparation(entry: entry.id, reference: track.reference)
        let cancellation = request.cancellation; nextCancellation = cancellation
        nextPrepared = request
        let normalize = normalizesVolume, peakOnly = measuresMaximumVolume && !normalizesVolume
        let references = references, preprocessor = preprocessor
        nextTask = Task {
            do {
                await retiringBackground?.value
                await retiringNext?.value
                try cancellation.check()
                let resolved = try references.resolve(track.reference)
                // Retain this one lease through preparation, measurement, and any role transfer.
                request.resolved = resolved
                let prepared = try await preprocessor.prepare(resolved.url, cancellation: cancellation,
                                                              seconds: 2, byteLimit: 32 * 1024 * 1024)
                try cancellation.check()
                request.audio = prepared
                if normalize {
                    let profile = try AudioEngineBackend.measurementProfile()
                    let levels = try await preprocessor.measureLevels(resolved.url, profile: profile,
                                                                      cancellation: cancellation, ownerID: track.id)
                    try cancellation.check()
                    request.levels = levels; request.peak = levels.sourcePeak
                } else if peakOnly {
                    let peak = try await preprocessor.measure(resolved.url, cancellation: cancellation, ownerID: track.id)
                    try cancellation.check()
                    request.peak = peak
                }
            } catch {
                // Only a later explicit consumer reports this error.
                request.failure = error
            }
        }
    }
    private func currentReference(_ entryID: UUID, in playlistID: UUID) -> TrackReference? {
        playlist(playlistID)?.entries.first { $0.id == entryID }.flatMap { track($0.trackID)?.reference }
    }
    /// Follows playback state: playing starts speculation, paused keeps measured levels,
    /// any other state retires background work.
    private func updatePreprocessing() {
        guard preprocessingEnabled, !shuttingDown else { return }
        if playback.state == .playing {
            guard !isPreparing else { return }
            playlistPreprocessingMayStart = true
            prepareNext()
            if playlistPreprocessing == nil || playlistPreprocessing?.supportsProfile == false { measureCurrent() }
        } else if playback.state == .paused {
            let levels = measuredLevels
            cancelPreparation()
            measuredLevels = levels
            if normalizesVolume, let levels { levelMeasurement = .complete(levels) }
        } else if playback.state == .finished, selectionTask != nil {
            // Natural advancement has already taken the prepared next entry.
            cancelNext(); cancelMeasurement()
        } else { cancelPreparation() }
    }
    private func measureCurrent() {
        if measuresMaximumVolume, let levels = currentTrackMetrics {
            peakMeasurement = .complete(levels.sourcePeak); measuredTrack = currentTrack?.id; return
        }
        guard measuresMaximumVolume, let track = currentTrack, measuredTrack != track.id,
              let lease = playback.activeFileLease, let url = playback.selectedURL else { return }
        cancelMeasurement(); measuredTrack = track.id; peakMeasurement = .pending
        let id = UUID(); measurementID = id
        let cancellation = PreparationCancellation(); measurementCancellation = cancellation
        measurementTask = Task { [weak self, lease, preprocessor] in
            defer { withExtendedLifetime(lease) {} }
            do {
                let result = try await preprocessor.measure(url, cancellation: cancellation, ownerID: track.id)
                try cancellation.check()
                guard let self, self.measurementID == id, self.currentTrack?.id == track.id else { return }
                self.peakMeasurement = .complete(result); self.measurementTask = nil
            } catch {
                guard let self, self.measurementID == id else { return }
                self.measurementTask = nil
                if !(error is CancellationError) { self.peakMeasurement = .failed(error.localizedDescription) }
            }
        }
    }
}

/// Main-actor ownership can move from speculation to selection without cancelling its worker.
@MainActor final class NextPreparation {
    let trackID: UUID?
    var profile: MeasurementProfile?
    let entry: UUID
    let reference: TrackReference
    let cancellation = PreparationCancellation()
    var audio: PreparedAudio?
    var resolved: ResolvedTrack?
    var peak: TrackPeak?
    var levels: TrackAudioMetrics?
    var failure: (any Error)?
    init(entry: UUID, reference: TrackReference, trackID: UUID? = nil) { self.entry = entry; self.reference = reference; self.trackID = trackID }
}

/// How a selection changes the shuffle cycle: next, previous and resuming keep it (`keep`),
/// choosing a row adds the row (`add`), and playing a whole list starts a new cycle (`restart`).
enum ShuffleStep { case keep, add, restart }

/// MainActor-owned intent; only the current selection can be upgraded by a row click.
@MainActor private final class SelectionIntent {
    let entry: UUID
    let playlist: UUID
    let reference: TrackReference?
    var autoPlay: Bool
    init(entry: UUID, playlist: UUID, reference: TrackReference?, autoPlay: Bool) {
        self.entry = entry; self.playlist = playlist; self.reference = reference; self.autoPlay = autoPlay
    }
}
