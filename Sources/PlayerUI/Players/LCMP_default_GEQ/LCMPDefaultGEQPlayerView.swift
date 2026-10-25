import SwiftUI
import PlaybackCore
import LibraryCore

struct LCMPDefaultGEQPlayerView: View {
    let playback: PlaybackController
    let library: LibraryController?
    @Bindable var presentation: PlayerPresentation
    let chooseFile: () -> Void
    let toggleExtension: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var volumeOutsideClick = VolumeOutsideClickHandler()
    @State private var seekOutsideClick = VolumeOutsideClickHandler()
    @State private var seekPreview: Double?
    @State private var seekSelection: URL?

    init(playback: PlaybackController, presentation: PlayerPresentation, library: LibraryController? = nil,
                chooseFile: @escaping () -> Void, toggleExtension: @escaping () -> Void) {
        self.playback = playback; self.presentation = presentation
        self.library = library
        self.chooseFile = chooseFile; self.toggleExtension = toggleExtension
    }
    private var playLabel: String {
        playback.state == .playing ? "一時停止" : playback.state == .paused ? "再開" : "再生"
    }
    private var playColor: Color? {
        playback.state == .playing ? .green : playback.state == .paused ? .orange : nil
    }
    private var status: String { playback.state == .playing ? "PLAY" : playback.state == .paused ? "PAUSE" : "STOP" }

    @Environment(\.playerFrame) private var frameStyle

    var body: some View {
        Group {
            switch frameStyle {
            case .window:
                player(Metrics.window).frame(width: 360, height: 210)
            case .card:
                GeometryReader { geometry in player(Metrics.card(width: geometry.size.width)) }
                    .aspectRatio(360 / 210, contentMode: .fit)
            case .fullScreen:
                // Backgrounds run edge to edge; the plot and buttons stay inside the safe area.
                GeometryReader { geometry in player(Metrics.fullScreen(size: geometry.size, insets: geometry.safeAreaInsets)).ignoresSafeArea() }
            case .panel:
                GeometryReader { geometry in player(Metrics.panel(size: geometry.size)) }
            }
        }
        .onEscape { presentation.closeOverlays(); seekPreview = nil }
        .onChange(of: playback.selectedURL) { _, _ in seekPreview = nil }
        .onChange(of: playback.state) { _, _ in seekPreview = nil }
        .onChange(of: presentation.seekVisible) { _, _ in seekPreview = nil }
    }

    /// Sizes of one framing. `window` is the macOS layout every other framing derives from.
    struct Metrics {
        var visualizationHeight: CGFloat?
        var controlsHeight: CGFloat
        var spacing: CGFloat
        var cornerRadius: CGFloat
        var axisLabelSize: CGFloat
        var insets = EdgeInsets()
        /// Touch target and symbol size of the transport buttons.
        var buttonSize: CGFloat = 44
        var symbolSize: CGFloat = 17
        /// Horizontal offset of the volume popup from the centre: over the fifth of six buttons.
        var volumePopupOffset: CGFloat { 1.5 * (buttonSize + spacing) + 19.5 }
        static let window = Metrics(visualizationHeight: 144, controlsHeight: 66, spacing: 9, cornerRadius: 12, axisLabelSize: 9)
        static func card(width: CGFloat) -> Metrics {
            let scale = max(1, width / 360)
            return Metrics(visualizationHeight: 144 * scale, controlsHeight: 66 * scale, spacing: 9 * scale,
                           cornerRadius: 18, axisLabelSize: 9 * scale)
        }
        /// `size` is the safe-area size; the six buttons spread up to 48pt apart within it.
        /// Landscape buttons are larger than the portrait ones: 56pt targets with 24pt symbols.
        static func fullScreen(size: CGSize, insets: EdgeInsets) -> Metrics {
            Metrics(visualizationHeight: nil, controlsHeight: 84, spacing: min(48, max(9, (size.width - 6 * 56 - 32) / 5)),
                    cornerRadius: 0, axisLabelSize: 16,
                    insets: EdgeInsets(top: max(10, insets.top), leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing),
                    buttonSize: 56, symbolSize: 24)
        }
        static func panel(size: CGSize) -> Metrics {
            Metrics(visualizationHeight: nil, controlsHeight: 76, spacing: min(48, max(6, (size.width - 6 * 52 - 24) / 5)),
                    cornerRadius: 18, axisLabelSize: 13, insets: EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0),
                    buttonSize: 52, symbolSize: 21)
        }
    }

    private func player(_ metrics: Metrics) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                PlaybackVisualization(playback: playback, presentation: presentation, library: library)
                    .environment(\.geqAxisLabelSize, metrics.axisLabelSize)
                AnimationDragSurface { presentation.seekVisible.toggle() }
                VStack {
                    if playback.error != nil || library?.error != nil {
                        Button { presentation.section = .source; if !presentation.extensionVisible { toggleExtension(); presentation.section = .source } } label: {
                            Label("再生エラー・詳細を確認", systemImage: "exclamationmark.triangle")
                                .font(.caption).padding(5).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                    } else if !playback.canPlay {
                        Button("メニューから音源を選択") { if !presentation.extensionVisible { toggleExtension() } }
                            .font(.caption).buttonStyle(.plain).padding(.top, 12)
                    }
                    Spacer()
                }
                #if os(iOS)
                // Touch has no outside-click monitor: a tap beside the open volume bar closes it.
                if presentation.volumeVisible {
                    Color.black.opacity(0.001).onTapGesture { presentation.volumeVisible = false }.accessibilityHidden(true)
                }
                #endif
                if presentation.seekVisible { seekBar.padding(.horizontal, 12).padding(.bottom, 5) }
                if presentation.volumeVisible {
                    volumePopup.frame(width: 54, height: 132).offset(x: metrics.volumePopupOffset, y: -6)
                }
            }
            .padding(.top, metrics.insets.top).padding(.leading, metrics.insets.leading).padding(.trailing, metrics.insets.trailing)
            .background(metrics.visualizationHeight == nil ? LCMPDefaultGEQRenderer.background : .clear)
            .frame(height: metrics.visualizationHeight.map { $0 + metrics.insets.top })
            .frame(maxHeight: metrics.visualizationHeight == nil ? .infinity : nil)
            HStack(spacing: metrics.spacing) {
                LEDButton(symbol: "backward.end.fill", label: "前の曲", enabled: library?.canPrevious == true) { library?.previous() }
                LEDButton(symbol: "play.fill", label: playLabel, enabled: playback.canPlay,
                          activeColor: playColor, status: status) { if let library { library.togglePlayPause() } else { playback.togglePlayPause() } }
                    .keyboardShortcut(.space, modifiers: [])
                LEDButton(symbol: "forward.end.fill", label: "次の曲", enabled: library?.canNext == true) { library?.next() }
                LEDButton(symbol: "stop.fill", label: "停止", enabled: playback.canStop || library?.isPreparing == true, pulseColor: .orange) {
                    if let library { library.stop() } else { playback.stop() }
                }

                LEDButton(symbol: playback.isMuted || playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          label: "音量", activeColor: presentation.volumeVisible ? .green : nil) { presentation.volumeVisible.toggle() }
                    .background(VolumeClickRegion(handler: volumeOutsideClick))
                LEDButton(symbol: "line.3.horizontal", label: "メニュー", activeColor: presentation.extensionVisible ? .green : nil, action: toggleExtension)
            }.environment(\.ledButtonSize, LEDButtonSize(frame: metrics.buttonSize, symbol: metrics.symbolSize))
                .frame(maxWidth: .infinity).frame(height: metrics.controlsHeight)
                .padding(.bottom, metrics.insets.bottom)
                .background {
                    PlayerGlassBackground()
                }
        }
        .foregroundStyle(.white.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: metrics.cornerRadius).stroke(.white.opacity(metrics.cornerRadius == 0 ? 0 : 0.12), lineWidth: 1))
    }

    #if os(iOS)
    private static let seekHeight: CGFloat = 36
    #else
    private static let seekHeight: CGFloat = 20
    #endif
    private var seekBar: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            HStack(spacing: 6) {
                Text(timeText(seekPreview ?? playback.currentTime)).font(.system(size: 10, design: .monospaced))
                NativeSlider(value: Binding(get: { seekPreview ?? playback.currentTime }, set: {
                    presentation.cancelSeekHide()
                    if seekPreview == nil { seekSelection = playback.selectedURL }
                    seekPreview = $0
                }), range: 0...max(1, playback.duration), vertical: false, label: "再生位置", commit: {
                    // The library replays a track that has just ended; it holds the access the player gave up.
                    if let seekPreview, seekSelection == playback.selectedURL {
                        if let library { library.seek(to: seekPreview) } else { playback.seek(to: seekPreview) }
                    }
                    seekPreview = nil
                }, cancel: { presentation.closeOverlays(); seekPreview = nil }, focusChanged: { focused in
                    if focused { presentation.cancelSeekHide() } else { presentation.scheduleSeekHide() }
                }).frame(height: Self.seekHeight).disabled(!playback.canSeek)
                Text(timeText(playback.duration)).font(.system(size: 10, design: .monospaced))
            }.frame(height: Self.seekHeight + 4)
        }
        .onHover { inside in if inside { presentation.cancelSeekHide() } else { presentation.scheduleSeekHide() } }
        .background(VolumeClickRegion(handler: seekOutsideClick, isPopup: true, dismiss: presentation.scheduleSeekHide))
    }
    private var volumePopup: some View {
        VolumeFocusScope(content: volumeContents, dismiss: { presentation.volumeVisible = false })
            .background(VolumeClickRegion(handler: volumeOutsideClick, isPopup: true, dismiss: { presentation.volumeVisible = false }))
    }
    private var volumeContents: some View {
        VStack(spacing: 3) {
            Text("\(Int((Double(playback.volume) * 100).rounded()))%").font(.system(size: 10, design: .monospaced))
            NativeSlider(value: Binding(get: { Double(playback.volume) }, set: { playback.setVolume(Float($0)); presentation.volumeInteraction() }),
                         range: 0...1, vertical: true, label: "アプリ内音量", cancel: { presentation.closeOverlays() },
                         volumeCurve: true, trackingChanged: presentation.trackVolume).frame(width: 28, height: 64)
            LEDButton(symbol: "speaker.slash.fill", label: playback.isMuted ? "ミュート解除" : "ミュート",
                      activeColor: playback.isMuted ? .green : nil) { playback.toggleMute(); presentation.volumeInteraction() }
        }.padding(4).background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct LEDButton: View {
    let symbol: String
    let label: String
    var enabled = true
    var activeColor: Color? = nil
    var pulseColor: Color = .green
    var status: String? = nil
    let action: () -> Void
    @Environment(\.ledButtonSize) private var size
    @State private var flash = false
    @State private var pulseID = UUID()
    var body: some View {
        Button {
            let id = UUID(); pulseID = id; flash = true
            action()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                if pulseID == id { flash = false }
            }
        } label: {
            Image(systemName: symbol).font(.system(size: size.symbol))
                .foregroundStyle(activeColor ?? (flash ? pulseColor : Color.white.opacity(enabled ? 0.65 : 0.2)))
                .shadow(color: activeColor ?? (flash ? pulseColor : .clear), radius: 5)
                .frame(width: size.frame, height: size.frame)
                .overlay(alignment: .top) {
                    if let status {
                        Text(status).font(.system(size: 7 * size.symbol / 17, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5)).offset(y: size.frame * 34 / 44)
                    }
                }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
            .accessibilityValue(status ?? "")
            .onDisappear { pulseID = UUID(); flash = false }
    }
}

func timeText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let value = Int(seconds)
    return String(format: "%d:%02d", value / 60, value % 60)
}

extension View {
    /// Escape closes overlays: the exit command on macOS, a hardware keyboard's Escape on iOS.
    func onEscape(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) { action(); return .handled }
        #endif
    }
}

/// Size of the LED transport buttons; the volume popup's mute button keeps the default.
struct LEDButtonSize: Sendable {
    var frame: CGFloat = 44
    var symbol: CGFloat = 17
}
extension EnvironmentValues {
    @Entry var ledButtonSize = LEDButtonSize()
}
