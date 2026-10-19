import CoreGraphics
import SwiftUI
import Testing
@testable import PlayerUI

/// Layout sizes of each player framing. The macOS window values are the baseline the
/// iPhone framings derive from and must not move.
@Suite struct PlayerFrameTests {
    typealias Metrics = LCMPDefaultGEQPlayerView.Metrics

    @Test func macWindowKeepsItsLayout() {
        let metrics = Metrics.window
        #expect(metrics.visualizationHeight == 144)
        #expect(metrics.controlsHeight == 66)
        #expect(metrics.spacing == 9)
        #expect(metrics.cornerRadius == 12)
        #expect(metrics.axisLabelSize == 9)
        #expect(metrics.insets == EdgeInsets())
        #expect(metrics.buttonSize == 44 && metrics.symbolSize == 17)
        #expect(metrics.volumePopupOffset == 99)
    }

    @Test func cardScalesWithTheScreenWidthButNeverBelowTheWindow() throws {
        let scale = 406.0 / 360
        let card = Metrics.card(width: 406)
        #expect(abs(try #require(card.visualizationHeight) - 144 * scale) < 1e-9)
        #expect(abs(card.controlsHeight - 66 * scale) < 1e-9)
        #expect(abs(card.spacing - 9 * scale) < 1e-9)
        #expect(abs(card.axisLabelSize - 9 * scale) < 1e-9)
        #expect(card.cornerRadius == 18)
        let narrow = Metrics.card(width: 300)
        #expect(narrow.visualizationHeight == 144 && narrow.spacing == 9)
    }

    @Test func fullScreenSpreadsButtonsInsideTheSafeArea() {
        let insets = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
        let wide = Metrics.fullScreen(size: CGSize(width: 814, height: 409), insets: insets)
        #expect(wide.visualizationHeight == nil)
        #expect(wide.cornerRadius == 0)
        #expect(wide.axisLabelSize == 16)
        #expect(wide.spacing == 48)
        #expect(wide.insets == EdgeInsets(top: 10, leading: 59, bottom: 21, trailing: 59))
        // Landscape buttons are larger than in portrait.
        #expect(wide.buttonSize == 56 && wide.symbolSize == 24)
        #expect(abs(wide.volumePopupOffset - 175.5) < 1e-9)
        let narrow = Metrics.fullScreen(size: CGSize(width: 446, height: 400), insets: EdgeInsets())
        #expect(6 * narrow.buttonSize + 5 * narrow.spacing <= 446 - 32)
        let tiny = Metrics.fullScreen(size: CGSize(width: 100, height: 100), insets: EdgeInsets())
        #expect(tiny.spacing == 9)
    }

    @Test func panelFitsBesideTheExtension() {
        let panel = Metrics.panel(size: CGSize(width: 446, height: 380))
        #expect(panel.buttonSize > 44)
        #expect(6 * panel.buttonSize + 5 * panel.spacing <= 446)
        #expect(panel.visualizationHeight == nil)
        #expect(panel.cornerRadius == 18)
        #expect(panel.insets == EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
    }
}
