import Foundation
import Testing
@testable import PlaybackCore

@MainActor struct OutputLatencyTrackerTests {
    private let routeChange = Notification.Name("test.routeChange")

    /// Speaker 15.8ms, then Bluetooth earphones 240.6ms, as an iPhone reported them.
    @Test func aRouteChangeAppliesTheNodesOwnLatencyAsIs() {
        let center = NotificationCenter()
        var reported: Double? = 0.0158
        var applied: [Double] = []
        let tracker = OutputLatencyTracker(initial: 0.0158, notification: routeChange, center: center,
                                           read: { reported }, apply: { applied.append($0) })
        #expect(tracker.applied == 0.0158)
        center.post(name: routeChange, object: nil)
        // Same route: nothing to apply.
        #expect(applied.isEmpty)
        reported = 0.2406
        center.post(name: routeChange, object: nil)
        // The node's report already holds the route's latency: applied alone, not added to anything.
        #expect(applied == [0.2406] && tracker.applied == 0.2406)
        reported = 0.2406 + OutputLatencyTracker.threshold / 2
        center.post(name: routeChange, object: nil)
        reported = 0.0158
        center.post(name: routeChange, object: nil)
        #expect(applied == [0.2406, 0.0158])
    }

    @Test func invalidReportsAreNotApplied() {
        let center = NotificationCenter()
        var reported: Double? = nil
        var applied: [Double] = []
        let tracker = OutputLatencyTracker(initial: 0.02, notification: routeChange, center: center,
                                           read: { reported }, apply: { applied.append($0) })
        for value in [nil, .nan, .infinity, -0.01, 5] as [Double?] {
            reported = value
            center.post(name: routeChange, object: nil)
        }
        #expect(applied.isEmpty && tracker.applied == 0.02)
        // An invalid starting value still lets the first valid report through.
        let late = OutputLatencyTracker(initial: .nan, notification: nil, read: { 0.03 }, apply: { applied.append($0) })
        #expect(late.applied == nil)
        late.refresh()
        #expect(applied == [0.03])
    }

    @Test func cancellingStopsFollowingTheRoute() {
        let center = NotificationCenter()
        var applied: [Double] = []
        let tracker = OutputLatencyTracker(initial: 0.01, notification: routeChange, center: center,
                                           read: { 0.2 }, apply: { applied.append($0) })
        tracker.cancel()
        center.post(name: routeChange, object: nil)
        #expect(applied.isEmpty)
    }
}
