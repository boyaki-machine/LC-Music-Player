# 周波数解析の実装設計

[設計書一覧](./README.md)に戻る。

## 責務と音声経路

`AnalysisCore`は表示に依存しないスペクトラム・左右レベルと時刻情報を生成します。`PlaybackCore`のSFBAudioBackendが音声取得と解析セッションの寿命を所有します。`AnalysisTransport`はCの固定容量SPSCキューとAudio Unitのレンダー通知を実装します。可視化の周波数解析は再生経路を観測し、音源を再度開きません。任意の全曲sample peak測定は[再生前処理](./preprocessing-implementation.md)の別処理です。

```text
SFBAudioEngine source
    → 形式変換mixer → 観測ノード ──→ PCMコピー → 有界キュー → FFTワーカー → 最新結果 → 表示側
    → 将来の音声加工・同期遅延段
    → mainMixer（アプリ音量）→ OS出力
```

現在の観測ノードは`AVAudioUnitEQ(numberOfBands: 0)`です。フィルターはなく、globalGainは0dBです。公開AudioUnitへのレンダー通知を使用するために置き、音声イコライザーの利用者向け機能は提供しません。観測側の形式はmainMixerの出力レート・チャンネル数に対応する標準Float32 PCMです。前段のmixerが音源から出力形式へ変換し、後段mainMixerと同じ形式を使って不要な追加レート変換を避けます。SFBの初期source形式は変更せず、デコーダと内部ring bufferの形式変更をSFB自身へ委ねます。SFBAudioEngineの`modifyProcessingGraph`内でsourceとmainMixerの間だけを変更し、engineを直接開始・停止しません。

通知はpost-renderかつエラーがない場合だけ処理し、音声データを変更せずコピーします。Float32非interleavedを受け取り、monoは左右へ同じ値、2ch以上は出力形式の先頭2chを解析します。全チャンネルのサラウンド解析ではありません。解析はアプリ音量・ミュートより前なので、音量ゼロでも音源のレベルを返します。

## 設定と解析

`AnalysisConfiguration`は帯域数8〜128、更新頻度15/30/60Hz、FFTサイズ1024/2048/4096/8192点を受け付けます。既定は32帯域・30Hz・2048点です。表示実装は初期化・切替時に`PlaybackController.configureAnalysis`を呼び、nilで購読を解除できます。

- Accelerate/vDSPのFFTと周期的Hann窓を使用する。DCを除き、20Hz〜min(20kHz, Nyquist)を対数帯域に分ける。
- 入力の平均値（DC）を窓掛け前に除き、窓の二乗和でパワーを補正し、片側スペクトラムのDC/Nyquist以外を2倍する。左右それぞれで求めたパワーを平均して帯域内を加算する。逆相の左右信号を波形平均して相殺しない。
- `bandDBFS`は平均二乗値1を0dBFSとし、−100〜0dBFSに制限する。正弦波のpeak1は全帯域合計で約−3.01dBFS。汎用の`levels`はこのdB範囲を0〜1へ写す。可視化は`bandDBFS`から固有の表示範囲へ写し直せる。`LCMP_default_GEQ`は−80〜0dBFSを使う。狭すぎて独立FFT binがない帯域は下限値になる。
- RMSとpeakはDC除去前の窓内の左右波形から求める。NaN/Infinity入力は0として扱う。表示の減衰・残像・ピークホールドは表示側の責務とする。
- FFT窓の長さは帯域数と独立する。2048点/48kHzの窓長は約42.7ms。細かい帯域を選んでもFFTの周波数分解能が増えるわけではない。

## 受渡し・上限・終了

レンダー通知にはメモリ確保、FFT、Swift Task、UI更新、待つロック、I/Oを置きません。8スロット×最大16384フレーム×左右Float32を事前確保します。C11のlock-free原子操作とrelease/acquireで所有権を移します。`AnalysisRenderSource`は観測Audio Unitごとに安定したcallback contextを1つ登録し、エンジン停止まで保持します。解析キューは原子ポインターで差し替えます。callbackは読取数を増やしてからキューを読み、コピー後に減らします。`AnalysisSession.detach()`は制御側でポインターをnilにし、旧キューを読んでいるcallbackが完了するまで待ってから解放を許可します。render側は待機しません。通知解除だけを実行中callbackの完了保証として使いません。セッションを取り消しても観測contextは残り、キューがnilの間はコピーを省略します。エンジンを停止してから通知を解除しcontextを破棄します。attach／detachとSourceの所有・破棄は単一の制御側で直列に行い、render callbackから呼びません。満杯・過大・不正なバッファは音声を待たせず解析側だけで捨てます。

単一の直列ワーカーが4ms周期で最大8バッファを回収し、最後の完全なFFT窓を解析します。窓のhopはmin(窓長/2, sampleRate/更新頻度)です。欠落連番・サンプル時刻/host時刻の不連続・時刻の有効/無効の切替・レート変更で途中の窓を破棄し、離れたPCM区間を結合しません。

結果は`AsyncStream(bufferingNewest: 1)`で渡し、計算・送信が遅れても過去の結果をまとめて送信しません。指定頻度は時刻基準の目標平均頻度で、OS・入力周期・負荷により減るbest effortです。4msの回収周期などで隣接する配信間隔は揺れます。解析時間を各周期に累積させず、遅れて期限を越えた分は飛ばして過去フレームを連続送信しません。PlaybackControllerはplaying中の最新1フレームを`analysisFrame`へ公開します。未選択・停止・一時停止・自然終了ではnilです。

設定変更・シーク・曲変更・一時停止後の再開は解析セッションを作り直します。世代UUIDとセッション内連番を使い、取消済み世代の結果を破棄します。終了時に通知を解除し、配信Task・ストリーム・ワーカータイマーを終了します。FFT中の短い処理をMainActorで待たず、最後の所有参照が消えるとバッファとFFT setupを解放します。解析は追加のファイルアクセス権を保持しません。

## 将来の音声・表示同期の契約

解析フレームの時刻は、コールバックの到着時刻や壁時計ではなく、音声レンダー時刻を基準にします。

| フィールド | 意味 |
| --- | --- |
| generation / sequence | 再生世代とその中の解析結果の順番 |
| windowStartSample / windowFrameCount / sampleRate | 観測ノードの音声サンプル区間。ファイルの再生位置ではない |
| windowCenterHostTime | その音声区間の中央時刻。単調増加host clockの秒へ変換 |
| producedHostTime | 解析結果が準備できた時刻。同じhost clock |
| estimatedOutputLatency | 観測位置から下流の推定出力遅延。追加補償分は除く |
| appliedAudioDelay | 音声側が実際に適用した同期補償量。現実装は常に0 |
| estimatedPresentationHostTime | 中央host時刻＋推定出力遅延＋適用済み補償量 |
| computationSeconds / droppedBuffers / queuedBufferHighWatermark | 計算時間、取得側の累積欠落数、キューの最大使用スロット数（上限8） |

host時刻や遅延を取得できない場合はnilとし、0で代用しません。ノードの`outputPresentationLatency`は開始・再開・再設定時に取得し、機器の遅延を別途加えて二重計上しません。将来、下流の遅延段がノード報告値に含まれる場合は、その既知の補償量を報告値から分離してから設定します。

`SynchronizationEstimate.additionalAudioDelay`は、追加量=max(0, 表示までの遅延＋余裕−既存出力遅延)を計算する純粋な補助関数です。音声の時刻・速度・出力機器設定を変更しません。表示を推定提示時刻まで待たせる処理は[可視化側](./visualization-implementation.md)が担当します。実際に音声を遅らせる段は将来の機能です。

将来の補償器では、次を満たす構成にします。

- 音声取得を遅延段の前へ保ち、同じPCM時刻から解析と音声を分岐する。
- FFTの計算だけでなく、窓の中央からデータが揃うまで、取得、配信、描画までの時間を計測する。描画側も同じhost clockで実際の描画時刻を記録する。
- 出力先・形式・補償量の変更時は時刻基準と解析世代を更新する。値をフレームごとに変えて音声を伸縮させない。
- 遅延中のPCMは固定上限を持ち、停止・シークで破棄し、自然終了は最終サンプルの出力まで排出を待つ。SFBAudioEngineのsource終了通知だけで音声エンジンを停止しない。
- 再生位置表示・pause/resume・次曲送りも、デコーダ位置と実際の提示位置を区別する。

推定提示時刻は物理的な発音を測定した値ではありません。OS報告遅延、Bluetooth内部のバッファ、ディスプレイの描画遅延を含む実際の同期は、同じインパルスの出音・画面を別途測定して評価します。

## 再利用できる検証方法

1. `LCMP_TEST_AUDIO_OUTPUT=0 ./scripts/swift.sh test --disable-automatic-resolution`で合成正弦波、振幅比、無音、逆相、左右分離、Nyquist、レート、欠落/上限、時刻、世代と解放を検証する。
2. `LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --disable-automatic-resolution --filter AudioOutputTests`で独自の小音量fixtureを実出力し、対応形式での解析受信、pause/resume/seek/stop/自然終了とOS音量不変を確認する。
3. 負荷測定は設定・サンプルレート・機器を明示して計算時間p95、配信間隔、windowCenterHostTimeからproducedHostTimeまでの時間、drop数と常駐メモリを記録する。
4. 実音声遅延を導入するときは、透過性、最大遅延、最終サンプル排出、繰り返しの停止・シーク・出力変更と、物理出音対描画の誤差を追加検証する。

参照：[Apple Accelerate](https://developer.apple.com/documentation/accelerate)、[AudioUnitAddRenderNotify](https://developer.apple.com/documentation/audiotoolbox/audiounitaddrendernotify(_:_:_:))、[AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime)、[outputPresentationLatency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency)。

### 配信・負荷の継続測定

`AnalysisPerformanceTests`は独自のステレオWAVを一時作成して既定のデバイスへ実再生し、アプリ音量を0にします。システム音量は変更しません。解析なしと15/30/60Hzの短時間比較は次で実行します。

```sh
LCMP_ANALYSIS_PROFILE=1 LCMP_ANALYSIS_REPORT_DIR=build/analysis-profile \
  ./scripts/swift.sh test --disable-automatic-resolution \
  --filter 'AnalysisPerformanceTests/measuresConfiguredCadence'
```

10分連続の32帯域・60Hz測定は次で実行します。

```sh
LCMP_ANALYSIS_PROFILE=1 LCMP_ANALYSIS_SOAK=1 \
LCMP_ANALYSIS_REPORT_DIR=build/analysis-soak \
  ./scripts/swift.sh test --disable-automatic-resolution \
  --filter 'AnalysisPerformanceTests/tenMinuteRealOutputRemainsBounded'
```

測定は実際に配信されたフレームを受け取り、固定長ヒストグラムを使って測定自身のメモリ増加を防ぎます。CPUはテストプロセス全体のuser＋system CPU時間/経過時間で、100%を1コアとします。再生・解析・受信・測定の処理を含み、解析専用のCPU値ではありません。RSSは30秒ごとの常駐メモリを記録します。

基準条件はステレオ48kHz音源・32帯域・2048点です。観測レートは出力形式に従うため、JSONに実レートを残します。受入チェックは実配信平均が指定値の90〜102%、計算p95が2ms以内、窓中央→生成p95が80ms以内、生成→受信p95と推定提示時刻からの遅れp95が1更新周期以内、最大配信間隔0.5秒未満、drop0、キュー最大8以下、プロセスCPU30%未満、開始60秒以降のRSS変動幅10MiB未満です。しきい値には実行環境が影響するため、測定条件・結果を併記して評価します。生成→受信や提示時刻に対する準備の遅れは描画そのものの遅れではありません。

測定終了後は停止して追加の配信がないことも確認します。物理的な発音と画面の一致は、将来の表示・音声遅延機能を合わせた測定で評価します。

### 解析キュー寿命の競合検証

`scripts/check-analysis-lifetime.c`は製品のC render callbackを使い、別スレッドで5万回キューを差し替え、旧キューを直ちに解放する。`clang -std=c11 -g -O1 -fsanitize=address,undefined -I Sources/AnalysisTransport/include scripts/check-analysis-lifetime.c -framework AudioToolbox -o build/check-analysis-lifetime`で作成して実行する。Thread Sanitizerは`-fsanitize=thread`で別実行する。実音声の`AnalysisLifetimeTests`ではエンジンを動かしたまま解析を200回差し替え、音声継続・再購読・停止解放を確認する。
