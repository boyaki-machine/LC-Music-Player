import Foundation
import Testing
@testable import PlayerUI

struct WindowLayoutTests {
    @Test @MainActor func seekHidesAfterDisengagementAndInteractionCancelsOldTimer() async throws {
        let model = PlayerPresentation(seekHideDelay: .milliseconds(80))
        model.seekVisible = true; model.cancelSeekHide()
        try await Task.sleep(for: .milliseconds(130))
        #expect(model.seekVisible)
        model.scheduleSeekHide()
        // The 80ms timer runs on the MainActor; a parallel run can hold it well past a fixed sleep.
        let deadline = ContinuousClock.now + .seconds(2)
        while model.seekVisible, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.seekVisible)
        model.seekVisible = true
        model.closeOverlays()
        model.seekVisible = true; model.cancelSeekHide()
        try await Task.sleep(for: .milliseconds(130))
        #expect(model.seekVisible)
        model.closeOverlays()
    }
    #if os(macOS)
    /// Covered, on another Space, minimized, closed or with the display asleep, the window draws nothing.
    @Test func onlyAVisibleUncoveredWindowShowsTheVisualization() {
        #expect(WindowLayout.showsVisualization(isVisible: true, isMiniaturized: false, occlusion: .visible))
        #expect(!WindowLayout.showsVisualization(isVisible: true, isMiniaturized: false, occlusion: []))
        #expect(!WindowLayout.showsVisualization(isVisible: true, isMiniaturized: true, occlusion: .visible))
        #expect(!WindowLayout.showsVisualization(isVisible: false, isMiniaturized: false, occlusion: .visible))
    }
    #endif
    @Test func extensionFitsBelowAtScreenEdgesAndNegativeCoordinates() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1280, y: -200, width: 1280, height: 800)] {
            for origin in [CGPoint(x: screen.minX - 50, y: screen.minY), CGPoint(x: screen.maxX, y: screen.maxY)] {
                let result = WindowLayout.frames(main: CGRect(origin: origin, size: WindowLayout.mainSize), visible: screen, expanded: true)
                #expect(screen.contains(result.main))
                #expect(screen.contains(result.extensionWindow))
                #expect(result.main.minY - result.extensionWindow.maxY == WindowLayout.gap)
                #expect(result.main.minX == result.extensionWindow.minX)
            }
        }
    }
    @Test func openingInAvailableSpaceDoesNotMoveMain() {
        let main = CGRect(x: 300, y: 450, width: 360, height: 210)
        let result = WindowLayout.frames(main: main, visible: CGRect(x: 0, y: 0, width: 1440, height: 900), expanded: true)
        #expect(result.main == main)
        let closed = WindowLayout.frames(main: result.main, visible: CGRect(x: 0, y: 0, width: 1440, height: 900), expanded: false)
        #expect(closed.main == main)
    }
    @Test func shortScreenShrinksExtensionWithoutOverlap() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 450)
        let result = WindowLayout.frames(main: CGRect(x: 100, y: 100, width: 360, height: 210), visible: screen, expanded: true)
        #expect(screen.contains(result.main))
        #expect(screen.contains(result.extensionWindow))
        #expect(result.extensionWindow.height == 238)
        #expect(!result.main.intersects(result.extensionWindow))
    }
    @Test func verticalResizeKeepsTopWidthAndGapWithinScreen() {
        let screen = CGRect(x: -1280, y: -200, width: 1280, height: 900)
        let main = CGRect(x: -800, y: 450, width: 360, height: 210)
        for proposed in [CGFloat(100), 300, 500, 2000, .nan] {
            let height = WindowLayout.resizedExtensionHeight(proposed, main: main, visible: screen)
            let result = WindowLayout.frames(main: main, visible: screen, expanded: true, extensionHeight: height)
            #expect(result.main == main)
            #expect(result.extensionWindow.width == main.width)
            #expect(result.extensionWindow.maxY == main.minY - WindowLayout.gap)
            #expect(screen.contains(result.extensionWindow))
            #expect(result.extensionWindow.height >= WindowLayout.minimumExtensionHeight)
        }
        let taller = WindowLayout.frames(main: main, visible: screen, expanded: true, extensionHeight: 500)
        #expect(taller.extensionWindow.height == 500)
        #expect(WindowLayout.resizedExtensionHeight(100, main: main, visible: screen) == 240)
        #expect(WindowLayout.resizedExtensionHeight(2000, main: main, visible: screen) == 648)
        let short = CGRect(x: 0, y: 0, width: 800, height: 400)
        let clipped = WindowLayout.frames(main: main, visible: short, expanded: true, extensionHeight: 500)
        #expect(clipped.extensionWindow.height == 188)
        #expect(short.contains(clipped.extensionWindow))
        let restored = WindowLayout.frames(main: taller.main, visible: screen, expanded: true, extensionHeight: 500)
        #expect(restored == taller)
    }
    @Test @MainActor func menuReopensCurrentListAndOverlaysAreIndependent() {
        let model = PlayerPresentation()
        model.toggleExtension()
        model.section = .settings
        model.toggleExtension()
        model.toggleExtension()
        #expect(model.section == .playlist)
        model.seekVisible = true; model.volumeVisible = true
        model.closeOverlays()
        #expect(!model.seekVisible && !model.volumeVisible)
        #expect(model.extensionVisible)
    }
    @Test @MainActor func menuClosesTheVolumePopup() {
        let model = PlayerPresentation()
        for _ in 0..<2 {
            model.volumeVisible = true
            model.toggleExtension()
            #expect(!model.volumeVisible)
        }
        #expect(!model.extensionVisible)
    }
}
