# ビルド・配置とローカル配布

[README](../README.md)・[文書一覧](README.md)に戻る。

## 必要な環境

| 必要なもの | 確認するコマンド |
| --- | --- |
| macOS 14以降 | — |
| Swift 6.2以降を扱えるXcodeまたはCommand Line Tools | `xcode-select -p`、`swift --version` |
| Python 3.9以降 | `python3 --version` |
| make | `make --version` |

`codesign`、`otool`、`install_name_tool`、`ditto`、`hdiutil`、`osascript`はmacOSの開発ツール・標準のコマンドを使用します。iPhone向けの成果物は作成しません。

以下のコマンドはリポジトリの直下で実行します。初回はネットワーク接続が必要で、SwiftPMが`Package.resolved`に基づいて公開依存を取得します。`scripts/swift.sh`は、そのコマンドの中だけキーチェーン・netrc・Gitの認証ヘルパーの参照を無効にします。保存済みの認証やグローバル設定は変更しません。

## ビルドする

| コマンド | 成果物 | 用途 |
| --- | --- | --- |
| `make` / `make help` | ヘルプの表示 | コマンドと出力先の確認 |
| `make release` | `build/release/LCMP.app` | 最適化した通常利用・配布準備用 |
| `make debug` | `build/debug/LCMP.app` | デバッガーを使う開発用 |
| `make archive` | `build/dist/LCMP.zip` | Releaseを再ビルドしてZIP化 |
| `make distribution` | `build/distribution/LCMP-distribution.zip` | ソースから構築したコーデック・対応ソース・再リンク材料付き |
| `make dmg` | `build/dmg/LCMP-<バージョン>.dmg` | 対応ソース付きのアプリを入れたインストーラー |
| `make test` | ターミナルの結果 | 音声出力なしの通常の回帰テスト |

- 各ビルドは、実行ファイル、動的framework、本体のApache 2.0のLICENSE/NOTICE、依存のライセンス、解決済みのパッケージ情報をアプリ内へまとめます。hardened runtimeとApp Sandboxを付けたad-hoc署名と、署名の検証を行います。署名鍵は使いません。同梱の仕様は[依存ライブラリ](design/11_third-party-dependencies.md)を参照してください。
- ReleaseとDebugで、アプリの識別子とデータの保存先（App Sandboxのコンテナ`~/Library/Containers/local.lcmp.player`）は共通です。両方を同時に起動するとライブラリを共有するため、使う方を切り替えるときは先に終了してください。
- 全曲測定の速度の評価には、最適化されたReleaseを使います。

### バージョン

ビルドは、Gitの履歴からアプリのバージョン`<メジャー>.<マイナー>.<ビルド番号>`を決め、Info.plistへ書き込みます（`scripts/app_version.py`）。

| 部分 | 決め方 |
| --- | --- |
| メジャー | 開発者が`MAJOR`に設定する。現在は1 |
| マイナー | メジャーを上げてから、developブランチへマージした回数（developの第1親をたどったマージコミットの数） |
| ビルド番号 | ビルドしたコミットから到達できるコミットの数。developでビルドすると、developのコミット数になる |

- メジャーを上げるときは、`MAJOR`と、新しいメジャーを始めるコミットの`MAJOR_START`を同時に設定します。マイナーは0から数え直し、ビルド番号は数え直しません。
- 作業ブランチでビルドすると、マイナーは分岐元までのマージの数、ビルド番号は作業ブランチのコミットも含めた数になります。
- `LCMP_VERSION=0.20.50 make release`のように、`<メジャー>.<マイナー>.<ビルド番号>`の形で値を上書きできます。Gitの履歴がない場所（対応ソースの展開先など）では、上書きしない限り`<メジャー>.0.0`になり、警告を表示します。

### アイコン

ビルドは、リポジトリにある`assets/AppIcon.icns`をアプリの`Contents/Resources/AppIcon.icns`へコピーし、Info.plistの`CFBundleIconFile`に設定します。ビルドのたびには描き直しません。

アイコンの図形を変えたときは、`scripts/render-app-icon.swift`を直してから、次のコマンドで描き直します。各サイズのPNGを図形から描き、`iconutil`でicnsにまとめます。

```sh
swift scripts/render-app-icon.swift assets/AppIcon.icns
```

- 外観の仕様は[UI・UX設計](design/01_ui-ux-design.md#アプリのアイコン)に従います。
- `make test`は、icnsに16pxから1024pxまでのすべてのサイズが入っていることを確かめます（`scripts/test_app_icon.py`）。
- Finder や Dock が古いアイコンを表示し続けるときは、アプリを入れ直すか、`touch`でアプリの更新日時を変えてください。

### 出力先を変える

別の出力先は変数で指定できます。パスに空白がある場合は、変数の代入全体を引用符で囲みます。

```sh
make release RELEASE_OUTPUT=build/preview/LCMP.app
make debug 'DEBUG_OUTPUT=build/debug preview/LCMP.app'
make archive RELEASE_OUTPUT=build/package/LCMP.app ARCHIVE=build/package/LCMP.zip
```

ビルドスクリプトを直接使うこともできます。この場合の既定の出力先は`build/LCMP.app`です。

```sh
python3 scripts/build-app.py --configuration release --output build/preview/LCMP.app
python3 scripts/build-app.py --configuration debug --output build/debug/LCMP.app
```

### 注意

- `PYTHON`でPythonの実行コマンドを変更できます。
- 1回の`make -j release debug archive test`でも、共有のSwiftPM成果物を同時に変更しないよう直列に実行します。別のターミナルからのmakeやSwiftのビルド・テストは同時に実行せず、完了を待ってください。

## 起動・更新・配置

```sh
open build/release/LCMP.app
```

- ビルド時は指定先のアプリを作り直します。起動中のアプリと同じ出力先を置き換えず、終了してから再ビルドするか、別の出力先を使ってください。
- makeは起動やインストールを自動では行いません。
- 必要なら、アプリを終了してからFinderで`LCMP.app`を`~/Applications`などへコピーし、そのコピーを開きます。更新するときも、配置済みのアプリを終了してから入れ替えます。
- 利用者のライブラリや音源はアプリ内に含まれず、アプリのコピーだけでは別のMacへ移行しません。データの保存と復元は[ライブラリの実装設計](design/03_library-implementation.md)を参照してください。

## ZIPを作成して検証する

```sh
make archive
ditto -x -k build/dist/LCMP.zip build/archive-check
codesign --verify --deep --strict build/archive-check/LCMP.app
```

- 展開先には空の新しいディレクトリを使います。
- 標準の`ditto`でアプリを親ディレクトリごと格納し、frameworkのsymlinkとリソースを保持します。
- ZIPは一時ファイルへ作成してから指定先へ置き換えます。ビルド・圧縮が失敗するとmakeは0以外で終了し、新しいZIPの成功を表示しません。以前のZIPが残っていても今回の成功した成果物とは扱わず、終了コードを確認してください。

このZIPはad-hoc署名のローカル検証用の成果物です。

- Developer ID署名・公証は行っておらず、別のMacのGatekeeperによる受け入れを保証しません。一般公開用の配布では、Developer ID署名、公証と必要な配布設定、配布チャネルの条件等を別途確認してください。
- 依存の対応ソースと再リンクの材料は、次の配布準備用ビルドで作成します。
- 鍵の操作、アップロード、配布の公開をmakeから実行する機能はありません。

## 対応ソース付きの配布物を作る

```sh
make distribution
# 固定コミットの上流checkoutを既に持っている場合
make distribution DISTRIBUTION_OUTPUT=build/source-package AUDIO_SOURCE=path/to/AudioXCFrameworks
```

- 完全なXcodeが必要です。現在のホストのarm64またはx86_64向けに、macOS 14以上のReleaseを作成します。
- `DISTRIBUTION_OUTPUT`には新しいディレクトリを指定します。既存の成果物は上書きしません。
- `AUDIO_SOURCE`を省略すると公開の上流を取得し、`third-party/distribution.json`に固定されたソースのコミットを使います。`AUDIO_SOURCE`を指定しても、コミットと変更の有無を検査します。

出力フォルダには、`LCMP-distribution/LCMP.app`、`LCMP-distribution/SHA256SUMS.json`と、このフォルダをまとめた`LCMP-distribution.zip`ができます。アプリ内の`Contents/Resources/CorrespondingSource`に、対応ソース・ビルド情報・再リンクの材料を含みます。対象のライブラリを互換な改変版へ差し替え、秘密鍵なしで再署名する手順は、同梱のREADMEおよび[対応ソースの案内](../third-party/CORRESPONDING-SOURCE.md)を参照してください。

### 配布物を検証する

```sh
ditto -x -k build/distribution/LCMP-distribution.zip build/source-package-check
python3 scripts/distribution.py --verify build/source-package-check/LCMP-distribution
codesign --verify --deep --strict build/source-package-check/LCMP-distribution/LCMP.app
```

- 検証は全収録ファイルのSHA256とsymlinkを照合し、欠落・追加・改ざんを検出します。
- 依存の版を更新した場合は、コーデックの対応ソースと補足の原文を再確認して設定を更新する必要があります。ラッパーの版だけを、コーデックの版や対応ソースの証明に使いません。
- ビルドの途中で失敗した場合は完成した出力を公開せず、作業ディレクトリを片付けます。

### 再リンクを確認する

署名の方式や同梱物を変えたときは、展開したアプリで再リンクも確認します。出力先には新しい`.app`のパスを指定します。

```sh
S=build/source-package-check/LCMP-distribution/LCMP.app/Contents/Resources/CorrespondingSource
python3 "$S/relink.py" --rebuild-taglib --output build/relink-check/LCMP.app
codesign -dv build/relink-check/LCMP.app   # flagsにruntimeが含まれる
codesign -d --entitlements - build/relink-check/LCMP.app
```

- 改変版のTagLib（`--taglib-object`）と、同梱のソースから`LCMP/scripts/rebuild_frameworks.py`で再構築したframework（`--frameworks`）でも同様に確認します。
- 起動を確かめるときは、利用者のコンテナを読み書きしないよう、bundle IDを変えたコピーを`signing.py`で再署名して使います。
- `DYLD_INSERT_LIBRARIES`で指定したdylibが、起動中のプロセスに読み込まれない（`lsof -p <pid>`に現れない）ことも確認します。Sandbox下では注入したdylibがファイルを書けないため、マーカーファイルの有無では判定しません。

### 配布の前に確認すること

- このコマンドも、公開・アップロード・Developer ID署名・公証は実行しません。
- 本体のApache 2.0のLICENSE/NOTICEを、`Contents/Resources/LCMPLicense`と対応ソース内の`LCMP/`へ同梱します。
- 依存のソース提供・再リンクの材料、署名・ストア等の配布条件をそれぞれ確認します。通常の`make archive`だけでは、対応ソース付きの配布物にはなりません。

## インストーラー（DMG）を作る

```sh
make dmg
# 固定コミットの上流checkoutを既に持っている場合
make dmg AUDIO_SOURCE=path/to/AudioXCFrameworks
# 出力先を変える場合
make dmg DMG_OUTPUT=build/package/LCMP.dmg
```

- 対応ソース付きの配布物（`make distribution`と同じ手順）を作業用の一時ディレクトリに作り、その`LCMP.app`をDMGに入れます。前提は[対応ソース付きの配布物を作る](#対応ソース付きの配布物を作る)と同じで、完全なXcodeが必要です。
- 既定の出力先は`build/dmg/LCMP-<バージョン>.dmg`で、バージョンはアプリのInfo.plistから取ります。同じ名前のDMGは、検証まで成功した後に置き換えます。
- バージョンを上げて配布し直すときも、同じ`make dmg`を実行します。
- DMGのウィンドウは、Finderに配置を設定させて作ります。ログイン中のGUIセッションで実行してください。初回は、ターミナル（またはエディタ）がFinderを操作する許可を求められるので、許可します。
- 同じボリューム名（`LC Music Player <バージョン>`）のディスクをマウントしていると失敗します。先に取り出してください。
- 外観の仕様は[UI・UX設計](design/01_ui-ux-design.md#インストーラー)に従います。

作る手順は次のとおりです（`scripts/build-dmg.py`）。

1. アプリ、`/Applications`へのシンボリックリンク、`.background/background.tiff`を一時フォルダに並べ、読み書きできるDMG（HFS+）を作ります。
2. DMGをマウントし、AppleScriptでFinderにウィンドウの大きさ・アイコンの大きさと位置・背景を設定させます。Finderは設定をボリュームの`.DS_Store`に保存します。
3. 取り出して、圧縮した読み出し専用のDMG（UDZO）に変換します。
4. 圧縮したDMGを検証します。チェックサム、アプリの署名（`codesign --verify --deep --strict`）、Applicationsのリンク先、背景と`.DS_Store`の有無、見える項目がアプリとApplicationsだけであることを確かめます。

既存のDMGだけを検証することもできます。

```sh
python3 scripts/build-dmg.py --verify build/dmg/LCMP-0.22.57.dmg
```

### 手元で確かめるだけのDMG

既にあるアプリでDMGの見た目を確かめるときは、`DMG_APP`でアプリを指定します。対応ソースを含まないアプリでは警告を表示します。このDMGは配布に使いません。

```sh
make release
make dmg DMG_APP=build/release/LCMP.app DMG_OUTPUT=build/dmg-check/LCMP.dmg
```

### 背景を描き直す

背景はリポジトリにある`assets/DMGBackground.tiff`を使い、ビルドのたびには描き直しません。外観やアイコンの位置を変えたときは、`scripts/render-dmg-background.swift`と`scripts/build-dmg.py`の配置の値をそろえて直し、次のコマンドで描き直します。640×400と1280×800の画像を図形から描き、`tiffutil`で1つのTIFFにまとめます。

```sh
swift scripts/render-dmg-background.swift assets/DMGBackground.tiff
```

- `make test`は、TIFFの2つの画像の大きさと、描画スクリプト・Finderの設定の配置の値が一致することを確かめます（`scripts/test_build_dmg.py`）。
- Finderのタイトルバーの高さ（`TITLE_BAR`）は、ウィンドウの外枠から内容領域を640×400にするための値です。macOSの更新で背景の下端が欠けたり余白が出たりしたら、実際のウィンドウで測り直します。

### 署名と公証について

DMGの中のアプリはad-hoc署名で、Developer ID署名・公証は行っていません。別のMacでは、初めて開くときにGatekeeperの確認が出ます。DMGのウィンドウには、システム設定の「プライバシーとセキュリティ」から「このまま開く」を選ぶ手順を表示しています。

- `make dmg`も、公開・アップロード・Developer ID署名・公証は実行しません。
- DMGには配布物の`SHA256SUMS.json`を入れません。対応ソースと再リンクの材料は、アプリ内の`Contents/Resources/CorrespondingSource`に含まれます。

## テスト

```sh
make test
```

- `LCMP_TEST_AUDIO_OUTPUT=0`を明示し、`--no-parallel`で通常のテストを行います。生成器のPythonテストも含みます。
- テストの前後で`~/Library/Preferences`の`lcmp-*.plist`の件数を比べ、増えていたら失敗にします。
- 長時間の負荷試験用の`LCMP_*`環境変数を設定したシェルでは、その設定を解除してから実行してください。

実際の出力を確認する場合は、別に次を実行します。既定の出力へテスト音を送ります。手動の確認は[再生の検証手順](design/02_playback-implementation.md#5-検証)を参照してください。

```sh
LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test --no-parallel
```

- `--no-parallel`を外してスイートを並列に実行しても成功します。
- 実出力のテストを追加するときは、並列でも成功するように書きます。固定の待ち時間ではなく条件が成り立つまで待ち、負荷が高くても待つ間に自然送りが起きない長さ（数秒以上）の音源を使います。共有の`AudioPreprocessor.shared`ではなく専用のインスタンスを渡し、LibraryControllerが裏で行うキャッシュの照合などは、完了を確かめてから次へ進みます。共有の一時フォルダは、件数ではなく自分が作ったファイルだけを確かめます。

## 謝辞情報の更新

- 各ビルドは、現在の解決済みの依存から`Contents/Resources/ThirdPartyLicenses/index.json`と原文を再生成します。make経由とbuild-app.pyの直接実行で共通です。
- アプリでは、設定→「このアプリについて」→「謝辞とライセンス…」で確認できます。
- 依存のバージョンを勝手に更新せず、Package.resolvedに反映された追加・削除・版の変更を次のビルドで取り込みます。
- 依存グラフの不一致や原文の不足で生成に失敗した場合はビルドを成功扱いにせず、解決済みのcheckoutと上流のnoticeの収録状況を確認してください。原文を省略する・ダミーの文書で埋める手順はありません。
- ZIPを展開した後は、署名とともに、`ThirdPartyLicenses/index.json`の依存が`Package.resolved`と一致し、各文書が索引の相対パスに存在することを確認します。ビルド機のcheckoutへアクセスせず、展開したアプリ内だけで読めることも確認します。

## 問題の切り分け

| 症状 | 確認すること |
| --- | --- |
| SwiftやSDKが見つからない | Xcode／Command Line Toolsの導入状況と`xcode-select -p` |
| 公開依存の取得に失敗する | ネットワーク接続と表示されたSwiftPMのエラー。同じmakeコマンドを再実行します。利用者の認証情報を登録する必要はありません |
| 署名・同梱に失敗する | ビルドを成功扱いにせず、最初の0以外の終了を確認します。検証済みの別のアプリを上書きせず、新しい出力先で再試行できます |
| ビルド中にアプリを置き換えてしまう | 使用中のアプリを終了するか、`RELEASE_OUTPUT`／`DEBUG_OUTPUT`を変更します |
| Debugで全曲測定が遅い | Releaseでも比較します。測定待ちと先頭PCMの準備は別の処理です（[再生前処理](design/04_preprocessing-implementation.md)） |
