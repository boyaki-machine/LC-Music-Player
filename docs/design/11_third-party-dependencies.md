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
