import SwiftUI
import PlaybackCore

public struct ExtensionView: View {
    let playback: PlaybackController
    @Bindable var presentation: PlayerPresentation
    let chooseFile: () -> Void
    public init(playback: PlaybackController, presentation: PlayerPresentation, chooseFile: @escaping () -> Void) {
        self.playback = playback; self.presentation = presentation; self.chooseFile = chooseFile
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("機能", selection: $presentation.section) {
                ForEach(ExtensionSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch presentation.section {
                    case .playlist:
                        Text("現在の再生リスト").font(.headline)
                        if let url = playback.selectedURL {
                            Label(url.lastPathComponent, systemImage: "music.note").textSelection(.enabled)
                            Text("単曲再生・リスト編集は準備中").foregroundStyle(.secondary)
                        } else { Text("音源がありません。音楽ファイルを選択してください。") }
                        openButton
                    case .source:
                        Text("音楽ファイル").font(.headline)
                        Text(playback.selectedURL?.lastPathComponent ?? "未選択").textSelection(.enabled)
                        openButton
                        Text(playback.message).foregroundStyle(.secondary)
                    case .visualization:
                        Text("可視化").font(.headline)
                        Text("可視化の表示領域を用意しています。音声解析とデザイン切替は準備中です。")
                    case .settings:
                        Text("再生と表示").font(.headline)
                        Text("音量はアプリ内の再生音量です。出力はmacOSの既定デバイスを使用します。")
                        Text("⌘O 音源選択 · Space 再生／一時停止\n⌘M 最小化 · ⌘W 閉じる · ⌘Q 終了\n表示メニューからシーク・音量・拡張を切替")
                    }
                    if let error = playback.error {
                        Text(error.localizedDescription).foregroundStyle(.orange).textSelection(.enabled)
                            .accessibilityLabel("エラー：\(error.localizedDescription)")
                        openButton
                    }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.11)).foregroundStyle(.white.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .preferredColorScheme(.dark)
    }
    private var openButton: some View {
        Button("音楽ファイルを選択…", action: chooseFile).disabled(presentation.selectingFile)
    }
}
