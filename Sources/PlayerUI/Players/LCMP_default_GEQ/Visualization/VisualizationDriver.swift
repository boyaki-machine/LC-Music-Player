import AnalysisCore
import Foundation
import Observation
import VisualizationKit

/// One UI clock per visible visualization, independent of the audio callback.
@Observable @MainActor
public final class VisualizationDriver {
    public private(set) var snapshot = SpectrumSnapshot()
    public private(set) var drawTime = 0.0
    @ObservationIgnored public private(set) var presentation = SpectrumPresentation()
    @ObservationIgnored public private(set) var activity: VisualizationActivity = .inactive
    @ObservationIgnored public private(set) var isVisible = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tickerID = UUID()
    public var isRunning: Bool { ticker != nil }

    public init() {}
    deinit { ticker?.cancel() }

    public func synchronize(activity next: VisualizationActivity, visible: Bool) {
        let old = activity
        let wasVisible = isVisible
        activity = next; isVisible = visible
        guard visible, next != .inactive else { reset(); return }
        if next == .playing && (old != .playing || !wasVisible) { presentation.begin(now: VisualizationClock.now()) }
        if next == .paused && old != .paused { presentation.pause() }
        publish()
        updateTicker()
    }

    public func reset() {
        tickerID = UUID(); ticker?.cancel(); ticker = nil
        presentation.reset(); snapshot = presentation.snapshot; drawTime = VisualizationClock.now()
        if isVisible, activity == .playing { presentation.begin(now: drawTime); updateTicker() }
    }

    public func receive(_ frame: AnalysisFrame) {
        guard isVisible, activity == .playing else { return }
        _ = presentation.receive(SpectrumSample(defaultGEQFrame: frame), now: VisualizationClock.now())
        publish()
        updateTicker()
    }

    private func publish() {
        let now = VisualizationClock.now()
        let previousCount = presentation.adoptionCount
        presentation.tick(now: now, playing: activity == .playing)
        if previousCount != presentation.adoptionCount || snapshot != presentation.snapshot || presentation.hasAfterglow(at: now) {
            drawTime = now
            snapshot = presentation.snapshot
        }
    }

    private func updateTicker() {
        let needed = isVisible && (activity == .playing || presentation.hasAfterglow(at: VisualizationClock.now()))
        guard needed else { tickerID = UUID(); ticker?.cancel(); ticker = nil; return }
        guard ticker == nil else { return }
        let id = UUID(); tickerID = id
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                guard self?.step(id: id) == true else { return }
            }
        }
    }

    private func step(id: UUID) -> Bool {
        guard tickerID == id else { return false }
        publish()
        let needed = isVisible && (activity == .playing || presentation.hasAfterglow(at: drawTime))
        if !needed { ticker = nil }
        return needed
    }
}
