# ビルド・配置とローカル配布

[README](../README.md)・[設計書一覧](./README.md)に戻る。

## 必要な環境

macOS 14以降、Swift 6.2以降を扱えるXcodeまたはCommand Line Tools、Python 3.9以降、makeを使用します。`xcode-select -p`、`swift --version`、`python3 --version`、`make --version`で環境を確認できます。`codesign`、`otool`、`install_name_tool`、`ditto`はmacOSの開発ツールを使用します。iPhone向けの成果物は作成しません。

以下はリポジトリ直下で実行します。初回はネットワーク接続が必要で、SwiftPMが`Package.resolved`に基づく公開依存を取得します。`scripts/swift.sh`はコマンド内だけキーチェーン・netrc・Gitの認証ヘルパー参照を無効にし、保存済み認証やグローバル設定は変更しません。

## ビルドコマンド

```sh
make
make release
make debug
```

| コマンド | 成果物 | 用途 |
| --- | --- | --- |
| `make` / `make help` | ヘルプ表示 | コマンドと出力先の確認 |
| `make release` | `build/release/LCMP.app` | 最適化した通常利用・配布準備用 |
| `make debug` | `build/debug/LCMP.app` | デバッガーを使う開発用 |
| `make archive` | `build/dist/LCMP.zip` | Releaseを再ビルドしてZIP化 |
| `make distribution` | `build/distribution/LCMP-distribution.zip` | ソースから構築したコーデック・対応ソース・再リンク材料付き |
| `make test` | ターミナルの結果 | 音声出力なしの通常回帰 |

ReleaseとDebugでアプリの識別子やデータ保存先（App Sandboxのコンテナ`~/Library/Containers/local.lcmp.player`）は共通です。同じ利用者環境で両方を同時起動するとライブラリを共有するため、使用する方を切り替えるときは先に終了してください。全曲測定の速度評価には最適化されたReleaseを使います。

各ビルドは、実行ファイル、動的framework、本体のApache 2.0 LICENSE/NOTICE、依存ライセンス、解決済みパッケージ情報をアプリ内へまとめ、hardened runtimeとApp Sandboxを付けたad-hoc署名と署名検証を行います。署名鍵は使いません。同梱仕様は[依存ライブラリ](./design/11_third-party-dependencies.md)を参照してください。

任意の別出力先は変数で指定できます。パスに空白がある場合は変数の代入全体を引用符で囲みます。

```sh
make release RELEASE_OUTPUT=build/preview/LCMP.app
make debug 'DEBUG_OUTPUT=build/debug preview/LCMP.app'
make archive RELEASE_OUTPUT=build/package/LCMP.app ARCHIVE=build/package/LCMP.zip
```

`PYTHON`でPython実行コマンドを変更できます。1回の`make -j release debug archive test`でも共有SwiftPM成果物を同時変更しないよう直列実行します。別ターミナルからのmakeやSwiftビルド・テストは同時実行せず、完了を待ってください。

既存スクリプトも直接利用できます。こちらの既定出力先は`build/LCMP.app`です。

```sh
python3 scripts/build-app.py --configuration release --output build/preview/LCMP.app
python3 scripts/build-app.py --configuration debug --output build/debug/LCMP.app
```

## 起動・更新・配置

```sh
open build/release/LCMP.app
```

ビルド時は指定先のアプリを作り直します。起動中のアプリと同じ出力先を置き換えず、終了してから再ビルドするか別の出力先を使ってください。makeは起動やインストールを自動実行しません。

必要なら、アプリを終了してからFinderで`LCMP.app`を`~/Applications`などへコピーし、そのコピーを開きます。更新時も配置済みアプリを終了してから入れ替えます。利用者のライブラリや音源はアプリ内に含まれず、アプリのコピーだけでは別のMacへ移行しません。データ保存・復元は[ライブラリ設計](./design/03_library-implementation.md)を参照してください。

## ZIPを作成して検証する

```sh
make archive
ditto -x -k build/dist/LCMP.zip build/archive-check
codesign --verify --deep --strict build/archive-check/LCMP.app
```

展開先には空の新しいディレクトリを使います。標準の`ditto`でアプリを親ディレクトリごと格納し、frameworkのsymlinkとリソースを保持します。ZIPは一時ファイルへ作成してから指定先へ置き換えます。ビルド・圧縮が失敗するとmakeは非0で終了し、新しいZIPの成功を表示しません。以前のZIPが残っていても今回の成功成果物と扱わず、終了コードを確認してください。

このZIPはad-hoc署名のローカル検証用成果物です。Developer ID署名・公証は行っておらず、別のMacのGatekeeperによる受け入れを保証しません。一般公開用の配布では、Developer ID署名、公証と必要な配布設定、配布チャネルの条件等を別途確認してください。依存の対応ソースと再リンク材料は次の配布準備用ビルドで作成します。これらの鍵操作、アップロード、配布公開をmakeから実行する機能はありません。

## 対応ソース付きの配布物を作る

```sh
make distribution
# 固定コミットの上流checkoutを既に持っている場合
make distribution DISTRIBUTION_OUTPUT=build/source-package AUDIO_SOURCE=path/to/AudioXCFrameworks
```

完全なXcodeが必要です。現在のホストのarm64またはx86_64向けに、macOS 14以上のReleaseを作成します。`DISTRIBUTION_OUTPUT`は新しいディレクトリを指定します。既存の成果物は上書きしません。省略時は公開上流を取得し、`third-party/distribution.json`に固定されたソースコミットを使用します。`AUDIO_SOURCE`を指定しても、コミットと変更の有無を検査します。

出力フォルダには`LCMP-distribution/LCMP.app`、`LCMP-distribution/SHA256SUMS.json`と、このフォルダをまとめた`LCMP-distribution.zip`ができます。アプリ内の`Contents/Resources/CorrespondingSource`に対応ソース・ビルド情報・再リンク材料を含みます。対象ライブラリの互換な改変版へ差し替え、秘密鍵なしで再署名する手順は、同梱READMEおよび[対応ソース案内](../third-party/CORRESPONDING-SOURCE.md)を参照してください。

```sh
ditto -x -k build/distribution/LCMP-distribution.zip build/source-package-check
python3 scripts/distribution.py --verify build/source-package-check/LCMP-distribution
codesign --verify --deep --strict build/source-package-check/LCMP-distribution/LCMP.app
```

検証は全収録ファイルのSHA256とsymlinkを照合し、欠落・追加・改ざんを検出します。依存版を更新した場合は、コーデックの対応ソースと補足原文を再確認して設定を更新する必要があります。ラッパーの版だけをコーデックの版や対応ソースの証明に使いません。ビルド途中の失敗では完成出力を公開せず、作業ディレクトリを片付けます。

このコマンドも公開・アップロード・Developer ID署名・公証を実行しません。本体のApache 2.0 LICENSE/NOTICEを`Contents/Resources/LCMPLicense`と対応ソース内の`LCMP/`へ同梱します。依存のソース提供・再リンク材料、署名・ストア等の配布条件をそれぞれ確認します。通常の`make archive`だけでは対応ソース付きの配布物にはなりません。

## テスト

```sh
make test
```

`LCMP_TEST_AUDIO_OUTPUT=0`を明示し、`--no-parallel`で通常テストを行います。長時間負荷試験用の`LCMP_*`環境変数を設定したシェルでは、その設定を解除してから実行してください。実出力を確認する場合は別途、次を実行します。

```sh
LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --no-parallel
```

実出力テストは既定出力へテスト音を送ります。手動確認は[再生の検証手順](./design/02_playback-implementation.md)を参照してください。

## 問題の切り分け

- SwiftやSDKが見つからない場合は、Xcode／Command Line Toolsの導入状況と`xcode-select -p`を確認します。
- 公開依存の取得に失敗した場合はネットワーク接続と表示されたSwiftPMエラーを確認し、同じmakeコマンドを再実行します。利用者の認証情報を登録する必要はありません。
- 署名・同梱に失敗した場合はビルドを成功扱いにせず、最初の非0終了を確認します。検証済みの別アプリを上書きせず、新しい出力先で再試行できます。
- ビルド中のアプリ置換を避けるには、使用中のアプリを終了するか`RELEASE_OUTPUT`／`DEBUG_OUTPUT`を変更します。
- Debugで全曲測定が遅い場合はReleaseでも比較します。測定待ちと先頭PCMの準備は別の処理で、詳細は[前処理](./design/04_preprocessing-implementation.md)を参照してください。

## 謝辞情報の更新

各ビルドは現在の解決済み依存から`Contents/Resources/ThirdPartyLicenses/index.json`と原文を再生成します。make経由とbuild-app.pyの直接実行で共通です。設定→「このアプリについて」→「謝辞とライセンス…」で確認できます。依存バージョンを勝手に更新せず、Package.resolvedに反映された追加・削除・版変更を次のビルドで取り込みます。

`make test`には生成器のPythonテストも含まれます。依存グラフの不一致や原文不足で生成に失敗した場合はビルドを成功扱いにせず、解決済みcheckoutと上流のnotice収録状況を確認してください。原文を省略する・ダミー文書で埋める手順はありません。

ZIPを展開した後は署名とともに、`ThirdPartyLicenses/index.json`の依存が`Package.resolved`と一致し、各文書が索引の相対パスに存在することを確認します。ビルド機のcheckoutへアクセスせず、展開したアプリ内だけで読めることも確認します。
