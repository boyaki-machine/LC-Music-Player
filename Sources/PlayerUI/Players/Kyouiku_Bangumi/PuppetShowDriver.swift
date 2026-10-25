import AnalysisCore
import AudioProcessingCore
import Foundation
import Observation
import VisualizationKit

/// Where the puppets get the beat when the track's map has no clear beat: estimated while playing.
protocol PuppetBeatSource: Sendable {
    mutating func reset()
    /// The registers' levels in dB (bass, low mid, high mid, high) at the time they will be heard.
    mutating func feed(registerDB: [Double], at time: Double)
    /// The beat at `time`, or nil while the tempo is unknown.
    func beat(at time: Double) -> (index: Int, phase: Double, period: Double)?
}

/// The same estimate as the ermine chorus.
extension ErmineBeatTracker: PuppetBeatSource {}

/// One 30fps clock for the puppet show, following the same lifecycle as the other designs: it runs only while
/// visible and playing, lets the puppets settle after a pause, and stops at once when stopped or hidden.
/// The time of day advances only while playing and is kept when stopped.
@Observable @MainActor
public final class PuppetShowDriver: PlayerVisualizationDriver {
    static let frameInterval = Duration.milliseconds(33)
    static let settleSeconds = 1.5
    static let dataTimeout = 0.25
    static let maxPending = 64
    /// Below this clarity the map's beats are not followed and the live estimate decides.
    static let minimumMapClarity = 0.3
    /// How long the last frame's track position is extrapolated.
    static let trackClockLimit = 1.0

    private(set) var scene = PuppetShowScene()
    public private(set) var waitingForData = false
    @ObservationIgnored public private(set) var activity: VisualizationActivity = .inactive
    @ObservationIgnored public private(set) var isVisible = false
    @ObservationIgnored public var reduceMotion = false
    @ObservationIgnored private(set) var directors = PuppetShowDriver.makeDirectors()
    @ObservationIgnored private(set) var ensemble = PuppetEnsemble()
    @ObservationIgnored var beats: any PuppetBeatSource = ErmineBeatTracker()
    @ObservationIgnored private(set) var trackMap: TrackMap?
    /// Who sings which phrase of the current map's vocal; nil when it has no sung phrase.
    @ObservationIgnored private(set) var casting: PuppetCasting?
    @ObservationIgnored private(set) var vocal: PuppetVocal?
    var beatMap: BeatMap? { trackMap?.beats }
    /// The track position of the newest frame and the host time it is heard at.
    @ObservationIgnored private var trackClock: (host: Double, track: Double)?
    @ObservationIgnored private var registers = PuppetRegisterLevels()
    @ObservationIgnored private(set) var levels = Array(repeating: 0.0, count: PuppetRegister.allCases.count)
    @ObservationIgnored private var pending: [(at: Double, levels: [Double])] = []
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var lastProduced: Double?
    @ObservationIgnored private var lastData = 0.0
    @ObservationIgnored private var lastStep: Double?
    @ObservationIgnored private var pausedAt: Double?
    @ObservationIgnored private var beatCount = 0
    @ObservationIgnored private var lastBeatIndex: Int?
    @ObservationIgnored private(set) var beat: PuppetBeat?
    /// Seconds of playback so far and the time of day; both survive stopping.
    @ObservationIgnored private(set) var showTime = 0.0
    @ObservationIgnored private(set) var timeOfDay = 0.05
    @ObservationIgnored var date: () -> Date = Date.init
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tickerID = UUID()
    public var isRunning: Bool { ticker != nil }
    var pendingCount: Int { pending.count }

    public init() { scene.moonAge = PuppetBackdrop.moonAge(at: Date()) }
    deinit { ticker?.cancel() }

    private static func makeDirectors() -> [PuppetDirector] { PuppetMember.all.map { PuppetDirector(member: $0) } }

    public func synchronize(activity next: VisualizationActivity, visible: Bool) {
        let old = activity
        activity = next; isVisible = visible
        guard visible, next != .inactive else { stop(); return }
        let now = VisualizationClock.now()
        if next == .paused && old != .paused { pausedAt = now; pending.removeAll() }
        if next == .playing && old != .playing { pausedAt = nil; lastData = now; lastStep = now }
        updateTicker()
    }

    /// Seek, new analysis and similar: drop queued data, the register sensitivity and the beat; the puppets stay.
    public func reset() {
        pending.removeAll(); registers.reset(); beats.reset(); generation = nil; lastSequence = nil; lastProduced = nil; trackClock = nil
        levels = Array(repeating: 0, count: levels.count)
        lastData = VisualizationClock.now()
        updateTicker()
    }

    public func receive(_ frame: AnalysisFrame) {
        guard isVisible, activity == .playing else { return }
        if frame.generation != generation {
            generation = frame.generation; lastSequence = nil; lastProduced = nil; pending.removeAll(); registers.reset(); beats.reset()
            trackClock = nil
        }
        if let lastSequence, frame.sequence <= lastSequence { return }
        guard let db = PuppetRegisterLevels.registerDB(bandDBFS: frame.bandDBFS, edgesHz: frame.bandEdgesHz) else { return }
        let produced = frame.timing.producedHostTime
        let dt = lastProduced.map { min(0.5, max(0, produced - $0)) } ?? 0
        lastSequence = frame.sequence; lastProduced = produced
        let now = VisualizationClock.now()
        // Wait for the estimated presentation time, as the other designs do; invalid times show at once.
        var at = frame.timing.estimatedPresentationHostTime ?? now
        if !at.isFinite || at > now + 2 || at < now - 2 { at = now }
        pending.append((at, registers.levels(registerDB: db, dt: dt)))
        beats.feed(registerDB: db, at: at)
        if let track = frame.trackSeconds { trackClock = (at, track) }
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        updateTicker()
    }

    /// The track's beats and vocal, found before playback. Kept until the next track's map or nil arrives.
    public func receive(trackMap: TrackMap?) {
        guard trackMap != self.trackMap else { return }
        self.trackMap = trackMap
        casting = trackMap.map { PuppetCasting(vocals: $0.vocals) }.flatMap { $0.phrases.isEmpty ? nil : $0 }
    }

    /// Seconds into the track heard at host time `time`, while the newest frame's position is recent enough.
    func trackPosition(at time: Double) -> Double? {
        guard let trackClock, time - trackClock.host < Self.trackClockLimit else { return nil }
        return trackClock.track + (time - trackClock.host)
    }

    /// The beat at host time `time`: from the beat map where it is clear and the track position is known,
    /// otherwise from the live estimate. The map has no beat before its first and after its last.
    func trackedBeat(at time: Double) -> (index: Int, phase: Double, period: Double)? {
        if let beatMap, beatMap.clarity >= Self.minimumMapClarity, let position = trackPosition(at: time) {
            return beatMap.beat(at: position)
        }
        return beats.beat(at: time)
    }

    /// Counts beats only upward, so "every other beat" stays steady while the estimate is refined.
    private func follow(_ tracked: (index: Int, phase: Double, period: Double)?) {
        guard let tracked, tracked.period > 0 else { beat = nil; lastBeatIndex = nil; return }
        if let last = lastBeatIndex, tracked.index != last { beatCount += max(1, min(2, tracked.index - last)) }
        lastBeatIndex = tracked.index
        beat = PuppetBeat(count: Double(beatCount) + tracked.phase, bpm: 60 / tracked.period)
    }

    /// Advances the show to `now`. Called by the clock; tests call it directly.
    func step(now: Double) {
        // Adopted slightly before the estimated presentation time, as the other designs do.
        let due = now + VisualizationClock.presentationLead
        if let index = pending.lastIndex(where: { $0.at <= due }) {
            levels = pending[index].levels; lastData = now
            pending.removeFirst(index + 1)
        }
        let playing = activity == .playing
        let waiting = playing && now - lastData > Self.dataTimeout
        if waiting || !playing { levels = Array(repeating: 0, count: levels.count) }
        if waitingForData != waiting { waitingForData = waiting }
        let dt = min(0.1, max(0, now - (lastStep ?? now))); lastStep = now
        if playing {
            showTime += dt
            timeOfDay = (timeOfDay + dt / PuppetBackdrop.daySeconds).truncatingRemainder(dividingBy: 1)
        }
        follow(playing && !waiting ? trackedBeat(at: due) : nil)
        // The vocal at the same moment, when the map has one.
        let position = playing && !waiting ? trackPosition(at: due) : nil
        vocal = nil
        if let casting, let position, let vocals = trackMap?.vocals { vocal = vocals.puppetVocal(at: position) }
        for i in directors.indices {
            if vocal != nil, let casting, let position {
                let part = casting.part(of: i, at: position)
                directors[i].update(dt: dt, now: showTime, levels: levels, beat: beat, playing: playing,
                                    vocal: vocal, part: part, register: casting.register(for: part))
            } else {
                directors[i].update(dt: dt, now: showTime, levels: levels, beat: beat, playing: playing)
            }
        }
        if playing { ensemble.update(&directors, now: showTime) }
        var next = scene
        next.timeOfDay = timeOfDay; next.time = showTime; next.reduceMotion = reduceMotion
        next.poses = directors.map { $0.pose(now: showTime, reduceMotion: reduceMotion) }
        // The moon's age changes slowly; read the date about once a minute of playback.
        if Int(showTime / 60) != Int((showTime - dt) / 60) || dt == 0 { next.moonAge = PuppetBackdrop.moonAge(at: date()) }
        scene = next
    }

    private func stop() {
        tickerID = UUID(); ticker?.cancel(); ticker = nil
        pending.removeAll(); registers.reset(); generation = nil; lastSequence = nil; lastProduced = nil; pausedAt = nil
        levels = Array(repeating: 0, count: levels.count)
        directors = Self.makeDirectors(); ensemble = PuppetEnsemble(); beats.reset(); trackClock = nil
        beat = nil; beatCount = 0; lastBeatIndex = nil
        var idle = scene
        idle.poses = directors.map { $0.pose(now: showTime, reduceMotion: reduceMotion) }
        scene = idle
        waitingForData = false; lastStep = nil
    }

    private var needsClock: Bool {
        guard isVisible else { return false }
        if activity == .playing { return true }
        if activity == .paused, let pausedAt {
            return VisualizationClock.now() - pausedAt < Self.settleSeconds && !directors.allSatisfy(\.isSettled)
        }
        return false
    }

    private func updateTicker() {
        guard needsClock else { tickerID = UUID(); ticker?.cancel(); ticker = nil; return }
        guard ticker == nil else { return }
        let id = UUID(); tickerID = id
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.frameInterval) } catch { return }
                guard self?.tick(id: id) == true else { return }
            }
        }
    }

    private func tick(id: UUID) -> Bool {
        guard tickerID == id else { return false }
        step(now: VisualizationClock.now())
        if !needsClock { ticker = nil; return false }
        return true
    }
}
