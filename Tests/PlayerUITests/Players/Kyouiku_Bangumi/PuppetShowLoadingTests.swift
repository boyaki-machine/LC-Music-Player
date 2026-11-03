#if os(macOS)
import AppKit
#endif
import Foundation
import SwiftUI
import Testing
@testable import PlayerUI

/// Lets a test hold the preparation until it has looked at the loading state.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var threads: [Bool] = []
    func open() { semaphore.signal() }
    /// Waits for `open()`, at most a few seconds so that a preparation on the main thread fails instead of hanging.
    func pass() { record(); _ = semaphore.wait(timeout: .now() + 3) }
    func record() { lock.withLock { threads.append(Thread.isMainThread) } }
    var ranOnMain: [Bool] { lock.withLock { threads } }
}

@MainActor
@Suite(.serialized) struct PuppetShowLoadingTests {
    private func waitUntilLoaded(_ loader: PuppetShowLoader) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while loader.loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!loader.loading)
    }

    @Test func preparesOffTheMainThreadWhileTheMainActorStaysFree() async throws {
        let gate = Gate()
        let loader = PuppetShowLoader { gate.pass(); return PuppetShowLoader.prepare() }
        loader.request()
        #expect(loader.loading && loader.renderer == nil)
        // The main actor keeps running while the preparation waits off it.
        try await Task.sleep(for: .milliseconds(100))
        #expect(loader.loading && loader.renderer == nil)
        gate.open()
        try await waitUntilLoaded(loader)
        #expect(loader.renderer != nil && !loader.failed)
        #expect(gate.ranOnMain == [false])
        // Asked again, it keeps the stage it has.
        loader.request()
        #expect(!loader.loading)
    }

    @Test func withoutTheStageItStopsLoadingAndShowsTheSky() async throws {
        let loader = PuppetShowLoader { nil }
        loader.request()
        #expect(loader.loading)
        try await waitUntilLoaded(loader)
        #expect(loader.failed && loader.renderer == nil)
        loader.request()
        #expect(!loader.loading)
    }

    @Test func theNoticeAppearsOnlyWhenLoadingOutlastsTheDelay() {
        #expect(PuppetShowView.showsPreparing(loading: true, delayPassed: true))
        #expect(!PuppetShowView.showsPreparing(loading: true, delayPassed: false))
        #expect(!PuppetShowView.showsPreparing(loading: false, delayPassed: true))
        // Longer than a usual load in a release build (about 0.2–0.45 s measured on an iPhone and a Mac), so it does not flash.
        #expect(PuppetShowView.preparingDelay >= .milliseconds(500))
    }

    #if os(macOS)
    /// The share of the middle row's pixels darker than the sky (the notice's capsule), from raw components.
    private func covered(_ host: NSView) throws -> Double {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["LCMP_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("puppet-preparing.png"))
        }
        let dark = (0..<rep.pixelsWide).filter { x in (rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.blueComponent ?? 1) < 0.75 }
        return Double(dark.count) / Double(rep.pixelsWide)
    }

    @Test func theSkyShowsTheNoticeOnlyAfterTheDelay() async throws {
        let gate = Gate()
        let loader = PuppetShowLoader { gate.pass(); return nil }
        let host = NSHostingView(rootView: PuppetShowView(driver: PuppetShowDriver(), loader: loader).frame(width: 360, height: 144))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 144)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        defer { gate.open(); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(loader.loading)
        #expect(try covered(host) == 0, "only the sky at first")
        try await Task.sleep(for: PuppetShowView.preparingDelay + .milliseconds(300))
        #expect(loader.loading)
        // The notice's dark capsule lies across the middle of the sky.
        let share = try covered(host)
        #expect(share > 0.2 && share < 0.8, "the notice over the sky: \(share)")
    }
    #endif
}
