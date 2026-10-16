# 再生前処理の実装設計

[設計書一覧](../README.md)に戻る。

前処理は、音源参照と[単曲再生](02_playback-implementation.md)の間で、再生に使う先頭PCMと全曲の最大サンプル音量を準備する。再生音のゲインや周波数特性は変更しない。[リアルタイム周波数解析](07_analysis-implementation.md)は再生経路のPCMを観測する別機能である。

本書のAPIと動作は現行実装を記述する。Integrated LUFS・true peakの全曲測定と、自動調整ON時の再生待ちは[音量自動調整と前処理拡張](06_audio-processing-design.md)を参照する。sample peak専用APIも互換機能として維持する。

## 構成と境界

```text
LibraryCore（参照解決・再生順序・設定・取消）
    ├─ PreprocessingCore（utilityキュー、デコーダ、先頭PCM、全曲sample peak）
    └─ PlaybackCore（準備結果の受領、SFBAudioEngine、音声出力）
           └─ AnalysisCore → Player UI内の可視化
```

`PreprocessingCore`はFoundation、AVFAudio、固定版SFBAudioEngineに依存し、LibraryCore、PlaybackCore、UIには依存しない。`AudioDecoderFactory`はここで共有し、PlaybackCoreからも参照できる。特定の短いM4Aでopen時にeofErrが生じる場合のAVAudioFile互換デコーダを維持し、既知の末尾位置では長さ0の正常な読み取りを返す。

`AudioPreprocessing`は先頭準備・測定・Auditの非同期境界で、取消を確認して戻るまで呼出側がファイルアクセスを保持する。アプリは永続キャッシュを設定したAudioPreprocessorを`LibraryController(preprocessingEnabled: true, playlistPreprocessingEnabled: true, preprocessor: ...)`へ注入する。`playlistPreprocessingEnabled`の既定はfalseで、独立した呼出元や既存の単曲/次曲検証に出力形式依存の全リスト巡回を暗黙に追加しない。`false`は同期操作の互換経路であり、注入した再生バックエンドの単体検証等に使う。単曲再生の同期APIは残すが、アプリのリスト選択・再生開始は背景準備を経由する。

## 先頭バッファと再生への移譲

- 先頭PCMを保持する対象は、現在再生リストの現在エントリの直後1件だけ。全曲測定の巡回とは先行枠を共有する。別リストの閲覧では対象を変更しない。
- `AudioPreprocessor.prepare`はデコーダを背景で開き、最大2秒または32MiBの先に達した量まで、元のprocessingFormatでPCMを読む。全ファイルをメモリへ読み込まない。上限は先頭PCMの確保量であり、デコーダ内部・最大8192フレームの作業バッファは別に必要になる。
- `PreparedAudio`はファイル識別情報、時間、シーク可否、確保量と、一度だけ取得できるデコーダを持つ。ロックは所有権の移譲に使い、同じデコーダを複数スレッドで操作する許可にはしない。
- `PrefixDecoder`は外向きのpositionを0から開始する。キャッシュ済みPCMを返し、その直後から同じデコーダの読み取りを続ける。再openと再走査を挟まない。
- SFBAudioEngineは要求より短い読み取りをEOFと解釈する。キャッシュ境界では同じ呼び出しのバッファをファイル本体のPCMで満たし、境界を途中の短い読み取りとして返さない。波形・順番・フレーム数は変更しない。
- 自動調整ONで、再生要求のエントリと音源参照が次曲準備と同じなら、MainActor上の`NextPreparation`、実行中Task、取消token、先頭PCMと同じleaseを選択要求へ移す。先頭準備または全曲測定が未完了でも、その要求を取り消して測り直さない。測定結果のsource/profileと出力profileを再確認し、有効な完了値から補正を確定する。
- 異なるエントリ・参照では取消後の終了を待つ。自動調整OFFと未再生の選択は全曲測定を待たず、準備済み先頭PCMだけを引き継ぐ。先頭準備も未完了なら取消・終了後に背景で新たに準備する。変更済みsourceの古い先頭PCMとleaseは、新しい参照を開く前に解放する。
- 未再生の曲選択では、背景で読み込み確認した後にURL・時間・シーク可否だけを保持する。アイドル中はデコーダとファイルアクセスを残さず、再生時に取り直す。
- `selectPrepared`は再生へ移譲するまで渡されたleaseを保持し、停止でも解放する。通常の未再生選択は`selectMetadata`を使い、アイドル中に先頭バッファを残さない。
- `selectPrepared`／`selectMetadata`は、ライブラリの保存が成功してから現在の再生を差し替える。準備や保存に失敗した場合は、現在の選択と再生を維持する。準備中は拡張画面に短い状態文だけを示し、停止ボタンで取り消せる。測定進捗バー・スピナー・割合・残り時間は表示しない。

## 全曲最大音量

設定「最大音量を測定」は既定OFFで、UserDefaultsの`measureMaximumVolume`へ保存する。ONのときに現在曲の測定値を公開する。この設定は音量調整の有効化ではない。アプリのリスト巡回はこの設定と独立し、OFFでもLUFS・true peak・sample peakを事前測定して保存する。

測定値は全チャンネル・全フレームの絶対値最大、すなわちsample peakである。線形値と`20 log10(peak)`のdBFSを提供する。無音は線形0、dBFSは負の無限大。LUFS、true peak、聴感上の音量一致の指標にはしない。

`AudioPreprocessor.measure`は再生と独立したデコーダを使い、8192フレームずつ読む。通常の浮動小数・整数PCMを直接測定し、整数値はビット深度で正規化する。packed signed PCMのバイト順と上位配置も扱う。その他の形式で必要な浮動小数変換は測定用コピーだけに適用する。非有限サンプル、読取エラー、取消、既知フレーム長に達しないEOFは完了値にしない。

`TrackPeak`は音源のfingerprint、線形sample peak、dBFS、読んだフレーム数、サンプルレート、チャンネル数、解析版1を持つ。結果は現在曲／次曲のメモリに加えて、専用SQLiteキャッシュへ保存する。ライブラリJSONへは追加しない。識別・復元・Audit・容量は[永続キャッシュ](05_measurement-cache-implementation.md)を参照する。

`LibraryController.peakMeasurement`はdisabled／pending／complete／failedをUIへ提供する。音声処理側は`currentTrackPeak`を使用する。このプロパティは設定がONで現在再生のURLと一致し、ファイル識別情報・サイズ・更新日時が一致する完了値だけを返す。未完了・変更済みの値ではnilとなる。音声処理でのゲイン適用は別責務とし、前処理から音量を操作しない。`currentTrackPeak`はMainActor上で設定用の値を取得するAPIであり、ファイル属性を確認するためrender callbackから呼ばない。

## 音量自動調整の全曲測定

追加測定は、全曲のIntegrated LUFS・sample peak・true peakを同じ背景走査から生成する。ファイル参照、デコーダ、一時的なblockエネルギー列と取消はPreprocessingCoreが所有し、数値DSPと補正量の算出はAudioProcessingCoreが担当する設計とする。前処理から再生音量を操作しない境界は維持する。

`TrackAudioMetrics`には既存のfingerprintに加えて、出力レート・チャンネル変換と測定版を含むprofileを付ける。`TrackPeak`はsample peak専用として保持し、LUFS/true peakの代用にはしない。補正用には新しい`measureLevels`／`currentTrackMetrics`を使う。これらは全曲測定用の公開APIである。測定と自動調整ONの再生は`ProfileConversion`を共有し、再生側は`ProfileDecoder`で変換する。

将来のEQ併用時は、補正用測定でも形式変換と同じ設定のEQを適用し、レベル自動調整段へ入る音声を測る。EQの有効状態・設定・実装版をprofileへ含め、変更時は再測定する。手動音量・ミュートと純粋な同期用ディレイは測定後の処理であり、その変更では全曲測定を取り直さない。これらの加工段は[後処理の構成と順序](06_audio-processing-design.md)に従う。

自動調整ONでは測定完了を再生開始条件とし、OFFでは従来の測定待ちなし経路を維持する。先頭準備は直後1曲に限定し、全曲測定はプレイリスト所属曲を順次巡回する。同じsource/profileの要求は合流し、条件が一致した永続結果があれば全曲scanを省く。mono/stereo変換、短い曲、gating対象なし、true-peak補間の末尾、資源上限と再生要求の優先順位は[拡張設計](06_audio-processing-design.md)に従う。

## プレイリストの事前測定

`LibraryCore.PlaylistPreprocessing`は、保存に成功した全プレイリストに含まれる音源を一件ずつ処理する。正常起動/復元、曲追加・M3U8インポート・リスト編集・参照修復と再生状態の変更で候補を再評価する。ライブラリ登録だけでどのリストにも属さない音源は巡回しない。インポート中は巡回を始めず、登録用アクセスの寿命が終わってから開始する。

優先順位は、明示的な再生要求、再生中の現在曲、直後、直前、現在リストの残り、他リストの保存順とする。リスト端は折り返さず、同じtrackIDの重複行を除く。別IDの同じsource/profileは既存cache照合と所有対応を使う。閲覧中のリストでは再生リストを変更しない。既存の`measureLevels`から有効cacheを検索し、未測定ならLUFS・true peak・sample peakを一走査で求める。補正ON/OFFと測定値の表示ON/OFFは巡回の開始条件ではなく、補正OFFの音声経路と設定値はそのまま維持する。

次曲の先頭準備と巡回は同じ先行枠を使う。次曲測定が終わって他曲へ進むときは先頭PCM・decoder・leaseを解放し、完了測定値はSQLiteに残す。巡回中の次曲再生では先頭だけを再準備する。一巡後、再生が続いていれば直後曲の先頭準備を戻す。全曲分のPCMやTaskを保持しない。現在曲の測定は再生leaseを共有し、先行leaseは一つまで、合計最大2を維持する。

再生要求と同じtrackID/参照/profileの巡回中処理は、Task・取消token・測定状態・leaseを再生側へ移す。先頭がない要求では同じleaseで先頭を追加準備する。異なる要求は背景処理を取消し、その終了を待ってから枠を使う。OFFの再生を全曲測定完了まで待たせない。

完了/失敗した候補は巡回内で記録し、破損・参照切れ・保存不可を高速に再試行しない。失敗しても後続を続け、現在の再生は止めない。参照修復/新しい編集、出力profileや音源属性の変更、次の正常起動で再評価する。出力identity/レート/チャンネル構成はCore Audioの通知で観測し、UIのないアイドル巡回中でも旧profileの処理を無効化する。未対応profileでは巡回を見送り、通常再生を制限しない。最大音量の表示を有効にした場合は、現在曲のnative sample peak専用経路を維持する。

Stop・一時停止・末尾終了・終了は巡回と出力監視も止める。Stop直後には自動再開せず、再生または新しい編集/追加で再開する。完了値は永続cacheに残し、停止後の基盤I/O終了時にはlease0、一時停止では再生leaseだけを保持する。進捗バー・スピナー・割合・残り時間は追加しない。

## キュー、取消とファイルアクセス

単一のutility DispatchQueueがデコーダのopenと読み取りを担当する。全曲測定は1チャンクごとに再投入し、後から到着した先頭準備を長い測定全体の後ろへ待たせない。I/Oや測定を音声render callbackへ追加しない。

`PreparationCancellation`はチャンク間で確認する。タスク取消に加えて世代IDを照合し、古い曲・設定・順序の結果を公開しない。基盤デコーダのopen自体を途中で強制終了することはできず、取消時はその呼び出しが戻った後に資源を閉じる。

- 曲順・次曲対象・参照の変更では次曲準備を破棄して作り直す。現在曲の変更では測定結果も破棄する。
- 一時停止では次曲準備と測定を取り消し、再開で必要な処理を作り直す。音声は通常の一時停止位置を保持する。
- 停止・末尾終了・失敗・出力変更・終了では背景処理と先頭PCM・メモリ保持を破棄する。完了済みの永続測定記録は残す。自動調整の完了結果はpause中に保持し、同じ音源/出力profileのresume・seekでは再測定しない。自然終了から次曲へ進む際は準備済みデコーダを先に引き継ぐ。明示的な曲選択が準備中なら自然送りで上書きしない。
- 通常は現在再生のlease1つと次曲準備のlease1つを保持する。測定は該当する同じleaseを共有する。取消中の基盤I/Oと非同期後処理が完了してから最後の参照が解放される。
- 先行準備の失敗だけで現在再生を停止したり、未選択の曲を削除したりしない。再生対象として選んだときに参照・読み込みエラーを表示する。

反復曲変更でも解析のキューを安全に解放するため、観測callbackはエンジン単位の`AnalysisRenderSource`を通し、キュー取消時は実行中の読取が終わってからメモリを解放する。[解析の実装設計](07_analysis-implementation.md)を参照する。バックエンドのisolated deinitで停止・解除を行うため、ビルドにはSwift 6.2以降を使用する。

再生時の解析と可視化の時計・PCM取得位置・OS音量は、この処理から変更しない。エンジン作成・グラフ接続は引き続きMainActor上のSFBAudioBackendが担当する。先頭準備が冷間の初曲のI/O時間や、デバイス開始の時間をなくす保証にはしない。SFBのring／供給chunkとPrefixDecoder／ProfileDecoderの有界バッファによる逐次供給を維持し、全曲PCMの保持や別FIFOを追加しない。

## 検証手順

1. `LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --disable-automatic-resolution --no-parallel`で8形式の元PCM一致、先頭境界、シーク、末尾最大値、無音、整数精度、非有限値、取消、設定、参照変更、保存失敗、自然送り・停止・解放を確認する。
2. `scripts/generate-fixtures.py`で独自の長い音源をignoredディレクトリへ生成する。`LCMP_PREPROCESS_PROFILE=1 LCMP_PREPROCESS_FIXTURES=<絶対パス>`で`PreprocessingTests/startupPreparationProfile`を実行し、従来の2回openと、背景準備・取得後最初のPCMまでを分けて記録する。初回はOSキャッシュの完全なcold状態を保証しない。
3. 同じディレクトリを指定し、`LCMP_PREPROCESS_OUTPUT_PROFILE=1`で`PreprocessingPerformanceTests/engineAndFirstAnalysisTiming`を実行する。順番を交互にし、選択・play呼出・最初の解析受信を分ける。最後の値は物理出音時刻ではない。
4. `LCMP_PREPROCESS_SOAK=1`と同ディレクトリを指定し、`PreprocessingPerformanceTests/tenMinutePlaybackPreparationAndMeasurementRemainBounded`を実行する。既定600秒、アプリ音量0の実出力で測定ON・FFT・反復曲変更を動かし、CPU、RSS、バッファ量、lease数、停止後解放とPCM欠落を確認する。通常の全回帰では性能測定をskipする。
5. `LCMP_UI_SNAPSHOTS=<出力先>`で設定のON/OFFを最小240ptの拡張画面へ描き、説明が読めることを確認する。ビルドは`python3 scripts/build-app.py --output build/preprocessing-verified/LCMP.app`等で別出力し、起動中bundleを置換しない。

利用者向け開始時間・CPUの評価はReleaseで行う。`scripts/build-app.py`は既定Release、Debugは`--configuration debug`で明示する。`NextPreparationTests`は非同期workerの返却を制御し、測定未完了／先頭未完了の同じ要求が一度だけ実行されること、手動／自然送り、停止、保存失敗、別エントリ、削除、設定変更とlease最大2を確認する。`LCMP_NEXT_PROMOTION_PROFILE=1 LCMP_PREPROCESS_FIXTURES=<生成したstartup音源ディレクトリ>`で大容量FLACの走査中引き継ぎを実測する。予定初回renderのhost時刻と解析PCM dropを、物理出音や音声ringの供給不足と混同しない。

`PlaylistPreprocessingTests`は固定profileと待機可能なworkerで、順位・全リスト巡回・重複・失敗後続・測定中の移譲・割込み退役・音源/profile失効・永続再利用・追加と停止を検証する。実出力と巡回負荷は専用の一時cache/独自音源を使い、実ユーザーの保存領域を検証対象にしない。

`LCMP_PLAYLIST_SOAK=1 LCMP_PREPROCESS_FIXTURES=<独自音源の専用領域> ./scripts/swift.sh test --configuration release --disable-automatic-resolution --no-parallel --filter tenMinutePlaylistSweepWithPlaybackInterruptions`で、600秒のリスト巡回と再生割込みを実行する。領域には独自生成の`tone.wav`・`tone.flac`（60秒）と`large.flac`（600秒）を置く。APFSのclonefileで独立した音源識別子を持つ複製を追加し、走査開始から400ms後に再生を切り替える。専用の一時SQLiteを使い、`playlist-soak.json`へCPU・RSS・解析drop・最大lease・停止後解放と、背景取消の退役時間／要求からplayingまでを分けて記録する。先頭準備だけの費用や物理出音時刻とは区別する。性能実行中は別のSwift build/testを動かさない。
