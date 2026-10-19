# iPhone版の実装設計

[設計書一覧](../README.md)に戻る。

本書は、iPhone版のアプリの構成と、macOS版と共用する部分のOSごとの分け方を記述する。画面の仕様は[UI・UX設計](01_ui-ux-design.md#6-iphone版の画面)に、ビルドの手順は[ビルド・配置手順](../build-and-deploy.md#iphone版)に記載する。

## 1. 概要

- iPhone版は、macOS版と同じSwiftパッケージのライブラリ（LibraryCore・PlayerUI・PlaybackCoreと、それらが依存するCoreモジュール）を使う。再生・解析・前処理・測定キャッシュ・ライブラリ・画面の部品は共通のソースである。
- iOSだけの部分は、Xcodeプロジェクト`iOS/LCMPiOS.xcodeproj`のアプリ（`iOS/LCMPiOS/`）に置く。アプリの入口、音声セッション、ロック画面の操作、書類の選択、画面の向きに応じた配置を受け持つ。
- 対象はiOS 26以降のiPhoneとする。

## 2. 要件

- 共用部分のmacOSでの動作・寸法・テストの結果を変えない。
- 画面を閉じても、他のアプリに切り替えても、ロックしても再生を続ける。
- 電話や他のアプリの音声で中断されたら一時停止し、自動では再開しない。
- ロック画面・コントロールセンターの「再生中」には、曲名・経過時間を出さない。
- ファイルアプリに出る場所（このiPhone内・iCloud Drive・OneDrive等のファイル提供元）の音源と、「ミュージック」のライブラリの曲を、コピーせずに参照する。
- バックグラウンドでは描画と解析の購読を止める。

## 3. 方式

### OSごとの分け方

共用のソースは、OSに依存する箇所だけを`#if os(macOS)`／`#if os(iOS)`で分ける。

| 箇所 | macOS | iOS |
| --- | --- | --- |
| 音源のブックマーク（`BookmarkFileReferences`） | 読み取り専用のsecurity-scoped bookmark | オプションなしのブックマーク（選択時のアクセス権を暗黙に持つ） |
| 「ミュージック」のライブラリ（`SystemMediaLibrary`） | なし（ライブラリの曲は参照切れ） | `MPMediaQuery`でpersistent IDから曲を探す |
| 出力の変化の監視（`PlaylistOutputObserver`） | Core Audio HALの既定出力・サンプルレート・ストリーム構成 | `AVAudioSession`の経路変更の通知 |
| 入力部品（シーク・音量・行の操作・クリック・ツールチップ等） | AppKitの`NSViewRepresentable`（`NativeControls.swift`ほか） | 同じ型名と引数の部品（`TouchControls.swift`。行のクリックと並べ替えはUIKitの`UIViewRepresentable`） |
| ライセンスの表示 | 専用のウィンドウ（`AcknowledgementsWindowController`） | シート（`AcknowledgementsSheet`） |
| Escapeで閉じる | `onExitCommand` | ハードウェアキーボードのEscape（`onKeyPress`） |
| 設定の説明文 | 既定の出力デバイスとキーボードショートカット | 現在の出力先（ショートカットの説明は出さない） |
| アプリの入口（`LCMPApp`） | AppKitのアプリとウィンドウ | 何もしない入口（iPhoneのアプリは`iOS/LCMPiOS/`） |

### 画面の枠

メイン画面の大きさは、環境値`playerFrame`で決める。macOSのウィンドウ（360×210pt）を基準とし、iPhoneの枠はこれから求める。

| 枠 | 使う場面 | 寸法 |
| --- | --- | --- |
| `window` | macOSのウィンドウ | 可視化144pt、操作部66pt、ボタンの間隔9pt、角丸12pt、周波数の文字9pt |
| `card` | iPhoneの縦置き | 幅/360の倍率で`window`の寸法を拡大（1倍未満にはしない）、角丸18pt |
| `fullScreen` | iPhoneの横置き・拡張を閉じたとき | 可視化は残りの高さ全部、操作部84pt、ボタン56pt（記号24pt）、ボタンの間隔は安全領域の幅から最大48pt、角丸なし、文字16pt。背景は画面の端まで、中身は安全領域の内側、上に10ptの余白 |
| `panel` | iPhoneの横置き・拡張の横 | 可視化は残りの高さ全部、操作部76pt、ボタン52pt（記号21pt）、ボタンの間隔は幅から最大48pt、角丸18pt、文字13pt |

- 音量バーの位置は、6つのボタンのうち5つ目（音量）の上になるよう、ボタンの間隔から求める。
- 拡張画面の文字は、macOSの指定の大きさに3ptを足して表示する（`Font.ui`）。
- iOSのシークバーは、指で操作しやすいよう高さ36ptとする。

### iOSのアプリ

| 型 | 受け持つこと |
| --- | --- |
| `LCMPiOSApp`・`AppModel` | PlaybackController・LibraryController・PlayerPresentationの所有、起動時の復元、画面の状態に応じた描画と解析の停止・再開、`lcmp://extension`で拡張画面を開く |
| `AudioSessionController` | 音声セッションの区分、中断の処理、ロック画面・コントロールセンターの操作と「再生中」の表示 |
| `RootView` | 画面の向きと拡張の開閉に応じた配置、書類の選択・書き出し、ライブラリの曲の選択、ライセンスのシート |
| `MusicLibraryPicker` | `MPMediaPickerController`による曲の選択と、ライブラリへのアクセスの許可 |

## 4. 実装

### 音声セッションとバックグラウンド再生

- Info.plistの`UIBackgroundModes`に`audio`を入れる。音声セッションの区分は`.playback`、方針は`.longFormAudio`とし、消音スイッチの状態にかかわらず鳴らす。
- 再生を始めたときにセッションを有効にし、停止したときに他のアプリへ知らせて無効にする。曲の自然な終わりでは無効にしない（次の曲が続くため）。
- 中断の始まりで、再生中なら一時停止する。中断の終わりでは再開しない。
- 出力の経路が変わると（ヘッドホンの抜き差し・Bluetoothの接続の変化）、AVAudioEngineの構成変更としてmacOSと同じく停止する。
- 画面がアクティブでないとき（バックグラウンド・ロック）は、`visualizationVisible`を偽にし、解析の設定を外す。再生は続ける。

### ロック画面の操作

- `MPRemoteCommandCenter`の再生・一時停止・切り替え・停止・次の曲・前の曲を、LibraryControllerの操作へつなぐ。再生位置の変更と早送り・早戻しは無効にする。
- `MPNowPlayingInfoCenter`には、タイトル「LC Music Player」、アートワークとしてアプリのアイコン、再生速度（再生中1・一時停止0）だけを渡す。長さと経過時間は渡さず、経過時間のバーを出さない。アプリのアイコンは画像として読めないため、同じ画像をアセット`NowPlayingArtwork`として持つ。

### 書類の選択

- ファイル・フォルダ・プレイリストの選択には、1つの`fileImporter`を使い、開く目的（ファイル・フォルダ・修復・プレイリスト）で受け付ける種類を変える。ファイルは対応する拡張子の種類、フォルダは`.folder`、プレイリストはM3U8とする。
- 選んだURLは、macOSと同じくLibraryControllerの登録・修復・読み込みに渡す。登録はアクセスを開始してから行い、フォルダの中の音源ごとにブックマークを作る。
- プレイリストの書き出しは、アプリの一時フォルダへM3U8を書き、`fileMover`で利用者の選んだ場所へ移す。
- 選択画面は、閉じるときに表示のフラグを偽にしてから結果を渡す。開いた目的（登録・修復・読み込み）は表示のフラグとは別に持ち、結果を受け取るまで残す。

### 「ミュージック」のライブラリ

- 曲の選択は`MPMediaPickerController`で行い、複数選択を許し、iCloudだけの曲とDRM付きの曲を出さない。選んだ曲は、asset URLと曲名を`LibraryController.importMediaItems`に渡す。登録先のプレイリストを指定でき、同じ曲は同じ音源として扱う。
- Info.plistの`NSAppleMusicUsageDescription`で利用目的を示し、初めて選ぶときに許可を求める。許可がないときは、設定を開く案内を出す。
- 再生・測定はファイルと同じく`AudioFileDecoder`（AVAudioFile）で読む。asset URLの拡張子で形式を決める。
- M3U8へはasset URLのまま書き出し、読み込みでも受け付ける。macOSで読み込んだ場合は参照切れになる。
- 測定結果は、ファイルと同じく永続キャッシュに保存し、再起動後も再利用する。識別にはpersistent ID・asset URL・長さ・追加日時を使う（[永続キャッシュ](05_measurement-cache-implementation.md)）。アプリは`MeasurementCacheConfiguration.application`の音源識別のadapterを`MediaLibraryMeasurementSourceIdentity`に差し替える。
- 再生前処理の`SourceFingerprint`は、ファイルの属性を読まず、asset URLそのものを識別にする（asset URLは1つの曲を指す）。
- 音源一覧では、asset URLが曲ごとに異なっても、ライブラリの曲をすべて1つの「ミュージック」のまとまりに入れる。

### プレイリストの行の操作

- 行のタップ・ダブルタップ・長押しは、行に重ねたUIKitのviewのジェスチャー認識（`UITapGestureRecognizer`・`UILongPressGestureRecognizer`、長押しは0.35秒）で受ける。タップはダブルタップの失敗を待ってから選択として扱う。
- 長押しの成立前に指が動くと、タップと長押しは失敗し、一覧のスクロールが動く。成立した後の指の動きは行の移動として扱い、ウィンドウ座標の縦の移動量を並べ替えに渡す。
- SwiftUIのジェスチャー（長押しの後にドラッグを続ける形。`UIGestureRecognizerRepresentable`で付けた長押しを含む）は、行の上から始めたスクロールを妨げるため使わない。

### 画面の回転

- 縦置きと横置きは別のプレイヤーの画面を作るため、回転で画面が入れ替わる。新しい画面が出てから古い画面が消える順序でも描画を止めないよう、`PlayerPresentation`が可視化を表示している画面の数を数え、最後の1つが消えたときだけ描画を止める。

### ビルドの構成

- `iOS/Shared.xcconfig`（Git管理）に共通の設定を置き、Git管理外の`iOS/Local.xcconfig`を任意で読み込む。Team IDとバンドルIDの接頭辞はLocal.xcconfigだけに置く。既定のバンドルIDは`local.lcmp.player`である。
- アプリのソースはファイルシステムと同期するグループで参照し、ファイルの追加でプロジェクトを編集しない。
- Info.plistはビルド設定から生成し、`iOS/LCMPiOS-Info.plist`の項目（バックグラウンドの音声、URLスキーム`lcmp`）を合わせる。
- 最後のビルドの段で`scripts/ios_resources.py`を実行し、LICENSE/NOTICEを`LCMPLicense/`へ、空の依存の索引を`ThirdPartyLicenses/`へ入れ、Gitの履歴から決めたバージョンをInfo.plistへ書き込む。依存を加えたときは、この段で依存のnoticeも入れる必要があり、スクリプトはPackage.resolvedがあると失敗して知らせる。
- パッケージにもmacOS版の実行ファイル`LCMP`があるため、iPhoneのターゲットとスキームの名前は`LCMPiOS`とする（アプリの名前は`LCMP.app`）。
- 指の操作のテストはUIテストのターゲット`LCMPiOSUITests`（`iOS/LCMPiOSUITests/`）に置き、共有のスキーム`LCMPiOS`のテストに含める。

## 5. 検証

| 確かめること | 方法 |
| --- | --- |
| 共用モジュールのテストがiOSでも成功する（測定キャッシュの識別を含む） | `make ios-test` |
| macOSの寸法・テストが変わらない | `make test`（`PlayerFrameTests`がウィンドウの寸法を固定する） |
| 各枠の寸法・ボタンが枠に収まる | `PlayerFrameTests` |
| 項目の多いプレイリストを行の上から指でスクロールでき、タップ・ダブルタップ・長押しの並べ替えも動く | `make ios-uitest`（`PlaylistTouchTests`。シミュレータで40曲を登録し、指の操作を再現する。`-LCMPLibraryFile`で専用のライブラリを使う） |
| 回転で画面が入れ替わっても描画が止まらない | `VisualizationHostTests`（出る・消える順序の両方） |
| ライブラリの曲の参照・登録・解決・M3U8・音源のまとまり・測定キャッシュの識別 | `MediaLibraryTests`・`SourceGroupTests`・`MediaLibraryIdentityTests`（ライブラリを差し替えてmacOSでも実行する） |
| 提供元の識別で、別のprocessorでも測定結果を再利用し、revisionが変われば測り直す | `MeasurementCacheTests` |
| iPhoneのアイコンが不透明な1024pxの正方形である | `scripts/test_app_icon.py` |
| ビルドの段がライセンスとバージョンを入れる | `scripts/test_ios_resources.py` |
| 縦置き・横置き・拡張を閉じた全画面の配置 | シミュレータで起動引数（`-LCMPImportPaths`・`-LCMPAutoplay`・`-LCMPOrientation`・`-LCMPExtension`）を付けて撮影し、UI・UX設計と見比べる |
| バックグラウンドで再生が続く | 再生中に他のアプリへ切り替え、音が続くことと、アプリがMediaPlaybackの権利を持ち続けることを確かめる |
| 実機での動作 | 実機で、ライブラリの曲の選択と再生（一度測った曲は、アプリの再起動後も測り直さずに鳴り始める）、再生中の回転、書類の選択（このiPhone内・iCloud Drive・OneDrive）、ロック中の再生、中断（電話・他のアプリの音声）からの一時停止、Bluetoothの接続の変化での停止、ロック画面の表示がアプリ名だけであることを確かめる |

## 6. 参照

- [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)
- [MPMediaPickerController](https://developer.apple.com/documentation/mediaplayer/mpmediapickercontroller)・[MPMediaQuery](https://developer.apple.com/documentation/mediaplayer/mpmediaquery)
- [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)・[MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
- [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
