# 可視化の実装設計

[設計書一覧](../README.md)に戻る。

## 1. 概要

本書は、`LCMP_default_GEQ`の16列の蛍光管LED表示を記述する。[周波数解析](07_analysis-implementation.md)の結果を受け取り、提示時刻に合わせてセルを点灯・消灯し、残光を描く。

- 画面と操作は[コンパクト画面](09_compact-ui-implementation.md)に記載する。
- フォルダ構成・モジュールのI/F・新しい可視化の追加方法は、[Player UI・可視化の開発ガイド](10_player-ui-developer-guide.md)に記載する。
- 外観の要件は[UI・UX設計](01_ui-ux-design.md)に記載する。
- 同じ領域で切り替えるほかのデザインは、[オコジョ合唱団の実装設計](12_ermine-chorus-implementation.md)、[教育番組（パペット）の実装設計](14_puppet-show-implementation.md)、[Last Century ラジカセの実装設計](17_radio-cassette-implementation.md)に記載する。

## 2. 要件

- 可視化は、音源・再生エンジン・ファイルアクセス権を所有しない。再デコードや音声の加工も行わない。
- 同じ帯域パワーは、曲や時刻によらず同じ高さで表示する。
- 解析結果を推定提示時刻に合わせて表示し、そのために音声側を遅らせない。
- 一時停止では静止し、停止・曲の変更・シークでは旧表示を破棄する。データの欠落と正常な無音を区別する。
- 非表示・最小化の間と、macOSでメインのウインドウが見えない間（他のウインドウの裏・別の操作スペース・画面のスリープ。`NSWindow.occlusionState`）は、解析の購読と描画の時計を止める。

## 3. 方式

表示固有の可視化は`PlayerUI/Players/LCMP_default_GEQ/Visualization/`へまとめ、画面と同じPlayer UIの一部として扱う。`AnalysisCore`の`AnalysisFrame`を、表示用の`SpectrumSample`へ変換する。`VisualizationKit/Shared/`は、UIに依存しない値型・時計・activityだけを提供する。

| 要素 | 担当 |
| --- | --- |
| `LCMPDefaultGEQ` | このPlayer UIのID、名前、解析設定、表示データへの変換 |
| `LCMPDefaultGEQView` | driverから受け取った状態のCanvas描画 |
| `SpectrumPresentation` | 上限付きの提示待ち、セル数、残光の開始時刻、欠落の判定 |
| `VisualizationDriver` | MainActorでの受信と表示の更新、取消できる共通の時計 |
| `PlaybackVisualization` | 再生状態・解析結果・表示可否を表示側へ渡すアダプター |
| `PlayerPresentation.visualizationDriver` | メイン表示の状態の所有。非表示時に描画の時計を直接終了する |
| `VisualizationKit/Shared/` | 表示用データの値型、host clock、activity |

- 現在のIDと表示名は、`LCMPDefaultGEQ.id`・`LCMPDefaultGEQ.name`が返す`LCMP_default_GEQ`である。
- 追加のPlayer UIは、画面・可視化を一式で`PlayerUI/Players/<ID>/`へまとめ、メインの`PlayerView`とアプリ側の接続を合わせる。外部のコードを実行時に読み込む仕組みは設けない。
- 拡張画面の表示タブには現在の表示内容を示し、候補が1つだけの選択UIは置かない。

## 4. 実装

### 解析設定と表示スケール

- `LCMP_default_GEQ`は16帯域・30Hz・2048点のFFTを要求する。表示を開いた時点で`PlaybackController.configureAnalysis`へ設定し、閉じる・最小化・ウインドウが見えなくなる・終了でnilへ解除する。解析API自体の既定（32帯域）とは区別する。
- 帯域は20Hz〜min(20kHz, Nyquist)の等対数分割である。縦軸も帯域パワーの対数値（dBFS）で、表示範囲は−80〜0dBFSとする。
- 実装フォルダ内の`SpectrumSample(defaultGEQFrame:)`が、`bandDBFS`から`clamp((dBFS + 80) / 80, 0, 1)`で表示用のレベルを求め、点灯数を`floor(level × 24)`とする。1セルは約3.33dB相当で、−80dBFS以下は消灯、−40dBFSは12段、0dBFSは24段となる。非数値は受信側で拒否する。
- 解析APIの`bandDBFS`（−100〜0dBFS）と`levels`（その範囲の0〜1）は維持し、表示固有の感度を解析へ持ち込まない。二重の対数変換や自動ゲイン調整は行わない。直線的な波形の振幅や耳元の音圧ではない。
- 解析はアプリ音量より前で取得するため、ミュート中も音源に応じて動く。
- 帯域数とFFTの周波数分解能は別である。48kHz/2048点のbin間隔は約23.4Hz、窓長は約42.7msである。出力レートが高い場合や狭い低域では独立したbinが入らない帯域があり、その下限値を架空のレベルで埋めない。

### 蛍光管LEDの描画

360×144ptの表示領域に、16列×24段を配置する。左右の余白18pt、上20pt、下27pt、列の間7pt、段の間1ptとし、下部に20Hz・1kHz・20kHzの位置の目安を置く。1kHzは対数軸上の位置に合わせる。

| セルの位置 | 点灯色 | 消灯色 |
| --- | --- | --- |
| 下の12段 | `#66ff79` | `#0d2113` |
| 次の6段 | `#eaff51` | `#20210d` |
| 上の6段 | `#ff585c` | `#240e12` |

- 周囲の背景は`#050807`とする。色はセルの高さに対応し、周波数ごとに色を変えない。赤いセルは表示範囲の上部を表すもので、クリッピングの判定や音量の警告ではない。
- セル本体は全面を固定色でON/OFFする。部分的な充填、点灯へのフェード、入力レベルによるセル本体の連続的な輝度変化はしない。
- OFFへ変わったセルだけ、別のレイヤーに最大0.25の残光を置き、`0.25 × (1 − 経過時間 / 0.2秒)²`で消す。再点灯で残光を取り消し、200ms後に時刻情報を除く。
- 周辺光は色別にまとめたPathへ薄いぼかしを重ね、セル本体より先に描く。これにより隣のセルの光が発光面を覆わない。4pt/9pt程度のぼかしと低い不透明度で広がりを作る。残光にも薄い周辺光を添える。ブラウザーの試作のCSSとネイティブの描画ではぼかしの計算が異なるため、数値の一致より外観を基準にする。
- OSの「動きを減らす」設定では残光を描かない。

画面への描画はMetal（`LCMPDefaultGEQMetal`、`MTKView`）で行う。

- SwiftUIの`Canvas`で毎フレーム描くと、ラスタライズ自体はGPUで行われても、毎回の描画命令の組み立てと受け渡しにCPUを使う（360×144ptの画面上の測定で、描画分のCPUの電力が約13mW）。Metalでは、毎フレームのCPUの仕事をセルの四角形の一覧（最大で約800個、約0.03ms）に限る。
- セル本体は四角形として描き、端は画素の被覆率でアンチエイリアスする（Core Graphicsの塗りと同じ考え方）。
- 周辺光は毎フレームぼかさない。点灯は列の下から連続するので、1列の光は点灯数（1〜24）だけで決まる。半径ごとに24通りの列の光と、色ごとの残光の光を、`LCMPDefaultGEQRenderer`と同じぼかしの描画（`drawLitGlow`・`drawAfterglowGlow`）で一度だけ画像にし、毎フレームは位置と不透明度を変えて重ねる。画像は表示の大きさ・倍率・目盛りの文字の大きさが変わったときに作り直す（2倍で約7〜11ms）。
- 光の画像の解像度は、4ptの光と残光は最大2倍、9ptの光は1倍とする。ぼかしが広いほど細部がないため、倍率を下げても外観は変わらず、メモリが減る（360×144pt・2倍で約4MB）。
- 重ねる順は`Canvas`と同じく、消灯セル、4ptの光、9ptの光、残光の光、点灯セルと残光のセルとする。合成は事前乗算のsource-overで、Core Graphicsと同じく保存された値（sRGB）のまま行う。
- 新しいフレームはSwiftUIを通さずに描く。`MTKView`の描画部（`LCMPDefaultGEQStageCoordinator`）がdriverの`snapshot`と`drawTime`をObservationで直接見張り、変わったら自分の層だけを描き直す。`LCMPDefaultGEQView`の本体は毎フレームの値を読まないので、フレームごとにSwiftUIのビューの更新や、SwiftUI自身の層の描き直しが起きない。SwiftUIを通していたときは、描画の方式をMetalにしてもこの更新が負荷の大半を占めた（実際の再生での測定で、`Canvas`約58mW、Metalのみ約48mW、SwiftUIを通さない形で約28mW、解析だけなら約6mW）。
- 描くタイミングはdriverが値を更新したときで、SwiftUIを通していたときと同じである。Observationの通知は値を書き込む前に届き、driverは時刻とセルを続けて書き込むため、両方をMainActorの次の順番で読む。
- 「解析データを待っています」と支援技術への値は、driverの`waitingForData`（`snapshot.waitingForData`が変わったときだけ書き込む）から作る。「動きを減らす」と目盛りの文字の大きさはSwiftUIから描画部へ渡す。
- 表示を片付けると（`dismantleNSView`/`dismantleUIView`）、描画部はdriverの見張りをやめる。見張りの登録ごとに番号を持ち、片付けた後に届く古い通知は無視する。
- 目盛りの文字は、Metalの上に重ねた別のビュー（`LCMPDefaultGEQLabels`）の`Canvas`で描く。入力（文字の大きさ）が変わらないので、再生中に描き直されない。
- Metalが使えない環境では、従来の`Canvas`の描画（`LCMPDefaultGEQRenderer`）で同じ絵を描く。`Canvas`の描画は、Metalの外観を確かめる基準としても残す。
- 表示名と解析データの待機を支援技術へ公開するが、毎フレームのレベルは読み上げない。
- 描画面は入力イベントを受けず、ドラッグ移動・シーク・音量の操作面を妨げない。

### 時刻・上限・欠落

- 表示の時計は、音声と同じ`AVAudioTime`のhost clockを秒へ換算して使う。壁時計やファイル上の再生位置は使わない。
- 推定提示時刻を持つ結果は、その時刻の25ms前（`VisualizationClock.presentationLead`）まで待ってから採用する。取得できない時刻や、不正・過大な未来の時刻は即時表示へフォールバックし、存在しない出力時刻を算出しない。
- 先読みの幅は、約33msの時計で期限の後に採用する待ち（平均で半周期）と、描画が画面に届くまでの約1回の画面更新を足した値である。提示時刻ちょうどに採用すると、表示は常に音より遅れる（実測でp95が約40〜55ms）。先読みで誤差の中心を音に寄せる。映像が音より少し先になるずれは、音が映像より先になるずれより気づかれにくい。
- 提示待ちは最大64フレームとする。満杯なら、先頭の期限を保護してその次に古い待ちを捨てる。到着が多すぎるときも、先頭を捨て続けていつまでも表示されない状態を避ける。
- 更新時には、期限を迎えた中の最新1フレームだけを採用し、過去の表示を順に再生しない。新しい受信で既存のフレームの期限を延長しない。待機のために音声側を遅らせる処理は追加しない。
- 世代が変わると、待ちと旧セルの状態を破棄する。同じ世代の古い連番、配列数の不一致、NaN/Infinity、古すぎる結果は採用しない。再生側も接続ごとの取消IDを照合し、シーク・再設定・再開前の遅延通知を破棄する。
- 新しい受信または最新の採用から250ms以上更新がなく、提示待ちも空なら、再生中のセルを消灯して短い残光だけを残し、「解析データを待っています」を示す。正常な無音フレームは、全消灯でも待機表示にしない。新しいフレームが来れば復帰する。

### 状態と資源の寿命

| 状態・操作 | 表示と資源 |
| --- | --- |
| 再生中 | 受信時に期限（提示時刻−先読みの幅）が到来した分を採用する。約33msの共通の時計で、未来の提示・残光・欠落も更新する |
| 一時停止（出力変更による一時停止を含む） | 点灯セルを静止し、提示待ちを破棄する。既存の残光が消えると時計も終了する |
| 再開 | 旧表示を捨て、新しい世代のデータを待つ |
| 停止・自然終了・再生失敗 | セルと提示待ちをリセットし、時計を終了する |
| 曲の変更・シーク・解析の再設定 | `analysisResetID`で、フレームがすでにnilでも旧表示を破棄する |
| 閉じる・最小化・ウインドウが見えなくなる | 解析の購読を解除し、表示の時計と待ちを直ちに解放する。音声の再生は続ける |
| 再表示 | 16帯域の設定を適用し、再生中なら新しいデータから再開する |
| アプリの終了 | 非表示の処理に加え、ライブラリ・再生の終了処理を実行する |

- 非表示時は`PlayerPresentation`からdriverを直接停止する。非表示になったNSHostingViewの再評価やonDisappearだけに依存しない。
- Taskはdriverを弱参照し、取消IDで旧時計が新しい時計へ干渉するのを防ぐ。セルごとのTaskやタイマーは作らない。

## 5. 検証

### 合格基準

- 量子化、消灯時だけの残光、未来の期限・最新の採用・上限、欠落と無音、世代・取消、一時停止・非表示時の終了と解放が仕様どおりである。
- 生成したPCMが実際のPlayerViewへ届き、一時停止・シーク・停止・自然終了、非表示と再表示が正しく動作する。

### 自動テスト

- 通常の`./scripts/swift.sh test --disable-automatic-resolution`で、状態と寿命を確認する。
- `LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --disable-automatic-resolution --no-parallel`で、実出力からPlayerViewまでの接続を確認する。全体の実出力の検証では`--no-parallel`を明示し、他のMainActorの処理による短い音源の観測漏れを避ける。suiteの`.serialized`だけでは、別のsuiteとの並行実行は止まらない。
- 可視化専用の生成音源はアプリ音量0で再生し、元のファイルやOS音量を変更しない。
- `LCMPDefaultGEQMetalTests`で、Metalの描画を`Canvas`の描画と1・2・3倍で比べる（全消灯・一部点灯・全点灯・残光あり、目盛りの文字の上まで）。基準は、平均の差が1/255未満、最大の差が40/255以下、4/255を超える差が1.5%未満とする。実測は平均0.6以下、最大27（セルの端のアンチエイリアス）、0.6%程度だった。あわせて、点灯セルの周辺光、「動きを減らす」での残光の省略、光の画像の作り直しの条件とメモリを確かめる。光の画像を作り直すと、ぼかしの結果が1〜2/255ほど揺れることがあるため、完全一致を比べるときは同じ画像を使う。
- 同じスイートで、描画部がSwiftUIを通さずにdriverの新しいフレームを受け取ること、設定の変更を反映すること、片付けた後はdriverを見張らないこと、`waitingForData`が毎フレームには通知されないことを確かめる。

### 画像による確認

`LCMP_UI_SNAPSHOTS=build/visualization-native-qa`を指定して`VisualizationLifecycleTests`と`VisualizationIntegrationTests`を実行すると、ネイティブの単体表示と、実PCMを表示するメインの画像を保存する。点灯色、OFFのセル、周辺光、セルの境界、操作部との重なりを目視する。`cacheDisplay`はMetalの表示を写さないため、単体表示の画像は同じフレームを画面外のMetalで描き、目盛りの文字を重ねて保存する。

### 負荷と同期の測定

2048/4096点の短時間の比較：

```sh
LCMP_VISUALIZATION_PROFILE=1 \
LCMP_VISUALIZATION_REPORT_DIR=build/visualization-profile \
./scripts/swift.sh test --disable-automatic-resolution \
  --filter 'VisualizationPerformanceTests/comparesAnalysisWindows'
```

音源の条件（48kHzのWAV、AAC、96kHz/24bitのFLAC、192kHz/24bitのWAV、音量自動調整ありのFLAC）ごとの比較：

```sh
LCMP_VISUALIZATION_PROFILE=1 \
LCMP_VISUALIZATION_REPORT_DIR=build/visualization-sources \
./scripts/swift.sh test --disable-automatic-resolution --no-parallel \
  --filter 'VisualizationPerformanceTests/comparesSourceConditions'
```

- 推定提示時刻に対する遅れ・早さと、観測した出力遅延（`estimatedOutputLatencyMs`）をJSONに残す。出力遅延は出力先で大きく変わる（macの内蔵スピーカー約1.5ms、Bluetoothのイヤホン約220ms、iPhoneのスピーカー約16ms、Bluetoothのイヤホン約240ms）ので、評価では出力先を併記する。iPhoneでも推定提示時刻は経路の遅延を含み、再生中の経路の変更にも追従する（[iPhone版の実装設計](13_iphone-implementation.md#出力遅延の取り方)）。
- 内蔵スピーカーなど出力遅延が解析の窓の半分より短い出力先では、解析結果が揃った時点で提示時刻を過ぎている。この遅れは先読みでは縮まらず、縮めるには音声を遅らせる同期用ディレイが要る。

10分連続の測定：

```sh
LCMP_VISUALIZATION_PROFILE=1 LCMP_VISUALIZATION_SOAK=1 \
LCMP_VISUALIZATION_REPORT_DIR=build/visualization-soak \
./scripts/swift.sh test --disable-automatic-resolution \
  --filter 'VisualizationPerformanceTests/tenMinuteRenderingRemainsBounded'
```

- 既定のデバイスで独自のステレオPCMをアプリ音量0で再生し、実際の解析とdriverを動かしながら、360×144ptを画面と同じMetalの描画で約30回/秒オフスクリーンに描いて読み出す。
- 描画コマンドのCPU処理（四角形の一覧の作成とエンコード）と、GPUの描画・画像の読み出しを含む全体を分けて測る。後者はオフスクリーンの測定であり、画面上の実際の提示時刻ではない。
- 固定容量のヒストグラムで時間のp50/p95/maxを求め、受信・採用・異なる結果を描いた回数、待ちの上限、PCMの欠落、CPU、30秒ごとのRSSを記録する。CPUは再生・解析・テストの描画を含むプロセス全体の値で、100%を1コアとする。

画面上の描画の負荷（`Canvas`とMetalの比較）：

```sh
LCMP_VISUALIZATION_PROFILE=1 \
LCMP_VISUALIZATION_REPORT_DIR=build/visualization-onscreen \
./scripts/swift.sh test --disable-automatic-resolution --no-parallel \
  --filter 'VisualizationPerformanceTests/comparesOnScreenRenderers'
```

- 360×144ptの見えるウインドウで、比較用の4つの状態を約30回/秒で切り替え、`Canvas`とMetalを交互に15秒ずつ2回描く。再生と解析は動かさないので、差は描画方式だけによる。
- プロセスのCPU時間・CPUの電力（`proc_pid_rusage`の`ri_energy_nj`、権限不要）・起床回数をJSONに残す。GPUとWindowServerの電力は含まない。測定は時間帯でCPUの電力が動くため、比べる2つを交互に測る。
- 基準：Metalの電力が`Canvas`より小さい。実測（Release、Apple Silicon）では、`Canvas`約15〜17mW・Metal約6.4mW、起床は約58→27回/秒だった。

受け入れの基準は次のとおりとする。時刻差の実測値も残し、しきい値だけで同期の精度を表さない。

| 項目 | 基準 |
| --- | --- |
| 受信 | 27Hz超 |
| 異なる結果の描画 | 20Hz超 |
| 全体の描画のp95 | 1周期未満 |
| 推定提示時刻から画像の準備までの遅れのp95 | 120ms未満 |
| 推定提示時刻より早い表示 | 先読みの幅＋2ms未満 |
| 待ち | 64以下 |
| PCMの欠落 | 0 |
| CPU | 50%未満 |
| 60秒以後のRSSの変動幅 | 15MiB未満 |

音声デバイスの物理的な発音とディスプレイの提示時刻の一致は、この測定では保証しない。同じインパルスの出音と画面を別に測って評価する。将来の音声遅延の補償は、解析側の時刻の契約を保った上で追加する。

## 6. 参照

- [Canvas](https://developer.apple.com/documentation/swiftui/canvas)
- [GraphicsContext](https://developer.apple.com/documentation/swiftui/graphicscontext)
- [ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer)
- [Swift Testingの並行実行](https://developer.apple.com/documentation/testing/parallelization)
