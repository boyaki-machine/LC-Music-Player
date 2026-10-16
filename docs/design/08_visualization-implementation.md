# 可視化の実装設計

[設計書一覧](../README.md)に戻る。入力データの算出方法と時刻は[周波数解析](07_analysis-implementation.md)、画面と操作は[コンパクト画面](09_compact-ui-implementation.md)、フォルダ構成・モジュールI/F・追加方法は[Player UI・可視化の開発ガイド](10_playerUI_developers.md)を参照する。

## 責務と構成

表示固有の可視化は`PlayerUI/Players/LCMP_default_GEQ/Visualization/`へまとめ、画面と同じPlayer UIの一部として扱う。`AnalysisCore`の`AnalysisFrame`を表示用の`SpectrumSample`へ変換する。`VisualizationKit/Shared/`はUIに依存しない値型・時計・activityのみを提供する。可視化は音源・再生エンジン・ファイルアクセス権を所有せず、再デコードや音声加工も行わない。

| 要素 | 責務 |
| --- | --- |
| `LCMPDefaultGEQ` | このPlayer UIのID、名前、解析設定、表示データへの変換 |
| `LCMPDefaultGEQView` | driverから受け取った状態のCanvas描画 |
| `SpectrumPresentation` | 上限付き提示待ち、セル数、残光の開始時刻、欠落判定 |
| `VisualizationDriver` | MainActorでの受信と表示更新、取消可能な共通時計 |
| `Players/LCMP_default_GEQ/Visualization/` | 蛍光管LEDの表示スケール、提示状態・driver、Canvas描画、再生との接続 |
| `VisualizationKit/Shared/` | 表示用データの値型、host clock、activity |
| `PlaybackVisualization` | 再生状態・解析結果・表示可否を表示側へ渡すアダプター |
| `PlayerPresentation.visualizationDriver` | メイン表示の状態所有。非表示時に描画時計を直接終了 |

追加Player UIは画面・可視化を一式で`PlayerUI/Players/<ID>/`へまとめ、メインの`PlayerView`とアプリ側の接続を合わせる。外部コードを実行時に読み込む仕組みは設けない。現在のIDと表示名は`LCMPDefaultGEQ.id`・`LCMPDefaultGEQ.name`が返す`LCMP_default_GEQ`とする。拡張の表示タブには現在の表示内容を示し、単一候補の選択UIは置かない。

## 解析設定と表示スケール

`LCMP_default_GEQ`は16帯域・30Hz・2048点FFTを要求する。表示を開いた時点で`PlaybackController.configureAnalysis`へ設定し、閉じる・最小化・終了でnilへ解除する。解析API自体の既定32帯域や他の設定は、表示固有の設定と区別する。

帯域は20Hz〜min(20kHz, Nyquist)の等対数分割。縦軸も帯域パワーの対数値（dBFS）で、表示範囲は−80〜0dBFSとする。実装フォルダ内の`SpectrumSample(defaultGEQFrame:)`で`bandDBFS`から`clamp((dBFS + 80) / 80, 0, 1)`で表示用レベルを求め、点灯数を`floor(level × 24)`とする。1セルは約3.33dB相当で、−80dBFS以下は消灯、−40dBFSは12段、0dBFSは24段となる。非数値は受信側で拒否する。

解析APIの`bandDBFS`（−100〜0dBFS）と`levels`（その範囲の0〜1）は維持し、表示固有の感度を解析へ持ち込まない。二重の対数変換や自動ゲイン調整は行わず、同じ帯域パワーは曲や時刻によらず同じ高さになる。直線的な波形振幅や耳元の音圧ではない。解析はアプリ音量より前で取得するため、ミュート中も音源に応じて動く。

帯域数とFFTの周波数分解能は別である。48kHz/2048点のbin間隔は約23.4Hz、窓長は約42.7ms。出力レートが高い場合や狭い低域では独立binが入らない帯域があり、その下限値を架空のレベルで埋めない。帯域集約とDC除去・窓掛けは解析側の仕様に従う。

## 蛍光管LEDの描画

360×144ptの表示領域に16列×24段を配置する。左右余白18pt、上20pt、下27pt、列間7pt、段間1ptとし、下部に20Hz・1kHz・20kHzの位置目安を置く。1kHzは対数軸上の位置に合わせる。

| セル位置 | 点灯色 | 消灯色 |
| --- | --- | --- |
| 下12段 | `#66ff79` | `#0d2113` |
| 次の6段 | `#eaff51` | `#20210d` |
| 上6段 | `#ff585c` | `#240e12` |

周囲の背景は`#050807`。色はセルの高さに対応し、周波数ごとに色を変えない。赤いセルは表示範囲の上部を表し、クリッピング判定や音量警告ではない。

セル本体は全面を固定色でON/OFFする。部分的な充填、点灯へのフェード、入力レベルによるセル本体の連続輝度変更はしない。OFFへ変わったセルだけ、別レイヤーに最大0.25の残光を置き、`0.25 × (1 − 経過時間 / 0.2秒)²`で消す。再点灯で残光を取り消し、200ms後に時刻情報を除く。

周辺光は色別にまとめたPathへ薄いぼかしを重ね、セル本体より先に描く。これにより隣のセルの光が発光面を覆わない。4pt/9pt程度のぼかしと低い不透明度で広がりを作る。残光にも薄い周辺光を添える。ブラウザー試作のCSSとネイティブ描画ではぼかしの計算が異なるため、数値の一致より外観を基準にする。

OSの「動きを減らす」設定では残光を描かない。表示名と解析データ待ちを支援技術へ公開するが、毎フレームのレベルを読み上げない。描画面は入力イベントを受けず、既存のドラッグ移動・シーク・音量の操作面を維持する。

## 時刻、上限、欠落

表示時計は音声と同じ`AVAudioTime`のhost clockを秒へ換算する。壁時計やファイル上の再生位置は使わない。既知の推定提示時刻を持つ結果は、その時刻まで待ってから採用する。取得不能な時刻や不正・過大な未来時刻は即時表示へフォールバックし、存在しない出力時刻を算出しない。

提示待ちは最大64フレーム。満杯なら先頭の期限を保護して、その次に古い待ちを捨てる。到着が多すぎるときも、先頭を捨て続けていつまでも表示されない状態を避ける。更新時には期限を迎えた中の最新1フレームだけを採用し、過去の表示を順に再生しない。新規受信で既存フレームの期限を延長しない。待機により音声側を遅らせる処理は追加しない。

世代が変わると待ちと旧セル状態を破棄する。同じ世代で古い連番を受け取った場合、配列数の不一致、NaN/Infinity、古すぎる結果は採用しない。再生側も接続ごとの取消IDを照合し、シーク・再設定・再開前の遅延通知を破棄する。

新規受信または最新の採用から250ms以上更新がなく、提示待ちも空なら、再生中のセルを消灯して短い残光だけを残し「解析データを待っています」を示す。正常な無音フレームは全消灯でも待機表示にしない。新しいフレームが来れば復帰する。

## 状態と資源寿命

| 状態・操作 | 表示と資源 |
| --- | --- |
| 再生中 | 受信時に期限到来分を採用。約33msの共通時計で未来の提示・残光・欠落も更新 |
| 一時停止 | 点灯セルを静止し、提示待ちを破棄。既存の残光が消えると時計も終了 |
| 再開 | 旧表示を捨て、新しい世代のデータを待つ |
| 停止・自然終了・再生失敗・出力変更 | セルと提示待ちをリセット、時計終了 |
| 曲変更・シーク・解析再設定 | `analysisResetID`で、フレームが既にnilでも旧表示を破棄 |
| 閉じる・最小化 | 解析を購読解除し、表示時計と待ちを直ちに解放。音声再生は維持 |
| 再表示 | 16帯域設定を適用し、再生中なら新規データから再開 |
| アプリ終了 | 非表示処理に加え、既存のライブラリ／再生終了処理を実行 |

非表示時は`PlayerPresentation`からdriverを直接停止する。非表示になったNSHostingViewの再評価やonDisappearだけに依存しない。Taskはdriverを弱参照し、取消IDで旧時計が新しい時計へ干渉するのを防ぐ。1セルごとのTaskやタイマーは作らない。

## 検証と測定方法

通常の`./scripts/swift.sh test --disable-automatic-resolution`で、量子化、消灯時だけの残光、未来期限・最新採用・上限、欠落と無音、世代・取消、pause/hide時の終了と解放を確認する。

`LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --disable-automatic-resolution --no-parallel`では通常の実出力回帰に加え、生成したPCMが実際のPlayerViewへ届くこと、pause/seek/stop/自然終了、非表示と再表示を確認する。全体の実出力検証では`--no-parallel`を明示し、他のMainActor処理による短い音源の観測漏れを避ける。suiteの`.serialized`だけでは別suiteとの並行実行を止めない。可視化専用の生成音源はアプリ音量0で再生し、元ファイルやOS音量を変更しない。

`LCMP_UI_SNAPSHOTS=build/visualization-native-qa`を指定して`VisualizationLifecycleTests`と`VisualizationIntegrationTests`を実行すると、ネイティブの単体表示と実PCMを表示するメイン画像を保存する。点灯色、OFFセル、周辺光、セル境界、操作部との重なりを目視する。

2048/4096点の短時間比較：

```sh
LCMP_VISUALIZATION_PROFILE=1 \
LCMP_VISUALIZATION_REPORT_DIR=build/visualization-profile \
./scripts/swift.sh test --disable-automatic-resolution \
  --filter 'VisualizationPerformanceTests/comparesAnalysisWindows'
```

10分連続測定：

```sh
LCMP_VISUALIZATION_PROFILE=1 LCMP_VISUALIZATION_SOAK=1 \
LCMP_VISUALIZATION_REPORT_DIR=build/visualization-soak \
./scripts/swift.sh test --disable-automatic-resolution \
  --filter 'VisualizationPerformanceTests/tenMinuteRenderingRemainsBounded'
```

測定では既定デバイスで独自ステレオPCMをアプリ音量0で再生し、実解析とdriverを動かしながら360×144ptをImageRendererで約30回/秒ラスタライズする。描画コマンドのCPU処理と、SwiftUIの準備・ラスタライズ・画像取得を含む全体を分けて測る。後者はオフスクリーン測定であり、画面上の実提示時刻ではない。

固定容量ヒストグラムで時間のp50/p95/maxを求め、受信／採用／異なる結果を描いた回数、待ち上限、PCM欠落、CPU、30秒ごとのRSSを記録する。CPUは再生・解析・テスト描画を含むプロセス全体で、100%を1コアとする。受入チェックは受信27Hz超、異なる結果の描画20Hz超、全体描画p95が1周期未満、推定提示時刻から画像準備までの遅れp95が120ms未満、早出し2ms未満、待ち64以下、PCM欠落0、CPU50%未満、60秒以後のRSS変動幅15MiB未満とする。時刻差の実測値も残し、しきい値だけで同期精度を表現しない。

音声デバイスの物理的な発音とディスプレイの提示時刻の一致は、この測定では保証しない。同じインパルスの出音と画面を別途測って評価する。将来の音声遅延補償は解析側の時刻契約を保った上で追加する。

参照：[Canvas](https://developer.apple.com/documentation/swiftui/canvas)、[GraphicsContext](https://developer.apple.com/documentation/swiftui/graphicscontext)、[ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer)、[Swift Testingの並行実行](https://developer.apple.com/documentation/testing/parallelization)。
