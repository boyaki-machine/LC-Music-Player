# 依存ライブラリと同梱構成

[設計書一覧](../README.md)に戻る。

## 1. 概要

LCMPは第三者のライブラリを使用しません。音声の読み込み（デコード）と再生には、macOSが提供するCore Audio・AVFoundation（AVAudioFile、AVAudioEngine）を使います。SwiftPMのパッケージ依存はなく、`Package.resolved`もありません。

依存を加えるときは、その依存と間接依存のライセンスを確認し、本書の同梱構成と索引の仕組みに従ってください。LGPL・GPLのライブラリは、iPhone版をApp Storeで配布する妨げになり、対応ソースや再リンクの材料の同梱も必要になるため、加えないことを原則とします。

## 2. ライセンス

### LCMP本体

- LCMPのオリジナル成果物はApache License, Version 2.0（Apache-2.0）です。
- リポジトリの[LICENSE](../../LICENSE)と[NOTICE](../../NOTICE)を、`Contents/Resources/LCMPLicense`へ原文のまま同梱します。ビルドは公式のApache 2.0本文とのSHA256の一致と、NOTICEの存在を確認します。

### 第三者のコード・素材

- 第三者のコード・素材を加えた場合は、それぞれの原許諾を適用し、配布する成果物に著作権表示とライセンスの原文を同梱します。
- 音源のテストデータには、独自に合成した信号だけを使用します。市販の音源や第三者の音楽は含めません。WAV・AIFF・M4A・FLACは`scripts/generate-fixtures.py`で生成します。MP3はLAME 3.100で符号化してリポジトリに置いたものを使い、作り直しません。

## 3. アプリのリンクと同梱構成

| 対象 | 方法 |
| --- | --- |
| 音声のデコード・再生 | OSのCore Audio・AVFoundationを使います |
| SQLite | OSが提供するSQLiteへ`CSQLite`からリンクします |
| ハッシュ | Apple CryptoKitを使用します |

- アプリはframeworkを同梱しません。`scripts/build-app.py`は、実行ファイルがOS（`/System/Library/`・`/usr/lib/`）以外のライブラリへリンクしていればビルドを失敗させます。
- 測定キャッシュのために、外部のSwiftPMパッケージや独自のSQLiteバイナリは追加しません。

### 署名と権限

- ローカル起動用のアプリには、秘密鍵やキーチェーンの認証を必要としないアドホック署名を使用します。アプリの署名は`scripts/signing.py`に集約し、すべてのビルドでhardened runtimeを有効にします。これにより、dyldは`DYLD_INSERT_LIBRARIES`等の環境変数による注入を無視します。
- ライブラリの検証は有効のままとします。アプリはOSのライブラリだけを読み込みます。
- App Sandboxを有効にし、`com.apple.security.app-sandbox`、利用者が選んだファイルの読み書き（`com.apple.security.files.user-selected.read-write`）、security-scoped bookmark（`com.apple.security.files.bookmarks.app-scope`）だけを許可します。ネットワーク・カメラ等の権限は持ちません。
- データの保存先は[ライブラリの実装設計](03_library-implementation.md)を参照してください。

### ライセンス文書の同梱

- `Contents/Resources/ThirdPartyLicenses`に、依存の索引（`index.json`）と本書（`dependency-notes.md`）を置きます。依存がない現在、索引の一覧は空です。
- 依存を加えた場合は、各依存のチェックアウトのLICENSE／COPYING／COPYRIGHT／ACKNOWLEDGMENTS／NOTICE等と、固定したPackage.resolvedを同じ場所へコピーします。

## 4. ライセンス索引の自動生成と表示

`scripts/acknowledgements.py`は、`Package.resolved`とSwiftPMの`show-dependencies --format json`を照合し、現在の依存集合だけを対象にします。`Package.resolved`がなければ、依存はないものとして空の索引を作ります。

- ビルドは依存を更新せず、固定版を使います。
- 各checkoutと対応するbinary artifact内のLICENSE/COPYING/COPYRIGHT/ACKNOWLEDGMENTS/NOTICE等を収集し、原文のbyteを保持します。ライセンス名や適用条件をファイル名から推測しません。
- 必要なら、補足の原文を対象のrevisionとSHA256に結び付けて追加できます（`generate`の`supplements`）。
- 同梱領域の`index.json`は、`schemaVersion: 1`、依存のidentity/name/version/revision/公開URL、文書のtitle/pathを持ちます。文書のパスは同梱領域からの相対パスで、ソースcheckoutの絶対パスを含めません。
- 生成の順序を固定し、削除済みの依存の古い索引・文書を残しません。
- 依存集合・URL・版の不一致、原文の不足、表示できないUTF-8、参照範囲外のsymlinkは、ビルドを失敗させます。

PlayerUIの「ライセンス」ウィンドウは、LCMP本体（`LCMPLicense`のLICENSE・NOTICE）と索引の依存の原文を、プレーンテキストのNSTextViewへ表示します。依存がない現在は、LCMP本体だけを1枚で表示します。

- HTMLとして解釈しません。
- 索引の版・依存ID・文書のパスを検査し、文書の参照先を同梱領域内へ限定します。
- 欠落・破損・読み込み不可では、明確なメッセージを表示します。
- ライセンス情報の表示・同梱を、署名・公証や全配布条件の履行の証明と混同しません。

## 5. 公開依存の取得時の認証

- 依存を加える場合は、公開GitHubリポジトリと公開のリリースファイルから取得します。
- `scripts/swift.sh`はSwiftPMのキーチェーン・netrcの検索を無効にし、Gitのcredential helperもそのコマンド内だけで無効にします。ユーザーの永続的なGit設定、キーチェーン、認証情報は変更しません。
- SwiftPMのアーカイブのチェックサム検証は有効なままとします。

## 6. 既知の脆弱性の確認

音声ファイルとM3U8は信頼できない入力として扱います。アプリはネットワーク通信と外部プロセスの起動を行わないため、外部からの主な攻撃面はデコーダの解析処理です。解析はすべてOSのCore Audioが行い、[デコーダの選択](02_playback-implementation.md)で拡張子ごとに受け付ける符号化方式を限ります。Core Audioの修正はmacOSの更新で届きます。

iPhone版の`lcmp://`スキームは、どのWebページ・アプリからも開けます。受け付けるのは、拡張画面を開く`lcmp://extension`だけで、一覧にない値は何もしません。値を足すときの条件は[iPhone版の実装設計](13_iphone-implementation.md#urlスキーム)にあります。M3U8の書き出しは、利用者が選ばない限り、書き出し先のフォルダの外にある曲をフルパス（ユーザ名やフォルダの構成）で書きません。

公開の前には、次を確認します。

1. 動作対象のmacOSについて、Core Audio・AVFoundationの音声解析に関するセキュリティ更新（Appleのセキュリティリリース）を確認する。
2. 依存を加えた場合は、各版について、NVD・Debian/Ubuntuのセキュリティトラッカー等で既知のCVEと修正版を確認し、到達し得る処理に該当するものは修正版へ更新する。
3. 確認日、対象の版、該当するCVE、判断を開発の記録へ残す。

## 7. 検証

- 生成器の回帰：`python3 scripts/test_acknowledgements.py`
- 表示モデル・ネイティブの回帰：`AcknowledgementsTests`

`make test`はこれらを実行します。ビルドしたアプリで索引・原文・署名を確認する手順は[ビルド・配置手順](../build-and-deploy.md)を参照してください。
