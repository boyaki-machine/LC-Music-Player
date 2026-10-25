# 再生前処理の実装設計

[設計書一覧](../README.md)に戻る。

## 1. 概要

前処理は、音源参照と[単曲再生](02_playback-implementation.md)の間で、再生に使う先頭PCMと全曲の測定値を背景で準備する。

- **先頭PCM**：次に再生する曲の先頭を読み込んでおき、再生へ引き継ぐ。
- **全曲測定**：全プレイリストの曲を1曲ずつ走査し、Integrated LUFS・true peak・sample peakを求めて保存する。同じ走査で、拍とリードボーカルの動きを求める（[曲の地図の実装設計](15_track-map-implementation.md)）。
- **最大音量の表示**：現在曲のsample peakを表示用に公開する。

前処理は再生音のゲインや周波数特性を変更しない。LUFS・true peakの測定方式と、音量自動調整ONのときの再生待ちは[音量自動調整の実装設計](06_volume-normalization-implementation.md)、測定値の保存は[永続キャッシュ](05_measurement-cache-implementation.md)に記載する。[周波数解析](07_analysis-implementation.md)は再生経路のPCMを観測する別の機能である。

## 2. 要件

- 全ファイルをメモリへ読み込まない。先頭PCMの量と同時に保持するファイルアクセスに上限を設ける。
- 再生要求を、長い背景処理の後ろで待たせない。
- 停止・曲の変更・設定の変更で、古い結果を公開しない。
- 背景処理の失敗だけで現在の再生を止めない。
- 測定の進捗バー・スピナー・割合・残り時間は表示しない。準備中は拡張画面に短い状態文だけを示す。

## 3. 方式

```text
LibraryCore（参照解決・再生順序・設定・取消）
    ├─ PreprocessingCore（utilityキュー、デコーダ、先頭PCM、全曲測定）
    └─ PlaybackCore（準備結果の受領、AVAudioEngine、音声出力）
           └─ AnalysisCore → Player UI内の可視化
```

- `PreprocessingCore`はFoundation、AVFAudio、CryptoKit、OSのSQLiteに依存し、LibraryCore、PlaybackCore、UIには依存しない。
- `PCMDecoding`と`AudioDecoderFactory`はここで定義し、PlaybackCoreからも参照する。拡張子ごとに受け付ける符号化方式は[基本再生の実装設計](02_playback-implementation.md)に記載する。デコーダは、末尾では長さ0の正常な読み取りを返す。
- `AudioPreprocessing`は先頭準備・測定・Auditの非同期の境界である。取消を確認して戻るまで、呼出側がファイルアクセスを保持する。
- アプリは永続キャッシュを設定したAudioPreprocessorを、`LibraryController(preprocessingEnabled: true, playlistPreprocessingEnabled: true, preprocessor: ...)`へ注入する。
- `playlistPreprocessingEnabled`の既定はfalseである。独立した呼出元や単曲・次曲の検証に、出力形式に依存する全リストの巡回を暗黙に追加しないためである。`preprocessingEnabled: false`は同期操作の経路で、注入した再生バックエンドの単体検証等に使う。アプリのリスト選択・再生開始は背景準備を経由する。

### キュー

- 単一の直列のDispatchQueueが、デコーダのopenと読み取りを担当する。キュー自体にはQoSを持たせない。キューのQoSは処理の下限になり、background の要求も utility で動いてしまうためである。
- 処理の優先度は、要求したタスクの優先度に従う。user-initiated以上のタスク（曲の選択など利用者が待つ要求）からの要求はuser-initiated、backgroundのタスクからの要求はbackground、それ以外はutilityで実行する。次曲の準備・最大音量の表示の測定、プレイリストの事前測定のうち現在の曲と前後の曲はutility、それ以外の曲の事前測定はbackgroundのタスクから要求する。同じ音源の測定へ優先度の高い要求が合流すると、その測定の残りのチャンクを高い優先度で進める（`PreprocessingPriorityTests`）。
- Apple siliconでは、backgroundの処理は高効率コアだけで動く。10分の曲の測定は、utilityの約1.0秒・約5.1J（CPUのエネルギー）に対し、backgroundでは約6.3秒・約0.8Jになる。
- 事前測定の途中の曲を利用者が選んで前面へ引き継いだときは、`AudioPreprocessing.promote(_:)`でその取消の印を持つ進行中の測定をuser-initiatedへ引き上げる。まだキューに届いていない要求は、待つ側が引き上げたタスクの優先度で実行される。タスクの`value`を待つと、待たれたタスクは待つ側の優先度へ引き上げられる。backgroundのまま進めたい処理を、優先度の高いタスクから待たない。
- 低電力モードのとき、または熱の状態が`serious`以上のときは、事前測定は現在の曲と前後の曲だけにし、状態が戻ったら（`NSProcessInfoPowerStateDidChange`・`thermalStateDidChangeNotification`）残りを続ける。充電中だけ進める方式（iOSの`BGProcessingTask`）は採らない。事前測定はアプリの実行中に行い、バックグラウンドでの起動とファイルへのアクセスの扱いが増えるためである。
- 全曲測定は1チャンクごとに再投入し、後から到着した先頭準備を長い測定全体の後ろへ待たせない。
- I/Oや測定を音声のrender callbackへ追加しない。
- `PreparationCancellation`はチャンク間で確認する。タスクの取消に加えて世代IDを照合し、古い曲・設定・順序の結果を公開しない。
- 基盤デコーダのopen自体は途中で強制終了できない。取消時はその呼び出しが戻った後に資源を閉じる。

## 4. 実装

### 先頭PCMと再生への引き渡し

- 先頭PCMを保持する対象は、現在の再生リストの現在エントリの直後1件だけである。全曲測定の巡回と、先行処理の枠を共有する。別リストの閲覧では対象を変更しない。
- `AudioPreprocessor.prepare`はデコーダを背景で開き、最大2秒または32MiB（`PreparedAudio.prefixSeconds`・`prefixByteLimit`、呼び出しは`preparePrefix`）の先に達した量まで、元のprocessingFormatでPCMを読む。上限は先頭PCMの確保量であり、デコーダ内部と最大8192フレームの作業バッファは別に必要になる。
- `PreparedAudio`は、ファイル識別情報、時間、シーク可否、確保量と、一度だけ取得できるデコーダを持つ。ロックは所有権の移譲に使い、同じデコーダを複数スレッドで操作する許可にはしない。
- `PrefixDecoder`は外向きのpositionを0から開始する。キャッシュ済みPCMを返した後、その直後から同じデコーダの読み取りを続ける。再openと再走査を挟まない。
- `PCMDecoding`では、要求より短い読み取りがEOFを意味する。そのためキャッシュの境界では、同じ呼び出しのバッファをファイル本体のPCMで満たし、境界を途中の短い読み取りとして返さない。波形・順番・フレーム数は変更しない。

選択から再生までは次のように扱う。

- 未再生の曲の選択（起動時の復元を含む）では、背景で読み込みを確認した後に、再生側にはURL・時間・シーク可否だけを渡す（`selectMetadata`）。準備した先頭PCM・開いたデコーダ・ファイルアクセスは、ライブラリが次の再生用に1曲分だけ保持し（`NextPreparation`）、再生ボタンでは参照の解決と先頭の読み込みを省いて始める。停止・別の曲の選択・設定の変更・終了で解放する。
- `selectPrepared`は、再生へ移譲するまで渡されたleaseを保持し、停止でも解放する。
- `selectPrepared`／`selectMetadata`は、ライブラリの保存が成功してから現在の再生を差し替える。準備や保存に失敗した場合は、現在の選択と再生を維持する。準備中は停止ボタンで取り消せる。
- 音量自動調整ONで、再生を要求したエントリと音源参照が次曲の準備と同じ場合は、MainActor上の`NextPreparation`、実行中のTask、取消token、先頭PCMと同じleaseを選択要求へ移す。先頭準備や全曲測定が未完了でも取り消して測り直さない。測定結果のsource/profileと出力profileを再確認し、有効な完了値から補正を確定する。
- 要求が別のエントリ・参照の場合は、取消後の終了を待つ。
- 自動調整OFFと未再生の選択は全曲測定を待たず、準備済みの先頭PCMだけを引き継ぐ。先頭準備も未完了なら、取消・終了後に背景で新たに準備する。
- sourceが変わっていた場合は、古い先頭PCMとleaseを、新しい参照を開く前に解放する。
- 自然終了から次曲へ進むときは、準備済みのデコーダを先に引き継ぐ。明示的な曲選択が準備中なら、自然送りで上書きしない。

### 最大音量（sample peak）

設定「最大音量を測定」は既定OFFで、UserDefaultsの`measureMaximumVolume`へ保存する。ONのときに現在曲の測定値を公開する。この設定は音量調整の有効化ではない。アプリのリスト巡回はこの設定とは独立して行う。

- 測定値は全チャンネル・全フレームの絶対値の最大、すなわちsample peakである。線形値と`20 log10(peak)`のdBFSを提供する。無音は線形0、dBFSは負の無限大とする。LUFS、true peak、聴感上の音量一致の指標にはしない。
- 読み取りはデコーダのnative形式のまま行う。Float32/Float64/Int16/Int32と、共通形式を持たない符号付き整数（packed 24bit、32bit語の上位に詰めた16bit等）を、`LevelDSP`のバッファ単位の関数で走査する。packed signed PCMのバイト順と上位配置も扱う。
- 整数はビット深度のフルスケールで正規化する。値は1サンプルずつ読み取った場合と完全に一致する。その他の形式で必要な浮動小数への変換は、測定用のコピーだけに適用する。
- `AudioPreprocessor.measure`は再生とは独立したデコーダを使い、8192フレームずつ読む。
- 非有限のサンプル、読み取りエラー、取消、既知のフレーム長に達しないEOFは完了値にしない。
- `TrackPeak`は、音源のfingerprint、線形のsample peak、dBFS、読んだフレーム数、サンプルレート、チャンネル数、解析版1を持つ。結果は現在曲・次曲のメモリに加えて専用SQLiteキャッシュへ保存し、ライブラリのJSONへは追加しない。
- `LibraryController.peakMeasurement`は、disabled／pending／complete／failedをUIへ提供する。
- 音声処理側は`currentTrackPeak`を使う。このプロパティは、設定がONで、現在再生のURLと一致し、ファイル識別情報・サイズ・更新日時が一致する完了値だけを返す。未完了・変更済みの値ではnilとなる。MainActor上で設定用の値を取得するAPIであり、ファイル属性を確認するためrender callbackから呼ばない。
- ゲインの適用は音声処理の担当であり、前処理から音量を操作しない。

### LUFS・true peakの全曲測定

- 全曲のIntegrated LUFS・sample peak・true peakを、同じ背景走査から求める（`measureLevels`）。ファイル参照、デコーダ、一時的なblockエネルギー列と取消はPreprocessingCoreが所有し、数値DSPと補正量の算出はAudioProcessingCoreが担当する。
- `TrackAudioMetrics`は、fingerprintに加えて、出力レート・チャンネル変換と測定版を含むprofileを持つ。出力レートは出力機器のレートで、44.1/48/88.2/96/176.4/192kHzを受け付ける（[音量自動調整](06_volume-normalization-implementation.md)）。レートが高いほど全曲測定の計算量が増える（192kHzで48kHzの約3倍）。`TrackPeak`はsample peak専用であり、LUFS/true peakの代用にはしない。補正用には`measureLevels`／`currentTrackMetrics`を使う。
- 測定と自動調整ONの再生は`ProfileConversion`を共有し、再生側は`ProfileDecoder`で変換する。
- 自動調整ONでは測定の完了を再生開始の条件とし、OFFでは測定を待たずに再生する。
- 同じsource/profileの要求は合流する。条件が一致した永続結果があれば全曲の走査を省く。
- 将来EQを併用するときは、補正用の測定でも形式変換と同じ設定のEQを適用し、レベル自動調整段へ入る音声を測る。手動音量・ミュートと純粋な同期用ディレイは測定後の処理であり、その変更では全曲測定を取り直さない。

mono/stereo変換、短い曲、gatingの対象がない曲、true-peak補間の末尾、資源の上限は[音量自動調整の実装設計](06_volume-normalization-implementation.md)に記載する。

### プレイリストの事前測定

`LibraryCore.PlaylistPreprocessing`は、保存に成功した全プレイリストに含まれる音源を1件ずつ処理する。

- 正常な起動・復元、曲の追加・M3U8のインポート・リストの編集・参照の修復と、再生状態の変更で候補を再評価する。
- ライブラリに登録されているだけで、どのリストにも属さない音源は巡回しない。
- インポート中は巡回を始めず、登録用アクセスの寿命が終わってから開始する。
- 優先順位は、明示的な再生要求、再生中の現在曲、直後、直前、現在リストの残り、他リストの保存順とする。直後・直前は再生順序に従い、ランダム再生では一巡の記録の直前と、控えた次の曲を使う。リストの端は折り返さず、同じtrackIDの重複行を除く。別IDの同じsource/profileは、既存のキャッシュ照合と所有対応を使う。
- 閲覧中のリストは再生リストを変更しない。
- `measureLevels`で有効なキャッシュを検索し、未測定ならLUFS・true peak・sample peakと曲の地図を1回の走査で求める。続けて`trackMap`を要求し、地図より前に測定済みだった曲や解析器の版が変わった曲だけ、地図を一度走査する。
- 音量自動調整のON/OFFと測定値の表示のON/OFFは巡回の開始条件ではない。補正OFFの音声経路と設定値はそのまま維持する。最大音量の表示を有効にした場合は、現在曲のnative sample peak専用の経路を維持する。

先行処理の枠とleaseは次のように扱う。

- 次曲の先頭準備と巡回は、同じ先行処理の枠を使う。次曲の測定が終わって他の曲へ進むときは、先頭PCM・デコーダ・leaseを解放し、完了した測定値はSQLiteに残す。
- 巡回中に次曲を再生するときは、先頭だけを再準備する。一巡した後も再生が続いていれば、直後の曲の先頭準備を戻す。
- 全曲分のPCMやTaskを保持しない。現在曲の測定は再生leaseを共有し、先行leaseは1つまで、合計で最大2を維持する。
- 再生要求と同じtrackID・参照・profileの巡回中の処理は、Task・取消token・測定状態・leaseを再生側へ移す。先頭がない要求では、同じleaseで先頭を追加準備する。
- 異なる要求は背景処理を取り消し、その終了を待ってから枠を使う。自動調整OFFの再生を全曲測定の完了まで待たせない。

失敗と再評価は次のように扱う。

- 完了・失敗した候補は巡回内で記録し、破損・参照切れ・保存不可を高速に再試行しない。失敗しても後続を続け、現在の再生は止めない。
- 参照の修復・新しい編集、出力profileや音源属性の変更、次の正常な起動で再評価する。
- 出力のidentity・レート・チャンネル構成はCore Audioの通知で観測し、UIのないアイドル巡回中でも旧profileの処理を無効化する。未対応のprofileでは巡回を見送り、通常の再生を制限しない。

### 取消とファイルアクセス

| 操作 | 扱い |
| --- | --- |
| 曲順・次曲の対象・参照の変更 | 次曲の準備を破棄して作り直す |
| 現在曲の変更 | 測定結果も破棄する |
| 一時停止 | 次曲の準備と測定・巡回・出力監視を取り消し、再開で必要な処理を作り直す。音声は一時停止位置を保持する。一時停止中は再生leaseだけを保持する |
| 停止・末尾での終了・失敗・出力変更・終了 | 背景処理、巡回と出力監視、先頭PCM・メモリ上の保持を破棄する。完了済みの永続記録は残す |

- 自動調整の完了結果は一時停止中も保持し、同じ音源・出力profileでの再開・シークでは再測定しない。
- Stopの直後は巡回を自動で再開せず、再生または新しい編集・追加で再開する。停止後、基盤I/Oが終わった時点でleaseは0になる。
- 通常は、現在再生のlease 1つと次曲準備のlease 1つを保持する。測定は該当する同じleaseを共有する。取消中の基盤I/Oと非同期の後処理が完了してから、最後の参照を解放する。
- 先行準備の失敗だけで現在の再生を停止したり、未選択の曲を削除したりしない。再生対象として選んだときに参照・読み込みのエラーを表示する。

### 再生経路との境界

- 曲を繰り返し変更しても解析のキューを安全に解放できるよう、観測callbackはエンジン単位の`AnalysisRenderSource`を通す。キューの取消時は、実行中の読み取りが終わってからメモリを解放する（[解析の実装設計](07_analysis-implementation.md)）。
- バックエンドのisolated deinitで停止・解除を行うため、ビルドにはSwift 6.2以降を使用する。
- 再生時の解析と可視化の時計・PCMの取得位置・OS音量は、前処理から変更しない。エンジンの作成・グラフの接続は、MainActor上のAudioEngineBackendが担当する。
- 先頭準備は、初回の曲のI/O時間や、デバイスの開始時間をなくすことを保証しない。
- `PCMFeeder`の4つの再利用バッファと、PrefixDecoder／ProfileDecoderの有界バッファによる逐次供給を維持し、全曲PCMの保持や別のFIFOを追加しない。

## 5. 検証

### 合格基準

- 8形式で元のPCMと一致し、先頭の境界、シーク、末尾の最大値、無音、整数の精度、非有限値を正しく扱う。
- 取消、設定、参照の変更、保存の失敗、自然送り・停止の後に、古い結果を公開せず、資源を解放する。
- 同じ要求が一度だけ実行され、leaseが最大2を超えない。
- 最小240ptの拡張画面で、設定の説明が読める。

### 自動テスト

1. `LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --disable-automatic-resolution --no-parallel`で、上の合格基準を確認する。
2. `NextPreparationTests`は非同期workerの返却を制御し、測定未完了・先頭未完了の同じ要求が一度だけ実行されること、手動・自然送り、停止、保存失敗、別エントリ、削除、設定変更とlease最大2を確認する。
3. `PlaylistPreprocessingTests`は、固定profileと待機できるworkerで、順位・全リストの巡回・重複・失敗後の続行・測定中の移譲・割込み時の退役・音源とprofileの失効・永続結果の再利用・追加と停止を検証する。
4. `LCMP_UI_SNAPSHOTS=<出力先>`で、設定のON/OFFを最小240ptの拡張画面へ描き、説明が読めることを確認する。

### 性能測定

利用者向けの開始時間・CPUの評価はReleaseで行う。`scripts/build-app.py`の既定はReleaseで、Debugは`--configuration debug`で明示する。確認用のビルドは`python3 scripts/build-app.py --output build/preprocessing-verified/LCMP.app`等で別の出力先に作り、起動中のbundleを置き換えない。性能測定の実行中は、別のSwift build/testを動かさない。

実出力と巡回の負荷は、専用の一時キャッシュと独自の音源を使い、利用者の保存領域を検証の対象にしない。

1. `scripts/generate-fixtures.py`で、独自の長い音源をGit管理外のディレクトリへ生成する。
2. `LCMP_PREPROCESS_PROFILE=1 LCMP_PREPROCESS_FIXTURES=<絶対パス>`で`PreprocessingTests/startupPreparationProfile`を実行し、2回openする方式と、背景準備・取得後の最初のPCMまでを分けて記録する。初回はOSキャッシュの完全なcold状態を保証しない。
3. 同じディレクトリを指定し、`LCMP_PREPROCESS_OUTPUT_PROFILE=1`で`PreprocessingPerformanceTests/engineAndFirstAnalysisTiming`を実行する。順番を交互にし、選択・play呼出・最初の解析受信を分ける。最後の値は物理的な出音の時刻ではない。
4. `LCMP_PREPROCESS_SOAK=1`と同じディレクトリを指定し、`PreprocessingPerformanceTests/tenMinutePlaybackPreparationAndMeasurementRemainBounded`を実行する。既定600秒、アプリ音量0の実出力で、測定ON・FFT・曲の繰り返し変更を動かし、CPU、RSS、バッファ量、lease数、停止後の解放とPCMの欠落を確認する。通常の全回帰では性能測定をskipする。
5. `LCMP_NEXT_PROMOTION_PROFILE=1 LCMP_PREPROCESS_FIXTURES=<生成したstartup音源のディレクトリ>`で、大容量FLACの走査中の引き継ぎを実測する。予定された初回renderのhost時刻と解析のPCM dropを、物理的な出音や音声ringの供給不足と混同しない。
6. 次のコマンドで、600秒のリスト巡回と再生の割込みを実行する。

   ```sh
   LCMP_PLAYLIST_SOAK=1 LCMP_PREPROCESS_FIXTURES=<独自音源の専用領域> \
     ./scripts/swift.sh test --configuration release --disable-automatic-resolution --no-parallel \
     --filter tenMinutePlaylistSweepWithPlaybackInterruptions
   ```

   領域には独自に生成した`tone.wav`・`tone.flac`（60秒）と`large.flac`（600秒）を置く。テストはAPFSのclonefileで独立した音源識別子を持つ複製を追加し、走査開始から400ms後に再生を切り替える。専用の一時SQLiteを使い、`playlist-soak.json`へCPU・RSS・解析drop・最大lease・停止後の解放と、背景取消の退役時間・要求からplayingまでの時間を分けて記録する。先頭準備だけの費用や物理的な出音の時刻とは区別する。
