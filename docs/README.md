# LC Music Player 文書一覧

[README](../README.md)に戻る。

このディレクトリでは、LC Music Player（LCMP）のビルド手順と設計書を管理します。

## ビルドと配布

- [ビルド・配置手順](build-and-deploy.md)：必要な環境、ビルドコマンド、ZIPとインストーラー（DMG）の作成と検証、テスト、問題の切り分け。

## 設計書

設計書は`design/`に置き、基本設計から実装設計・開発ガイド・依存構成の順に2桁の番号を付けます。

| 文書 | 内容 |
| --- | --- |
| [00 基本設計](design/00_basic-design.md) | 製品の目的、機能要件、機能構成とデータの流れ、画面構成、品質方針 |
| [01 UI・UX設計](design/01_ui-ux-design.md) | メイン画面、拡張画面、シーク、縦型音量、設定、状態の伝え方 |
| [02 基本再生機能の実装設計](design/02_playback-implementation.md) | 単曲再生の構成、対応形式、ファイルアクセス、状態遷移、シーク、音量、デコーダの選択 |
| [03 ライブラリ・プレイリストの実装設計](design/03_library-implementation.md) | 保存・復元、ブックマーク、再生順序、M3U8交換、リスト表示、終了処理 |
| [04 再生前処理の実装設計](design/04_preprocessing-implementation.md) | 次曲の先頭PCM、全曲測定、プレイリストの事前測定と優先度・省電力、取消とファイルアクセス |
| [05 前処理測定結果の永続キャッシュ](design/05_measurement-cache-implementation.md) | SQLiteの保存形式、識別と失効、Audit、容量の回収 |
| [06 音量自動調整の実装設計](design/06_volume-normalization-implementation.md) | 全曲LUFS/true peakの測定、固定ゲインの算出、処理段の順序、再生準備と設定 |
| [07 周波数解析の実装設計](design/07_analysis-implementation.md) | 解析データ、音声の取得、時刻情報と将来の同期補償の契約 |
| [08 可視化の実装設計](design/08_visualization-implementation.md) | 16列の蛍光管LED、提示時刻・残光・欠落、表示の寿命と描画の測定 |
| [09 コンパクト画面の実装設計](design/09_compact-ui-implementation.md) | ウィンドウの配置、シークと音量、キーボードと支援技術、設定タブ、ライセンスウィンドウ |
| [10 Player UI・可視化の開発ガイド](design/10_player-ui-developer-guide.md) | `LCMP_default_GEQ`のフォルダ構成、モジュール間のI/F、新しいUI・可視化の追加手順 |
| [11 依存ライブラリと同梱構成](design/11_third-party-dependencies.md) | 依存を持たない構成、署名と権限、ライセンス表示、脆弱性の確認 |
| [12 オコジョ合唱団の実装設計](design/12_ermine-chorus-implementation.md) | 原画と中割り、キャラクタごとの演出、音域と感度、セルの描画、時計と寿命 |
| [13 iPhone版の実装設計](design/13_iphone-implementation.md) | 共用部分のOS分岐、画面の枠と配置、音声セッションとバックグラウンド再生、ウィジェットとURLスキーム、ファイルの選択、ビルド |
| [14 教育番組（パペット）の実装設計](design/14_puppet-show-implementation.md) | 背景の時刻と層、パペットの組み立てと演出、素材の切り出し、Metalでの描画、時計と寿命 |
| [15 曲の地図（拍とボーカル）の実装設計](design/15_track-map-implementation.md) | 拍とボーカルの地図と保存形式、解析の方式と差し替え、前処理・キャッシュとの関係、再生中の使い方、実際の曲での評価 |
| [16 重低音の強調の実装設計](design/16_bass-enhancement-implementation.md) | 低域の立ち上がりを強める段、遅延の契約、ピークの保護、段階の変更 |
| [17 Last Century ラジカセの実装設計](design/17_radio-cassette-implementation.md) | カセットテープの動き、インディケータの表記と情報源、レベルメーター、Core Animationでの省電力の描画 |

## 設計書の書き方

- 00・01は製品の仕様として、「目的 → 機能要件 → 画面 → 品質方針」の順に書きます。
- 02〜17の実装設計は、「概要 → 要件 → 方式 → 実装 → 検証 → 参照」の順に書きます。書くことがない章は省きます。

| 章 | 書くこと |
| --- | --- |
| 概要 | その機能が何をするか、対象範囲、前提 |
| 要件 | 満たすべき仕様（挙動・数値・制約） |
| 方式 | 要件をどう実現するか。部品の分担と外部I/F、データの流れ |
| 実装 | 採用した技術・アルゴリズム・状態遷移・資源の寿命など、具体的な処理 |
| 検証 | 何を正解とするか（合格基準）と、その確かめ方（自動テスト・手動確認・性能測定） |
| 参照 | 外部の規格・APIの資料 |

- 設計書の本文は「である」調、利用者向けの文書（README・ビルド手順・アプリに同梱する11）は「です・ます」調で書きます。
- 設計書には、合意した仕様と実装済みの設計だけを書きます。チケット番号、作業の経緯、検証の実施結果は書きません。
