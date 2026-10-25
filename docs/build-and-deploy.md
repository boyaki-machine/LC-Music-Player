# ビルド・配置とローカル配布

[README](../README.md)・[文書一覧](README.md)に戻る。

## 必要な環境

| 必要なもの | 確認するコマンド |
| --- | --- |
| macOS 14以降 | — |
| Swift 6.2以降を扱えるXcodeまたはCommand Line Tools | `xcode-select -p`、`swift --version` |
| Python 3.9以降 | `python3 --version` |
| make | `make --version` |

`codesign`、`otool`、`install_name_tool`、`strip`、`ditto`、`hdiutil`、`osascript`、公証の`notarytool`・`stapler`・`spctl`はmacOSの開発ツール・標準のコマンドを使用します。iPhone版には、iOS 26以降のSDKとiOSシミュレータの実行環境を含むXcodeが要ります（[iPhone版](#iphone版)）。

以下のコマンドはリポジトリの直下で実行します。パッケージの依存はないので、ビルドにネットワーク接続は要りません。`scripts/swift.sh`は、そのコマンドの中だけキーチェーン・netrc・Gitの認証ヘルパーの参照を無効にします。保存済みの認証やグローバル設定は変更しません。

## ビルドする

| コマンド | 成果物 | 用途 |
| --- | --- | --- |
| `make` / `make help` | ヘルプの表示 | コマンドと出力先の確認 |
| `make release` | `build/release/LCMP.app` | 最適化した通常利用・配布準備用 |
| `make debug` | `build/debug/LCMP.app` | デバッガーを使う開発用 |
| `make archive` | `build/dist/LCMP.zip` | Releaseを再ビルドしてZIP化 |
| `make dmg` | `build/dmg/LCMP-<バージョン>.dmg` | 配布用に作り直したReleaseのアプリを入れたインストーラー |
| `make test` | ターミナルの結果 | 音声出力なしの通常の回帰テスト |

- 各ビルドは、実行ファイル、本体のApache 2.0のLICENSE/NOTICE、依存の索引（現在は空）をアプリ内へまとめます。frameworkは同梱しません。実行ファイルがOS以外のライブラリへリンクしていると、ビルドは失敗します。hardened runtimeとApp Sandboxを付けて署名し、署名を検証します。署名は、設定がなければad-hoc署名（署名鍵を使いません）、Git管理外の`Signing.local.xcconfig`があればDeveloper ID署名です（[署名と公証](#署名と公証)）。同梱の仕様は[依存ライブラリ](design/11_third-party-dependencies.md)を参照してください。
- ReleaseとDebugで、アプリの識別子（`io.github.boyaki-machine.LC-Music-Player`、iPhone版と共通）とデータの保存先（App Sandboxのコンテナ`~/Library/Containers/io.github.boyaki-machine.LC-Music-Player`）は共通です。両方を同時に起動するとライブラリを共有するため、使う方を切り替えるときは先に終了してください。
- コンテナは署名者に結び付きます。同じMacで、ad-hoc署名のアプリとDeveloper ID署名のアプリを混ぜて使わないでください（コンテナへのアクセスの確認が出たり、読めなかったりします）。設定があれば`make release`・`make debug`もDeveloper IDで署名するので、配布したアプリと手元のビルドの署名者はそろいます。
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
- `LCMP_VERSION=0.20.50 make release`のように、`<メジャー>.<マイナー>.<ビルド番号>`の形で値を上書きできます。Gitの履歴がない場所（ソースのアーカイブを展開した先など）では、上書きしない限り`<メジャー>.0.0`になり、警告を表示します。

### アイコン

ビルドは、リポジトリにある`assets/AppIcon.icns`をアプリの`Contents/Resources/AppIcon.icns`へコピーし、Info.plistの`CFBundleIconFile`に設定します。ビルドのたびには描き直しません。

### パッケージのリソース

可視化「教育番組」の絵は、`PlayerUI`ターゲットのリソースとしてSwiftPMが`LCMP_PlayerUI.bundle`にまとめます。ビルドはこのバンドルを`Contents/Resources/`へコピーして署名し、その後でアプリ全体に署名します（アプリの直下に置くと署名の検証に失敗します）。iPhone版では、Xcodeがアプリの直下へ入れます。

パペットの部品は、原画`assets/puppet-show/puppets.png`から次のコマンドで作り直します。結果はリポジトリに置き、ビルドのたびには作りません。

```sh
uv run --with pillow --with numpy python -I scripts/make-puppet-parts.py
```

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

`--prefix-map`を付けると、実行ファイルからこのチェックアウトの絶対パスを除き、残っていればビルドを失敗させます。`make dmg`はこの指定でアプリを作ります。

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
- 標準の`ditto`でアプリを親ディレクトリごと格納し、リソースと署名を保持します。
- ZIPは一時ファイルへ作成してから指定先へ置き換えます。ビルド・圧縮が失敗するとmakeは0以外で終了し、新しいZIPの成功を表示しません。以前のZIPが残っていても今回の成功した成果物とは扱わず、終了コードを確認してください。

このZIPはローカル検証用の成果物です。

- 公証はせず、時刻印も付けません。別のMacで開くためのものは、公証まで行う`make dmg`で作ります。
- 配布の公開をmakeから実行する機能はありません。

## ソースの提供について

アプリは第三者のライブラリを含まず、LGPL等によるソースの提供や再リンクの材料は必要ありません。LCMP本体のApache 2.0のLICENSE/NOTICEは`Contents/Resources/LCMPLicense`に同梱します。依存を加えるときは、[依存ライブラリと同梱構成](design/11_third-party-dependencies.md)に従ってライセンスを確認してください。

## インストーラー（DMG）を作る

```sh
make dmg
# 出力先を変える場合
make dmg DMG_OUTPUT=build/package/LCMP.dmg
```

- 作業用の一時ディレクトリに、Releaseのアプリを`--prefix-map`付きで作り直し（実行ファイルにビルド機のパスを残さない）、それをDMGに入れます。
- 署名の設定（[署名と公証](#署名と公証)）があれば、アプリとDMGをDeveloper IDで署名し、公証とstapleまで行います。設定がなければ、従来どおりad-hoc署名のアプリを入れた、署名のないDMGを作ります。
- 既定の出力先は`build/dmg/LCMP-<バージョン>.dmg`で、バージョンはアプリのInfo.plistから取ります。同じ名前のDMGは、検証まで成功した後に置き換えます。
- バージョンを上げて配布し直すときも、同じ`make dmg`を実行します。
- DMGのウィンドウは、Finderに配置を設定させて作ります。ログイン中のGUIセッションで実行してください。初回は、ターミナル（またはエディタ）がFinderを操作する許可を求められるので、許可します。
- 同じボリューム名（`LC Music Player <バージョン>`）のディスクをマウントしていると失敗します。先に取り出してください。
- 外観の仕様は[UI・UX設計](design/01_ui-ux-design.md#インストーラー)に従います。

作る手順は次のとおりです（`scripts/build-dmg.py`）。

1. アプリ、`/Applications`へのシンボリックリンク、`.background/background.tiff`を一時フォルダに並べ、読み書きできるDMG（HFS+）を作ります。
2. DMGをマウントし、AppleScriptでFinderにウィンドウの大きさ・アイコンの大きさと位置・背景を設定させます。Finderは設定をボリュームの`.DS_Store`に保存します。
   - Finderは指定したウィンドウの大きさを取りこぼし、既定のウィンドウのまま保存することがあります。そのため、大きさを読み戻して一致するまで設定し直し、保存された`.DS_Store`のウィンドウの大きさ・アイコンの大きさ・2つのアイコンの位置が配置の値と一致するまで待ちます。一致しなければFinderでの設定を数回やり直し、それでも一致しなければ失敗します。
3. 取り出して、圧縮した読み出し専用のDMG（UDZO）に変換します。
4. 圧縮したDMGを検証します。チェックサム、アプリの署名（`codesign --verify --deep --strict`）、Applicationsのリンク先、背景が署名の方式に合ったものであること、`.DS_Store`の有無と保存された配置（ウィンドウの大きさ・アイコンの大きさと位置）、見える項目がアプリとApplicationsだけであることを確かめます。
5. 署名の設定があるときは、DMGに時刻印付きで署名し、公証に出して結果を待ち（`notarytool submit --wait`）、Acceptedならチケットをstapleします。その後、4の検証に加えて公証の検証（[署名と公証](#署名と公証)）を行います。

既存のDMGだけを検証することもできます。署名されたDMGには、公証の検証も行います。

```sh
python3 scripts/build-dmg.py --verify build/dmg/LCMP-0.22.57.dmg
```

### 手元で確かめるだけのDMG

既にあるアプリでDMGの見た目を確かめるときは、`DMG_APP`でアプリを指定します。`make release`のアプリは実行ファイルにビルド機のパスを含み得るので、このDMGは配布に使いません。署名の設定があるときは、アプリが同じDeveloper IDで時刻印付きで署名されていないと失敗し、通ればこのDMGも公証に出します。見た目だけを確かめるときは、`LCMP_SIGNING_IDENTITY= LCMP_NOTARY_PROFILE=`を前に付けて設定を外し、ad-hoc署名のアプリで作ります。

```sh
make release
make dmg DMG_APP=build/release/LCMP.app DMG_OUTPUT=build/dmg-check/LCMP.dmg
```

### 背景を描き直す

背景はリポジトリにある2枚を使い、ビルドのたびには描き直しません。違うのは下端の案内だけです。

| 背景 | 使うDMG | 下端の案内 |
| --- | --- | --- |
| `assets/DMGBackground-Notarized.tiff` | 公証したDMG | 初めて開くときの確認で「開く」を選ぶ |
| `assets/DMGBackground.tiff` | ad-hoc署名のDMG | システム設定の「プライバシーとセキュリティ」から「このまま開く」を選ぶ |

外観やアイコンの位置を変えたときは、`scripts/render-dmg-background.swift`と`scripts/build-dmg.py`の配置の値をそろえて直し、次のコマンドで2枚とも描き直します。640×400と1280×800の画像を図形から描き、`tiffutil`で1つのTIFFにまとめます。

```sh
swift scripts/render-dmg-background.swift assets/DMGBackground.tiff
swift scripts/render-dmg-background.swift --notarized assets/DMGBackground-Notarized.tiff
```

- `make test`は、2枚のTIFFの画像の大きさと、描画スクリプト・Finderの設定の配置の値が一致することを確かめます。`.DS_Store`の読み取りと、配置の食い違い（Finderの既定のウィンドウ・アイコンの位置）を検出することも確かめます（`scripts/test_build_dmg.py`）。
- Finderのタイトルバーの高さ（`TITLE_BAR`）は、ウィンドウの外枠から内容領域を640×400にするための値です。macOSの更新で背景の下端が欠けたり余白が出たりしたら、実際のウィンドウで測り直します。

## 署名と公証

Apple Developer Programのチームで、アプリをDeveloper IDで署名し、DMGを公証します。公証してstapleしたDMGとアプリは、別のMacでもGatekeeperに止められずに開けます。インターネットから入手したアプリなので、初めて開くときに「開く」を選ぶ確認だけは出ます。

### 設定

リポジトリの直下に、Git管理外の`Signing.local.xcconfig`を置きます。名前とTeam IDを含むので、Gitには入れません（`.gitignore`済み）。

```
// Developer ID signing of the macOS app
LCMP_SIGNING_IDENTITY = Developer ID Application: <名前> (<Team ID>)
LCMP_NOTARY_PROFILE = LCMP-notary
```

| 設定 | 内容 |
| --- | --- |
| `LCMP_SIGNING_IDENTITY` | 署名に使う証明書。`security find-identity -v -p codesigning`に出る名前か、40桁のSHA-1 |
| `LCMP_NOTARY_PROFILE` | `notarytool store-credentials`でキーチェーンに保存したプロファイルの名前。`make dmg`に必要 |

- 1行に`キー = 値`を書き、行頭の`//`は注釈です。知らないキーや形の崩れた行があると、ビルドの前に失敗します。
- 同じ名前の環境変数があれば、ファイルより優先します。空の値は設定なしの意味なので、`LCMP_SIGNING_IDENTITY= make release`とすると、その場だけad-hoc署名になります。
- ファイルがなければ、すべてのビルドがad-hoc署名になり、キーチェーンを読みません。
- 資格情報（Apple ID・パスワード）はキーチェーンのプロファイルだけに置き、ファイルにもリポジトリにも書きません。

### 一度だけの準備

1. **Developer ID Application証明書を作る。** Xcode › Settings › Accounts で有料のチームを選び、Manage Certificates › ＋ › Developer ID Application。作れるのはチームのAccount Holderだけです。`security find-identity -v -p codesigning`に「Developer ID Application: …」が出ることを確かめます。
2. **秘密鍵を控える。** キーチェーンアクセスの「自分の証明書」で証明書を書き出し（.p12、強いパスワード付き）、リポジトリの外に保管します。この鍵はこのMacにしかありません。
3. **App用パスワードを作る。** account.apple.com › サインインとセキュリティ › App用パスワード。
4. **公証の資格情報を保存する。** パスワードを会話やログに残さないよう、自分のターミナルで実行し、求められたらApp用パスワードを入力します。

   ```sh
   xcrun notarytool store-credentials "LCMP-notary" --apple-id "<Apple ID>" --team-id "<Team ID>"
   ```

   `xcrun notarytool history --keychain-profile LCMP-notary`が「No submission history.」などを返せば使えます。
5. `Signing.local.xcconfig`を書きます（上の設定）。

Macのアプリについては、Apple DeveloperのサイトでのApp IDの登録は要りません（Developer IDの配布では必須ではありません）。

### ビルドでの署名

- アプリ（`scripts/signing.py`）：リソースのバンドルを先に、次にアプリ全体を、同じ証明書で署名します。アプリにはhardened runtimeとApp Sandboxの権利を付けます。署名の後に、設定した証明書で署名されていることを要件（`codesign -R`）で確かめます。
- 時刻印：公証には安全な時刻印が要ります。時刻印はAppleのサーバーへ問い合わせるので、`make dmg`のビルドだけに付け（`build-app.py --timestamp`）、`make release`・`make debug`では付けません。
- 初回の署名では、codesignがキーチェーンの鍵の使用の許可を求めることがあります。「常に許可」を選ぶと次からは出ません。

### 公証

`make dmg`は、DMGの配置を検証した後に次を行います。公証のアップロードはDMGだけで、中のアプリも公証に登録されます。

1. DMGに時刻印付きで署名します。
2. `xcrun notarytool submit <DMG> --keychain-profile <プロファイル> --wait`で公証に出し、結果を待ちます。通常は数分で、混んでいると長くかかります。
3. 結果がAccepted以外なら失敗にし、理由のログを取るコマンド（`xcrun notarytool log <ID> --keychain-profile <プロファイル>`）を表示します。
4. `xcrun stapler staple`でチケットをDMGに付けます。オフラインでも、DMGを開くときの確認が通ります。

### 公証の検証

`make dmg`の最後と`--verify`は、署名されたDMGに次を確かめます。

| 対象 | 確かめること |
| --- | --- |
| DMG | `codesign --verify --strict`、署名者がDeveloper ID Applicationで時刻印があること（`codesign -dvv`）、`stapler validate`、`spctl -a -t open --context context:primary-signature`がaccepted |
| 中のアプリ | 署名者がDeveloper ID Applicationで、時刻印とhardened runtimeがあること、`spctl -a -t exec -vv`がaccepted（source=Notarized Developer ID） |

`make test`は、設定の読み取り（ファイル・環境変数・崩れた行）、ad-hoc／Developer IDの署名のコマンド、証明書の要件を`scripts/test_signing.py`で、公証の工程（結果を待ってstapleする・Accepted以外でログの取り方を示す）、署名の表示の判定、背景の選び方を`scripts/test_build_dmg.py`で確かめます。Appleへの送信は行いません。

ダウンロードした状態での確認は、quarantine属性を付けたコピーで行えます。

```sh
cp build/dmg/LCMP-<バージョン>.dmg /tmp/LCMP-check.dmg
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" /tmp/LCMP-check.dmg
open /tmp/LCMP-check.dmg
```

### 識別子の変更と、ライブラリの引き継ぎ

アプリの識別子を、仮の`local.lcmp.player`から`io.github.boyaki-machine.LC-Music-Player`に変えました（バージョン1.30以降）。識別子と署名者が変わったので、macOSではApp Sandboxのコンテナが、iPhoneではApp Groupが新しくなり、それまでのライブラリ・プレイリスト・設定は引き継がれません。移行の機能はなく、音源を登録し直します。

- macOSの旧コンテナ`~/Library/Containers/local.lcmp.player`は、新しいアプリでライブラリを作り直した後に、Finderで削除できます。
- iPhoneでは、旧アプリ（旧識別子）を削除します。

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

拍とボーカルの解析を実際の曲で評価する場合は、`scripts/beat-annotator.html`で記録した正解と音源を同じディレクトリに置き、次を実行します。音源と正解はリポジトリに入れません。記録の方法と指標は[曲の地図の実装設計](design/15_track-map-implementation.md#実際の曲での評価)を参照してください。

```sh
LCMP_BEAT_EVAL=<音源と正解のディレクトリ> ./scripts/swift.sh test --filter BeatEvaluationTests
```

## iPhone版

iPhone版は`iOS/LCMPiOS.xcodeproj`でビルドします。macOS版と同じSwiftパッケージのライブラリ（LibraryCore・PlayerUI・PlaybackCore・ControlSurfaces）を参照し、iOSだけの部分（アプリの入口・音声セッション・ファイルの選択）を`iOS/LCMPiOS/`に、ホーム画面のウィジェットを`iOS/LCMPWidgets/`（アプリに埋め込む拡張）に置きます。

| コマンド | 内容 |
| --- | --- |
| `make ios-build` | シミュレータ向けにビルドします（署名なし）。成果物は`build/ios/app/Build/Products/Debug-iphonesimulator/LCMP.app`です。 |
| `make ios-test` | 共用モジュールのテストをiOSシミュレータで実行します。AppKitの画面のテストはmacOSだけで実行します。 |
| `make ios-uitest` | アプリをシミュレータで起動し、指の操作のテスト（`iOS/LCMPiOSUITests/`）を実行します。 |
| `make ios-sim` | ビルドしてシミュレータに入れ、起動します。 |
| `make ios-device` | 署名して実機向けにビルドし、接続したiPhoneに入れて起動します。 |

- 上書きできる変数は`IOS_CONFIGURATION`（Debug／Release）、`IOS_SIMULATOR`（シミュレータの名前、既定は`iPhone 18 Pro Max`）、`IOS_DEVICE`（実機の名前か識別子）です。
- 実機向けの署名には、Git管理外の`iOS/Local.xcconfig`に`DEVELOPMENT_TEAM`（Team ID）を書きます。ないときはシミュレータ向けにだけビルドできます。
- 識別子は`iOS/Shared.xcconfig`の`LCMP_BUNDLE_ID`（既定は`io.github.boyaki-machine.LC-Music-Player`、macOS版と同じ）から作ります。

  | 対象 | 識別子 |
  | --- | --- |
  | アプリ | `$(LCMP_BUNDLE_ID)` |
  | ウィジェット拡張 | `$(LCMP_BUNDLE_ID).widgets` |
  | UIテスト | `$(LCMP_BUNDLE_ID).uitests` |
  | App Group | `group.$(LCMP_BUNDLE_ID)` |

  既定の識別子はこのプロジェクトのチームに登録されています。別のチームで署名するときは、`iOS/Local.xcconfig`に`LCMP_BUNDLE_ID = <自分だけの識別子>`を書きます。App IDとApp Groupは、Xcodeの自動署名が初回のビルドでチームに登録します。
- ウィジェットに再生中の点灯を出すには、App Groupを使えるチーム（有料のチーム）で`iOS/Local.xcconfig`に`LCMP_APP_GROUP_ENABLED = YES`を書きます。書かないときはApp Groupの権利を付けず、無料の個人チームでも署名でき、ウィジェットは切り替えの記号になります。

  ```
  DEVELOPMENT_TEAM = <Team ID>
  LCMP_APP_GROUP_ENABLED = YES
  ```
- バージョンはmacOS版と同じく、ビルドの最後の段（`scripts/ios_resources.py`）がGitの履歴から決めてInfo.plistへ書き込みます。同じ段で、LCMPのLICENSE/NOTICEと依存の索引（空）をアプリへ入れます。ウィジェット拡張には同じバージョンだけを書き込みます（`--version-only`）。
- アイコンは`scripts/render-app-icon.swift --ios`で、macOS版と同じ図形から角の丸みと余白のない1024pxの画像を描きます。
- DEBUGビルドには、シミュレータで確かめるための起動引数があります。`-LCMPImportPaths <パス>,<パス>`はMac上のファイル・フォルダを選択画面なしで現在のリストに登録し、`-LCMPAutoplay YES`で再生を始めます。`-LCMPOrientation landscape`は横置きに（`-LCMPOrientationDelay <秒>`で回すまでの待ち時間）、`-LCMPExtension NO`は拡張画面を閉じた状態で起動します。`-LCMPControlSurfaces YES`はウィジェットの見本を各状態で並べます。

## ライセンス情報の更新

- 各ビルドは、現在の解決済みの依存から`Contents/Resources/ThirdPartyLicenses/index.json`と原文を再生成します。`Package.resolved`がない現在は、空の索引になります。make経由とbuild-app.pyの直接実行で共通です。
- アプリでは、設定→「このアプリについて」→「ライセンス…」で確認できます。LCMP本体のLICENSEとNOTICEを表示します。
- 依存のバージョンを勝手に更新せず、Package.resolvedに反映された追加・削除・版の変更を次のビルドで取り込みます。
- 依存グラフの不一致や原文の不足で生成に失敗した場合はビルドを成功扱いにせず、解決済みのcheckoutと上流のnoticeの収録状況を確認してください。原文を省略する・ダミーの文書で埋める手順はありません。
- ZIPを展開した後は、署名とともに、`ThirdPartyLicenses/index.json`の依存が`Package.resolved`と一致し（ないときは空）、各文書が索引の相対パスに存在することを確認します。ビルド機のcheckoutへアクセスせず、展開したアプリ内だけで読めることも確認します。表示の確認は、`LCMP_NOTICE_RESOURCES=<展開したアプリ>/Contents/Resources ./scripts/swift.sh test --filter AcknowledgementsTests`で行えます。

## 問題の切り分け

| 症状 | 確認すること |
| --- | --- |
| SwiftやSDKが見つからない | Xcode／Command Line Toolsの導入状況と`xcode-select -p` |
| 署名・同梱に失敗する | ビルドを成功扱いにせず、最初の0以外の終了を確認します。検証済みの別のアプリを上書きせず、新しい出力先で再試行できます |
| Developer IDの署名に失敗する | `security find-identity -v -p codesigning`に`LCMP_SIGNING_IDENTITY`と同じ名前が出るか、キーチェーンの鍵の使用を拒否していないかを確認します |
| 公証がAcceptedにならない | 表示された`notarytool log`のコマンドで理由を読みます。資格情報の誤りは`notarytool history --keychain-profile <プロファイル>`で確かめます |
| ビルド中にアプリを置き換えてしまう | 使用中のアプリを終了するか、`RELEASE_OUTPUT`／`DEBUG_OUTPUT`を変更します |
| Debugで全曲測定が遅い | Releaseでも比較します。測定待ちと先頭PCMの準備は別の処理です（[再生前処理](design/04_preprocessing-implementation.md)） |
