import SwiftUI
import PlaybackCore

struct PlayerView: View {
    let playback: PlaybackController
    let selectingFile: Bool
    let chooseFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("LCMP").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button("ファイルを選択…", action: chooseFile)
                    .disabled(selectingFile)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(playback.selectedURL?.lastPathComponent ?? "音楽ファイルが選択されていません")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(playback.selectedURL?.lastPathComponent ?? "")

                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    HStack {
                        Text(playback.message)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text("\(timeText(playback.currentTime)) / \(timeText(playback.duration))")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }

            HStack(spacing: 12) {
                Button(action: playback.togglePlayPause) {
                    Label(playback.state == .playing ? "一時停止" : "再生",
                          systemImage: playback.state == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 80)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!playback.canPlay)

                Button(action: playback.stop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!playback.canStop)

                Spacer(minLength: 16)
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { Double(playback.volume) },
                    set: { playback.setVolume(Float($0)) }
                ), in: 0...1)
                .frame(width: 110)
                .accessibilityLabel("再生音量")
                .accessibilityValue("\(Int(playback.volume * 100))パーセント")
            }

            if let error = playback.error {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityLabel("エラー：\(error.localizedDescription)")
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 220, alignment: .topLeading)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
