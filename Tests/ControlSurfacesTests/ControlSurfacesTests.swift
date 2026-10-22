import CoreGraphics
import Foundation
import SwiftUI
import Testing
import PlaybackCore
@testable import ControlSurfaces
@testable import PlayerUI

@Suite struct TransportStateMappingTests {
    @Test func playbackStatesMapToTheThreeLights() {
        #expect(TransportState(PlaybackState.playing) == .playing)
        #expect(TransportState(PlaybackState.paused) == .paused)
        for state in [PlaybackState.stopped, .finished, .empty, .failed] { #expect(TransportState(state) == .stopped) }
    }

    /// Switching songs passes through `ready`; the widgets keep what they show instead of blinking.
    @Test func switchingSongsKeepsTheShownState() {
        #expect(TransportState(PlaybackState.ready) == nil)
    }
}

@Suite struct TransportGlyphTests {
    @Test func thePlayGlyphLightsLikeTheMainWindow() {
        #expect(TransportGlyph(.playPause, state: .playing, size: 24).light == ControlSurfaceColors.led)
        #expect(TransportGlyph(.playPause, state: .paused, size: 24).light == ControlSurfaceColors.amber)
        #expect(TransportGlyph(.playPause, state: .stopped, size: 24).light == nil)
        #expect(TransportGlyph(.next, state: .playing, size: 24).light == nil)
    }

    /// Without the shared state the widgets show one toggle glyph that never lights.
    @Test func anUnknownStateShowsAToggle() {
        let glyph = TransportGlyph(.playPause, state: nil, size: 24)
        #expect(glyph.symbol == "playpause.fill")
        #expect(glyph.light == nil)
        #expect(glyph.accessibilityLabel == "再生／一時停止")
        #expect(TransportGlyph(.playPause, state: .playing, size: 24).symbol == "play.fill")
        #expect(TransportGlyph(.playPause, state: .playing, size: 24).accessibilityLabel == "一時停止")
    }

    @Test func theMenuOpensTheExtension() {
        #expect(TransportCommand.menuURL.absoluteString == "lcmp://extension")
        #expect(AppLink(TransportCommand.menuURL) == .showExtension)
    }
}

/// Any web page or app can open `lcmp://`; only the exact links do something.
@Suite struct AppLinkTests {
    @Test func theSchemeAcceptsOnlyTheListedLinks() {
        #expect(AppLink.allCases == [.showExtension])
        #expect(AppLink.allCases.map(\.url.absoluteString) == ["lcmp://extension"])
        #expect(AppLink(URL(string: "lcmp://extension")!) == .showExtension)
    }

    @Test(arguments: [
        "lcmp://", "lcmp:extension", "lcmp://play", "lcmp://delete", "lcmp://extension/", "lcmp://extension/library",
        "lcmp://extension?file=/etc/passwd", "lcmp://extension#top", "lcmp://user@extension", "lcmp://extension:80",
        "lcmp://EXTENSION", "lcmp:///extension", "https://extension", "file:///extension", "lcmpx://extension",
    ])
    func otherURLsDoNothing(_ text: String) throws {
        #expect(AppLink(try #require(URL(string: text))) == nil)
    }
}

@Suite struct SharedTransportStoreTests {
    @Test func withoutAnAppGroupTheStateIsUnknown() {
        let store = SharedTransportStore(defaults: nil)
        store.write(.playing)
        #expect(!store.isShared)
        #expect(store.state == nil)
    }

    /// The test bundle has no App Group in its Info.plist.
    @Test func aBundleWithoutTheGroupKeyHasNoSharedState() {
        #expect(!SharedTransportStore.appGroup(bundle: Bundle(for: BundleToken.self)).isShared)
    }
}
private final class BundleToken {}

/// The widgets drawn off screen: only the play glyph of a playing state lights green.
@MainActor @Suite struct ControlSurfaceRenderingTests {
    private func greenPixels<V: View>(_ view: V, size: CGSize) throws -> Int {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(ControlSurfaceColors.plate))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).filter { i in
            Int(pixels[i + 1]) > 180 && Int(pixels[i + 1]) - Int(pixels[i]) > 60 && Int(pixels[i + 1]) - Int(pixels[i + 2]) > 60
        }.count
    }
    private func small(_ state: TransportState?) -> some View {
        SmallWidgetLayout(state: state) { _, glyph in glyph }
    }
    private func medium(_ state: TransportState?) -> some View {
        MediumWidgetLayout(state: state) { _, glyph in glyph }
    }

    @Test func thePlayGlyphLightsOnlyWhilePlaying() throws {
        let size = CGSize(width: 170, height: 170)
        #expect(try greenPixels(small(.playing), size: size) > 20)
        #expect(try greenPixels(small(.paused), size: size) == 0)
        #expect(try greenPixels(small(.stopped), size: size) == 0)
        #expect(try greenPixels(small(nil), size: size) == 0)
    }

    /// The medium widget carries the green app mark; the play glyph adds to it while playing.
    @Test func theMediumWidgetLightsMoreWhilePlaying() throws {
        let size = CGSize(width: 364, height: 170)
        let idle = try greenPixels(medium(.stopped), size: size)
        #expect(idle > 0)
        #expect(try greenPixels(medium(.playing), size: size) > idle + 20)
    }
}
