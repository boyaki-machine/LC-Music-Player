# 周波数解析の実装設計

[設計書一覧](../README.md)に戻る。

## 1. 概要

`AnalysisCore`は、再生中の音声から、表示に依存しないスペクトラム・左右レベルと時刻情報を生成する。可視化は、この解析結果を受け取って描画する（[可視化の実装設計](08_visualization-implementation.md)）。全曲のsample peakの測定は[再生前処理](04_preprocessing-implementation.md)の別の処理である。

## 2. 要件

- 再生経路の音声を観測し、音源を再度開かない。音声データを変更しない。
- 解析はアプリ音量・ミュートより前で行い、音量0でも音源のレベルを返す。
- 音声のrender callbackを待たせない。メモリ確保・FFT・ロックの待ち・I/Oをrender callbackに置かない。
- 解析が遅れても過去の結果をまとめて送らず、最新の結果を渡す。
- 将来の音声と表示の同期補償に使えるよう、音声のレンダー時刻を基準とした時刻情報を付ける。

## 3. 方式

`PlaybackCore`のAudioEngineBackendが、音声の取得と解析セッションの寿命を所有する。`AnalysisTransport`は、Cの固定容量SPSCキューとAudio Unitのレンダー通知を実装する。

```text
PCMFeeder → AVAudioPlayerNode
    → 形式変換mixer → 観測ノード ──→ PCMコピー → 有界キュー → FFTワーカー → 最新結果 → 表示側
    → 音量自動調整gain → 将来の同期遅延段
    → mainMixer（アプリ音量）→ OS出力
```

- 観測ノードは`AVAudioUnitEQ(numberOfBands: 0)`である。フィルターはなく、globalGainは0dBとする。公開AudioUnitへのレンダー通知を使うために置くもので、利用者向けの音声イコライザー機能は提供しない。
- 観測側の形式は、mainMixerの出力レート・チャンネル数に対応する標準Float32 PCMである。前段のmixerが音源から出力形式へ変換し、後段のmainMixerと同じ形式を使って不要なレート変換を避ける。
- グラフは再生開始ごとに、エンジンを開始する前に組み立てる。再生中にグラフを組み替えない。
- [音量自動調整](06_volume-normalization-implementation.md)では、この観測ノードの後に専用のgain段を置く。観測用EQのgainは変更せず、解析の購読を解除しても自動補正は続ける。自動調整ONでは、共通の形式変換を行うProfileDecoderの出力を観測する。
- 可視化の解析値と、LUFS/true peakによる出力補正の測定値・状態は別のデータとして扱う。

## 4. 実装

### 観測

- 通知はpost-renderかつエラーがない場合だけ処理し、音声データを変更せずにコピーする。
- Float32の非interleavedを受け取る。monoは左右へ同じ値、2ch以上は出力形式の先頭2chを解析する。全チャンネルのサラウンド解析ではない。

### 設定と解析

`AnalysisConfiguration`は、帯域数8〜128、更新頻度15/30/60Hz、FFTサイズ1024/2048/4096/8192点を受け付ける。既定は32帯域・30Hz・2048点である。表示の実装は初期化・切替時に`PlaybackController.configureAnalysis`を呼び、nilで購読を解除できる。

- Accelerate/vDSPの実数FFT（`vDSP_fft_zrip`）と周期的なHann窓を使う。入力は実数なので、半分の長さの複素FFTで求め、出力の2倍の倍率とNyquistの格納位置を補正する。帯域の値は複素FFTの場合と0.01dB以内で一致する（`RealTransformTests`）。完全な窓は、初めに確保した領域へ写してから解析し、窓ごとにメモリを確保しない。DCを除き、20Hz〜min(20kHz, Nyquist)を対数の帯域に分ける。
- 入力の平均値（DC）を窓掛けの前に除き、窓の二乗和でパワーを補正し、片側スペクトラムのDC/Nyquist以外を2倍する。左右それぞれで求めたパワーを平均して帯域内を加算する。逆相の左右信号を波形平均して相殺しない。
- `bandDBFS`は平均二乗値1を0dBFSとし、−100〜0dBFSに制限する。正弦波のpeak 1は、全帯域の合計で約−3.01dBFSになる。汎用の`levels`はこのdBの範囲を0〜1へ写す。可視化は`bandDBFS`から固有の表示範囲へ写し直せる（`LCMP_default_GEQ`は−80〜0dBFSを使う）。狭すぎて独立したFFT binがない帯域は下限値になる。
- RMSとpeakは、DC除去前の窓内の左右の波形から求める。NaN/Infinityの入力は0として扱う。表示の減衰・残像・ピークホールドは表示側が担当する。
- FFT窓の長さは帯域数と独立している。2048点/48kHzの窓長は約42.7msである。細かい帯域を選んでも、FFTの周波数分解能は増えない。

### 受け渡し・上限・終了

render側は次のように実装する。

- 8スロット×最大16384フレーム×左右Float32を事前に確保する。C11のlock-freeな原子操作とrelease/acquireで所有権を移す。
- `AnalysisRenderSource`は、観測Audio Unitごとに安定したcallback contextを1つ登録し、エンジンの停止まで保持する。解析キューは原子ポインターで差し替える。
- callbackは読み取り数を増やしてからキューを読み、コピー後に減らす。`AnalysisSession.detach()`は制御側でポインターをnilにし、旧キューを読んでいるcallbackが完了するまで待ってから解放を許可する。render側は待機しない。通知の解除だけを、実行中のcallbackの完了保証として使わない。
- セッションを取り消しても観測contextは残り、キューがnilの間はコピーを省く。エンジンを停止してから通知を解除し、contextを破棄する。
- attach／detachとSourceの所有・破棄は、単一の制御側で直列に行い、render callbackから呼ばない。
- 満杯・過大・不正なバッファは、音声を待たせず解析側だけで捨てる。

解析ワーカーは次のように実装する。

- 単一の直列ワーカーが4ms周期で最大8バッファを回収し、最後の完全なFFT窓を解析する。窓のhopはmin(窓長/2, sampleRate/更新頻度)である。
- 連番の欠落、サンプル時刻・host時刻の不連続、時刻の有効・無効の切替、レートの変更があれば途中の窓を破棄し、離れたPCM区間を結合しない。
- 結果は`AsyncStream(bufferingNewest: 1)`で渡し、計算・送信が遅れても過去の結果をまとめて送らない。
- 指定した頻度は、時刻を基準とした目標の平均頻度である。OS・入力の周期・負荷によって減るbest effortで、4msの回収周期などにより隣り合う配信の間隔は揺れる。解析時間を各周期に累積させず、期限を過ぎた分は飛ばして、過去のフレームを連続して送らない。
- PlaybackControllerは、playing中の最新1フレームを`analysisFrame`へ公開する。未選択・停止・一時停止・自然終了ではnilである。

セッションの寿命は次のとおりとする。

- 設定の変更・シーク・曲の変更・一時停止後の再開では、解析セッションを作り直す。世代UUIDとセッション内の連番を使い、取り消した世代の結果を破棄する。
- 終了時に通知を解除し、配信のTask・ストリーム・ワーカーのタイマーを終了する。FFT中の短い処理をMainActorで待たず、最後の所有参照が消えた時点でバッファとFFT setupを解放する。
- 解析は追加のファイルアクセス権を保持しない。

### 時刻情報と同期補償の契約

解析フレームの時刻は、コールバックの到着時刻や壁時計ではなく、音声のレンダー時刻を基準にする。

| フィールド | 意味 |
| --- | --- |
| generation / sequence | 再生世代と、その中の解析結果の順番 |
| windowStartSample / windowFrameCount / sampleRate | 観測ノードの音声サンプルの区間。ファイルの再生位置ではない |
| windowCenterHostTime | その音声区間の中央の時刻。単調増加するhost clockの秒へ変換する |
| producedHostTime | 解析結果が準備できた時刻。同じhost clock |
| estimatedOutputLatency | 観測位置から下流の推定出力遅延。追加の補償分は除く |
| appliedAudioDelay | 音声側が実際に適用した同期補償量。現在の実装では常に0 |
| estimatedPresentationHostTime | 中央のhost時刻＋推定出力遅延＋適用済みの補償量 |
| computationSeconds / droppedBuffers / queuedBufferHighWatermark | 計算時間、取得側の累積の欠落数、キューの最大使用スロット数（上限8） |

- host時刻や遅延を取得できない場合はnilとし、0で代用しない。
- ノードの`outputPresentationLatency`は開始・再開・再設定時に取得し、機器の遅延を別に加えて二重に計上しない。macOSでは、この値は出力機器の遅延（Core Audioの`kAudioDevicePropertyLatency`）と一致し、IOバッファの長さを含まない。iOSでは、この値は`AVAudioSession.outputLatency`と一致し、Bluetoothなど経路の遅延を含む（[iPhone版の実装設計](13_iphone-implementation.md#出力遅延の取り方)）。どちらも、観測ノードのレンダー通知のhost時刻は呼び出しの時点よりIOバッファ約1回分先を指すので、host時刻＋報告値がOSの報告どおりの提示時刻になる。将来、下流の遅延段がノードの報告値に含まれる場合は、その既知の補償量を報告値から分離してから設定する。
- 再生を続けたまま出力の経路が変わったとき（iOSで形式の変わらない経路の変更）は、`AnalysisSession.updateOutputLatency(_:)`で以降のレンダーの遅延を差し替える。転送のキューは遅延を原子的な値として持ち、レンダーのスレッドが読む。解析はレンダーごとに打刻の遅延を読み直す（窓は重ねて進むので空にならず、窓の始まりだけで読むと差し替えが届かない）。
- 打刻には、レンダー通知が走った時点のhost時刻（`callback_seconds`）も入れる。host時刻の意味を実機で確かめるためのもので、表示の計算には使わない。
- `SynchronizationEstimate.additionalAudioDelay`は、追加量＝max(0, 表示までの遅延＋余裕−既存の出力遅延)を計算する純粋な補助関数である。音声の時刻・速度・出力機器の設定は変更しない。表示を推定提示時刻まで待たせる処理は可視化側が担当する（採用の時計と画面の更新の遅れを見込んで、少し前に採用する。[可視化の実装設計](08_visualization-implementation.md)を参照）。実際に音声を遅らせる段は将来の機能である。

将来の補償器は次を満たす構成にする。

- 音声の取得を遅延段の前に保ち、同じPCM時刻から解析と音声を分岐する。
- FFTの計算だけでなく、窓の中央からデータが揃うまでと、取得、配信、描画までの時間を計測する。描画側も同じhost clockで実際の描画時刻を記録する。
- 出力先・形式・補償量の変更時は、時刻の基準と解析の世代を更新する。値をフレームごとに変えて音声を伸縮させない。
- 遅延中のPCMは固定の上限を持ち、停止・シークで破棄する。自然終了では最終サンプルの出力まで排出を待つ。供給の終了（最後のバッファの消費）だけで音声エンジンを停止しない。
- 再生位置の表示・一時停止・再開・次曲送りも、デコーダの位置と実際の提示位置を区別する。

推定提示時刻は、物理的な発音を測定した値ではない。OSが報告する遅延、Bluetooth内部のバッファ、ディスプレイの描画遅延を含む実際の同期は、同じインパルスの出音と画面を別に測定して評価する。

## 5. 検証

### 合格基準

- 合成した正弦波で、振幅比、無音、逆相、左右の分離、Nyquist、レート、欠落・上限、時刻、世代と解放が仕様どおりである。
- 実出力で、対応形式の解析を受信し、一時停止・再開・シーク・停止・自然終了でOS音量が変わらない。
- 解析キューを差し替え続けても、メモリの安全性が保たれる。

### 自動テスト

1. `LCMP_TEST_AUDIO_OUTPUT=0 ./scripts/swift.sh test --disable-automatic-resolution`で、合成信号による解析を検証する。
2. `LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --disable-automatic-resolution --filter AudioOutputTests`で、独自の小音量fixtureを実出力し、解析の受信と再生操作を確認する。

### 解析キューの寿命の競合検証

`scripts/check-analysis-lifetime.c`は製品のC render callbackを使い、別のスレッドで5万回キューを差し替え、旧キューを直ちに解放する。次のコマンドで作成して実行する。Thread Sanitizerは`-fsanitize=thread`で別に実行する。

```sh
clang -std=c11 -g -O1 -fsanitize=address,undefined -I Sources/AnalysisTransport/include \
  scripts/check-analysis-lifetime.c -framework AudioToolbox -o build/check-analysis-lifetime
```

実音声の`AnalysisLifetimeTests`では、エンジンを動かしたまま解析を200回差し替え、音声の継続・再購読・停止時の解放を確認する。

### 配信と負荷の測定

`AnalysisPerformanceTests`は、独自のステレオWAVを一時的に作成して既定のデバイスへ実再生し、アプリ音量を0にする。システム音量は変更しない。

解析なしと15/30/60Hzの短時間の比較：

```sh
LCMP_ANALYSIS_PROFILE=1 LCMP_ANALYSIS_REPORT_DIR=build/analysis-profile \
  ./scripts/swift.sh test --disable-automatic-resolution \
  --filter 'AnalysisPerformanceTests/measuresConfiguredCadence'
```

32帯域・60Hzの10分連続の測定：

```sh
LCMP_ANALYSIS_PROFILE=1 LCMP_ANALYSIS_SOAK=1 \
LCMP_ANALYSIS_REPORT_DIR=build/analysis-soak \
  ./scripts/swift.sh test --disable-automatic-resolution \
  --filter 'AnalysisPerformanceTests/tenMinuteRealOutputRemainsBounded'
```

- 測定は実際に配信されたフレームを受け取り、固定長のヒストグラムを使って測定自身のメモリ増加を防ぐ。
- CPUはテストプロセス全体のuser＋systemのCPU時間/経過時間で、100%を1コアとする。再生・解析・受信・測定の処理を含み、解析だけのCPU値ではない。RSSは30秒ごとの常駐メモリを記録する。
- 基準の条件は、ステレオ48kHzの音源・32帯域・2048点である。観測レートは出力形式に従うため、JSONに実際のレートを残す。
- 測定の終了後は停止し、追加の配信がないことも確認する。

受け入れの基準は次のとおりとする。しきい値には実行環境が影響するため、測定の条件・結果を併記して評価する。

| 項目 | 基準 |
| --- | --- |
| 実配信の平均 | 指定値の90〜102% |
| 計算時間のp95 | 2ms以内 |
| 窓の中央→生成のp95 | 80ms以内 |
| 生成→受信のp95、推定提示時刻からの遅れのp95 | 1更新周期以内 |
| 配信間隔の最大 | 0.5秒未満 |
| drop | 0 |
| キューの最大 | 8以下 |
| プロセスのCPU | 30%未満 |
| 開始60秒以降のRSSの変動幅 | 10MiB未満 |

生成→受信や提示時刻に対する準備の遅れは、描画そのものの遅れではない。物理的な発音と画面の一致は、将来の表示・音声の遅延機能と合わせた測定で評価する。実音声の遅延を導入するときは、透過性、最大遅延、最終サンプルの排出、停止・シーク・出力変更の繰り返しと、物理的な出音と描画の誤差を追加で検証する。

## 6. 参照

- [Apple Accelerate](https://developer.apple.com/documentation/accelerate)
- [AudioUnitAddRenderNotify](https://developer.apple.com/documentation/audiotoolbox/audiounitaddrendernotify(_:_:_:))
- [AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime)
- [outputPresentationLatency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency)
