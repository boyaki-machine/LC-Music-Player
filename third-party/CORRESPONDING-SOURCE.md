# 対応ソースとLCMPの再リンク

このディレクトリは、このアプリを構築したソース・設定・再リンク用オブジェクトです。外部の開発用checkoutやビルドキャッシュを参照しなくても、同梱オブジェクトと変更したTagLib・互換frameworkを再結合できます。AppleのmacOS SDKと、`build-info.json`に記録した版のXcode／Swift、Python 3.9以降を用意してください。成果物は記録されたアーキテクチャ専用です。

## 収録物と許諾

- `AudioXCFrameworks/`: `build-info.json`に記録した上流コミットのソース、ビルド定義、既存patch。LAME、Musepack、mpg123、libsndfile、TTAと、そのビルド依存を含みます。
- `packages/`: `LCMP/Package.resolved`で固定した全SwiftPM依存のソース。TagLibは`packages/cxxtaglib/`です。包装パッケージのバージョンを内部コーデックのバージョンとは扱いません。
- `LCMP/`: このアプリをコンパイルしたプロジェクトのソース・テスト・スクリプト・設計文書。Git履歴や開発者のローカルノート、設定、音源・ライブラリを含みません。
- `Objects/`: LCMPと静的依存の再リンク用オブジェクト。デバッグ情報を除去し、開発機のパスを埋め込まない設定でコンパイルしています。
- `SOURCE-SHA256SUMS.json`: 元の収録ファイルのSHA256。配布フォルダ直下の`SHA256SUMS.json`は最終署名済みアプリを含みます。ご自身が変更したソースや再リンク版は、元のハッシュとは異なります。

第三者のコード・表示・ソースにはそれぞれの原許諾を適用し、原文を保持してください。TagLibのLGPL-2.1条件に対応するソースと再リンク材料を用意しています。MPL-1.1、Boost等の原表記も保持しています。LAMEのLGPL-2.0と他ライブラリのLGPL-2.1／3.0を一律に同じ条項として扱いません。GNU GPLv3原文の同梱は、LCMP本体をGPLに変更したという意味ではありません。

LCMPオリジナル部分の自身の利用のための変更、LGPLライブラリの改変版との再結合、およびそのデバッグ目的のリバースエンジニアリングについては`RELINKING.txt`を参照してください。LCMPオリジナル部分はApache License, Version 2.0（Apache-2.0）です。原文と表示は`LCMP/LICENSE`・`LCMP/NOTICE`、またはアプリ内の`Contents/Resources/LCMPLicense`にあります。依存OSSは各原許諾を保持します。配布署名・公証等は公開前に別途確認してください。

## TagLibを変更して再リンクする

展開したアプリのこのディレクトリへ移動し、`packages/cxxtaglib/Sources/`のソースを編集します。次のコマンドは、新しいアプリを配布フォルダへ作ります。既存のアプリは上書きしません。

```sh
cd LCMP.app/Contents/Resources/CorrespondingSource
python3 relink.py --rebuild-taglib --output ../../../../LCMP-modified.app
```

TagLibは同梱ソースからローカルで構築します。ネットワークやLCMP本体のソースの再コンパイルは不要です。既に互換オブジェクトを作った場合は、`--rebuild-taglib`の代わりに`--taglib-object path/to/taglib.o`を指定できます。TagLibのオブジェクトは、`build-info.json`に記録した対象・Swiftビルド方式に合わせてください。ABIを変更した場合、使用側の再コンパイルも必要です。

## 互換frameworkを構築・交換する

同じディレクトリで、記録されたアーキテクチャを指定します。下の`arm64`はIntel Mac用の成果物では`x86_64`に置き換えます。ビルド出力は新しいディレクトリにします。

```sh
python3 LCMP/scripts/rebuild_frameworks.py --source AudioXCFrameworks --output ../../../../modified-codecs --arch arm64
python3 relink.py --frameworks ../../../../modified-codecs/Frameworks --output ../../../../LCMP-modified.app
```

ソースの変更は`AudioXCFrameworks/`で行います。frameworkの名前・install name・公開API/ABIが使用側と互換である必要があります。必要な一部だけを再構築した場合も、その`.framework`を格納したディレクトリを`--frameworks`へ指定できます。`--rebuild-taglib`との併用も可能です。再リンクスクリプトはframeworkとアプリをアドホック再署名し、deep/strict検証を行います。アプリの署名は同梱の`signing.py`が行い、配布版と同じくhardened runtimeを有効にし、アドホック署名のframeworkを差し替えられるようライブラリ検証だけを外します。元の署名を維持するための秘密鍵は必要ありません。

## 本体もソースから再構築する

```sh
python3 LCMP/scripts/build-app.py --configuration release --prefix-map --frameworks-dir ../../../../modified-codecs/Frameworks --output ../../../../LCMP-rebuilt.app
```

この方法はSwiftPM依存を固定版で再取得するため、初回にネットワークを使います。上記のオブジェクトによる再リンクは依存の再取得を必要としません。取得したwrapperのバイナリを、同梱コーデックソースから作ったframeworkで置き換えます。

アドホック署名は公証やDeveloper ID署名ではありません。別のMacでのGatekeeperの扱い、将来のストア配布やhardened runtimeの設定は別途確認してください。再リンク版の起動は通常のアプリと同じデータ保存先を使用するので、同時起動せず、必要なら検証専用の利用者環境を用意してください。
