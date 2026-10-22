import Foundation
import VisualizationKit

public struct SpectrumSnapshot: Equatable, Sendable {
    public static let columns = 16
    public static let rows = 24
    public static let afterglowDuration = 0.2
    public var counts = Array(repeating: 0, count: columns)
    public var extinguishedAt = Array<Double?>(repeating: nil, count: columns * rows)
    public var waitingForData = false

    public init() {}
    public func isOn(column: Int, row: Int) -> Bool { row < counts[column] }
    public func residual(column: Int, row: Int, now: Double) -> Double {
        guard !isOn(column: column, row: row), let off = extinguishedAt[column * Self.rows + row] else { return 0 }
        let age = max(0, now - off)
        return age < Self.afterglowDuration ? 0.25 * pow(1 - age / Self.afterglowDuration, 2) : 0
    }
}

public struct SpectrumAdoption: Sendable {
    public let sequence: UInt64
    public let producedAt: Double
    public let presentationAt: Double?
    public let adoptedAt: Double
}

/// A bounded presentation queue. Tick displays only the newest due sample,
/// never replays a backlog. New arrivals cannot postpone existing deadlines.
/// A sample with a presentation time is due `VisualizationClock.presentationLead` before it.
public struct SpectrumPresentation {
    public static let capacity = 64
    public static let missingInterval = 0.25
    public private(set) var snapshot = SpectrumSnapshot()
    public private(set) var lastAdoption: SpectrumAdoption?
    public private(set) var adoptionCount: UInt64 = 0
    public private(set) var pendingHighWatermark = 0
    public private(set) var discardedSamples: UInt64 = 0
    private var generation: UUID?
    private var sequence: UInt64?
    private var pending: [SpectrumSample] = []
    private var receivedAt: Double?
    private var startedAt: Double?
    public var pendingCount: Int { pending.count }

    public init() { pending.reserveCapacity(Self.capacity) }

    public mutating func reset() { self = Self() }
    public mutating func begin(now: Double) { reset(); startedAt = now }
    public mutating func pause() {
        pending.removeAll(keepingCapacity: true); receivedAt = nil; startedAt = nil
        snapshot.waitingForData = false
    }

    @discardableResult
    public mutating func receive(_ sample: SpectrumSample, now: Double) -> Bool {
        guard now.isFinite, sample.producedAt.isFinite,
              sample.levels.count == SpectrumSnapshot.columns,
              sample.levels.allSatisfy({ $0.isFinite }),
              sample.producedAt <= now + 0.05, now - sample.producedAt < 2 else { return false }
        if generation != sample.generation {
            reset(); generation = sample.generation; startedAt = now
        }
        guard sequence.map({ sample.sequence > $0 }) ?? true else { return false }
        sequence = sample.sequence
        receivedAt = now
        snapshot.waitingForData = false
        // Preserve the next deadline even if arrivals exceed the configured rate.
        // Repeatedly dropping the head could otherwise postpone display forever.
        if pending.count == Self.capacity { pending.remove(at: 1); discardedSamples += 1 }
        pending.append(sample)
        pendingHighWatermark = max(pendingHighWatermark, pending.count)
        return true
    }

    private func deadline(_ sample: SpectrumSample) -> Double {
        validatedPresentationTime(sample).map { $0 - VisualizationClock.presentationLead } ?? sample.producedAt
    }

    private func validatedPresentationTime(_ sample: SpectrumSample) -> Double? {
        guard let time = sample.presentationAt, time.isFinite,
              abs(time - sample.producedAt) <= 2 else { return nil }
        return time
    }

    public mutating func tick(now: Double, playing: Bool) {
        guard now.isFinite else { return }
        if playing, let index = pending.lastIndex(where: { deadline($0) <= now }) {
            let sample = pending[index]
            pending.removeFirst(index + 1)
            // Keep multiplication at the input precision so exact cell boundaries
            // (e.g. normalized 5/6 = 20 cells) do not fall below an integer on widening.
            setCounts(sample.levels.map { Int((min(1, max(0, $0)) * Float(SpectrumSnapshot.rows)).rounded(.down)) }, now: now)
            lastAdoption = SpectrumAdoption(sequence: sample.sequence, producedAt: sample.producedAt,
                                            presentationAt: validatedPresentationTime(sample), adoptedAt: now)
            adoptionCount += 1
        }
        // A future presentation deadline is not a data outage.
        if playing, pending.isEmpty, let received = receivedAt ?? startedAt,
           now - max(received, lastAdoption?.adoptedAt ?? received) >= Self.missingInterval {
            if !snapshot.waitingForData { setCounts(Array(repeating: 0, count: 16), now: now) }
            snapshot.waitingForData = true
        }
        for i in snapshot.extinguishedAt.indices {
            if let off = snapshot.extinguishedAt[i], now - off >= SpectrumSnapshot.afterglowDuration {
                snapshot.extinguishedAt[i] = nil
            }
        }
    }

    public func hasAfterglow(at now: Double) -> Bool {
        snapshot.extinguishedAt.contains { $0.map { now - $0 < SpectrumSnapshot.afterglowDuration } ?? false }
    }

    private mutating func setCounts(_ counts: [Int], now: Double) {
        for col in 0..<16 {
            let old = snapshot.counts[col], next = counts[col]
            if next < old {
                for row in next..<old { snapshot.extinguishedAt[col * 24 + row] = now }
            }
            for row in 0..<next { snapshot.extinguishedAt[col * 24 + row] = nil }
        }
        snapshot.counts = counts
    }
}
