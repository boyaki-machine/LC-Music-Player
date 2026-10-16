# LC Music Player 設計書

[ビルド・配置手順](./build-and-deploy.md)は開発・ローカル配布の入口です。設計書は`design/`配下へ、基本設計から実装・開発ガイド・依存構成の順に2桁の番号を付けて配置します。

このディレクトリでは、LC Music Player（LCMP）で目指す製品の仕様と、実装の構造・動作を管理します。

- [基本設計](design/00_basic-design.md)：製品の目的、対象プラットフォーム、機能構成、再生・可視化の流れ、画面構成。
- [UI・UX設計](design/01_ui-ux-design.md)：コンパクトなメイン画面、拡張画面、シーク、縦型音量、macOSの操作と将来のiPhone共用方針。
- [基本再生機能の実装設計](design/02_playback-implementation.md)：単曲再生の責務分担、対応形式、状態遷移、ファイルアクセス、音量・出力、検証方法。
- [ライブラリ・プレイリストの実装設計](design/03_library-implementation.md)：JSON保存・復元、ブックマーク、M3U8交換、順次再生、音源管理。
- [再生前処理の実装設計](design/04_preprocessing-implementation.md)：次曲の先頭PCM、プレイリスト全曲の背景測定、背景処理・取消・音声処理へのI/F。
- [前処理測定結果の永続キャッシュ](design/05_measurement-cache-implementation.md)：SQLite・ハッシュ索引・識別/失効、音源ID対応のAudit、OS別境界。
- [音量自動調整と前処理拡張の設計](design/06_audio-processing-design.md)：全曲LUFS/true peakの追加測定、固定ゲイン算出、測定待ちと設定・出力条件の契約。測定・固定ゲインは実装済み、EQ/同期delayは将来の構成として区別する。
- [周波数解析の実装設計](design/07_analysis-implementation.md)：解析データ、更新設定、音声取得、時刻情報と将来の同期補償の接続点。
- [可視化の実装設計](design/08_visualization-implementation.md)：16列蛍光管LED、提示時刻・残光・欠落、表示の寿命と描画測定。
- [コンパクト画面の実装設計](design/09_compact-ui-implementation.md)：ウィンドウ配置、LED、操作・フォーカス、シークと縦型音量。
- [Player UI・可視化の開発ガイド](design/10_playerUI_developers.md)：`LCMP_default_GEQ`のフォルダ構成、モジュール間I/F、状態と時刻の契約、新しいUI・可視化の追加手順。
- [依存ライブラリ](design/11_third-party-dependencies.md)：バージョン固定、動的リンク、ライセンス表示、アプリへの同梱構成。

設計書には合意した仕様と実装設計を記載します。進捗、選定の経緯、未決事項、チケットへの引き継ぎ、検証の実施結果は、リポジトリ直下の`DEVELOPMENT_NOTES.md`に記録します。このファイルはローカル専用で、Git管理対象外です。ファイルが存在する環境でのみ参照してください。
