import Foundation
import Testing
import AudioProcessingCore
import PlaybackCore
@testable import LibraryCore

@Suite @MainActor struct BassEnhancementSettingTests {
    @Test func theChoiceIsKeptAndAppliedOnTheNextLaunch() {
        let preferences = MemoryPreferences()
        let firstPlayback = PlaybackController(makeBackend: { _ in TestBackend() })
        let first = LibraryController(playback: firstPlayback, store: MemoryStore(), references: TestReferences(), preferences: preferences)
        #expect(first.bassEnhancement == .off)
        first.setBassEnhancement(.strong)
        #expect(firstPlayback.bassEnhancement == .strong && preferences.object(forKey: "bassEnhancement") as? Int == 2)
        first.shutdown()
        let secondPlayback = PlaybackController(makeBackend: { _ in TestBackend() })
        let second = LibraryController(playback: secondPlayback, store: MemoryStore(), references: TestReferences(), preferences: preferences)
        defer { second.shutdown() }
        #expect(second.bassEnhancement == .strong && secondPlayback.bassEnhancement == .strong)
    }

    @Test func anUnknownStoredValueLeavesItOff() {
        let preferences = MemoryPreferences()
        preferences.set(7, forKey: "bassEnhancement")
        let playback = PlaybackController(makeBackend: { _ in TestBackend() })
        let library = LibraryController(playback: playback, store: MemoryStore(), references: TestReferences(), preferences: preferences)
        defer { library.shutdown() }
        #expect(library.bassEnhancement == .off)
    }
}
