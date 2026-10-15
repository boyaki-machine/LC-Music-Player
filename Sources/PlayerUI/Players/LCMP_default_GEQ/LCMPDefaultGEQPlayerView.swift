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

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                PlaybackVisualization(playback: playback, driver: presentation.visualizationDriver,
                                      visible: presentation.visualizationVisible)
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
                if presentation.seekVisible { seekBar.padding(.horizontal, 12).padding(.bottom, 5) }
                if presentation.volumeVisible { volumePopup.frame(width: 54, height: 132).offset(x: 99, y: -6) }
            }.frame(height: 144)
            HStack(spacing: 9) {
                LEDButton(symbol: "backward.end.fill", label: "前の曲", enabled: library?.canPrevious == true) { library?.previous() }
                LEDButton(symbol: "play.fill", label: playLabel, enabled: playback.canPlay,
                          activeColor: playColor, status: status) { if let library { library.togglePlayPause() } else { playback.togglePlayPause() } }
                    .keyboardShortcut(.space, modifiers: [])
                LEDButton(symbol: "forward.end.fill", label: "次の曲", enabled: library?.canNext == true) { library?.next() }
                LEDButton(symbol: "stop.fill", label: "停止", enabled: playback.canStop, pulseColor: .orange, action: playback.stop)
                LEDButton(symbol: playback.isMuted || playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          label: "音量", activeColor: presentation.volumeVisible ? .green : nil) { presentation.volumeVisible.toggle() }
                    .background(VolumeClickRegion(handler: volumeOutsideClick))
                LEDButton(symbol: "line.3.horizontal", label: "メニュー", activeColor: presentation.extensionVisible ? .green : nil, action: toggleExtension)
            }.frame(maxWidth: .infinity).frame(height: 66)
                .background {
                    PlayerGlassBackground()
                }
        }
        .foregroundStyle(.white.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
        .frame(width: 360, height: 210)
        .onExitCommand { presentation.closeOverlays(); seekPreview = nil }
        .onChange(of: playback.selectedURL) { _, _ in seekPreview = nil }
        .onChange(of: playback.state) { _, _ in seekPreview = nil }
        .onChange(of: presentation.seekVisible) { _, _ in seekPreview = nil }
    }

    private var seekBar: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            HStack(spacing: 6) {
                Text(timeText(seekPreview ?? playback.currentTime)).font(.system(size: 10, design: .monospaced))
                NativeSlider(value: Binding(get: { seekPreview ?? playback.currentTime }, set: {
                    presentation.cancelSeekHide()
                    if seekPreview == nil { seekSelection = playback.selectedURL }
                    seekPreview = $0
                }), range: 0...max(1, playback.duration), vertical: false, label: "再生位置", commit: {
                    if let seekPreview, seekSelection == playback.selectedURL { playback.seek(to: seekPreview) }
                    seekPreview = nil
                }, cancel: { presentation.closeOverlays(); seekPreview = nil }, focusChanged: { focused in
                    if focused { presentation.cancelSeekHide() } else { presentation.scheduleSeekHide() }
                }).frame(height: 20).disabled(!playback.canSeek)
                Text(timeText(playback.duration)).font(.system(size: 10, design: .monospaced))
            }.frame(height: 24)
        }
        .onHover { inside in if inside { presentation.cancelSeekHide() } else { presentation.scheduleSeekHide() } }
        .background(VolumeClickRegion(handler: seekOutsideClick, isPopup: true, dismiss: presentation.scheduleSeekHide))
    }
    private var volumePopup: some View {
        VStack(spacing: 3) {
            Text("\(Int(playback.volume * 100))%").font(.system(size: 10, design: .monospaced))
            NativeSlider(value: Binding(get: { Double(playback.volume) }, set: { playback.setVolume(Float($0)) }),
                         range: 0...1, vertical: true, label: "アプリ内音量", cancel: { presentation.closeOverlays() }).frame(width: 28, height: 64)
            LEDButton(symbol: "speaker.slash.fill", label: playback.isMuted ? "ミュート解除" : "ミュート",
                      activeColor: playback.isMuted ? .green : nil, action: playback.toggleMute)
        }.padding(4).background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 6))
            .background(VolumeClickRegion(handler: volumeOutsideClick, isPopup: true, dismiss: { presentation.volumeVisible = false }))
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
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17))
                    .foregroundStyle(activeColor ?? (flash ? pulseColor : Color.white.opacity(enabled ? 0.65 : 0.2)))
                    .shadow(color: activeColor ?? (flash ? pulseColor : .clear), radius: 5)
                if let status { Text(status).font(.system(size: 7, design: .monospaced)).foregroundStyle(.white.opacity(0.5)) }
            }.frame(width: 44, height: 44).contentShape(Rectangle())
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
