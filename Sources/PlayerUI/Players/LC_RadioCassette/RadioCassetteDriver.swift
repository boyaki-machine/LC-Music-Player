import AnalysisCore
import Foundation
import Observation
import VisualizationKit

/// The stereo level meter: 24 cells per channel from the channel's RMS. Like the LED equalizer,
/// a cell lights at once and the column falls back within about 300ms.
struct RadioCassetteMeter: Equatable {
    static let cells = 24
    /// RMS plus this many dB reads like a programme peak; −30...0dB of that fills the column.
    static let crestDB: Float = 3, floorDB: Float = -30
    static let fallSeconds = 0.3

    private(set) var levels = [0.0, 0.0]
    var litCells: [Int] { levels.map { min(Self.cells, Int(($0 * Double(Self.cells)) + 1e-6)) } }

    static func level(rms: Float) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms) + crestDB
        return Double(min(1, max(0, (db - floorDB) / -floorDB)))
    }
    /// `targets` nil lets the columns fall to nothing.
    mutating func follow(_ targets: [Double]?, dt: Double, reduceMotion: Bool) {
        for i in levels.indices {
            let target = targets?[i] ?? 0
            levels[i] = target >= levels[i] || reduceMotion ? target : max(target, levels[i] - dt / Self.fallSeconds)
        }
    }
    mutating func clear() { levels = [0, 0] }
}

/// What one drawing of the radio cassette shows.
struct RadioCassetteFrame: Equatable {
    var tape = RadioCassetteTape()
    var litCells = [0, 0]
    var indicators: [RadioCassetteIndicator] = RadioCassetteStatus().indicators + [RadioCassetteStatus.direction(reverse: false)]
}

/// Draws frames; the layer view, without SwiftUI updating every frame.
@MainActor protocol RadioCassetteRendering: AnyObject {
    func render(_ frame: RadioCassetteFrame)
}

/// One 30fps clock for the radio cassette. It runs only while visible and playing: a pause holds the
/// tape and the meter where they are, a stop empties the meter. The tape keeps its place for as long
/// as the app runs, and reverses with every new track.
@Observable @MainActor
public final class RadioCassetteDriver: PlayerVisualizationDriver {
    static let frameInterval = Duration.milliseconds(33)
    static let dataTimeout = 0.25
    static let maxPending = 64

    public private(set) var waitingForData = false
    @ObservationIgnored public private(set) var activity: VisualizationActivity = .inactive
    @ObservationIgnored public private(set) var isVisible = false
    @ObservationIgnored public var reduceMotion = false
    @ObservationIgnored private(set) var frame = RadioCassetteFrame()
    @ObservationIgnored private(set) var status = RadioCassetteStatus()
    /// The lamps change rarely; they are worked out again only when their sources change.
    @ObservationIgnored private var indicators: (status: RadioCassetteStatus, reverse: Bool, lamps: [RadioCassetteIndicator])?
    @ObservationIgnored private var meter = RadioCassetteMeter()
    @ObservationIgnored private var selection: UUID?
    @ObservationIgnored private weak var renderer: (any RadioCassetteRendering)?
    @ObservationIgnored private var pending: [(at: Double, levels: [Double])] = []
    @ObservationIgnored private var target: [Double]?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var lastData = 0.0
    @ObservationIgnored private var lastStep: Double?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tickerID = UUID()
    public var isRunning: Bool { ticker != nil }
    var pendingCount: Int { pending.count }

    public init() {}
    deinit { ticker?.cancel() }

    func attach(_ renderer: any RadioCassetteRendering) { self.renderer = renderer; renderer.render(frame) }

    public func synchronize(activity next: VisualizationActivity, visible: Bool) {
        let old = activity
        activity = next; isVisible = visible
        guard visible, next != .inactive else { stop(); publish(); return }
        let now = VisualizationClock.now()
        if next == .paused { pending.removeAll() }
        if next == .playing && old != .playing { lastData = now; lastStep = now }
        updateTicker()
        publish()
    }

    /// Seek, new analysis and similar: drop queued levels. The tape keeps its place.
    public func reset() {
        pending.removeAll(); target = nil; generation = nil; lastSequence = nil
        lastData = VisualizationClock.now()
        updateTicker()
    }

    public func receive(_ frame: AnalysisFrame) {
        guard isVisible, activity == .playing else { return }
        if frame.generation != generation { generation = frame.generation; lastSequence = nil; pending.removeAll() }
        if let lastSequence, frame.sequence <= lastSequence { return }
        lastSequence = frame.sequence
        let now = VisualizationClock.now()
        // Wait for the estimated presentation time, as the LED design does; invalid times show at once.
        var at = frame.timing.estimatedPresentationHostTime ?? now
        if !at.isFinite || at > now + 2 || at < now - 2 { at = now }
        pending.append((at, [RadioCassetteMeter.level(rms: frame.leftRMS), RadioCassetteMeter.level(rms: frame.rightRMS)]))
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        updateTicker()
    }

    /// The lamps' sources. A new selection after the first reverses the tape.
    func receive(status next: RadioCassetteStatus, selection id: UUID?) {
        if let id, id != selection {
            if selection != nil { self.frame.tape.nextTrack() }
            selection = id
        }
        status = next
        publish()
    }

    /// Advances to `now`. Called by the clock; tests call it directly.
    func step(now: Double) {
        let due = now + VisualizationClock.presentationLead
        if let index = pending.lastIndex(where: { $0.at <= due }) {
            target = pending[index].levels; lastData = now
            pending.removeFirst(index + 1)
        }
        let dt = min(0.1, max(0, now - (lastStep ?? now))); lastStep = now
        let playing = activity == .playing
        let waiting = playing && now - lastData > Self.dataTimeout
        if waitingForData != waiting { waitingForData = waiting }
        if playing {
            frame.tape.advance(seconds: dt)
            meter.follow(waiting ? nil : target, dt: dt, reduceMotion: reduceMotion)
        }
        publish()
    }

    private func publish() {
        var next = frame
        if activity == .inactive || !isVisible { meter.clear() }
        next.litCells = meter.litCells
        if let indicators, indicators.status == status, indicators.reverse == next.tape.reverse {
            next.indicators = indicators.lamps
        } else {
            next.indicators = status.indicators + [RadioCassetteStatus.direction(reverse: next.tape.reverse)]
            indicators = (status, next.tape.reverse, next.indicators)
        }
        frame = next
        if isVisible { renderer?.render(next) }
    }

    private func stop() {
        tickerID = UUID(); ticker?.cancel(); ticker = nil
        pending.removeAll(); target = nil; generation = nil; lastSequence = nil; lastStep = nil
        waitingForData = false
        meter.clear()
        var next = frame; next.litCells = meter.litCells; frame = next
    }

    private var needsClock: Bool { isVisible && activity == .playing }

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
