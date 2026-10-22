# 前処理測定結果の永続キャッシュ

[設計書一覧](../README.md)に戻る。

## 1. 概要

[再生前処理](04_preprocessing-implementation.md)の完了した測定値をSQLiteへ保存し、停止・他の曲の再生・アプリの再起動の後も再利用する。条件が一致する再生では全曲の再測定を省く。

保存するのは、目標LUFS・手動音量から独立した測定結果である。[音量自動調整](06_volume-normalization-implementation.md)の補正計画は、現在の設定から作り直す。音源そのもの、先頭PCM、デコーダ、アクセスlease、測定途中のblockエネルギーは保存しない。

## 2. 要件

- 音源・測定の方式・変換・OSのメジャー版・測定条件が変わった記録を再利用しない。
- アプリの更新（再ビルドを含む）とOSのマイナー更新では、測定済みの記録を引き継ぐ。
- 破損や読み込み失敗では再測定へ戻り、再生を妨げない。
- 容量・件数・期限に上限を設け、ライブラリから除外された音源の記録を回収する。
- 設定（UserDefaults）、音源参照とリスト（library.json）とは別の保存領域とする。
- テストや独立した利用から、利用者のキャッシュへ書き込まない。

## 3. 方式

| 要素 | 担当 |
| --- | --- |
| `MeasurementCacheConfiguration` | 保存先、OSの識別、音源識別のadapter、容量・件数・期限、測定・変換の版 |
| `MeasurementVersions` | 測定の方式（`algorithm`）と変換（`conversion`）の版。測定結果を変えうるコードの変更で上げる |
| `MeasurementCache` | 前処理の直列キューだけが操作するSQLite接続。検索・検証・更新・回収 |
| `AudioPreprocessor` | 現在曲・次曲・プレイリスト巡回に共通の`measureLevels`／`measure`で、キャッシュの参照と測定要求の合流を行う |
| `LibraryController` | 音源IDを測定へ渡し、正常なライブラリの読み込み・編集の保存の後に、有効な音源ID集合を渡す。キャッシュからライブラリへは依存しない |

- macOSアプリは専用の`AudioPreprocessor(cache: .application)`をLibraryControllerへ注入する。プレイリストの事前測定も同じprocessorとキャッシュを使う。
- 保存先は、アプリのコンテナ内のCachesディレクトリ配下`LCMP/Measurements/v1/measurements.sqlite`である。FoundationでOSの保存場所を求め、ユーザー名をハードコードしない。再生成できるデータとして扱い、OS等に削除された場合は再測定する。
- 通常の`AudioPreprocessor()`と`.shared`は永続保存を持たない。必要な呼出元だけが保存先を注入する。
- 背景の完了結果は、表示・補正のON/OFFとは独立して保存する。

## 4. 実装

### 保存形式と検索

システムのSQLiteを`CSQLite`からリンクし、外部パッケージは追加しない。スキーマ版は2、application_idはLCMP専用の値を使う。スキーマ版1のファイルは、開いたときに一度だけ版2へ移行する（「旧形式からの移行」）。

| テーブル | 内容 |
| --- | --- |
| measurements | 32byteのSHA-256主キー、照合条件、互換世代、測定値、測定値のchecksum、完了日時・最終利用日時、ライブラリ管理対象の印 |
| owners | ライブラリの音源IDと測定キーの多対多の対応。測定の削除時に対応も削除する |

- 主キー・対応・最終利用日時に索引を持つ。
- 測定値の型`CachedMeasurement`をbinary property listに符号化し、SQLiteのBLOBへ保存する。JSONや独自の索引ファイルを全件書き直さない。
- BLOBは1記録32KiB以下とし、SQLite値の読み込み上限も設ける。数値・状態の整合検証とchecksumに通った記録だけを復元する。
- 検索条件は、固定順の文字列配列をbinary property listへ符号化し、そのSHA-256をキーにする。単純な文字列連結の区切りの曖昧さや、Swift Hasherのプロセスごとの変化を避けるためである。元の条件も保存し、検索時に完全一致を確認する。hashから元の情報を逆算してAuditする必要はない。

### 識別と互換性

検索条件には次を含める。

- 正規化した音源の参照、資源識別子、更新revision、サイズ。
- OSの種類とメジャー版（例：`macOS 26`）、デコーダ（`CoreAudio`）。
- 保存形式、測定アルゴリズム、形式変換の版（`MeasurementVersions`）。
- LUFS/true peakでは、処理出力のレート・mono/stereo・profileの版。native sample peak専用の条件とは区別する。

アプリの版・ビルド値・実行ファイルは検索条件に含めない。測定結果を変えるのはアプリの版ではなく測定と変換のコードであり、その変更は版で表す。

- 測定と変換の版は、完全一致だけを許可する。古い版の記録は使わず、保存時に回収する。
- 版の上げ忘れは`MeasurementVersionTests`で防ぐ。版ごとに、可逆の形式の固定音源と、テストが整数の三角波から書くPCMの音源（大きい部分・-20dB・-90dBを持ち、二つのゲートを通る）の測定結果をビット単位で固定する。結果が変わると、版を上げて新しい版の結果を足すまで失敗する。過去の版の結果は書き換えない。
- OSは、Core Audioのデコーダとレート変換を通じて測定値をわずかに変えうる。マイナー更新では引き継ぎ、メジャー版が変わったときに一度だけ測り直す。圧縮形式（MP3・AAC）のデコード結果は版のテストで固定せず、OSのメジャー版で守る。

### 旧形式からの移行

スキーマ版1は、アプリの版・ビルド値・実行ファイルのSHA-256・OSの版の文字列全体を検索条件に含めていた。版2のアプリが版1のファイルを開くと、1つのtransactionで次を行う。

- 各記録に保存した元の条件を読み、版2の条件と主キーを作り直して移す。ライブラリの音源IDとの対応も移す。
- 移すのは、Core Audioで読んだ記録（環境の末尾が`/CoreAudio`）で、測定と変換の版が現在と同じものに限る。OSの版の文字列からメジャー版を取り出し、版2のOSの識別にする。
- 移せない記録は削除し、次の利用時に測り直す。移行に失敗した場合はtransactionを戻し、キャッシュを使わずに測定する。

音源の識別は次のように扱う。

- macOSの`LocalMeasurementSourceIdentity`は、symlinkの解決先のURL、ローカルvolumeのUUID、device/file番号、サイズ、mtime・ctime・birthtimeの秒・nanosecondを使う。
- 移動・改名は保守的にmissとする。同名の別パス、同じパスの差し替え、サイズとmtimeを維持した通常の書き換えも、識別・revisionの違いで失効する。再生直前に使うSourceFingerprintも、利用できるrevisionを照合する。
- 音源の内容全体のhashは毎回計算しない。属性を完全に維持・復元した変更、識別子の再利用、不確かな提供元を、内容が同一である保証にはしない。
- 非ローカルの媒体や、必要な識別情報が取れない場合はキャッシュを使わずに測定する。

他のOSへの対応は次のとおりとする。

- 共通の保存スキーマにはPOSIXの型を持ち込まない。`MeasurementSourceIdentifying`が`MeasurementSourceIdentity`を返す境界を用意し、iOSのファイル提供元に応じた参照・revisionの取得を差し替えられるようにする。
- 標準adapterはmacOSとiOSで共通とする。どちらも音源はローカルのAPFS上の通常ファイルで（iOSではファイル提供元が端末に置いたファイルを含む）、ボリューム・inode・各時刻・サイズのどれかが変われば別の音源として測り直す。SQLite・キー・DTO・Auditも共通である。標準adapterは「ミュージック」のライブラリの曲に識別を返さない。
- iOSアプリは、ライブラリの曲を`MediaLibraryMeasurementSourceIdentity`（LibraryCore）で識別し、ファイルは標準adapterに委ねる。ライブラリにはファイルの属性がないため、ライブラリが返す値を使う。
  - 参照：asset URL（persistent IDと形式を含む）。ライブラリが同じIDに返すasset URLと一致しなければ、識別を返さない。
  - 資源識別子：persistent ID。
  - 更新revision：曲の長さ（`playbackDuration`）とライブラリへの追加日時（`dateAdded`）。再生回数・最終再生日時は再生のたびに変わるので使わない。
  - サイズ：ライブラリはバイト数を返さないため、長さのミリ秒を入れる。
  - 許可がない曲、DRM付き・iCloudだけの曲、長さが0の曲には識別を返さず、毎回測定する。
- 同じpersistent IDのまま中身を差し替えた曲は、長さか追加日時が変われば別の音源として測り直す。両方が同じままの差し替えは見分けられず、古い測定値で補正する。影響は補正量のずれに限られ、true peakによる上限は古い値のまま効く。アプリの更新では失効せず、90日間の未使用・OSのメジャー版の変更・測定と変換の版の変更で失効する。
- 端末間の同期は提供しない。

### 完了値と再生の契約

- `CachedMeasurement`は、native sample peak・元のフレーム数・レート・ch数を持つ。LUFSを測定した場合は、Integrated LUFSの状態、変換後のsample/true peak、変換後のフレーム数、block数、profileと完了日時も持つ。
- 無音・短すぎる・gateの対象外を別の状態として表す。無音のpeakは線形0とし、NaN/Infinityを保存しない。
- 復元時は、有限値、非負のpeak、true peakとsample peakの大小、フレーム数、400ms/100msのblock数、元と変換後の時間の整合などを検証する。
- sample peak専用の記録をLUFS/true peakの測定の代わりにしない。
- LUFS測定の完了時は、同じ走査で得たnative peakも専用のキーへ保存し、最大音量の表示から再利用できるようにする。LUFSの結果を別の音源IDから参照した場合は、既存のnative peakの記録にも対応を追加する。片方のIDを除外しても、共有するピークを失わない。
- lookupは音源へのアクセスを得てから行う。前後の音源確認と、再生直前のsource/profileの照合を維持する。
- ヒット時は全曲の走査を省くが、先頭PCMと再生用のデコーダは必要に応じて準備する。補正ONで有効な全曲測定値が必要という契約は変えない。

同時の要求と失敗は次のように扱う。

- 同じsource/profileの同時要求は、worker上の1つの走査へ合流する。各要求の取消は独立に保持し、有効な要求が残る間は走査を続ける。
- 全要求が取り消された場合は、次の有界な読み込みの境界で閉じ、完了値を保存しない。デコーダを閉じてから、残る要求へ終了を返す。
- Library側の世代の照合と、lease最大2・取消後の解放待ちを維持する。
- 破損、欠落、未知の保存版、識別の不一致、DBのロック・読み込み失敗はmissとして通常の測定へ戻る。未知の版のDBを空のDBで上書きしない。
- 書き込みに失敗しても、今回の正常な測定結果は再生へ渡せる。再利用できる測定値と、保存の成功を混同しない。

### 更新・Audit・回収

- SQLiteのtransactionで測定値と対応を確定する。外部キーを有効にし、busyの待ちは50msまでとする。
- DBは0600、専用ディレクトリは新規作成時に0700とし、DB本体のsymlinkを拒否する。新規ファイルの親はPOSIXのrealpathで正規化する。Foundationが`/private/var`を`/var`へ短縮する場合も、SQLiteのNOFOLLOWと両立させる。
- ライブラリの正常な読み込み・編集の保存の後に、有効な音源ID集合でownersを照合し、対応がなくなった管理対象の記録を回収する。

| 操作・状態 | 扱い |
| --- | --- |
| 1つのプレイリストから削除、リスト自体を削除 | 音源がライブラリに残るため、測定結果を保持する |
| ライブラリから除外 | 当該IDの対応を除去する。他のIDからの対応がない記録を回収する |
| 音源が一時的に見つからない、外部媒体が未接続 | ライブラリに残るため、対応を保持する |
| ライブラリの保存失敗・読み込み不能 | 空集合としてAuditしない |
| 除外後に古い走査が完了 | 直近の有効なID集合にないIDの結果を、保存・再関連付けしない |

- library.jsonとSQLiteは別のtransactionである。保存成功後のAuditが中断された場合は、次回の正常な読み込み後の照合で修復する。
- Auditの呼出順を直列化し、古いsnapshotで新しい結果を上書きしない。
- 音源参照の修復後も、旧条件の記録はヒットせず、期限・容量によって回収される。

上限は、DB本体64MiB、10,000記録、最終利用から90日とする。

- 期限切れと非互換の世代（OSのメジャー版・測定と変換の版の違い）を除去し、件数・容量の余裕が足りない場合は利用の古い順に回収する。
- SQLiteの`max_page_count`でDB本体を制限し、空きpageを再利用する。incremental vacuumは保守時に限る。
- transaction中は別にrollback journalが必要で、その一時的な占有はDB本体の上限とは区別する。
- 回収は専用DB内の測定値と対応に限り、元の音源・library.json・他のファイルを削除しない。

## 5. 検証

### 合格基準

- 復元、版・音源・profileの失効、symlink、同時要求と取消、破損・保存不能、Audit、容量・件数・期限が要件どおりに動作する。
- アプリを再ビルドしても測定済みの記録を使い、OSのメジャー版・測定と変換の版の変更では使わない。版1のファイルの互換な記録を移し、そうでない記録を移さない。
- 測定と変換の結果が、現在の版に固定した値とビット単位で一致する。
- 現在曲・次曲、停止・他の曲・再構築後に再利用でき、設定の変更時は補正だけを再計算する。
- テストは専用の保存先とOSの識別を注入し、利用者のキャッシュに書き込まない。

### 自動テスト

1. `MeasurementCacheTests`で、保存先とOSの識別を専用の領域へ注入して、上の合格基準を検証する。
2. `MeasurementVersionTests`で、現在の版の測定結果を検証する。
3. `LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --disable-automatic-resolution --no-parallel`で、現在曲・次曲、停止・他の曲・再構築後の再利用、設定の変更時の再計算、leaseと8形式を回帰する。

### プロセスをまたぐ確認と測定

1. 同じビルドで`LCMP_CACHE_PROCESS=seed`、次に`read`と`LCMP_CACHE_PROCESS_ROOT=<short.wavを持つ専用領域>`を指定し、`MeasurementCacheTests/cacheSurvivesProcessRestart`を別のプロセスで実行する。生成済みのprocess-cacheを再seedする場合は、検証用のDBだけを事前に別の場所へ退避する。
2. `python3 scripts/generate-startup-fixtures.py <専用の空ディレクトリ>`で、固定1秒のbufferから独自の60秒・600秒のWAV/FLACを生成する。同じ場所を指定し、`LCMP_CACHE_TIMING=1 LCMP_STARTUP_INPUT=<専用領域>`で`StartupInvestigationTests/persistentCacheSeparatesScanAndStartup`を実行する。走査の数、lookup、先頭準備と予定された初回renderを分ける。`collectMeasurementTimings`は任意のworkerの診断で、renderを測る処理ではない。
3. `MeasurementStatistics`は、processorごとのscan・hit・miss・書き込み失敗の回数と、任意のworkerの処理時間を提供する。音源のパス・曲名を診断の出力へ追加しない。
