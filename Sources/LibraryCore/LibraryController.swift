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
    /// The running sleep timer, or nil while it is off. Turning it on is not kept across launches.
    public private(set) var sleepTimer: SleepTimer?
    /// The song count the timer starts with; the choice is kept.
    public private(set) var sleepTimerCount = SleepTimer.defaultCount
    static let sleepTimerCountKey = "sleepTimerSongCount"
    /// Called after the sleep timer has stopped playback. The Mac app quits here.
    @ObservationIgnored public var onSleepTimerFinished: (@MainActor () -> Void)?
    @ObservationIgnored private var sleepFadeTask: Task<Void, Never>?
    @ObservationIgnored private let sleepFadeInterval: Duration
    /// Turning the timer off while it has lowered the volume brings the volume back over this time.
    @ObservationIgnored private let sleepRestoreDuration: Duration
    @ObservationIgnored private var sleepRestoreTask: Task<Void, Never>?
    public private(set) var preparationStage: String?
    /// Changes when another track starts, or the same one again after it played to its end. A new
    /// start of the same track for changed settings, a resume or a seek keeps it.
    public private(set) var trackChangeID = UUID()
    @ObservationIgnored private var measuredLevels: TrackAudioMetrics?
    @ObservationIgnored private var normalizationNeedsPreparation = false
    @ObservationIgnored private var backgroundRetirement: Task<Void, Never>?
    @ObservationIgnored private let preprocessingEnabled: Bool
    @ObservationIgnored private let preferences: any PreferenceStoring
    @ObservationIgnored private let preprocessor: any AudioPreprocessing
    @ObservationIgnored private var playlistPreprocessingMayStart = true
    @ObservationIgnored private(set) var playlistPreprocessing: PlaylistPreprocessing?
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
    /// The map of the current track (see `currentTrackMap`) and the request for it.
    private var loadedTrackMap: LoadedTrackMap?
    @ObservationIgnored private var mapTask: Task<Void, Never>?
    @ObservationIgnored private var mapCancellation: PreparationCancellation?
    @ObservationIgnored private var mapRequestURL: URL?
    /// The app is in the background (iOS): measurements keep to a share of a core, and track maps wait for the foreground.
    @ObservationIgnored public var isInBackground = false {
        didSet { if isInBackground != oldValue { backgroundChanged(); if isInBackground { rememberPosition() } } }
    }
    @ObservationIgnored private var pendingAdvance = false
    /// Where the current track was left, as last saved (`ResumePosition`).
    @ObservationIgnored private var resumePosition: ResumePosition?
    /// The file the player holds and what identifies it, for the positions saved while it plays.
    @ObservationIgnored private var heldSource: (url: URL, source: ResumeSource)?
    @ObservationIgnored private var positionClock: Task<Void, Never>?
    @ObservationIgnored private let positionSaveInterval: Duration
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private let tagReader: (any TrackTagReading)?
    @ObservationIgnored private var tagTask: Task<Void, Never>?
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    /// Tracks whose references are checked together on another thread.
    static let availabilityBatchSize = 32
    /// Tracks whose tags could not be read in this run. They are tried again on the next launch.
    @ObservationIgnored private var tagFailures: Set<UUID> = []
    static let tagBatchSize = 64

    public init(playback: PlaybackController, store: any LibraryPersistence = JSONLibraryStore(url: JSONLibraryStore.defaultURL),
                references: any FileReferenceProvider = BookmarkFileReferences(),
                preprocessingEnabled: Bool = false, playlistPreprocessingEnabled: Bool = false, preferences: any PreferenceStoring = UserDefaults.standard,
                preprocessor: any AudioPreprocessing = AudioPreprocessor.shared,
                random: any RandomNumberGenerator = SystemRandomNumberGenerator(),
                preparationNoticeDelay: Duration = .milliseconds(300), sleepFadeInterval: Duration = .milliseconds(500),
                sleepRestoreDuration: Duration = .milliseconds(2500), tagReader: (any TrackTagReading)? = nil,
                positionSaveInterval: Duration = .seconds(5)) {
        self.playback = playback; self.store = store; self.references = references; self.tagReader = tagReader
        self.positionSaveInterval = positionSaveInterval
        self.sleepFadeInterval = sleepFadeInterval; self.sleepRestoreDuration = sleepRestoreDuration
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
        if let raw = preferences.object(forKey: "bassEnhancement") as? Int,
           let bass = BassEnhancement(rawValue: raw) { playback.setBassEnhancement(bass) }
        if let count = preferences.object(forKey: Self.sleepTimerCountKey) as? Int, SleepTimer.choices.contains(count) { sleepTimerCount = count }
        if let target = preferences.object(forKey: "normalizationTargetLUFS") as? Double,
           let settings = try? NormalizationSettings(targetLUFS: target) { normalizationSettings = settings }
        playback.requireNormalization(normalizesVolume)
        levelMeasurement = normalizesVolume ? .pending : .disabled
        playback.onActivityChange = { [weak self] in self?.playbackActivityChanged() }
        do {
            publish(try store.load().prunedShuffleCycles()); message = store.recoveryMessage; auditMeasurementCache()
            resumePosition = store.loadPosition()
        } catch { self.error = error.localizedDescription; editsEnabled = false }
        readMissingTags()
        if playlistPreprocessing != nil {
            Task { [weak self] in self?.resumePlaylistPreprocessing() }
        }
        playback.onNaturalFinish = { [weak self] in
            guard let self else { return }
            if self.sleepTimerEndsWithThisSong() { return }
            // A new start for changed settings is no longer needed once the track has ended.
            if self.isPreparing, self.selectionIntent?.followsPlayback != true { return }
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
    /// Play works whenever there is a current entry: the library prepares it when the player does not
    /// hold it yet, so neither a preparation on its way nor one that failed or was cancelled disables it.
    public var canPlay: Bool { playback.canPlay || (currentTrack != nil && editsEnabled) }

    // MARK: Document lookup

    public func playlist(_ id: UUID?) -> MusicPlaylist? { document.playlists.first { $0.id == id } }
    public func track(_ id: UUID) -> LibraryTrack? { trackIndex[id].map { document.tracks[$0] } }
    private func publish(_ next: LibraryDocument) {
        if next.currentEntryID != document.currentEntryID, document.currentEntryID != nil { sleepTimer?.songChanged() }
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
    /// Removes the chosen copies of songs registered more than once (`DuplicateTracks`). A playlist
    /// entry of a removed copy moves to a remaining copy, the one in the most playlists, unless the
    /// playlist already holds that copy. Entries of other removed tracks go, as with `excludeTracks`.
    public func excludeDuplicates(_ ids: [UUID]) {
        let ids = Set(ids)
        guard canEdit, !ids.isEmpty else { return }
        let memberships = document.playlistMemberships
        var replacement: [UUID: UUID] = [:]
        for set in DuplicateTracks.sets(document.tracks) {
            let remaining = set.filter { !ids.contains($0) }
            guard let kept = remaining.enumerated().min(by: { a, b in
                (-(memberships[a.element] ?? 0), a.offset) < (-(memberships[b.element] ?? 0), b.offset)
            })?.element else { continue }
            for id in set where ids.contains(id) { replacement[id] = kept }
        }
        var next = document, moved = 0
        if let current = currentTrack?.id, ids.contains(current) { next.currentEntryID = nil }
        next.tracks.removeAll { ids.contains($0.id) }
        for i in next.playlists.indices {
            var held = Set(next.playlists[i].entries.map(\.trackID).filter { !ids.contains($0) })
            next.playlists[i].entries = next.playlists[i].entries.compactMap { entry in
                guard ids.contains(entry.trackID) else { return entry }
                guard let kept = replacement[entry.trackID], held.insert(kept).inserted else { return nil }
                var entry = entry; entry.trackID = kept; moved += 1
                return entry
            }
        }
        let removed = document.tracks.count - next.tracks.count
        if commit(next) { message = "\(removed)曲を除外しました。" + (moved > 0 ? "リストの\(moved)曲は残した方に付け替えました。" : "") }
    }
    /// Whether each track stores its audio without loss, left out where unknown. Only M4A files are
    /// opened, since they may hold either Apple Lossless or AAC; the rest are known by extension.
    public func losslessFlags(_ ids: [UUID]) async -> [UUID: Bool] {
        var flags: [UUID: Bool] = [:], opened: [(UUID, ResolvedTrack)] = []
        for id in ids {
            guard let track = track(id) else { continue }
            if let known = AudioEncoding.isLosslessByExtension(track.reference.lastKnownURL) { flags[id] = known; continue }
            if let resolved = try? await references.resolved(track.reference) { opened.append((id, resolved)) }
        }
        let read = await Task.detached(priority: .userInitiated) {
            opened.compactMap { id, resolved in withExtendedLifetime(resolved.lease) { AudioEncoding.isLossless(resolved.url).map { (id, $0) } } }
        }.value
        for (id, lossless) in read { flags[id] = lossless }
        return flags
    }

    // MARK: File references and availability

    public func repairTrack(_ id: UUID, using url: URL) {
        guard canEdit, let i = document.tracks.firstIndex(where: { $0.id == id }) else { return }
        do {
            guard SupportedAudio.accepts(url) else { throw PlaybackError.unsupportedFormat }
            var next = document; next.tracks[i].reference = try references.makeReference(url)
            // The replacement file may carry other tags.
            next.tracks[i].tags = nil
            if commit(next) {
                unavailable[id] = nil; tagFailures.remove(id); readMissingTags()
                // Another file: a preparation of the old one, or the old one held idle, is prepared again.
                if let intent = selectionIntent, trackForEntry(intent.entry, in: intent.playlist)?.id == id {
                    Logger.selection.notice("Track repaired while it was prepared: preparing it again")
                    beginPreparedSelection(intent.entry, playlistID: intent.playlist, autoPlay: intent.autoPlay, position: 0,
                                           shuffle: intent.shuffle, startsTrack: intent.startsTrack, cause: "repair")
                } else if currentTrack?.id == id, playback.state != .playing, playback.state != .paused,
                          let list = document.currentPlaylistID, let entry = document.currentEntryID {
                    selectEntry(entry, in: list)
                }
                message = "ファイル参照を更新しました。"
            }
        } catch { self.error = error.localizedDescription }
    }
    /// Reads ahead the last song, at the position where it was left, so that play starts at once and the
    /// seek bar works before it; the whole library is checked in the background. Nothing waits for the
    /// read-ahead: play prepares the current entry itself if it is not ready (`togglePlayPause`).
    public func restore() {
        if canEdit, let list = document.currentPlaylistID, let entry = document.currentEntryID, currentTrack != nil {
            let resume = resumePosition.flatMap { $0.playlistID == list && $0.entryID == entry ? $0 : nil }
            Logger.selection.notice("Restoring the last track\(resume == nil ? "" : " at its saved position", privacy: .public)")
            if preprocessingEnabled {
                beginPreparedSelection(entry, playlistID: list, autoPlay: false, startsTrack: true, resume: resume, cause: "restore")
            } else if selectEntry(entry, in: list), let resume { applyResume(resume) }
        }
        refreshAvailability()
    }
    /// Readability is transient. A missing file never removes a persisted entry.
    /// Checks every track on another thread in batches, so neither launch nor opening the list
    /// waits for it; marks are updated batch by batch. A check already running is kept. Refreshed
    /// bookmarks are saved together at the end, except for tracks that changed meanwhile, and an
    /// import or another edit that makes the library busy ends the check without saving.
    @discardableResult public func refreshAvailability() -> Task<Void, Never>? {
        if let availabilityTask { return availabilityTask }
        guard !isBusy, !shuttingDown else { return nil }
        let tracks = document.tracks.map { ($0.id, $0.reference) }
        availabilityTask = Task { [weak self] in
            var refreshed: [UUID: (old: TrackReference, new: TrackReference)] = [:]
            var start = 0
            while start < tracks.count {
                let batch = tracks[start..<min(start + Self.availabilityBatchSize, tracks.count)]
                guard let self, !Task.isCancelled, !self.isBusy else { break }
                let results = await self.references.availability(of: batch.map(\.1))
                guard !Task.isCancelled, !self.isBusy else { break }
                for ((id, old), new) in zip(batch, results) where self.track(id)?.reference == old {
                    // Only a change is written: every write makes the list observe the marks again.
                    let mark = new == nil ? LibraryFailure.unavailable.localizedDescription : nil
                    if self.unavailable[id] != mark { self.unavailable[id] = mark }
                    if let new, new != old { refreshed[id] = (old, new) }
                }
                start += Self.availabilityBatchSize
            }
            guard let self else { return }
            self.availabilityTask = nil
            guard start >= tracks.count, !Task.isCancelled, !self.isBusy, self.editsEnabled, !refreshed.isEmpty else { return }
            var next = self.document
            for i in next.tracks.indices {
                if let change = refreshed[next.tracks[i].id], next.tracks[i].reference == change.old { next.tracks[i].reference = change.new }
            }
            // Saving the refreshed references leaves a failure shown meanwhile, such as the last track's, in place.
            let shown = self.error
            if next != self.document, self.commit(next) { self.error = shown }
        }
        return availabilityTask
    }

    // MARK: Selection and transport

    @discardableResult public func selectEntry(_ entryID: UUID, in playlistID: UUID, autoPlay: Bool = false) -> Bool {
        selectEntry(entryID, in: playlistID, autoPlay: autoPlay, shuffle: .keep)
    }
    @discardableResult private func selectEntry(_ entryID: UUID, in playlistID: UUID, autoPlay: Bool, shuffle: ShuffleStep) -> Bool {
        guard canEdit, let entry = playlist(playlistID)?.entries.first(where: { $0.id == entryID }), let track = track(entry.trackID) else { return false }
        if preprocessingEnabled {
            beginPreparedSelection(entryID, playlistID: playlistID, autoPlay: autoPlay, shuffle: shuffle, startsTrack: true)
            return true
        }
        do {
            let resolved = try references.resolve(track.reference)
            var next = document
            recordShuffle(&next, entry: entryID, playlist: playlistID, step: shuffle)
            next.currentPlaylistID = playlistID; next.currentEntryID = entryID
            // Only a refreshed reference is written: an unchanged library keeps sharing its storage.
            if let i = trackIndex[track.id], next.tracks[i].reference != resolved.reference { next.tracks[i].reference = resolved.reference }
            // Decoder and file lease are prepared first; disk failure keeps the old audio intact.
            let changesTrack = changesTrack(to: entryID)
            let success = playback.select(resolved.url, using: resolved.lease) { if next != document { try store.save(next) } }
            guard success else { self.error = playback.error?.localizedDescription; return false }
            if changesTrack { trackChangeID = UUID() }
            publish(next); unavailable[track.id] = nil; error = nil; message = nil
            heldSource = (try? SourceFingerprint(url: resolved.url)).map { (resolved.url, ResumeSource($0, duration: playback.duration)) }
            rememberPosition()
            if autoPlay { playback.togglePlayPause(using: resolved.lease) }
            return true
        } catch {
            unavailable[track.id] = LibraryFailure.unavailable.localizedDescription
            self.error = error.localizedDescription; return false
        }
    }
    /// A second click upgrades the pending selection instead of opening another decoder.
    public func clickEntry(_ entryID: UUID, in playlistID: UUID, clickCount: Int) {
        guard canEdit, !shuttingDown, clickCount == 1 || clickCount == 2,
              currentReference(entryID, in: playlistID) != nil else { return }
        let play = playback.state == .playing || clickCount == 2
        if let intent = selectionIntent, intent.entry == entryID, intent.playlist == playlistID, !intent.followsPlayback {
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
    /// Moves within the current track. After a track has played to its end it has given up its file
    /// access, and the next track may be on its way; moving then plays the finished track again from
    /// there, in place of the next one, through the library's access to it.
    public func seek(to seconds: Double) {
        guard !shuttingDown, seconds.isFinite else { return }
        if playback.state == .finished, preprocessingEnabled, seconds < playback.duration,
           let list = document.currentPlaylistID, let entry = document.currentEntryID {
            pendingAdvance = false
            beginPreparedSelection(entry, playlistID: list, autoPlay: true, position: max(0, seconds))
            return
        }
        playback.seek(to: seconds)
    }
    public func togglePlayPause() {
        // A chosen track on its way plays when it is ready, in place of a paused one; pressing again changes nothing.
        if playback.state != .playing, let intent = selectionIntent, !intent.followsPlayback {
            if !intent.autoPlay { Logger.selection.notice("Play pressed during preparation: plays when ready") }
            intent.autoPlay = true
            return
        }
        if playback.state == .playing || (playback.state == .paused && !normalizationNeedsPreparation && levelsFitOutput) {
            let position = playback.currentTime
            playback.togglePlayPause()
            // The levels fit the kept profile, but the output's engine renders another format (the
            // output changed while it paused): the track is measured for that output and resumes there.
            if playback.error == .outputChanged, preprocessingEnabled, let list = document.currentPlaylistID, let entry = document.currentEntryID {
                Logger.output.notice("Resume failed on the output's format: preparing the track again")
                beginPreparedSelection(entry, playlistID: list, autoPlay: true, position: position)
            }
            return
        }
        guard let current = currentTrack, let list = document.currentPlaylistID, let entry = document.currentEntryID else { return }
        if preprocessingEnabled {
            // The player holds nothing (the read-ahead failed or was cancelled): the saved position is used.
            let resume = playback.state == .empty ? resumePosition.flatMap { $0.playlistID == list && $0.entryID == entry ? $0 : nil } : nil
            beginPreparedSelection(entry, playlistID: list, autoPlay: true, position: playback.currentTime == playback.duration ? 0 : playback.currentTime,
                                   resume: resume, cause: "play")
            return
        }
        do {
            let resolved = try references.resolve(current.reference)
            if playback.selectedURL == resolved.url {
                // Keep an idle/paused seek that has already been prepared by PlaybackCore.
                playback.togglePlayPause(using: resolved.lease)
                error = playback.error?.localizedDescription
            } else {
                let resume = playback.state == .empty ? resumePosition.flatMap { $0.entryID == entry ? $0 : nil } : nil
                if selectEntry(entry, in: list, autoPlay: true), let resume { applyResume(resume) }
            }
        } catch {
            unavailable[current.id] = LibraryFailure.unavailable.localizedDescription
            self.error = error.localizedDescription
        }
    }
    /// Whether the levels the paused track plays with still fit the output. Another output, which pauses the
    /// track, may render another rate; the track is then measured for it before it resumes. The playlist's
    /// sweep may already have measured the current track for the new output, so the levels shown are not
    /// necessarily the ones playing.
    private var levelsFitOutput: Bool {
        guard normalizesVolume else { return true }
        return playback.normalizationPlan.map { $0.profile == (try? AudioEngineBackend.measurementProfile()) } == true
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

    // MARK: Sleep timer

    /// Starts the timer with the chosen count, counting the current song as the first, or turns it off.
    public func setSleepTimer(_ enabled: Bool) {
        guard !shuttingDown, enabled != (sleepTimer != nil) else { return }
        if enabled {
            // A stopped or finished song starts again from the top, so it counts from its start.
            let started = playback.state == .playing || playback.state == .paused
            sleepTimer = SleepTimer(count: sleepTimerCount, startFraction: started ? currentSongFraction : 0)
            runSleepFade()
        } else { endSleepTimer(restoring: true) }
    }
    /// Choosing a count keeps it for next time and starts the timer; a running timer keeps its played songs.
    public func setSleepTimerCount(_ count: Int) {
        guard !shuttingDown, SleepTimer.choices.contains(count) else { return }
        sleepTimerCount = count; preferences.set(count, forKey: Self.sleepTimerCountKey)
        if sleepTimer == nil { setSleepTimer(true) } else { sleepTimer?.setCount(count); applySleepFade() }
    }
    private var currentSongFraction: Double {
        playback.duration > 0 ? playback.currentTime / playback.duration : 0
    }
    /// At the natural end of the last song (or of the list), stops instead of moving on.
    private func sleepTimerEndsWithThisSong() -> Bool {
        guard let timer = sleepTimer, timer.isOnLastSong || adjacentEntry(1) == nil else { return false }
        endSleepTimer(restoring: false)
        playback.stop()
        onSleepTimerFinished?()
        return true
    }
    /// Turning the timer off brings a lowered volume back gradually, so it never jumps up while
    /// someone listens. After the timer has stopped playback the volume is reset at once.
    private func endSleepTimer(restoring: Bool) {
        sleepFadeTask?.cancel(); sleepFadeTask = nil
        sleepTimer = nil
        if restoring, playback.fadeGain < 1 { restoreSleepFade() }
        else { sleepRestoreTask?.cancel(); sleepRestoreTask = nil; playback.setFadeGain(1) }
    }
    /// Rises evenly in decibels from the current level to full volume in 50ms steps over
    /// `sleepRestoreDuration`. It counts steps, not elapsed time, so a busy main actor makes the
    /// rise slower but never larger in one step.
    private func restoreSleepFade() {
        sleepRestoreTask?.cancel()
        let startDB = 20 * log10(Double(max(playback.fadeGain, 0.001)))
        let step = Duration.milliseconds(50)
        let steps = max(1, Int((sleepRestoreDuration / step).rounded(.up)))
        sleepRestoreTask = Task { @MainActor [weak self] in
            for done in 1...steps {
                do { try await Task.sleep(for: step) } catch { return }
                guard let self else { return }
                if done == steps { self.playback.setFadeGain(1); self.sleepRestoreTask = nil; return }
                self.playback.setFadeGain(Float(pow(10, startDB * (1 - Double(done) / Double(steps)) / 20)))
            }
        }
    }
    private func applySleepFade() {
        // While a lowered volume is still coming back, the new timer waits for it to finish.
        guard let timer = sleepTimer, sleepRestoreTask == nil else { return }
        playback.setFadeGain(timer.gain(currentFraction: currentSongFraction))
    }
    /// One clock follows the song position while the timer runs; it does nothing else.
    private func runSleepFade() {
        sleepFadeTask?.cancel()
        let interval = sleepFadeInterval
        let restoring = sleepRestoreTask
        sleepFadeTask = Task { @MainActor [weak self] in
            await restoring?.value
            while !Task.isCancelled {
                guard let self, self.sleepTimer != nil else { return }
                self.applySleepFade()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
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
        readMissingTags()
        if playlistPreprocessing != nil { resumePlaylistPreprocessing(retryFailures: true) }
        if pendingAdvance { pendingAdvance = false; if playback.state == .finished { move(1, autoPlay: true) } }
    }
    public func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        let logger = Logger.shutdown
        let started = ContinuousClock.now
        logger.notice("Library shutdown: stopping playback")
        rememberPosition()
        positionClock?.cancel(); positionClock = nil
        cancelPreparation()
        playback.onActivityChange = nil
        pendingAdvance = false; editsEnabled = false
        playback.onNaturalFinish = nil
        sleepFadeTask?.cancel(); sleepFadeTask = nil
        sleepRestoreTask?.cancel(); sleepRestoreTask = nil
        tagTask?.cancel(); tagTask = nil
        availabilityTask?.cancel(); availabilityTask = nil
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
    /// Adds the items to `next` and returns their track IDs, reusing a track already in the library
    /// for the same file. Locating the library's tracks, following symbolic links and creating the
    /// new references touch the file system for every file, so they run on another thread.
    private func stage(_ items: [M3U8Item], in next: inout LibraryDocument, allowMissing: Bool, folderRoots: [URL] = []) async throws -> [UUID] {
        let located = await references.located(next.tracks.map(\.reference))
        guard editsEnabled else { throw CancellationError() }
        let existing = zip(next.tracks, located).map { $1 ?? $0.reference }
        let itemURLs = items.map(\.url)
        let (existingPaths, itemPaths, roots) = await Task.detached(priority: .userInitiated) {
            // Native strings of the paths are the keys: hashing a URL, or a string bridged from one,
            // takes tens of microseconds, which a whole library would spend on the main actor.
            func canonical(_ url: URL) -> String {
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
                var key = resolved.isFileURL ? resolved.path : resolved.absoluteString
                key.makeContiguousUTF8()
                return key
            }
            return (existing.map { canonical($0.lastKnownURL) }, itemURLs.map(canonical), folderRoots.map { canonical($0) + "/" })
        }.value
        guard editsEnabled else { throw CancellationError() }
        // Edits go to a local array: changing an element of an inout argument of an async function
        // copies the whole array each time.
        var tracks = next.tracks
        defer { next.tracks = tracks }
        var paths: [String: UUID] = [:]
        for i in tracks.indices {
            if let refreshed = located[i] { tracks[i].reference = refreshed }
            paths[existingPaths[i]] = tracks[i].id
        }
        // Each new file is referenced once, however often the items list it.
        var pending: [String: Int] = [:], newURLs: [URL] = []
        for (item, path) in zip(items, itemPaths) where SupportedAudio.accepts(item.url) && paths[path] == nil && pending[path] == nil {
            pending[path] = newURLs.count; newURLs.append(item.url)
        }
        let made = await references.makeReferences(newURLs)
        guard editsEnabled else { throw CancellationError() }
        var ids: [UUID] = [], failed = 0
        var positions = Self.positions(tracks)
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard SupportedAudio.accepts(item.url) else { failed += 1; continue }
            let path = itemPaths[index]
            let fromFolder = roots.contains { path.hasPrefix($0) }
            if let id = paths[path] {
                if fromFolder, let i = positions[id] { tracks[i].registration = .folder }
                ids.append(id); continue
            }
            let reference: TrackReference
            if let created = pending[path].flatMap({ made[$0] }) { reference = created }
            else {
                if !allowMissing { failed += 1; continue }
                reference = TrackReference(bookmark: nil, lastKnownURL: item.url)
            }
            let name = item.title?.isEmpty == false ? item.title! : item.url.deletingPathExtension().lastPathComponent
            let track = LibraryTrack(name: name, reference: reference, registration: fromFolder ? .folder : .file)
            positions[track.id] = tracks.count
            tracks.append(track); paths[path] = track.id; ids.append(track.id)
            if reference.bookmark == nil && reference.mediaItemID == nil { unavailable[track.id] = LibraryFailure.unavailable.localizedDescription }
            // Adding a track takes tens of microseconds; a large import lets other main-actor work in between.
            if index % 32 == 31 { await Task.yield(); guard editsEnabled else { throw CancellationError() } }
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
            let items = try await Task.detached(priority: .userInitiated) { try M3U8.decode(try M3U8.read(url), relativeTo: url) }.value
            var next = document
            let ids = try await stage(items, in: &next, allowMissing: true)
            next.playlists.append(MusicPlaylist(name: url.deletingPathExtension().lastPathComponent, entries: ids.map { PlaylistEntry(trackID: $0) }))
            let skipped = error
            if commit(next) { error = skipped; message = "M3U8から\(ids.count)曲のリストを読み込みました。" }
        } catch { self.error = error.localizedDescription }
    }
    /// Writes the list with each track's current location, found and written on another thread.
    /// When some files lie outside the list's folder, `outside` asks how to write them; nil writes nothing.
    public func exportM3U8(_ playlistID: UUID, to url: URL, outside: @MainActor (Int) async -> M3U8OutsidePaths?) async {
        guard url.isFileURL else { error = LibraryFailure.inaccessible.localizedDescription; return }
        guard let list = playlist(playlistID), canEdit else { return }
        let scope = references.beginAccess(url)
        defer { withExtendedLifetime(scope) {} }
        do {
            let tracks = list.entries.compactMap { track($0.trackID) }
            let located = await references.located(tracks.map(\.reference))
            let items = zip(tracks, located).map { M3U8Item(url: $1?.lastKnownURL ?? $0.reference.lastKnownURL, title: $0.name) }
            let count = M3U8.outsideCount(items, relativeTo: url)
            var paths = M3U8OutsidePaths.fullPath
            if count > 0 {
                guard let chosen = await outside(count) else { return }
                paths = chosen
            }
            try await Task.detached(priority: .userInitiated) { try M3U8.encode(items, relativeTo: url, outside: paths).write(to: url, options: .atomic) }.value
            message = "M3U8を書き出しました。"; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Album tags

extension LibraryTrack {
    /// Not read yet, or read by an older reader without finding an album.
    var needsTags: Bool { tags.map { $0.album == nil && ($0.version ?? 1) < TrackTags.currentVersion } ?? true }
}

extension LibraryController {
    /// Reads the tags of tracks that have none yet in the background and saves them in batches,
    /// so new and older tracks join their albums. Tags never block an import or another edit:
    /// a batch that meets an import is dropped and read again when the import has finished.
    private func readMissingTags() {
        guard let tagReader, tagTask == nil, editsEnabled else { return }
        tagTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pending = Array(self.document.tracks.lazy.filter { $0.needsTags && !self.tagFailures.contains($0.id) }.prefix(Self.tagBatchSize))
                if pending.isEmpty { break }
                var read: [UUID: TrackTags] = [:]
                for track in pending {
                    guard let resolved = try? await self.references.resolved(track.reference) else { self.tagFailures.insert(track.id); continue }
                    if Task.isCancelled { return }
                    let tags = await tagReader.tags(for: resolved.url)
                    withExtendedLifetime(resolved.lease) {}
                    if Task.isCancelled { return }
                    if let tags { read[track.id] = tags } else { self.tagFailures.insert(track.id) }
                }
                if !self.saveTags(read) { break }
            }
            if !Task.isCancelled { self?.tagTask = nil }
        }
    }
    /// Saves read tags onto the current document. Tracks removed meanwhile are skipped.
    private func saveTags(_ read: [UUID: TrackTags]) -> Bool {
        guard editsEnabled, !isBusy else { return false }
        guard !read.isEmpty else { return true }
        var next = document
        for i in next.tracks.indices where next.tracks[i].needsTags {
            if var tags = read[next.tracks[i].id] { tags.version = TrackTags.currentVersion; next.tracks[i].tags = tags }
        }
        do { try next.validate(); try store.save(next); publish(next); return true }
        catch { return false }
    }
    /// Waits for the tags being read now. For tests.
    func waitForTags() async { while let task = tagTask { await task.value } }
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
        let choice = pendingChoice
        cancelPreparation()
        normalizesVolume = enabled; preferences.set(enabled, forKey: "normalizeVolume")
        playback.requireNormalization(enabled); normalizationNeedsPreparation = true
        levelMeasurement = enabled ? .pending : .disabled
        // A chosen track on its way is prepared again with the new settings; otherwise the playing one takes them.
        if let choice { prepareAgain(choice, autoPlay: choice.autoPlay, cause: "settings") } else { playOnWithNewSettings() }
    }
    /// The playing track takes the new strength at once; the level measurement is of the
    /// unprocessed audio and stays valid.
    public var bassEnhancement: BassEnhancement { playback.bassEnhancement }
    public func setBassEnhancement(_ enhancement: BassEnhancement) {
        guard !shuttingDown else { return }
        playback.setBassEnhancement(enhancement)
        preferences.set(enhancement.rawValue, forKey: "bassEnhancement")
    }
    public func setNormalizationTarget(_ target: Double) {
        guard !shuttingDown else { return }
        guard let settings = try? NormalizationSettings(targetLUFS: target), settings != normalizationSettings else { return }
        let previous = measuredLevels, choice = pendingChoice
        cancelPreparation(); measuredLevels = previous
        normalizationSettings = settings
        preferences.set(target, forKey: "normalizationTargetLUFS")
        playback.requireNormalization(normalizesVolume); normalizationNeedsPreparation = true
        levelMeasurement = normalizesVolume ? previous.map { .complete($0) } ?? .pending : .disabled
        // A chosen track on its way is prepared again with the new settings; otherwise the playing one takes them.
        if let choice { prepareAgain(choice, autoPlay: choice.autoPlay, cause: "settings") } else { playOnWithNewSettings() }
    }
    /// A playing track plays on as before while its start for the new settings is prepared (and
    /// measured if needed), then continues with them from where it is by then. A pause, a stop,
    /// another track or its end cancels that start; a paused track is prepared when it resumes.
    private func playOnWithNewSettings() {
        guard playback.state == .playing else { return }
        guard preprocessingEnabled, let list = document.currentPlaylistID, let entry = document.currentEntryID else {
            // Without a prepared start, the track pauses so that its level can change.
            playback.togglePlayPause(); playback.requireNormalization(normalizesVolume); return
        }
        beginPreparedSelection(entry, playlistID: list, autoPlay: true, position: nil)
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

    public func stop() {
        if selectionIntent != nil { Logger.selection.notice("Preparation ended: stopped by the listener") }
        cancelPreparation(); playback.stop()
    }

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
        let previous = backgroundRetirement, selection = selectionTask, next = nextTask, measurement = measurementTask, maps = mapTask
        if selection != nil || next != nil || measurement != nil || maps != nil {
            backgroundRetirement = Task {
                await previous?.value
                await selection?.value
                await next?.value
                await measurement?.value
                await maps?.value
            }
        }
        cancelTrackMap()
        selectionCancellation?.cancel(); selectionCancellation = nil
        selectionTask?.cancel(); selectionTask = nil; selectionIntent = nil; preparationID = UUID(); isPreparing = false
        cancelNext(); cancelMeasurement()
        measuredTrack = nil; peakMeasurement = measuresMaximumVolume ? .pending : .disabled
        measuredLevels = nil; levelMeasurement = normalizesVolume ? .pending : .disabled; preparationStage = nil
    }
    /// Selects an entry through the worker: reuses a matching speculative result when its
    /// source is unchanged, otherwise resolves, prepares a prefix and (for normalized
    /// playback) measures. Only the latest preparationID may commit the selection.
    /// A nil `position` follows the playing track: it starts from where that track is at the commit.
    /// `resume` is a saved position to start from, used only when it was saved in the same file and lies within it.
    private func beginPreparedSelection(_ entryID: UUID, playlistID: UUID, autoPlay: Bool, position: Double? = 0, shuffle: ShuffleStep = .keep,
                                        startsTrack: Bool = false, resume: ResumePosition? = nil, outputRetries: Int = 0,
                                        cause: String = "choice") {
        guard !shuttingDown else { return }
        playlistPreprocessingMayStart = true
        let requestedReference = currentReference(entryID, in: playlistID)
        if let intent = selectionIntent { Logger.selection.notice("Preparation ended: replaced (\(intent.cause, privacy: .public))") }
        let intent = SelectionIntent(entry: entryID, playlist: playlistID, autoPlay: autoPlay, position: position, shuffle: shuffle,
                                     startsTrack: startsTrack, resume: resume, cause: cause)
        selectionIntent = intent
        Logger.selection.notice("Preparation started (\(cause, privacy: .public)): \(autoPlay ? "plays" : "held", privacy: .public)")
        let handoff = takeOverPreparation(entryID, playlistID: playlistID, reference: requestedReference, autoPlay: autoPlay)
        let id = UUID(); preparationID = id
        let previousLevels = measuredLevels
        cancelMeasurement(); measuredTrack = nil
        peakMeasurement = measuresMaximumVolume ? .pending : .disabled
        isPreparing = true
        preparationStage = "音源ファイルを開いています…"
        selectionTask = Task { [weak self] in
            defer {
                if let self, self.preparationID == id, self.isPreparing {
                    self.endSelection()
                    if self.playback.state == .playing { self.resumePlaylistPreprocessing() }
                }
            }
            do {
                for retiring in handoff.retiring { await retiring?.value }
                try handoff.cancellation.check()
                if let failure = handoff.promoted?.failure { throw failure }
                // The track, not its reference: the check of the library may refresh the reference of the same file meanwhile.
                guard let self else { return }
                guard let entry = self.playlist(playlistID)?.entries.first(where: { $0.id == entryID }),
                      let track = self.track(entry.trackID) else {
                    if self.preparationID == id { Logger.selection.notice("Preparation ended: the entry was removed") }
                    return
                }
                let (resolved, prepared) = try await self.selectionAudio(for: track, handoff: handoff)
                let levels = try await self.selectionLevels(intent, track: track, url: resolved.url, prepared: prepared,
                                                            earlier: handoff.candidate?.levels ?? previousLevels, cancellation: handoff.cancellation)
                try handoff.cancellation.check()
                try self.commitSelection(id, intent: intent, track: track, resolved: resolved, prepared: prepared, levels: levels,
                                         earlierPeak: handoff.candidate?.peak, position: position, shuffle: shuffle)
            } catch {
                // The failed start has already ended this preparation, with the playback's failure.
                let failedStart = error is StartOnChangedOutput
                guard let self, self.preparationID == id || failedStart else { return }
                // The kind of failure only: a description may name the file.
                let reason = error is CancellationError ? "cancelled" : "failed (\(type(of: error)))"
                Logger.selection.notice("Preparation ended (\(cause, privacy: .public)): \(reason, privacy: .public)")
                self.endSelection()
                if failedStart || PlaybackError(error) == .outputChanged, autoPlay, outputRetries < Self.outputChangeRetries {
                    // The output was still changing (a new device settles its format in a moment):
                    // the track is measured again for the output it has then, and plays on.
                    self.retryAfterOutputChange(entryID, playlistID: playlistID, position: position,
                                                shuffle: self.document.currentEntryID == entryID ? .keep : shuffle,
                                                startsTrack: startsTrack, resume: resume, retries: outputRetries + 1)
                    return
                }
                if !(error is CancellationError) {
                    self.error = "再生を準備できませんでした。\(error.localizedDescription)"
                    if self.normalizesVolume { self.levelMeasurement = .failed(error.localizedDescription) }
                }
                self.updatePreprocessing()
            }
        }
    }

    /// A committed selection whose start failed: its levels were measured for an output that has changed since.
    private struct StartOnChangedOutput: LocalizedError {
        var errorDescription: String? { PlaybackError.outputChanged.localizedDescription }
    }
    /// How many times a selection that failed on a changing output is prepared again, and how long it waits first.
    static let outputChangeRetries = 3
    static let outputChangeRetryDelay = Duration.milliseconds(300)

    /// Prepares the selection again after a moment. Any other selection, stopping or a changed
    /// setting cancels the wait like a preparation.
    private func retryAfterOutputChange(_ entryID: UUID, playlistID: UUID, position: Double?, shuffle: ShuffleStep,
                                        startsTrack: Bool, resume: ResumePosition?, retries: Int) {
        Logger.output.notice("Preparation failed on the output's format: retry \(retries, privacy: .public)")
        let id = UUID(); preparationID = id
        // The choice stays known while it waits, so play, a repair or a changed setting finds it.
        selectionIntent = SelectionIntent(entry: entryID, playlist: playlistID, autoPlay: true, position: position, shuffle: shuffle,
                                          startsTrack: startsTrack, resume: resume, cause: "output")
        isPreparing = true
        preparationStage = "音声出力の切り替えを待っています…"
        selectionTask = Task { [weak self] in
            try? await Task.sleep(for: Self.outputChangeRetryDelay)
            guard !Task.isCancelled, let self, self.preparationID == id else { return }
            self.selectionIntent = nil
            self.beginPreparedSelection(entryID, playlistID: playlistID, autoPlay: true, position: position, shuffle: shuffle,
                                        startsTrack: startsTrack, resume: resume, outputRetries: retries, cause: "output")
        }
    }

    /// What a new selection takes over from the speculative work, and the work it waits for to retire.
    private struct SelectionHandoff {
        /// The sweep's or the next track's preparation of the same entry and reference.
        let candidate: NextPreparation?
        /// The candidate whose waiter and lease the selection takes over (normalized playback only).
        let promoted: NextPreparation?
        let fromSweep: Bool
        let retiring: [Task<Void, Never>?]
        let cancellation: PreparationCancellation
    }

    /// Takes over the speculative work for the entry, or cancels it, and cancels the previous selection.
    private func takeOverPreparation(_ entryID: UUID, playlistID: UUID, reference: TrackReference?, autoPlay: Bool) -> SelectionHandoff {
        let sweepTransfer = autoPlay && normalizesVolume ? trackForEntry(entryID, in: playlistID).flatMap { playlistPreprocessing?.take($0) } : nil
        // A sweep measures far tracks at background QoS; the listener now waits for this one.
        if let sweepTransfer { preprocessor.promote(sweepTransfer.0.cancellation) }
        playlistPreprocessing?.suspend()
        let sweepRetirement = playlistPreprocessing?.retirement
        let candidate = sweepTransfer?.0 ?? nextPrepared.flatMap { request in
            request.entry == entryID && request.reference == reference ? request : nil
        }
        // Transfer the existing waiter and lease, including a still-pending prefix.
        // OFF/metadata selections keep their cancellation path and never wait for a full scan.
        let promoted = autoPlay && normalizesVolume ? candidate : nil
        let promotedTask = sweepTransfer?.1 ?? (promoted == nil ? nil : nextTask)
        let retiringSelection = selectionTask, retiringNext = promoted == nil ? nextTask : nil
        selectionCancellation?.cancel(); selectionTask?.cancel()
        let cancellation = promoted?.cancellation ?? PreparationCancellation(); selectionCancellation = cancellation
        // Read before cancelling the next track, which adds that track's work to the background retirement.
        let retiringBackground = backgroundRetirement
        if promoted != nil {
            nextTask = nil; nextCancellation = nil; nextID = nil; nextPrepared = nil
        } else { cancelNext() }
        return SelectionHandoff(candidate: candidate, promoted: promoted, fromSweep: sweepTransfer != nil,
                                retiring: [sweepRetirement, retiringBackground, retiringSelection, retiringNext, promotedTask],
                                cancellation: cancellation)
    }

    /// The start of the track: the speculative prefix while its source is unchanged, a new prefix for a
    /// sweep's measured track, otherwise resolved and read again.
    private func selectionAudio(for track: LibraryTrack, handoff: SelectionHandoff) async throws -> (ResolvedTrack, PreparedAudio) {
        let cached = handoff.candidate
        if let cached, let audio = cached.audio, let access = cached.resolved,
           (try? audio.source.validate()) != nil, cached.reference == track.reference {
            return (access, audio)
        }
        if handoff.fromSweep, let cached, cached.audio == nil,
           let access = cached.resolved, cached.reference == track.reference,
           cached.levels?.profile == (try? AudioEngineBackend.measurementProfile()),
           (try? cached.levels?.source.validate()) != nil {
            return (access, try await preprocessor.preparePrefix(access.url, cancellation: handoff.cancellation))
        }
        // A changed source cannot keep an obsolete lease while reopening it.
        cached?.audio = nil; cached?.resolved = nil; cached?.levels = nil; cached?.peak = nil
        let resolved: ResolvedTrack
        do { resolved = try await references.resolved(track.reference) }
        catch {
            unavailable[track.id] = LibraryFailure.unavailable.localizedDescription
            throw error
        }
        return (resolved, try await preprocessor.preparePrefix(resolved.url, cancellation: handoff.cancellation))
    }

    /// The levels for normalized playback: an earlier result for the same source and output, otherwise measured now.
    private func selectionLevels(_ intent: SelectionIntent, track: LibraryTrack, url: URL, prepared: PreparedAudio,
                                 earlier: TrackAudioMetrics?, cancellation: PreparationCancellation) async throws -> TrackAudioMetrics? {
        guard intent.autoPlay, normalizesVolume else { return nil }
        let profile = try AudioEngineBackend.measurementProfile()
        let levels: TrackAudioMetrics
        if let earlier, earlier.source == prepared.source, earlier.profile == profile,
           (try? earlier.source.validate()) != nil { levels = earlier }
        else {
            preparationStage = "曲全体の音量を測定しています…"
            levels = try await preprocessor.measureLevels(url, profile: profile, cancellation: cancellation, ownerID: track.id)
        }
        guard try AudioEngineBackend.measurementProfile() == profile else { throw AudioProcessingFailure.outputChanged }
        return levels
    }

    /// Saves the selection and hands it to the player. A newer selection, read-only storage or a
    /// changed entry leaves everything as it was.
    private func commitSelection(_ id: UUID, intent: SelectionIntent, track: LibraryTrack, resolved: ResolvedTrack, prepared: PreparedAudio,
                                 levels: TrackAudioMetrics?, earlierPeak: TrackPeak?, position: Double?, shuffle: ShuffleStep) throws {
        guard preparationID == id, editsEnabled else { return }
        // The same entry and track: a reference refreshed meanwhile points to the same file (a repaired
        // track, another file, has started another preparation).
        guard let latest = playlist(intent.playlist)?.entries.first(where: { $0.id == intent.entry }), latest.trackID == track.id else {
            Logger.selection.notice("Preparation ended: the entry was removed or changed")
            return
        }
        // Read before the old run ends. A track that no longer plays needs no new start.
        if position == nil, playback.state != .playing { throw CancellationError() }
        var position = position ?? playback.currentTime
        if let resume = intent.resume {
            if resume.trackID == track.id, resume.source == ResumeSource(prepared), resume.seconds < prepared.duration { position = resume.seconds }
            else { Logger.selection.notice("Saved position not used: another file or beyond its end"); position = 0 }
        }
        let changesTrack = intent.startsTrack && changesTrack(to: intent.entry)
        var next = document
        recordShuffle(&next, entry: intent.entry, playlist: intent.playlist, step: shuffle)
        next.currentPlaylistID = intent.playlist; next.currentEntryID = intent.entry
        // Only a refreshed reference is written: an unchanged library keeps sharing its storage. One the
        // check refreshed meanwhile is newer than the one resolved here and stays.
        if let i = trackIndex[track.id], next.tracks[i].reference == track.reference, next.tracks[i].reference != resolved.reference {
            next.tracks[i].reference = resolved.reference
        }
        if intent.autoPlay {
            guard playback.selectPrepared(prepared, using: resolved.lease, metrics: levels,
                settings: normalizationSettings, committing: {
                if next != self.document { try self.store.save(next) }
            }) else { throw playback.error ?? PlaybackError.inaccessibleFile }
        } else {
            // The player holds only metadata while idle. The prepared start and its access stay
            // with the library, so pressing play starts without resolving and reading again;
            // stopping, choosing another entry or quitting releases them.
            guard playback.selectMetadata(url: resolved.url, duration: prepared.duration,
                supportsSeeking: prepared.supportsSeeking, using: resolved.lease, committing: {
                    if next != self.document { try self.store.save(next) }
                }) else { throw playback.error ?? PlaybackError.inaccessibleFile }
            let idle = NextPreparation(entry: intent.entry, reference: resolved.reference, trackID: track.id)
            idle.audio = prepared; idle.resolved = resolved
            nextPrepared = idle
        }
        if changesTrack { trackChangeID = UUID() }
        publish(next); unavailable[track.id] = nil; error = nil; message = nil
        isPreparing = false; selectionTask = nil; selectionCancellation = nil; selectionIntent = nil
        preparationStage = nil
        Logger.selection.notice("Preparation committed (\(intent.cause, privacy: .public)): \(intent.autoPlay ? "plays" : "held", privacy: .public)\(position > 0 ? " from a position" : "", privacy: .public)")
        heldSource = playback.selectedURL.map { ($0, ResumeSource(prepared)) }
        if position > 0 { playback.seek(to: position) }
        rememberPosition()
        measuredLevels = levels
        levelMeasurement = normalizesVolume ? levels.map { .complete($0) } ?? .pending : .disabled
        normalizationNeedsPreparation = false
        if measuresMaximumVolume, let peak = levels?.sourcePeak ?? earlierPeak, peak.source == prepared.source {
            measuredTrack = track.id; peakMeasurement = .complete(peak)
        }
        if intent.autoPlay {
            playback.togglePlayPause(using: resolved.lease)
            // Measured for an output that changed before the start: the selection prepares it again.
            if playback.error == .outputChanged { throw StartOnChangedOutput() }
        } else if playlistPreprocessing != nil { resumePlaylistPreprocessing() }
    }

    /// Read before the selection takes over the player.
    private func changesTrack(to entry: UUID) -> Bool {
        document.currentEntryID != entry || playback.state == .finished
    }

    /// Ends a selection that did not commit; its task retires behind the background work.
    private func endSelection() {
        let retiring = selectionTask, previous = backgroundRetirement
        backgroundRetirement = Task { await previous?.value; await retiring?.value }
        isPreparing = false; selectionTask = nil; selectionCancellation = nil; selectionIntent = nil
        preparationStage = nil
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
                                      adjacent: (adjacentEntry(1), adjacentEntry(-1)),
                                      nearOnly: playback.state == .paused || playback.state == .stopped)
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
        // Speculation runs at utility, so the preprocessor keeps it behind a listener's request.
        nextTask = Task(priority: .utility) {
            do {
                await retiringBackground?.value
                await retiringNext?.value
                try cancellation.check()
                let resolved = try await references.resolved(track.reference)
                // Retain this one lease through preparation, measurement, and any role transfer.
                request.resolved = resolved
                let prepared = try await preprocessor.preparePrefix(resolved.url, cancellation: cancellation)
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
    /// Follows playback state: playing starts speculation, paused keeps measured levels, a held track
    /// (moved before it plays) keeps its read-ahead, any other state retires background work.
    /// Paused or stopped, the sweep goes on with the current track and its neighbours only.
    /// A track the listener chose and that was still being prepared stays chosen: it is prepared again,
    /// without playing, since only stopping or another choice gives it up.
    private func updatePreprocessing() {
        guard preprocessingEnabled, !shuttingDown else { return }
        if playback.state == .playing {
            guard !isPreparing else { return }
            playlistPreprocessingMayStart = true
            prepareNext()
            if playlistPreprocessing == nil || playlistPreprocessing?.supportsProfile == false { measureCurrent() }
            loadTrackMap()
        } else if playback.state == .paused {
            let levels = measuredLevels, choice = pendingChoice
            cancelPreparation()
            measuredLevels = levels
            if normalizesVolume, let levels { levelMeasurement = .complete(levels) }
            prepareAgain(choice, autoPlay: false, cause: "paused")
            if choice == nil { resumeNearPreprocessing() }
        } else if playback.state == .finished, selectionTask != nil {
            // Natural advancement has already taken the prepared next entry.
            cancelNext(); cancelMeasurement()
        } else if playback.state == .ready {
            // Moved before it plays: the read-ahead it holds still starts it.
        } else {
            let choice = pendingChoice
            cancelPreparation()
            prepareAgain(choice, autoPlay: false, cause: "\(playback.state)")
            if choice == nil, playback.state == .stopped { resumeNearPreprocessing() }
        }
    }
    /// Paused or stopped, the current track and its neighbours in the playback order are still prepared
    /// and measured; the rest of the sweep waits for playback or a choice.
    private func resumeNearPreprocessing() {
        guard playlistPreprocessing != nil else { return }
        playlistPreprocessingMayStart = true
        resumePlaylistPreprocessing()
    }
    /// A track the listener chose (or the last one restored), still being prepared.
    private var pendingChoice: SelectionIntent? { selectionIntent.flatMap { $0.startsTrack && !$0.followsPlayback ? $0 : nil } }
    private func prepareAgain(_ choice: SelectionIntent?, autoPlay: Bool, cause: String) {
        guard let choice, !shuttingDown, selectionIntent == nil else { return }
        Logger.selection.notice("Preparation cancelled (\(cause, privacy: .public)): preparing the chosen track again")
        beginPreparedSelection(choice.entry, playlistID: choice.playlist, autoPlay: autoPlay, position: choice.position, shuffle: choice.shuffle,
                               startsTrack: true, resume: choice.resume, cause: choice.cause)
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
        measurementTask = Task(priority: .utility) { [weak self, lease, preprocessor] in
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

// MARK: - Track map

struct LoadedTrackMap {
    let url: URL
    let map: TrackMap
}

extension LibraryController {
    /// The beats and lead vocal of the track being played, found before playback (`AudioPreprocessing.trackMap`).
    /// Nil until they are known, and for a track that could not be mapped. A paused or stopped track keeps its map.
    public var currentTrackMap: TrackMap? {
        guard let loadedTrackMap, loadedTrackMap.url == playback.selectedURL else { return nil }
        return loadedTrackMap.map
    }
    /// Reads the current track's map from the cache, or joins or starts the scan that makes it. It shares
    /// the playing track's file access, so it adds no lease. In the background it waits for the foreground.
    private func loadTrackMap() {
        guard !isInBackground, let url = playback.selectedURL, let lease = playback.activeFileLease, let track = currentTrack,
              loadedTrackMap?.url != url, mapRequestURL != url else { return }
        cancelTrackMap()
        mapRequestURL = url
        let cancellation = PreparationCancellation(); mapCancellation = cancellation
        mapTask = Task(priority: .utility) { [weak self, lease, preprocessor] in
            defer { withExtendedLifetime(lease) {} }
            let map = try? await preprocessor.trackMap(url, cancellation: cancellation, ownerID: track.id)
            guard let self, self.mapCancellation === cancellation else { return }
            self.mapTask = nil; self.mapCancellation = nil
            // After a failure the request stays recorded, so the same track is not scanned again at once.
            if let map { self.loadedTrackMap = LoadedTrackMap(url: url, map: map) }
        }
    }
    private func backgroundChanged() {
        preprocessor.setBackground(isInBackground)
        playlistPreprocessing?.backgroundChanged(isInBackground)
        if !isInBackground, playback.state == .playing { loadTrackMap() }
    }
    private func cancelTrackMap() {
        mapCancellation?.cancel(); mapCancellation = nil
        mapTask?.cancel(); mapTask = nil; mapRequestURL = nil
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

/// MainActor-owned intent; only the current selection can be upgraded by a row click or play.
@MainActor private final class SelectionIntent {
    let entry: UUID
    let playlist: UUID
    var autoPlay: Bool
    /// Where it starts; nil follows the playing track (a new start for changed settings).
    let position: Double?
    let shuffle: ShuffleStep
    /// A new start of the playing track, which plays on until it is ready.
    var followsPlayback: Bool { position == nil }
    /// Chosen as a track to play, rather than started again for settings, a resume or a seek.
    let startsTrack: Bool
    let resume: ResumePosition?
    /// What started it, for the log.
    let cause: String
    init(entry: UUID, playlist: UUID, autoPlay: Bool, position: Double? = 0, shuffle: ShuffleStep = .keep, startsTrack: Bool = false,
         resume: ResumePosition? = nil, cause: String = "choice") {
        self.entry = entry; self.playlist = playlist; self.autoPlay = autoPlay; self.position = position; self.shuffle = shuffle
        self.startsTrack = startsTrack; self.resume = resume; self.cause = cause
    }
}

// MARK: - Resume position

extension Logger {
    /// Selections and their preparation: what started them and how they ended, never song names or paths.
    static let selection = Logger(subsystem: "io.github.boyaki-machine.LC-Music-Player", category: "selection")
}

extension LibraryController {
    /// Pausing or moving saves the position; stopping and the natural end forget it. While the track
    /// plays, a clock saves it every `positionSaveInterval`, since iOS may end the app without a word.
    func playbackActivityChanged() {
        switch playback.state {
        case .playing:
            rememberPosition(); runPositionClock()
        case .paused, .ready:
            stopPositionClock(); rememberPosition()
        case .stopped, .finished:
            stopPositionClock(); forgetPosition()
        case .empty, .failed:
            stopPositionClock()
        }
        updatePreprocessing()
    }
    /// Saves where the current track is, when the player holds it. An unchanged position writes nothing.
    func rememberPosition() {
        guard [.playing, .paused, .ready].contains(playback.state),
              let held = heldSource, held.url == playback.selectedURL, let track = currentTrack,
              let list = document.currentPlaylistID, let entry = document.currentEntryID else { return }
        savePosition(ResumePosition(playlistID: list, entryID: entry, trackID: track.id, seconds: playback.currentTime, source: held.source))
    }
    private func forgetPosition() { savePosition(nil) }
    private func savePosition(_ position: ResumePosition?) {
        guard position != resumePosition else { return }
        do { try store.savePosition(position); resumePosition = position }
        catch { Logger.selection.error("Position not saved (\(type(of: error), privacy: .public))") }
    }
    /// The saved position, on a track selected without preparation, when it was saved in the same file.
    func applyResume(_ resume: ResumePosition) {
        guard let held = heldSource, resume.trackID == currentTrack?.id, resume.source == held.source, resume.seconds < playback.duration else { return }
        playback.seek(to: resume.seconds)
    }
    private func runPositionClock() {
        guard positionClock == nil else { return }
        let interval = positionSaveInterval
        positionClock = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.playback.state == .playing else { return }
                self.rememberPosition()
            }
        }
    }
    private func stopPositionClock() { positionClock?.cancel(); positionClock = nil }
    /// The position as last saved. For tests.
    var savedPosition: ResumePosition? { resumePosition }
}
