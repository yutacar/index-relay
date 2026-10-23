# Flutter／Android step 1・2 の結果（2026-10-21）

## 判定

両ステップを完了。FlutterとAndroid環境を準備し、HaversineのAndroid依存・APIのコンパイル、Androidエミュレーター内での日本語WAVの実認識、iOS既存バックエンドへのFlutter接続を確認しました。次のUI・保存層の移植へ進めます。

既存iOS 0.9.7とmainのファイルは置き換えていません。作業ブランチは`codex/flutter-android-spike`。試作は`flutter_probe/`です。

## step 1：開発環境

- Flutter 3.47.7／Dart 3.13.5をApple Silicon向け公式配布から取得し、公式SHA-256を照合。
- Android SDKコマンドラインツール23.0、platform-tools、API 36、build-tools 36.0.0、Emulator 37.2.12、ARM64 API 36 AVD、NDK 28.2.13676358、CMake 3.22.1、既存JDK 17を準備。
- Android Studioは導入せず、CLIでビルド・実行できる構成。Flutterの解析送信は無効化。
- SDK・AVD・キャッシュはこのタスクの`work/flutter-android/`に配置。端末向けアプリへSDKや開発環境パスを埋め込みません。
- Flutter doctorのAndroidツールチェーンは正常。CocoaPodsの警告は残りますが、この試作はSwift Package Manager経由でiOSシミュレーターのビルド・実行に成功しています。
- [保存・投稿・保護の移行条件](FLUTTER_MIGRATION_CONTRACT.md)を明文化。

## step 2：技術試作

### Haversine Android

`io.github.coredevices.haversine:haversine:2541a33`を解決し、Android AARのSHA-256を公開Gradleメタデータと照合しました。Android用マネージャーのコンストラクターを呼ぶ関数をコンパイルし、AVD上でクラス参照が解決することを確認しています。

マネージャー生成関数は実行しません。スキャン・ペアリング・実音声転送・音声デコード・受信位置の更新・削除・DFUは未検証です。単なる依存解決を実BLE動作確認とは扱いません。

### 日本語の端末内文字起こし

Whisper v1.9.5の固定コミットと多言語baseモデルを使用。モデルSHA-256は取得先のLFS値と一致し、Android側でも認識前に照合します。CPU上のJNI処理をワーカースレッドで実行し、ネットワーク認識へ切り替えるコードはありません。

- 入力：macOS Kyokoによる既知の合成文、16kHz／mono／PCM16、114692サンプル（約7.17秒）。
- 期待文：「これはインデックスリレーの動作確認です。録音した音声を文字に変換します。」
- 実結果：「これはインデックスリレーの動作確認です。6音した音声を文字に変換します。」
- 最適化後の統合テスト内の認識時間：1553ms。通常のDebug画面からの実行は23272msと15004msでした。モデル初回展開とハッシュ確認の時間は含みません。計測差は未解明で、性能の判断は保留します。
- Wi-FiとモバイルデータをオフにしたAVDで成功。計算速度はこのMac上のAVDの値で、Android実機の性能保証ではありません。
- 「録音」が「6音」になる誤認識あり。日本語全般の精度合格とはせず、技術的にファイル入力→実認識→結果取得できたという判定です。

初回の最適化なしDebugライブラリは209063msでした。認識ライブラリをRelease最適化し、対象を今回のARM64 AVDに絞りました。

統合試験で再インストール後のモデル消失も確認したため、試作では照合済みモデルをGit対象外のオフラインassetとしてAPKへ含めます。モデル・音声・APK・キャッシュはGitに登録しません。配布版のモデル準備UIや更新は別工程です。試作APKは約222.6MiBあります。

### iOS接続

既存のSpeechFileTranscriber.swiftとTranscriptArchive.swiftをXcodeから直接参照し、Flutterのチャネル経由でバックエンドと利用可否へ到達することをiOS 26.5シミュレーターで確認しました。iOS向けビルドと統合テストが成功しています。新しいFlutter UIでの実認識・自動受信・ロック中動作までは試験していません。

## 検証

- Flutter analyze：問題なし。
- Flutter Widget：2テスト成功。
- Android統合：2テスト成功（不正WAVの拒否、Haversineクラス参照と日本語の実認識）。
- iOS統合：1テスト成功（Flutter→既存Swiftバックエンドの接続）。
- Android Debug APK、iOSシミュレーター向けDebugビルド成功。
- 既存Swift：12スイート・506チェック成功。
- 既存Publication：8テスト成功。既存iOSブリッジの両スライスは通信静的基準内。
- [機械可読の結果](FLUTTER_SPIKE_EVIDENCE.json)も保存。

実機受信、Android常駐、履歴保存と送り先UIのFlutter移植、本番更新時の保存情報移行は次工程です。今回の試作に履歴蓄積・実投稿機能はありません。

## 再現

[試作README](../flutter_probe/README.md)と`scripts/prepare-flutter-probe.py`を参照してください。Flutter用の試験は手動実行で、既存CIは従来のSwift／Pythonの検査です。
