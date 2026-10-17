# 前処理測定結果の永続キャッシュ

[設計書一覧](../README.md)に戻る。

[再生前処理](04_preprocessing-implementation.md)の完了測定値をSQLiteへ保存し、停止・他曲再生・アプリ再起動後も再利用する。音源そのもの、先頭PCM、デコーダ、アクセスlease、測定途中のblock energyは保存しない。目標LUFS・手動音量から独立した結果を保存し、[音量自動調整](06_audio-processing-design.md)の補正計画は現在の設定から作り直す。

## 責務と保存先

- `MeasurementCacheConfiguration`：保存先、プログラム識別、音源識別adapter、容量・件数・期限、測定/変換版。
- `MeasurementCache`：前処理のutilityキューだけが操作するSQLite接続、検索・検証・更新・回収。
- `AudioPreprocessor`：現在曲・次曲・プレイリスト巡回共通の`measureLevels`／`measure`でキャッシュ参照と測定要求の合流を行う。
- `LibraryController`：音源IDを測定へ渡し、正常なライブラリ読込・編集保存の後に、有効な音源ID集合を渡す。キャッシュからライブラリへ依存しない。

プレイリスト事前測定も同じprocessor/cacheを使う。追加と正常復元から全リスト所属曲を巡回し、ヒット時は走査を省く。背景の完了結果は表示/補正のON/OFFと独立して保存する。

macOSアプリは専用`AudioPreprocessor(cache: .application)`をLibraryControllerへ注入する。保存先はアプリのコンテナ内のCachesディレクトリ配下`LCMP/Measurements/v1/measurements.sqlite`。FoundationでOSの保存場所を求め、ユーザー名をハードコードしない。再生成可能なデータとして扱い、OS等に削除された場合は再測定する。設定のUserDefaults、音源参照とリストのlibrary.jsonから分離する。

通常の`AudioPreprocessor()`と`.shared`は永続保存なし。テストや独立利用から実ユーザーのキャッシュへ書き込まず、必要な呼出元だけが保存先を注入する。

## 保存形式と検索

システムSQLiteを`CSQLite`からリンクし、新しい外部パッケージは追加しない。スキーマ版は1、application_idはLCMP専用値を使う。

| テーブル | 内容 |
| --- | --- |
| measurements | 32byteのSHA-256主キー、照合条件、互換世代、測定値、測定値のchecksum、完了日時・最終利用日時、ライブラリ管理対象の印 |
| owners | ライブラリ音源IDと測定キーの多対多の対応。測定削除時に対応も削除 |

主キー・対応・最終利用日時に索引を持つ。測定の値型は`CachedMeasurement`をbinary property listに符号化し、SQLiteのBLOBへ保存する。JSONや独自の索引ファイルを全件書き直さない。BLOBは1記録32KiB以下、SQLite値の読込上限も設ける。数値・状態の整合検証とchecksumに通った記録だけ復元する。

検索条件は固定順の文字列配列をbinary property listへ符号化し、そのSHA-256をキーにする。単純な文字列連結の区切り曖昧性やSwift Hasherのプロセスごとの変化を避ける。元の条件も保存し、検索時に完全一致を確認する。hashから元情報を逆算してAuditする必要はない。

## 識別と互換性

検索条件には次を含める。

- 正規化した音源の参照、資源識別子、更新revision、サイズ。
- アプリ版・ビルド値、実行ファイルのSHA-256、OS版/buildと固定したデコーダ版。
- 保存形式、測定アルゴリズム、形式変換の版。
- LUFS/true peakでは処理出力のレート・mono/stereo・profile版。native sample peak専用の条件とは区別する。

実行ファイルのdigestは最初の必要時にworker上で逐次計算し、同じprocessorでは再計算しない。開発ビルドでアプリ版・ビルド値が同じでも、実行物が変われば失効する。識別を取得できなければ永続再利用を無効にする。初期方式では版の完全一致だけを許可し、互換移行しない。

macOSの`LocalMeasurementSourceIdentity`はsymlink解決先のURL、ローカルvolume UUID、device/file番号、サイズ、mtime・ctime・birthtimeの秒/nanosecondを使用する。移動・改名は保守的にmiss。同名別パス、同パス差替え、サイズとmtimeを維持した通常の書換えも識別/revisionの違いで失効する。再生直前に使うSourceFingerprintも利用可能なrevisionを照合する。

音源内容全体のhashは毎回計算しない。属性を完全に維持/復元した変更、識別子の再利用、不確かな提供元を内容同一性の保証にしない。非ローカル媒体や必要な識別情報が取れない場合はキャッシュを使わず測定する。

共通の保存スキーマにはPOSIX型を持ち込まない。`MeasurementSourceIdentifying`が`MeasurementSourceIdentity`を返す境界を用意し、iOSのファイル提供元に応じた参照・revision取得を差し替える。現行の標準adapterはmacOS用で、他OSでは永続ヒットを無効とする。SQLite/キー/DTO/Auditの共通化は可能だが、iOSの音源参照adapterとビルド・実機検証は別途必要。端末間同期は提供しない。

## 完了値と再生の契約

`CachedMeasurement`はnative sample peak・元フレーム数/レート/ch数と、必要ならIntegrated LUFSの状態、変換後sample/true peak、変換後フレーム数、block数、profileと完了日時を持つ。無音・短すぎる・gate対象外を別の状態として表現する。無音のpeakは線形0とし、NaN/Infinityを保存しない。

復元時は有限値、非負peak、true peakとsample peakの大小、フレーム数、400ms/100msのblock数、元/変換後の時間の整合などを検証する。sample peak専用記録をLUFS/true peak測定の代用にしない。level測定の完了時は同じ走査で得たnative peakも専用キーへ保存し、測定専用設定から再利用できるようにする。level結果を別の音源IDから参照した場合は、既存のnative peak記録にも対応を追加する。片方のIDを除外しても共有するピークを失わない。

lookupは音源へのアクセスを得てから行う。前後の音源確認と再生直前のsource/profile照合を維持する。ヒット時は全曲scanを省くが、先頭PCMと再生用decoderは必要に応じて準備する。補正ONで有効な全曲測定値が必要という契約は変えない。

同じsource/profileの同時要求はworker上の一つのscanへ合流する。各要求の取消は独立に保持し、有効な要求が残る間はscanを継続する。全要求が取消された場合は次の有界読込境界で閉じ、完了値を保存しない。decoderを閉じてから残る要求へ終了を返す。Library側の世代照合とlease最大2・取消後解放待ちを維持する。

破損、欠落、未知の保存版、識別不一致、DBロック・読込失敗はmissとして通常測定へ戻る。書込失敗でも今回の正常測定結果は再生へ渡せる。未知版DBを空のDBで上書きしない。再利用できる測定値と保存成功を混同しない。

## 更新・Audit・回収

SQLite transactionで測定値と対応を確定する。外部キーを有効にし、busy待ちは50msまで。DBは0600、専用ディレクトリは新規作成時0700とし、DB本体のsymlinkを拒否する。新規ファイルの親はPOSIX realpathで正規化する。Foundationが`/private/var`を`/var`へ短縮する場合もSQLiteのNOFOLLOWと両立させる。

ライブラリの正常な読込・編集保存後に、有効な音源ID集合でownersを照合する。対応がなくなった管理対象記録を回収する。

| 操作/状態 | 扱い |
| --- | --- |
| 一つのプレイリストから削除、リスト自体を削除 | 音源がlibraryに残るため測定結果を保持 |
| libraryから除外 | 当該IDの対応を除去。他のIDからの対応がない記録を回収 |
| 音源が一時的に見つからない、外部媒体未接続 | libraryに残るため対応を保持 |
| libraryの保存失敗・読込不能 | 空集合としてAuditしない |
| 除外後に古いscanが完了 | 直近の有効ID集合にないIDの結果を保存/再関連付けしない |

library.jsonとSQLiteは別のtransactionである。保存成功後のAuditが中断された場合は次回正常読込後の照合で修復する。Auditの呼出順を直列化し、古いsnapshotで新しい結果を上書きしない。音源参照の修復後も旧条件の記録はhitせず、期限/容量によって回収される。

上限はDB本体64MiB、10000記録、最終利用から90日。期限切れと非互換世代を除去し、件数/容量の余裕が不足する場合は古い利用順に回収する。SQLiteのmax_page_countでDB本体を制限し、空きpageを再利用する。incremental vacuumは保守時に限定する。transaction中は別にrollback journalが必要で、その一時占有はDB本体の上限と区別する。回収は専用DB内の測定値/対応に限り、元音源・library.json・他のファイルを削除しない。

## 検証手順

1. `MeasurementCacheTests`で復元、版/音源/profile失効、symlink、同時要求/取消、破損/保存不能、Audit、容量・件数・期限を検証する。保存先とprogram identityを専用領域へ注入する。
2. `LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --disable-automatic-resolution --no-parallel`で現在/次曲、停止/他曲/再構築後の再利用、設定変更時の再計算、leaseと既存8形式を回帰する。
3. 同じビルドで`LCMP_CACHE_PROCESS=seed`、次に`read`と`LCMP_CACHE_PROCESS_ROOT=<short.wavを持つ専用領域>`を指定し、`MeasurementCacheTests/cacheSurvivesProcessRestart`を別プロセスで実行する。生成済みのprocess-cacheを再seedする場合は、検証用DBだけを事前に別の場所へ退避する。
4. `python3 scripts/generate-startup-fixtures.py <専用の空ディレクトリ>`で固定1秒bufferから独自の60秒/600秒WAV/FLACを生成する。同じ場所を指定し、`LCMP_CACHE_TIMING=1 LCMP_STARTUP_INPUT=<専用領域>`で`StartupInvestigationTests/persistentCacheSeparatesScanAndStartup`を実行する。scan数、lookup、先頭準備と予定初回renderを分ける。`collectMeasurementTimings`は任意のworker診断でありrenderを測る処理ではない。
5. `MeasurementStatistics`はprocessor単位のscan/hit/miss/write failure回数と任意のworker処理時間を提供する。音源のパス・曲名を診断出力へ追加しない。測定結果と速度の実行記録はローカル開発ノートへ保存する。
