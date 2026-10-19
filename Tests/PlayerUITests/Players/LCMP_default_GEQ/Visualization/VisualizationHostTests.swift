import Testing
@testable import PlayerUI

/// Turning an iPhone replaces the player view. Whichever order the new view appears and the old
/// one disappears in, the drawing keeps running while a view still shows it.
@Suite @MainActor struct VisualizationHostTests {
    /// What PlaybackVisualization does on appear and disappear.
    private func appear(_ presentation: PlayerPresentation) {
        presentation.visualizationHostAppeared()
        presentation.activeVisualizationDriver.synchronize(activity: .playing, visible: true)
    }
    private func disappear(_ presentation: PlayerPresentation) {
        if presentation.visualizationHostDisappeared() {
            presentation.activeVisualizationDriver.synchronize(activity: .inactive, visible: false)
        }
    }

    @Test func newViewAppearingBeforeTheOldOneLeavesKeepsDrawing() {
        let presentation = PlayerPresentation(preferences: MemoryPreferences())
        appear(presentation)
        appear(presentation)
        disappear(presentation)
        #expect(presentation.visualizationDriver.isRunning)
        disappear(presentation)
        #expect(!presentation.visualizationDriver.isRunning)
    }

    @Test func oldViewLeavingFirstStopsThenTheNewOneRestarts() {
        let presentation = PlayerPresentation(preferences: MemoryPreferences())
        appear(presentation)
        disappear(presentation)
        #expect(!presentation.visualizationDriver.isRunning)
        appear(presentation)
        #expect(presentation.visualizationDriver.isRunning)
    }

    @Test func extraDisappearanceNeverGoesBelowZero() {
        let presentation = PlayerPresentation(preferences: MemoryPreferences())
        #expect(presentation.visualizationHostDisappeared())
        appear(presentation)
        disappear(presentation)
        #expect(!presentation.visualizationDriver.isRunning)
    }
}
