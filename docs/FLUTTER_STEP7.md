# Flutter step 7：CIと配布用ビルドの準備（項目1・2）

Flutter／Androidの解析・テスト・ビルド・AVD統合試験をGitHub Actionsへ追加し、試験用previewと配布用productionを分離する。実サービスへの投稿、既存iPhoneアプリの更新、mainへの統合はこの工程に含めない。

## ビルドの区分

| 対象 | preview | production |
|---|---|---|
| Android ID | 既存の`dev.example.index_relay_probe` | ビルド時の明示指定が必須 |
| 表示名 | Index Relay Preview | Index Relay |
| バージョン初期値 | 0.11.0／32 | 0.11.0／32、CLIで上書き可 |
| ABI | ARM64、CIではx86_64 | ARM64 |
| 対象OS | Android 8以降、実受信は12以降 | Android 12以降 |
| 試験音声・補正の正解データ | 同梱 | 除外 |
| 模擬受信・技術確認 | 表示 | 非表示・ネイティブ入口も拒否 |
| DUMP保護の注入ハーネス | previewDebugだけ | productionDebugにも含めない |
| Release署名 | プレビュー用debug鍵 | 専用の署名設定、または明示した未署名検証 |

Flutterのasset flavor機能でモデルをAndroidのpreview／productionへ限定する。iOSはflavorなしでビルドし、Android用の約148MBのWhisperモデルと試験音声を含めない。iOSの試験用probeチャネルはDEBUGだけで登録する。元のSwiftサービス・既存データ形式・Keychainを変更しない。iOSの実機更新は別工程で行う。

根拠：[Flutterのflavorとasset設定](https://docs.flutter.dev/deployment/flavors)、[Androidのビルドと署名](https://docs.flutter.dev/deployment/android)。

## モデルとライセンス

AndroidはWhisper base multilingualをAPKへ同梱し、認識時のダウンロードやクラウド認識への切替は行わない。準備時とAPK検査でSHA-256 `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`、サイズ147951465バイトを照合する。モデルの固定取得URLとFlutter SDK配布物のハッシュは`flutter_probe/toolchain-lock.json`に記録する。モデル自体はGitへコミットしない。APKは約155MBになる。

「アプリ情報・ライセンス」に独自MIT、whisper.cpp、Whisperモデル、Android依存、Flutter／Dartパッケージの通知を表示する。Maven解決結果の座標と、レビュー済みの`ThirdPartyNotices/Android-runtime-dependencies.json`を比較し、変更時はライセンス表記の見直しを要求する。Apache-2.0、SLF4JのMIT、FlutterのBSD全文を同梱する。Haversineに含まれるネイティブコンポーネントの表記は配布元POMの情報に基づくもので、未公開部分のソース再現性を保証するものではない。

モデルの配布元：[ggerganov/whisper.cppのモデル情報](https://huggingface.co/ggerganov/whisper.cpp)、[OpenAI WhisperのMITライセンス](https://github.com/openai/whisper/blob/main/LICENSE)。モデル更新はコード上のハッシュ・配布条件の確認とテストを伴う変更として扱う。

## 署名なしの検証APK

SDK、固定ソース、モデルは`flutter_probe/README.md`で準備する。準備スクリプトはFlutterの検証済みWrapperもGit対象外の場所へ復元する。

```sh
python3 scripts/prepare-app-notices.py
python3 scripts/build-android-release.py \
  --application-id dev.example.indexrelay.releasecheck --unsigned
```

これは検査専用のIDを使う未署名APKで、そのままインストール・公開するものではない。生成先：`flutter_probe/build/app/outputs/flutter-apk/app-production-release.apk`、検査結果：`work/android-release/audit.json`。

検査は試験音声・正解データ・注入クラス・Debug専用HTTP設定の不在、モデルのサイズ／ハッシュ、ライセンス、ABI、アプリID／バージョン／番号、非debuggable／バックアップ無効、署名の状態を確認する。APK／AAB／JKS／keystoreは公開ファイル検査でも拒否する。

## 配布用IDとアップロード鍵を設定するとき

Android IDは公開前に所有・使用する名前を決め、以後の更新で維持する。既存previewのIDを勝手に本番用へ流用しない。`flutter_probe/android/release-signing.example.properties`を`release-signing.local.properties`へコピーし、リポジトリ外の鍵ファイルとaliasを設定する。パスワードはファイルへ書かず、環境変数`INDEX_RELAY_KEYSTORE_PASSWORD`／`INDEX_RELAY_KEY_PASSWORD`で渡す。

```sh
python3 scripts/build-android-release.py \
  --application-id your.owned.application --version 0.10.0 --build-number 31
```

このコマンドは署名設定がなければ失敗する。productionReleaseにdebug鍵への自動フォールバックはない。今回は実鍵の作成・登録・署名配布は行わない。Play向けAAB生成・アップロードとストア登録は別途実施する。

iOSは既存の`Migration.local.xcconfig`でBundle ID／Teamを照合し、`INDEX_RELAY_DISPLAY_NAME = Index Relay`も指定できる。初期値は既存アプリを置き換えないPreviewのID・表示名を維持する。ビルド番号を既存アプリより上げ、データ退避と復旧手順を確認してから更新する（[step 4](FLUTTER_STEP4.md)）。

## GitHub CI

`.github/workflows/flutter-android.yml`は対象ファイルのpush／PRと手動実行で起動する。Ubuntu 24.04、JDK 17、Android API 36、固定Flutter／NDK／CMakeを使う。checkout v7.0.1、upload-artifact v7.0.2は公式GitHub APIで照合したコミットSHAへ固定する。PRに署名鍵や本物のBotトークンは渡さず、checkoutの資格情報も保持しない。CIでは配布用署名を行わない。

1. Flutter解析・書式検査・previewの16テスト、productionの除外確認2テスト。
2. Kotlin単体テスト10件と依存座標の照合。
3. ARM64 productionの未署名APKを作成し、同梱物・モデル・ID等を検査。
4. x86_64の専用AVDを起動し、Flutter画面・ネイティブ状態・JNIロードを確認。
5. ネイティブ送信キュー、Keystore、WorkManager、模擬HTTP APIを使い、確認あり／なし・複数先・429・結果不明・復旧・削除との競合を確認。
6. ハッシュと検査結果、合成データだけの試験結果・所要時間をArtifactへ保存。保持期間は7日。約155MBの未署名APKは手動実行で`upload_apk=true`を選んだ場合だけ保存し、保持期間を1日とする。

LinuxのCI音声fixtureは合成トーンであり、日本語音声ではない。CIの送信試験は`--skip-speech-check`を指定し、実Whisper認識成功の欄をfalse、固定テキストでの経路確認をtrueとして記録する。これを音声認識精度や実BLEの証明には使わない。macOSのKyoko合成音声による実認識と、ARM64 AVDでの受信試験はローカルで継続する。

GitHub-hosted Linux runnerはAndroidのハードウェアアクセラレーションに対応する（[runnerの説明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)）。CI専用の使い捨て環境だけで不要な.NET／Haskell／古いAndroid SDK等を整理し、SDK準備前に20GiBの空き容量を要求する。ローカル／self-hosted環境ではこの整理処理を拒否する。AVDは特定の端末定義へ依存せず、作成先と探索先を`work/flutter-ci/avd`へ固定する。CIはKVMの存在を確認し、起動期限5分・ジョブ期限40分で停止する。実際の所要時間は`work/flutter-ci/evidence.json`に記録し、試験失敗時にも取得済みの検査結果とエミュレーターの診断ログを保存する。Artifactの閲覧にはPrivateリポジトリの読取権限が必要（[GitHubの説明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)）。

## ローカルの確認

```sh
cd flutter_probe
flutter test --flavor preview
flutter test --flavor production test/release_surface_test.dart
flutter test --flavor preview integration_test/ci_smoke_test.dart -d emulator-5554
flutter test --flavor preview integration_test/relay_flow_test.dart -d emulator-5554
flutter build apk --flavor preview --debug --target-platform android-arm64
cd android
./gradlew :app:testPreviewDebugUnitTest
cd ../..
python3 scripts/test-android-delivery.py --device emulator-5554 --reset-test-data
python3 -m unittest discover -s tests/ReleasePackaging -v
```

AVDの試験は個人データのない専用環境で行い、プレビューアプリのデータを初期化する。実サービスへの投稿確認、Android実機のBLE／ロック中動作、iPhone実機更新は引き続き未検証。


## 実施結果（2026-10-22 JST）

コードコミット`23f20c8d54eb4b39073ed146c15f68fb4acc62b7`で[Flutter／Android CI](https://github.com/yutacar/index-relay/actions/runs/39628066032)と[既存Swift／公開ファイル検査CI](https://github.com/yutacar/index-relay/actions/runs/39628066068)が成功した。証跡は[FLUTTER_STEP7_EVIDENCE.json](FLUTTER_STEP7_EVIDENCE.json)に保存する。以後の結果資料だけのコミットは、この検証済みコードとは区別する。

| GitHub Actionsでの確認 | 結果 |
|---|---|
| Flutter解析・書式 | 成功 |
| preview／production画面テスト | 16件／2件成功 |
| Kotlin単体テスト | 10件成功 |
| 配布ポリシーテスト | 8件成功 |
| ARM64 production APK | 未署名・同梱物／ID／モデル／ライセンス検査成功 |
| API 36 x86_64 AVD | 起動・Flutter画面・JNI・模擬送信キュー試験成功 |
| ジョブ全体 | 18分05秒 |
| AVD起動／Flutter統合／模擬送信 | 58.04秒／99.81秒／90.20秒 |

ローカルのAPI 36 ARM64 AVDでは、Kyoko合成音声を実際にWhisperで認識し、模擬APIへの送信まで確認した。既存Flutter統合2件と追加smoke 1件、Swiftコア506チェック、既存Python48テスト、ブリッジ通信マーカー照合も成功した。x86_64向けJNIのクロスビルドとELFのABI照合、productionDebugでの試験資産・注入クラス除外も確認した。

iOSは署名なしReleaseビルドに成功し、モデル・試験音声を除外して共通ライセンスを残すことを確認した。Androidの未署名APKは約155.9MB。実鍵による署名、実サービスへの投稿、Android実機でのBLE／ロック中動作、iPhone実機の更新は行っていない。CI内の音声認識検証はfalseのままで、固定テキストの送信試験を認識精度の証明には使わない。
