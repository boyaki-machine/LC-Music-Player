import Foundation
import Testing
@testable import PlayerUI

struct WindowLayoutTests {
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
}
