import Foundation
import PlaybackCore
import PreprocessingCore
import AudioProcessingCore

/// A single speculative slot, shared by playlist measurements and the next prefix.
/// All ownership changes happen on MainActor; decoding and cache I/O stay on the worker.
@MainActor final class PlaylistPreprocessing {
    struct Candidate: Equatable {
        let entry: UUID
        let track: LibraryTrack
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.track == rhs.track }
    }
    private struct Attempt {
        let reference: TrackReference
        let profile: MeasurementProfile
        let source: SourceFingerprint?
    }
    private let references: any FileReferenceProvider
    private let worker: any AudioPreprocessing
    private let profileProvider: @MainActor () throws -> MeasurementProfile
    var onMeasured: (@MainActor (UUID, TrackAudioMetrics) -> Void)?
    private(set) var active: NextPreparation?
    private var task: Task<Void, Never>?
    private(set) var retirement: Task<Void, Never>?
    private var candidates: [Candidate] = []
    private var attempts: [UUID: Attempt] = [:]
    private var profile: MeasurementProfile?
    var supportsProfile: Bool { profile != nil }
    private var nextCandidate: Candidate?
    private var nextMetrics: (UUID, TrackAudioMetrics)?
    private var currentID: UUID?
    private var previousID: UUID?
    /// In Low Power Mode or when the device runs hot, the sweep measures only the current track and
    /// its neighbours, and goes on with the rest when the state eases.
    var isEnergyConstrained: @MainActor () -> Bool = {
        ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
    private var energyObservers: [any NSObjectProtocol] = []
    private var publishedCurrent: UUID?
    private var currentURL: URL?
    private var currentLease: FileLease?
    private var suspended = true
    private var outputObserver: PlaylistOutputObserver?
    isolated deinit { suspend(); energyObservers.forEach(NotificationCenter.default.removeObserver) }

    init(references: any FileReferenceProvider, worker: any AudioPreprocessing,
         profile: @escaping @MainActor () throws -> MeasurementProfile) {
        self.references = references; self.worker = worker; profileProvider = profile
    }

    typealias Adjacent = (next: PlaylistEntry?, previous: PlaylistEntry?)

    /// Neighbors in playlist order. LibraryController passes the shuffle order's neighbors instead.
    static func listAdjacent(_ document: LibraryDocument) -> Adjacent {
        guard let list = document.playlists.first(where: { $0.id == document.currentPlaylistID }),
              let i = list.entries.firstIndex(where: { $0.id == document.currentEntryID }) else { return (nil, nil) }
        return (list.entries.indices.contains(i + 1) ? list.entries[i + 1] : nil, i > 0 ? list.entries[i - 1] : nil)
    }

    /// Deduplicate logical tracks without changing entry identity or playback order.
    static func ordered(_ document: LibraryDocument, playing: Bool, adjacent: Adjacent? = nil) -> [Candidate] {
        let tracks = Dictionary(uniqueKeysWithValues: document.tracks.map { ($0.id, $0) })
        let current = document.playlists.first { $0.id == document.currentPlaylistID }
        var entries: [PlaylistEntry] = []
        if playing, let list = current, let i = list.entries.firstIndex(where: { $0.id == document.currentEntryID }) {
            let adjacent = adjacent ?? listAdjacent(document)
            entries.append(list.entries[i])
            if let next = adjacent.next { entries.append(next) }
            if let previous = adjacent.previous { entries.append(previous) }
        }
        entries += current?.entries ?? []
        entries += document.playlists.filter { $0.id != current?.id }.flatMap(\.entries)
        var seen: Set<UUID> = []
        return entries.compactMap { entry in
            guard seen.insert(entry.trackID).inserted, let track = tracks[entry.trackID] else { return nil }
            return Candidate(entry: entry.id, track: track)
        }
    }

    func update(_ document: LibraryDocument, playback: PlaybackController, after audit: Task<Void, Never>?,
                completed: TrackAudioMetrics? = nil, retryFailures: Bool = false, adjacent: Adjacent? = nil) {
        let newProfile = try? profileProvider()
        let adjacent = adjacent ?? Self.listAdjacent(document)
        candidates = Self.ordered(document, playing: playback.state == .playing, adjacent: adjacent)
        let tracks = Dictionary(uniqueKeysWithValues: candidates.map { ($0.track.id, $0.track) })
        attempts = attempts.filter { id, attempt in
            guard tracks[id]?.reference == attempt.reference, attempt.profile == newProfile else { return false }
            if let source = attempt.source { return (try? source.validate()) != nil }
            return !retryFailures
        }
        if profile != newProfile { publishedCurrent = nil }
        profile = newProfile
        currentID = document.currentPlaylistID.flatMap { list in document.playlists.first { $0.id == list } }?
            .entries.first { $0.id == document.currentEntryID }?.trackID
        currentURL = playback.selectedURL; currentLease = playback.activeFileLease
        nextCandidate = nil
        previousID = adjacent.previous?.trackID
        if playback.state == .playing, let entry = adjacent.next,
           let track = document.tracks.first(where: { $0.id == entry.trackID }) {
            nextCandidate = Candidate(entry: entry.id, track: track)
        }
        if let completed, let id = currentID, let track = tracks[id], completed.profile == profile,
           completed.source.url == playback.selectedURL, (try? completed.source.validate()) != nil {
            attempts[id] = Attempt(reference: track.reference, profile: completed.profile, source: completed.source)
            publishedCurrent = id
        }
        // A completed idle sweep has no current display recipient. Load the current
        // cached result once after playback starts, even when its scan is already done.
        if playback.state == .playing, let currentID, publishedCurrent != currentID { attempts[currentID] = nil }
        if let completed, let nextCandidate, nextCandidate.track.id == currentID,
           completed.profile == profile { nextMetrics = (nextCandidate.track.id, completed) }
        if let metrics = nextMetrics, metrics.0 != nextCandidate?.track.id || metrics.1.profile != profile ||
           (try? metrics.1.source.validate()) == nil { nextMetrics = nil }
        suspended = false
        if outputObserver == nil {
            outputObserver = PlaylistOutputObserver { [weak self] in self?.outputChanged() }
        }
        guard newProfile != nil else { retireActive(); return }
        let desired = pending.first ?? preparedNextCandidate
        if let active, active.trackID != desired?.track.id || active.reference != desired?.track.reference || active.profile != profile {
            retireActive()
        }
        // Audit and prior worker returns must finish before acquiring another scope.
        let previous = retirement
        retirement = Task { await previous?.value; await audit?.value }
        pump()
    }

    private var pending: [Candidate] { candidates.filter { attempts[$0.track.id] == nil } }
    private var preparedNextCandidate: Candidate? {
        guard let nextCandidate, attempts[nextCandidate.track.id]?.source != nil else { return nil }
        return nextCandidate
    }

    /// Transfer in-flight work, including a measurement with no prefix yet.
    func take(_ track: LibraryTrack) -> (NextPreparation, Task<Void, Never>?)? {
        guard let active, active.trackID == track.id, active.reference == track.reference,
              active.profile == (try? profileProvider()) else { return nil }
        let result = (active, task)
        self.active = nil; task = nil
        suspended = true; currentLease = nil; publishedCurrent = nil; outputObserver = nil
        return result
    }

    func suspend() {
        suspended = true; currentLease = nil; currentURL = nil; publishedCurrent = nil; outputObserver = nil
        retireActive()
    }

    func outputChanged() {
        guard !suspended else { return }
        retireActive()
        profile = try? profileProvider()
        attempts.removeAll(); nextMetrics = nil; publishedCurrent = nil
        pump()
    }

    private func retireActive() {
        active?.cancellation.cancel(); task?.cancel()
        if let task {
            let previous = retirement
            retirement = Task { await previous?.value; await task.value }
        }
        active = nil; task = nil
    }

    /// Called when Low Power Mode or the thermal state changes.
    func energyStateChanged() { if !suspended { pump() } }

    private func observeEnergyState() {
        guard energyObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            energyObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.energyStateChanged() }
            })
        }
    }

    private func pump() {
        guard !suspended, active == nil, let profile, let candidate = pending.first ?? preparedNextCandidate else { return }
        let near = candidate.track.id == currentID || candidate.track.id == nextCandidate?.track.id || candidate.track.id == previousID
        if !near, isEnergyConstrained() { observeEnergyState(); return }
        let measure = attempts[candidate.track.id] == nil
        let prefix = candidate.entry == nextCandidate?.entry
        let request = NextPreparation(entry: candidate.entry, reference: candidate.track.reference, trackID: candidate.track.id)
        request.profile = profile
        if !measure, let metrics = nextMetrics, metrics.0 == candidate.track.id {
            request.levels = metrics.1; request.peak = metrics.1.sourcePeak
        }
        active = request
        let previous = retirement, references = references, worker = worker
        let sharedLease = candidate.track.id == currentID ? currentLease : nil
        let sharedURL = sharedLease == nil ? nil : currentURL
        // The current track and its neighbours run at utility, behind a listener's request. The rest of
        // the sweep runs at background, on the efficiency cores: about a sixth of the energy, six times slower.
        task = Task(priority: near ? .utility : .background) { [weak self] in
            do {
                await previous?.value
                try request.cancellation.check()
                if let sharedLease, let sharedURL {
                    request.resolved = ResolvedTrack(url: sharedURL, reference: request.reference, lease: sharedLease)
                } else { request.resolved = try await references.resolved(request.reference) }
                let url = request.resolved!.url
                if prefix {
                    request.audio = try await worker.preparePrefix(url, cancellation: request.cancellation)
                }
                if measure {
                    request.levels = try await worker.measureLevels(url, profile: profile, cancellation: request.cancellation, ownerID: candidate.track.id)
                    request.peak = request.levels?.sourcePeak
                }
                try request.cancellation.check()
                guard let self else { return }
                guard try self.profileProvider() == profile else { throw AudioProcessingFailure.outputChanged }
                if let levels = request.levels { try levels.source.validate() }
                guard self.active === request else { return } // A foreground consumer owns it now.
                if measure { self.attempts[candidate.track.id] = Attempt(reference: request.reference, profile: profile, source: request.levels?.source) }
                if let levels = request.levels {
                    if candidate.track.id == self.nextCandidate?.track.id { self.nextMetrics = (candidate.track.id, levels) }
                    if candidate.track.id == self.currentID { self.publishedCurrent = candidate.track.id }
                    self.onMeasured?(candidate.track.id, levels)
                }
                self.finish(request, retainPrefix: prefix && self.pending.isEmpty)
            } catch {
                request.failure = error
                guard let self, self.active === request else { return }
                if !(error is CancellationError) {
                    self.attempts[candidate.track.id] = Attempt(reference: request.reference, profile: profile, source: nil)
                }
                self.finish(request, retainPrefix: false)
            }
        }
    }

    private func finish(_ request: NextPreparation, retainPrefix: Bool) {
        guard active === request else { return }
        if retainPrefix { return }
        // The next Task waits for this Task's return, so even transient locals have retired.
        retirement = task; task = nil; active = nil
        request.audio = nil; request.resolved = nil
        pump()
    }
}
