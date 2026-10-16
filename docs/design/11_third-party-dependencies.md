# 音声再生の依存ライブラリ

SFBAudioEngine 0.14.0を使用します。直接・間接の依存バージョンとコミットは、リポジトリの`Package.resolved`で固定します。

本体はMITです。音源デコーダ等には別のライセンスが適用され、LGPLの依存も含まれます。[公式のライセンス・リンク方針](https://github.com/sbooth/SFBAudioEngine/blob/0.14.0/README.md#license)と[依存の著作権表示](https://github.com/sbooth/SFBAudioEngine/blob/0.14.0/ACKNOWLEDGMENTS.md)を参照します。

## アプリのリンクと同梱構成

`scripts/build-app.py`は、SwiftPMが解決したmacOS用frameworkを`LCMP.app/Contents/Frameworks`へコピーし、アプリから動的に読み込みます。LGPLを含むframeworkをLCMP本体へ静的に取り込みません。ローカル起動用アプリには、秘密鍵やキーチェーンの認証を必要としないアドホック署名を使用します。

各依存チェックアウトのLICENSE／COPYING／COPYRIGHT（内包するソースの表示を含む）と、SFBAudioEngineのACKNOWLEDGMENTSを`Contents/Resources/ThirdPartyLicenses`へコピーします。固定したPackage.resolvedも同梱します。

測定キャッシュはOSが提供するSQLiteへ`CSQLite`からリンクします。ハッシュはApple CryptoKitを使用し、これらのための外部SwiftPMパッケージや独自SQLiteバイナリは追加しません。

## 配布物の扱い

公開・配布する成果物には、使用する依存ライブラリの著作権表示とソース提供条件を適用します。動的frameworkの差し替えや、ライブラリを修正した場合の差分提供も、対応するライセンスの条件に従います。

音源テストデータには、`scripts/generate-fixtures.py`で生成する独自の正弦波を使用します。市販音源や第三者の音楽を含めません。

## 公開依存の取得時の認証

依存は公開GitHubリポジトリと公開のリリースファイルから取得します。`scripts/swift.sh`はSwiftPMのキーチェーン・netrc検索を無効にし、Gitのcredential helperもそのコマンド内だけで無効にします。ユーザーの永続的なGit設定、キーチェーン、認証情報は変更しません。SwiftPMのアーカイブのチェックサム検証は有効なままとします。

## 自動生成する謝辞索引

`scripts/acknowledgements.py`は`Package.resolved`とSwiftPMの`show-dependencies --format json`を照合し、現在の依存集合だけを対象にします。ビルドは依存を更新せず、既存の固定版を使います。各checkoutと対応するbinary artifact内のLICENSE/COPYING/COPYRIGHT/ACKNOWLEDGMENTS/NOTICE等を収集し、原文byteを保持します。wrapperと内包OSSの文書をそれぞれ保存し、ライセンス名や適用条件をファイル名から推測しません。

同梱領域の`index.json`は`schemaVersion: 1`、依存のidentity/name/version/revision/公開URL、文書title/pathを持ちます。文書パスは同梱領域からの相対パスで、ソースcheckoutの絶対パスを含めません。生成順序を固定し、削除済み依存の古い索引・文書を残しません。依存集合・URL・版の不一致、原文不足、表示できないUTF-8、参照範囲外のsymlinkはビルドを失敗させます。Package.resolvedと本説明も従来どおり同梱します。

PlayerUIは同梱索引だけを非同期に読み込み、選択された原文をプレーンテキストのNSTextViewへ表示します。HTMLとして解釈しません。索引の版/依存ID/文書パスを検査し、文書の参照先を同梱領域内へ限定します。欠落・破損・読込不可では明確なメッセージを表示します。ライセンス情報の表示・同梱を、署名/公証や全配布条件の履行証明と混同しません。

生成器の回帰は`python3 scripts/test_acknowledgements.py`、表示モデル/ネイティブの回帰は`AcknowledgementsTests`を使用します。`make test`は両方を実行します。ビルド・ZIP展開後に索引の依存集合、原文、署名を確認する手順は[ビルド・配置](../build-and-deploy.md)を参照してください。
