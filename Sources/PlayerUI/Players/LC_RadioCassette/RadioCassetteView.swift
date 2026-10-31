import LibraryCore
import PlaybackCore
import SwiftUI

/// The radio cassette in the animation area. The lamps' sources change rarely and are observed here;
/// the tape and the meter go from the driver straight to the layers, so SwiftUI does not update every frame.
public struct RadioCassetteView: View {
    let driver: RadioCassetteDriver
    let playback: PlaybackController
    let library: LibraryController?
    let visible: Bool
    @State private var monitor = RadioCassetteMonitor()
    @State private var format: RadioCassetteFormat?
    /// The track whose coding `format` fully describes; a partial reading is tried again.
    @State private var formatURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(driver: RadioCassetteDriver, playback: PlaybackController, library: LibraryController?, visible: Bool) {
        self.driver = driver; self.playback = playback; self.library = library; self.visible = visible
    }

    private var status: RadioCassetteStatus {
        let levelling = library.flatMap { $0.normalizesVolume ? $0.normalizationSettings.targetLUFS : nil }
        return RadioCassetteStatus(power: monitor.power, output: monitor.output, format: format,
                                   levellingTarget: levelling, bass: playback.bassEnhancement)
    }

    public var body: some View {
        RadioCassetteStage(driver: driver)
            .overlay(alignment: .topLeading) {
                if driver.waitingForData {
                    Text("解析データを待っています").font(.system(size: 10)).foregroundStyle(Color(white: 0.2))
                        .padding(.leading, 18).padding(.top, 2)
                }
            }
            // The player holds the file's access while it plays, so a reading that failed is tried again then.
            .task(id: FormatKey(url: playback.selectedURL, playing: playback.state == .playing)) { await readFormat() }
            .onAppear { driver.reduceMotion = reduceMotion; watch(visible); deliver() }
            .onDisappear { monitor.stop() }
            .onChange(of: visible) { _, value in watch(value) }
            .onChange(of: status) { _, _ in deliver() }
            .onChange(of: library?.trackChangeID) { _, _ in deliver() }
            .onChange(of: playback.selectedURL) { _, _ in deliver() }
            .onChange(of: reduceMotion) { _, value in driver.reduceMotion = value }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last Century ラジカセ、カセットテープと左右の音量のアニメーション")
            .accessibilityValue(driver.waitingForData ? "解析データ待ち" : "")
            .allowsHitTesting(false)
    }

    private func watch(_ visible: Bool) { if visible { monitor.start() } else { monitor.stop() } }
    private func deliver() {
        // Before any track is chosen there is nothing to reverse from.
        driver.receive(status: status, selection: playback.selectedURL == nil ? nil : library?.trackChangeID)
    }
    private struct FormatKey: Equatable { let url: URL?; let playing: Bool }
    private func readFormat() async {
        guard let url = playback.selectedURL else { format = nil; formatURL = nil; return }
        guard formatURL != url else { return }
        let read = await RadioCassetteFormat.read(url)
        guard !Task.isCancelled, playback.selectedURL == url else { return }
        if let read { format = read; formatURL = url; return }
        // Name the container at least, until the stream can be read.
        format = RadioCassetteFormat(formatID: 0, sampleRate: 0, bitRate: nil, pathExtension: url.pathExtension)
    }
}

#if os(macOS)
import AppKit

private struct RadioCassetteStage: NSViewRepresentable {
    let driver: RadioCassetteDriver
    func makeNSView(context: Context) -> RadioCassetteHostView {
        let view = RadioCassetteHostView(); driver.attach(view); return view
    }
    func updateNSView(_ view: RadioCassetteHostView, context: Context) {}
}

/// A flipped, layer-backed view: AppKit keeps its layer running top to bottom whatever the views
/// around it do, so the design's layers sit in it as they do in UIKit.
final class RadioCassetteHostView: NSView, RadioCassetteRendering {
    let layers = RadioCassetteLayers()
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(layers.root)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); relayout() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); relayout() }
    private func relayout() { layers.layout(size: bounds.size, screenScale: window?.backingScaleFactor ?? 2) }
    func render(_ frame: RadioCassetteFrame) { layers.render(frame) }
}
#else
import UIKit

private struct RadioCassetteStage: UIViewRepresentable {
    let driver: RadioCassetteDriver
    func makeUIView(context: Context) -> RadioCassetteHostView {
        let view = RadioCassetteHostView(); driver.attach(view); return view
    }
    func updateUIView(_ view: RadioCassetteHostView, context: Context) {}
}

final class RadioCassetteHostView: UIView, RadioCassetteRendering {
    let layers = RadioCassetteLayers()
    init() {
        super.init(frame: .zero)
        layer.addSublayer(layers.root)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        layers.layout(size: bounds.size, screenScale: window?.screen.scale ?? traitCollection.displayScale)
    }
    func render(_ frame: RadioCassetteFrame) { layers.render(frame) }
}
#endif
