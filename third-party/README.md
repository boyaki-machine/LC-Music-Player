# 第三者ライセンスの補完と対応ソース

このディレクトリには、依存OSSのライセンス原文の補完と、対応ソース付き配布物の設定を置きます。

| ファイル | 内容 |
| --- | --- |
| `licenses/GPL-3.0.txt` | GNU公式の原文（https://www.gnu.org/licenses/gpl-3.0.txt）を変更せずにコピーしたものです。TTAのLGPLv3に伴うGPLv3の本文を補完します |
| `licenses/LGPL-2.1.txt` | Package.resolvedで固定したmpc-binary-xcframework 0.1.2のLICENSE-LGPL.txtを変更せずにコピーしたものです。TagLibのLGPL-2.1の条件に対応するために同梱します。TagLibのMPL-1.1と内包するコードの原文も保持します |
| `notices.json` | 各補足原文のSHA256と依存のrevisionを指定し、アプリの謝辞索引の生成時に検証します。既存の上流の原文を編集・削除する仕組みではありません |
| `distribution.json` | コーデックのビルド元のURL・コミット、対応するPackage.resolvedのSHA256、frameworkの集合を固定します。上流のビルドシステムはMIT、個々の内包ソースは各原ライセンスです |
| `CORRESPONDING-SOURCE.md` | 対応ソース付き配布物に同梱する、ソースと再リンクの案内です |

バージョンを更新するときは、対応ソースと許諾を再確認してください。

LCMPのオリジナル成果物には[Apache 2.0](../LICENSE)を適用します。`RELINKING.txt`の改変・再リンクの案内は、その権利を制限せず、第三者の成果物の原許諾も変更しません。

関連する文書：[対応ソースと再リンク](CORRESPONDING-SOURCE.md)、[依存ライブラリと同梱構成](../docs/design/11_third-party-dependencies.md)、[ビルド・配置手順](../docs/build-and-deploy.md)。
