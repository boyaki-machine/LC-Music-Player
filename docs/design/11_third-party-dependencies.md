# 依存ライブラリと同梱構成

[設計書一覧](../README.md)に戻る。

## 1. 概要

LCMPは音声の再生にSFBAudioEngine 0.14.0を使用します。直接・間接の依存バージョンとコミットは、リポジトリの`Package.resolved`で固定します。

SFBAudioEngineはMITです。音源デコーダ等には別のライセンスが適用され、LGPLの依存も含まれます。[公式のライセンス・リンク方針](https://github.com/sbooth/SFBAudioEngine/blob/0.14.0/README.md#license)と[依存の著作権表示](https://github.com/sbooth/SFBAudioEngine/blob/0.14.0/ACKNOWLEDGMENTS.md)を参照してください。

## 2. ライセンス

### LCMP本体

- LCMPのオリジナル成果物はApache License, Version 2.0（Apache-2.0）です。
- リポジトリの[LICENSE](../../LICENSE)と[NOTICE](../../NOTICE)を、`Contents/Resources/LCMPLicense`へ原文のまま同梱します。ビルドは公式のApache 2.0本文とのSHA256の一致と、NOTICEの存在を確認します。
- これらは第三者の原文の索引とは分けます。

### 第三者のコード・素材・依存

- 各原許諾を適用し、LGPL等のソース提供・再リンクの条件も維持します。
- 公開・配布する成果物には、使用する依存ライブラリの著作権表示とソース提供の条件を適用します。動的frameworkの差し替えや、ライブラリを修正した場合の差分の提供も、対応するライセンスの条件に従います。
- 音源のテストデータには、`scripts/generate-fixtures.py`で生成する独自の正弦波を使用します。市販の音源や第三者の音楽は含めません。

## 3. アプリのリンクと同梱構成

| 依存 | リンクの方法 |
| --- | --- |
| LAME、Musepack、mpg123、libsndfile、TTA | 動的framework。`scripts/build-app.py`が`LCMP.app/Contents/Frameworks`へコピーし、アプリから動的に読み込みます |
| TagLib | SwiftPMのソース依存としてLCMPへ静的リンクします。LGPLの条件に対応するソースと再リンクの材料を、配布用ビルドに含めます。TagLib全体をMPLだけで扱えるとは仮定しません |
| SQLite | OSが提供するSQLiteへ`CSQLite`からリンクします |
| ハッシュ | Apple CryptoKitを使用します |

測定キャッシュのために、外部のSwiftPMパッケージや独自のSQLiteバイナリは追加しません。

### 署名と権限

- ローカル起動用のアプリには、秘密鍵やキーチェーンの認証を必要としないアドホック署名を使用します。アプリの署名は`scripts/signing.py`に集約し、通常ビルド・配布準備用ビルド・再リンクのすべてでhardened runtimeを有効にします。これにより、dyldは`DYLD_INSERT_LIBRARIES`等の環境変数による注入を無視します。
- アドホック署名のframeworkにはTeam IDがなく、LGPLの再リンクではframeworkを差し替えるため、ライブラリの検証だけを`com.apple.security.cs.disable-library-validation`で外します。
- App Sandboxを有効にし、`com.apple.security.app-sandbox`、利用者が選んだファイルの読み書き（`com.apple.security.files.user-selected.read-write`）、security-scoped bookmark（`com.apple.security.files.bookmarks.app-scope`）だけを許可します。ネットワーク・カメラ等の権限は持ちません。
- データの保存先は[ライブラリの実装設計](03_library-implementation.md)を参照してください。

### ライセンス文書の同梱

- 各依存のチェックアウトのLICENSE／COPYING／COPYRIGHT（内包するソースの表示を含む）と、SFBAudioEngineのACKNOWLEDGMENTSを、`Contents/Resources/ThirdPartyLicenses`へコピーします。固定したPackage.resolvedも同梱します。
- `third-party/notices.json`は、対象のrevisionに結び付けた補足の原文とSHA256を持ちます。TTAにはLGPLv3に加えてGPLv3の原文を、TagLibにはLGPL-2.1の原文を補完し、対象の依存の文書選択欄に表示します。原文の取得元は[原文の収録方針](../../third-party/README.md)を参照してください。

## 4. 謝辞索引の自動生成と表示

`scripts/acknowledgements.py`は、`Package.resolved`とSwiftPMの`show-dependencies --format json`を照合し、現在の依存集合だけを対象にします。

- ビルドは依存を更新せず、固定版を使います。
- 各checkoutと対応するbinary artifact内のLICENSE/COPYING/COPYRIGHT/ACKNOWLEDGMENTS/NOTICE等を収集し、原文のbyteを保持します。wrapperと内包OSSの文書をそれぞれ保存し、ライセンス名や適用条件をファイル名から推測しません。
- 同梱領域の`index.json`は、`schemaVersion: 1`、依存のidentity/name/version/revision/公開URL、文書のtitle/pathを持ちます。文書のパスは同梱領域からの相対パスで、ソースcheckoutの絶対パスを含めません。
- 生成の順序を固定し、削除済みの依存の古い索引・文書を残しません。
- 依存集合・URL・版の不一致、原文の不足、表示できないUTF-8、参照範囲外のsymlinkは、ビルドを失敗させます。

PlayerUIは同梱の索引だけを非同期に読み込み、選択された原文をプレーンテキストのNSTextViewへ表示します。

- HTMLとして解釈しません。
- 索引の版・依存ID・文書のパスを検査し、文書の参照先を同梱領域内へ限定します。
- 欠落・破損・読み込み不可では、明確なメッセージを表示します。
- ライセンス情報の表示・同梱を、署名・公証や全配布条件の履行の証明と混同しません。

## 5. 対応ソースと再リンク

`make distribution`は、`third-party/distribution.json`で固定したAudioXCFrameworksのソースから、LGPLを含むコーデックとそのビルド依存を構築します。使用したソース、Xcodeの定義、既存のpatch、全SwiftPM依存の固定ソース、LCMPのソーススナップショット、再リンク用のオブジェクト、手順を`Contents/Resources/CorrespondingSource`へ同梱します。通常のローカル用の`release`／`archive`は、このソース一式を含みません。

- 対応情報には、アーキテクチャ、ツールチェーン、ソースのコミット、Package.resolvedと同梱ファイルのSHA256を記録します。
- 依存の固定版を変更したときはソース対応の設定の見直しを要求し、ソースの不足・改変されたcheckout・hashの不一致を成功扱いにしません。
- 再リンクスクリプトは、同梱のオブジェクトと改変したTagLibまたは互換frameworkから別のアプリを生成し、アドホック再署名します。ライブラリのABIを変える場合は、使用側の再構築も必要です。
- LGPLの版ごとの条件と、利用者自身のための改変・再リンク・そのデバッグ目的のリバースエンジニアリングの許可を保持します。
- ソースの取得・再リンクの手順は、同梱の[対応ソース案内](../../third-party/CORRESPONDING-SOURCE.md)に従います。

## 6. 公開依存の取得時の認証

- 依存は、公開GitHubリポジトリと公開のリリースファイルから取得します。
- `scripts/swift.sh`はSwiftPMのキーチェーン・netrcの検索を無効にし、Gitのcredential helperもそのコマンド内だけで無効にします。ユーザーの永続的なGit設定、キーチェーン、認証情報は変更しません。
- SwiftPMのアーカイブのチェックサム検証は有効なままとします。

## 7. 既知の脆弱性の確認

音声ファイルとM3U8は信頼できない入力として扱います。アプリはネットワーク通信と外部プロセスの起動を行わないため、外部からの主な攻撃面はデコーダの解析処理です。到達できる解析処理は、[デコーダの選択](02_playback-implementation.md)で拡張子ごとに固定したmpg123・libFLAC・Core Audioに限ります。他の同梱ライブラリはSFBAudioEngineのリンク上は残りますが、アプリの再生・測定の経路からは呼びません。

依存の固定版を変更するとき、および公開の前には、次を確認します。

1. 同梱frameworkの実際の版を、ビルドしたアプリの`Contents/Frameworks/*/`の実行ファイルの版文字列（例：`strings -a <binary> | grep -E 'libFLAC|libsndfile|libopus|libVorbis'`）と`Package.resolved`で確認する。
2. 各版について、NVD・Debian/Ubuntuのセキュリティトラッカー等で既知のCVEと修正版を確認する。
3. 到達し得る解析処理（上記の固定デコーダ）に該当するものは、修正版への更新またはその経路の停止を行う。到達しない処理に該当するものは、到達しないことと更新の予定を記録する。
4. 確認日、対象の版、該当するCVE、判断を開発の記録へ残す。

## 8. 検証

- 生成器の回帰：`python3 scripts/test_acknowledgements.py`
- 配布の索引とソースの境界の回帰：`python3 scripts/test_distribution.py`
- 表示モデル・ネイティブの回帰：`AcknowledgementsTests`

`make test`はこれらを実行します。ビルド・ZIPの展開後に、索引の依存集合、原文、署名を確認する手順は[ビルド・配置手順](../build-and-deploy.md)を参照してください。
