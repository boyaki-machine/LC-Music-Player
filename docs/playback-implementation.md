# 基本再生機能の実装設計

[設計書一覧](./README.md)に戻る。

本書は、`Sources/LCMPApp`と`Sources/PlaybackCore`にある単曲再生機能の構造と動作を記述します。製品で目指す機能構成は[基本設計](./basic-design.md)に記載します。

## 1. 構成と責務

対象はmacOS 14以降です。画面はSwiftUI、ファイル選択はNSOpenPanel、再生はSFBAudioEngine 0.14.0を使用します。依存バージョンは`Package.resolved`で固定します。

| 構成要素 | 責務 |
| --- | --- |
| `Sources/LCMPApp` | 単一ウィンドウ、ファイル選択、ファイル名・状態・時間・操作・エラーの表示 |
| `PlaybackController` | 選択と再生状態、操作、音量、エラーの管理 |
| `LocalFileAccess`／`FileLease` | 通常ファイルの読み取り確認とsecurity-scoped accessの保持・解放 |
| `PlaybackBackend` | 再生ライブラリに依存しない操作と通知のインターフェース |
| `SFBAudioBackend` | SFBAudioEngineによる再生、アプリ内音量、delegate通知の受け渡し |
| `AudioDecoderFactory` | PCMデコーダの生成・読み込みとM4A互換処理 |

UIは再生ライブラリを直接操作しません。`PlaybackController`が`PlaybackBackend`を通じて再生を制御します。OS依存のファイルアクセスもUIと再生制御から分離します。

## 2. 対応音源とファイルアクセス

| ファイル | 対応内容 |
| --- | --- |
| MP3（.mp3） | MP3音源 |
| M4A（.m4a） | DRMのないAAC／ALAC音源 |
| WAV（.wav） | PCM音源 |
| AIFF（.aif / .aiff） | PCM音源 |
| FLAC（.flac） | 可逆圧縮音源 |

WAV・FLACの24bit／96kHz入力を扱います。出力条件はOSと出力機器に依存し、入力と同じサンプルレート・ビット深度の出力を保証しません。

拡張子の対応判定に加え、通常ファイルで読み取り可能なことと、デコーダで読み込めることを確認します。同じ拡張子の破損ファイルも読み込み失敗として扱います。

NSOpenPanelはファイルを1つ選択し、元ファイルのURLを再生制御へ渡します。音源の複製・移動は行いません。選択が有効な間は`FileLease`がsecurity-scoped accessを保持し、差し替えや終了時に解放します。再生を停止しただけでは選択を解除しません。選択URLやブックマークの永続化は行いません。

ファイル選択はトランザクションとして扱います。新しい音源の読み込みに成功してから、元の再生を停止して選択を差し替えます。選択取消・選択失敗では、元の音源と再生状態を維持して取消または理由を表示します。

## 3. 再生状態と操作

| 状態 | 意味 |
| --- | --- |
| `empty` | 有効な音源が選択されていない |
| `ready` | 選択音源を読み込み、再生を開始できる |
| `playing` | 再生中 |
| `paused` | 再生位置を保持して一時停止中 |
| `stopped` | 停止中。再生すると先頭から開始する |
| `finished` | 自然終了。再生すると先頭から開始する |
| `failed` | 再生が失敗して停止した。再試行できる |

- ファイルを選択しただけでは自動再生しません。
- 再生ボタンまたはSpaceは、再生中なら一時停止、一時停止中なら同じ位置から再開、それ以外は先頭から再生します。
- 停止は再生位置を先頭へ戻し、選択音源を保持します。
- 自然終了では`finished`へ遷移し、表示時間を音源の長さに合わせます。
- 再生失敗では再生を停止し、理由を表示します。選択音源は保持して再試行を受け付けます。
- 音声出力の設定変更通知では停止し、利用者の再生操作で先頭から再開します。

UIに渡す状態とイベントはmain actorで処理します。SFBAudioEngineのdelegateからは、デコーダオブジェクトを渡さず、終了・失敗・出力変更のイベントを受け渡します。

再生開始ごとにプレイヤーとデコーダを生成し、停止時にその再生世代を無効化します。選択・停止・再再生をまたいだ古い通知が、新しい状態を上書きしないようにします。プレイヤーへ渡したデコーダの所有権は再生ライブラリへ移し、アプリから変更しません。

## 4. 音量と音声出力

音声はmacOSの既定出力先へ送ります。アプリ内音量はmain mixerの`outputVolume`で0〜1に調整します。初期値は0.25です。非有限値は受け付けず、範囲外の値は0〜1へ制限します。

OSのシステム音量やデバイスのサンプルレートを変更するAPIは使用しません。単曲再生の音量値はアプリの実行中に保持し、永続化しません。製品のデバイス別音量仕様は[基本設計](./basic-design.md)に記載します。

## 5. M4Aの読み込み互換処理

`AudioDecoderFactory`はSFBAudioEngineのデコーダ生成とopenを使用します。M4Aの読み込みが、下位の`NSOSStatusErrorDomain`のeofErr（-39）で失敗した場合に限り、AVAudioFileでPCMを読み取る`PCMDecoding`アダプターへ切り替えます。

アダプターは元音源がAAC／ALACであることを確認します。それ以外の形式や読み込み失敗を正常扱いしません。PCMの再生は引き続きSFBAudioEngineが担当します。依存ライブラリのソースは変更せず、互換処理をアプリ側のデコーダ生成に集約します。

## 6. エラーの扱い

| エラー | 表示・制御 |
| --- | --- |
| `unsupportedFormat` | 対応形式を案内し、不正な再生要求を送らない |
| `inaccessibleFile` | ファイルの場所とアクセス権の確認を案内する |
| `loadingFailed` | 読み込みの失敗理由を表示する |
| `playbackFailed` | 再生を停止し、理由と再試行可能な状態を示す |

選択段階のエラーでは既存の再生を維持します。再生段階のエラーでは、同期・非同期のどちらも再生制御へ通知して停止します。

## 7. 検証方法

### 自動検証

```sh
./scripts/swift.sh test
LCMP_TEST_AUDIO_OUTPUT=1 ./scripts/swift.sh test
python3 scripts/build-app.py
```

通常のテストは音声を出力しません。出力テストは既定出力先へ小さい正弦波を送ります。検証対象は状態遷移、失敗・取消、遅延通知、アクセス解放、元ファイル不変、対応形式のデコード・再生終了、一時停止・再開・停止・再再生です。システム音量の比較はデバイスから読み取れる場合に行い、比較の可否をログへ出力します。

テスト音源は独自の正弦波です。開発ビルド後に`python3 scripts/generate-fixtures.py Tests/PlaybackCoreTests/Fixtures`で再生成できます。手動確認用の音源は`python3 scripts/generate-fixtures.py build/manual-audio --duration 12`で生成します。

### 操作と出力の確認

1. `python3 scripts/build-app.py`でアプリを作成し、`open build/LCMP.app`で起動する。
2. 「ファイルを選択…」またはCommand＋Oから対応音源を選び、ファイル名の表示を確認する。
3. 再生、Spaceによる一時停止・再開、停止、自然終了後の再再生を試し、音声と再生位置を確認する。
4. 再生中に選択画面をキャンセルし、現在の再生が維持されることを確認する。
5. 再生中に`broken.wav`を選び、失敗理由の表示と元の再生が維持されることを確認する。
6. 別の有効な音源を選び、元の再生が停止し、新しい音源が再生待ちになることを確認する。
7. 音量操作がアプリ内音量にのみ作用することを確認する。複数の出力先では切替・切断時の停止・通知・再試行も確認する。

自動テストの再生終了とは別に、実際の可聴性・音質を聴感で確認します。

## 8. 参照資料

- [SFBAudioEngine 0.14.0](https://github.com/sbooth/SFBAudioEngine/tree/0.14.0)。
- [SFBAudioEngineの再生インターフェース](https://github.com/sbooth/SFBAudioEngine/blob/0.14.0/Sources/CSFBAudioEngine/include/SFBAudioEngine/SFBAudioPlayer.h)。
- [依存ライブラリの構成](./third-party-dependencies.md)。
