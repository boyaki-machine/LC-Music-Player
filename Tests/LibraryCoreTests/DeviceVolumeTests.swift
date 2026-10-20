import Foundation
import Testing
import PlaybackCore
@testable import LibraryCore

@MainActor private final class FakeOutput: OutputVolumeSystem {
    var onChange: (@MainActor () -> Void)?
    var currentDevice: OutputDevice?
    var systemVolume: Float?
    var canSetSystemVolume = false
    /// Values the memory asked for; the fake applies them only when `follows` is set.
    var requested: [Float] = []
    var follows = true
    init(_ device: OutputDevice?, volume: Float?) { currentDevice = device; systemVolume = volume }
    func setSystemVolume(_ value: Float) {
        requested.append(value)
        if follows { systemVolume = value; onChange?() }
    }
    /// The OS changes the device or its volume.
    func change(device: OutputDevice? = nil, volume: Float?) {
        if let device { currentDevice = device }
        systemVolume = volume; onChange?()
    }
}

@Suite(.serialized) @MainActor struct DeviceVolumeTests {
    private let earphones = OutputDevice(kind: "BluetoothA2DPOutput", identifier: "earphones")
    private let speaker = OutputDevice(kind: "Speaker", identifier: "Speaker")
    /// A clock the test moves by hand, so the settle time after a device change is exact.
    private final class Clock { var now = ContinuousClock.now }

    @Test func eachDeviceKeepsItsOwnAppVolume() throws {
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let output = FakeOutput(speaker, volume: 0.5), preferences = MemoryPreferences(), clock = Clock()
        let memory = DeviceVolumeMemory(playback: playback, system: output, preferences: preferences, now: { clock.now })
        // A device seen for the first time keeps the current volumes.
        #expect(memory.record(for: speaker) == .init(app: 0.25, system: 0.5))
        playback.setVolume(0.6)
        output.change(device: earphones, volume: 0.5)
        #expect(playback.volume == 0.6 && memory.record(for: earphones) == .init(app: 0.6, system: 0.5))
        clock.now += .seconds(5)
        playback.setVolume(0.1)
        output.change(device: speaker, volume: 0.5)
        #expect(playback.volume == 0.6)
        output.change(device: earphones, volume: 0.5)
        #expect(playback.volume == 0.1)
        // The records outlive the app.
        let next = PlaybackController(makeBackend: { _ in TestBackend() })
        let reopened = DeviceVolumeMemory(playback: next, system: FakeOutput(earphones, volume: 0.5), preferences: preferences)
        #expect(next.volume == 0.1 && reopened.record(for: speaker)?.app == 0.6)
    }

    @Test func aLouderDeviceIsMadeUpForByTheAppVolumeWhereTheSystemVolumeCannotBeSet() throws {
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let output = FakeOutput(earphones, volume: 0.25), clock = Clock()
        let memory = DeviceVolumeMemory(playback: playback, system: output, preferences: MemoryPreferences(), now: { clock.now })
        playback.setVolume(0.4)
        clock.now += .seconds(5)
        output.change(device: speaker, volume: 0.25)
        clock.now += .seconds(5)
        // The earphones come back with the system volume reset to full: system × app stays at 0.25 × 0.4.
        output.change(device: earphones, volume: 1)
        #expect(abs(playback.volume - 0.1) < 0.0001 && output.requested.isEmpty)
        // A reset shortly after is undone too, without changing the record.
        clock.now += .seconds(1)
        output.change(volume: 0.5)
        #expect(abs(playback.volume - 0.2) < 0.0001 && memory.record(for: earphones) == .init(app: 0.4, system: 0.25))
        // A volume-button step right after is the listener's own, even within the settle time.
        output.change(volume: 0.25)
        #expect(playback.volume == 0.4)
        output.change(volume: 0.3)
        #expect(playback.volume == 0.4 && memory.record(for: earphones) == .init(app: 0.4, system: 0.3))
        output.change(volume: 0.25)
        #expect(memory.record(for: earphones) == .init(app: 0.4, system: 0.25))
        // Later changes are the listener's own and become the record.
        clock.now += .seconds(5)
        output.change(volume: 0.5)
        output.change(volume: 0.8)
        #expect(abs(playback.volume - 0.4) < 0.0001 && memory.record(for: earphones) == .init(app: 0.4, system: 0.8))
        // The app volume never goes above full.
        clock.now += .seconds(5)
        output.change(device: speaker, volume: 0.25)
        output.change(device: earphones, volume: 0.05)
        #expect(playback.volume == 1)
    }

    @Test func theSystemVolumeIsSetBackOnlyWhileThisAppPlays() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var backends: [TestBackend] = []
        let playback = PlaybackController(makeBackend: { _ in let b = TestBackend(); backends.append(b); return b })
        let library = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(), preferences: MemoryPreferences())
        defer { library.shutdown() }
        let list = try #require(library.document.currentPlaylistID)
        await library.importFiles([try fixture.file("a.wav")], into: list)
        let output = FakeOutput(earphones, volume: 0.3), clock = Clock()
        output.canSetSystemVolume = true
        let memory = DeviceVolumeMemory(playback: playback, system: output, preferences: MemoryPreferences(), now: { clock.now })
        clock.now += .seconds(5)
        output.change(device: speaker, volume: 0.6)
        clock.now += .seconds(5)
        // Not playing: another app may be playing, so only the app volume makes up for the louder device.
        output.change(device: earphones, volume: 0.6)
        #expect(output.requested.isEmpty && abs(playback.volume - 0.125) < 0.0001)
        // Playing: the system volume is set back, then the app volume returns to the record.
        output.follows = false
        library.playPlaylist(list)
        try await waitFor { output.requested == [0.3] }
        #expect(abs(playback.volume - 0.125) < 0.0001)
        output.change(volume: 0.3)
        #expect(playback.volume == 0.25 && memory.record(for: earphones) == .init(app: 0.25, system: 0.3))
        // The OS resetting the device as playback starts again is undone as well.
        library.togglePlayPause()
        try await waitFor { playback.state == .paused }
        try await Task.sleep(for: .milliseconds(20))
        clock.now += .seconds(10)
        library.togglePlayPause()
        try await waitFor { playback.state == .playing }
        try await Task.sleep(for: .milliseconds(20))
        output.follows = true
        output.change(volume: 1)
        #expect(output.systemVolume == 0.3 && playback.volume == 0.25)
    }

    @Test func mutingIsNotRemembered() {
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let output = FakeOutput(speaker, volume: 0.5), clock = Clock()
        let memory = DeviceVolumeMemory(playback: playback, system: output, preferences: MemoryPreferences(), now: { clock.now })
        playback.setVolume(0.7)
        playback.toggleMute()
        clock.now += .seconds(5)
        output.change(volume: 0.4)
        #expect(memory.record(for: speaker) == .init(app: 0.7, system: 0.5) && playback.volume == 0)
        playback.toggleMute()
        #expect(memory.record(for: speaker) == .init(app: 0.7, system: 0.4))
    }

    private func waitFor(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }
}
