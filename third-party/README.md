# 第三者ライセンスの補完と対応ソース

`licenses/GPL-3.0.txt`はGNU公式原文（https://www.gnu.org/licenses/gpl-3.0.txt）の変更していないコピーです。TTAのLGPLv3に伴うGPLv3本文を補完します。

`licenses/LGPL-2.1.txt`は、Package.resolvedで固定したmpc-binary-xcframework 0.1.2のLICENSE-LGPL.txtの変更していないコピーです。TagLibのLGPL-2.1条件への対応のため同梱します。TagLibのMPL-1.1と内包コードの原文も保持します。

`notices.json`は各補足原文のSHA256と依存revisionを指定し、アプリの謝辞索引生成時に検証します。既存の上流原文を編集・削除する仕組みではありません。

`distribution.json`は、コーデックのビルド元URL/コミット、対応するPackage.resolvedのSHA256、frameworkの集合を固定します。バージョン更新時は対応ソースと許諾を再確認してください。上流ビルドシステムはMIT、個々の内包ソースは各原ライセンスです。

[対応ソースと再リンク](CORRESPONDING-SOURCE.md)、[依存の構成](../docs/design/11_third-party-dependencies.md)、[ビルド・配置](../docs/build-and-deploy.md)を参照してください。LCMPのオリジナル成果物には[Apache 2.0](../LICENSE)を適用します。`RELINKING.txt`の改変・再リンクの案内は、その権利を制限せず、第三者の成果物の原許諾も変更しません。
