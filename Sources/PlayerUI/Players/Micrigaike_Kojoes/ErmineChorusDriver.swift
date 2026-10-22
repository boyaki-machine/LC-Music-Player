import AnalysisCore
import Foundation
import Observation
import VisualizationKit

/// One 30fps clock for the ermine chorus, independent of the audio callback.
/// It follows the same lifecycle contract as `VisualizationDriver`: it runs only while visible and playing,
/// settles to the idle pose after a pause, and stops at once when stopped or hidden.
@Observable @MainActor
public final class ErmineChorusDriver: PlayerVisualizationDriver {
    static let frameInterval = Duration.milliseconds(33)
    /// After a pause the ermines close their mouths and settle before the clock stops.
    static let settleSeconds = 1.2
    static let dataTimeout = 0.25
    static let maxPending = 64

    private(set) var drawings: [ErmineDrawing] = ErmineChorusDriver.idleDrawings()
    private(set) var stage = ErmineStage()
    private(set) var dust = ErmineDust().motes
    public private(set) var waitingForData = false
    @ObservationIgnored public private(set) var activity: VisualizationActivity = .inactive
    @ObservationIgnored public private(set) var isVisible = false
    @ObservationIgnored public var reduceMotion = false {
        didSet { for i in directors.indices { directors[i].reduceMotion = reduceMotion } }
    }
    @ObservationIgnored private(set) var directors: [ErmineDirector] = ErmineChorusDriver.makeDirectors()
    @ObservationIgnored private var tweens = Array(repeating: ErmineInbetweener(), count: ErmineCast.members.count)
    @ObservationIgnored private(set) var ensemble = ErmineEnsemble()
    @ObservationIgnored private var armTweens = Array(repeating: ErmineArmTween(), count: ErmineCast.members.count)
    @ObservationIgnored private(set) var beats = ErmineBeatTracker()
    @ObservationIgnored private var dustField = ErmineDust()
    @ObservationIgnored private var bands = ErmineBandLevels()
    @ObservationIgnored private(set) var levels = Array(repeating: 0.0, count: ErmineRange.allCases.count)
    @ObservationIgnored private var pending: [(at: Double, levels: [Double])] = []
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var lastProduced: Double?
    @ObservationIgnored private var lastData = 0.0
    @ObservationIgnored private var lastStep: Double?
    @ObservationIgnored private var pausedAt: Double?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tickerID = UUID()
    public var isRunning: Bool { ticker != nil }
    var pendingCount: Int { pending.count }

    public init() {}
    deinit { ticker?.cancel() }

    private static func makeDirectors() -> [ErmineDirector] {
        ErmineCast.members.enumerated().map { ErmineDirector(member: $1, seed: 51 + UInt64($0) * 17) }
    }
    private static func idleDrawings() -> [ErmineDrawing] {
        ErmineCast.members.map { _ in ErmineDrawing(pose: ErmineKeyName.idleA.key, frame: ErmineFrame()) }
    }

    public func synchronize(activity next: VisualizationActivity, visible: Bool) {
        let old = activity
        activity = next; isVisible = visible
        guard visible, next != .inactive else { stop(); return }
        let now = VisualizationClock.now()
        if next == .paused && old != .paused { pausedAt = now; pending.removeAll() }
        if next == .playing && old != .playing { pausedAt = nil; lastData = now; lastStep = now }
        updateTicker()
    }

    /// Seek, new analysis and similar: drop queued data and the register sensitivity; the ermines keep their places.
    public func reset() {
        pending.removeAll(); bands.reset(); beats.reset(); generation = nil; lastSequence = nil; lastProduced = nil
        levels = Array(repeating: 0, count: levels.count)
        lastData = VisualizationClock.now()
        updateTicker()
    }

    public func receive(_ frame: AnalysisFrame) {
        guard isVisible, activity == .playing else { return }
        if frame.generation != generation {
            generation = frame.generation; lastSequence = nil; lastProduced = nil; pending.removeAll(); bands.reset(); beats.reset()
        }
        if let lastSequence, frame.sequence <= lastSequence { return }
        let produced = frame.timing.producedHostTime
        let dt = lastProduced.map { min(0.5, max(0, produced - $0)) } ?? 0
        guard let next = bands.levels(bandDBFS: frame.bandDBFS, edgesHz: frame.bandEdgesHz, dt: dt),
              let registers = ErmineBandLevels.registerDB(bandDBFS: frame.bandDBFS, edgesHz: frame.bandEdgesHz) else { return }
        lastSequence = frame.sequence; lastProduced = produced
        let now = VisualizationClock.now()
        // Wait for the estimated presentation time, as the LED design does; invalid times show at once.
        var at = frame.timing.estimatedPresentationHostTime ?? now
        if !at.isFinite || at > now + 2 || at < now - 2 { at = now }
        pending.append((at, next))
        beats.feed(registerDB: registers, at: at)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        updateTicker()
    }

    /// Advances the chorus to `now`. Called by the clock; tests call it directly.
    func step(now: Double) {
        // Adopted slightly before the estimated presentation time, as the LED design does.
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
        ensemble.follow(playing && !waiting ? beats.beat(at: due) : nil)
        ensemble.update(&directors, dt: dt, playing: playing)
        let world = ErmineWorld(ermine1Intense: directors.first { $0.member.id == 1 }?.intense ?? false, beat: ensemble.beat)
        var next: [ErmineDrawing] = []
        for i in directors.indices {
            directors[i].step(dt: dt, level: levels[directors[i].member.range.rawValue], playing: playing, world: world)
            var frame = directors[i].frame
            frame.effects.notes = directors[i].notes(at: now)
            let body = tweens[i].pose(for: frame.key, at: now)
            next.append(ErmineDrawing(pose: armTweens[i].apply(frame.arms, to: frame.key, pose: body, at: now), frame: frame))
        }
        drawings = next
        if stage != ensemble.stage { stage = ensemble.stage }
        dustField.step(dt: dt); dust = dustField.motes
    }

    private func stop() {
        tickerID = UUID(); ticker?.cancel(); ticker = nil
        pending.removeAll(); bands.reset(); generation = nil; lastSequence = nil; lastProduced = nil; pausedAt = nil
        levels = Array(repeating: 0, count: levels.count)
        directors = Self.makeDirectors().map { var d = $0; d.reduceMotion = reduceMotion; return d }
        tweens = Array(repeating: ErmineInbetweener(), count: tweens.count)
        ensemble = ErmineEnsemble(); stage = ErmineStage(); beats.reset()
        armTweens = Array(repeating: ErmineArmTween(), count: armTweens.count)
        drawings = Self.idleDrawings(); waitingForData = false; lastStep = nil
    }

    private var needsClock: Bool {
        guard isVisible else { return false }
        if activity == .playing { return true }
        if activity == .paused, let pausedAt { return VisualizationClock.now() - pausedAt < Self.settleSeconds }
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
