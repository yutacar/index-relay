# Index Relay Flutter版（iOS／Android）

Flutter対応完了版は`codex/flutter`で管理します。アプリ版は0.12.1／34です。ディレクトリ名`flutter_probe/`はビルド・スクリプトの参照を維持するため残しています。[対応状況と管理方針](../docs/FLUTTER_STATUS.md)。

iOSは既存のSwiftサービスとKotlin/Native受信ブリッジへ接続します。履歴・連携状態・音声詳細をFlutterで表示し、歯車から既存のリング・送り先・送信一覧を開きます。実機で録音受信・文字起こし、ロック解除後の復帰、自動受信オフ→オン後の再開を確認済みです。同じBundle IDで既存版を更新する際は、[移行手順](../docs/FLUTTER_IOS_MIGRATION_READY.md)に従って退避・署名を確認します。

AndroidはBLE受信アダプター、通知付き受信サービス、WorkManagerによる文字起こし、資格情報保存と投稿をKotlinで実装しています。エミュレーターでは合成音声の保存・認識と、Discord／Telegramグループへの確認あり・自動送信（各2件の到着）を確認済みです。Android実機のBLE通信・ロック中動作は未確認です。構成は[step 5](../docs/FLUTTER_STEP5.md)、投稿は[step 6](../docs/FLUTTER_STEP6.md)と[実送信記録](../docs/FLUTTER_LIVE_DELIVERY.md)を参照してください。

## ソースを取得する

```sh
git clone --branch codex/flutter https://github.com/yutacar/index-relay-public.git
cd index-relay-public
```

以降、`cd flutter_probe`まではリポジトリ直下で実行します。

## 固定した環境

Apple Silicon macOS、Flutter 3.47.7／Dart 3.13.5、JDK 17、Android API 36 ARM64。Android SDKにplatform-tools、emulator、platforms;android-36、build-tools;36.0.0、system-images;android-36;google_apis;arm64-v8a、ndk;28.2.13676358、cmake;3.22.1を導入します。Android Studio自体は不要です。SDKの標準ライセンス受諾が必要です。

[toolchain-lock.json](toolchain-lock.json)にバージョン・直接取得した配布物のSHA-256を記録しています。GradleはFlutter生成の9.3.1を使用し、既存iOSブリッジ用8.14.3の設定を変更しません。依存バイナリ・SDK・モデルはGitに含めません。iOSはXcodeとiOS 26以降のシミュレーターが必要です。

## 準備

以下のパスを自分の環境へ合わせます。FLUTTER_SDKはFlutterのbinを含むディレクトリです。

```sh
export FLUTTER_SDK=/path/to/flutter
export ANDROID_HOME=/path/to/android-sdk
export JAVA_HOME=/path/to/jdk17/Contents/Home
export WHISPER_SOURCE=/path/to/whisper.cpp
export WHISPER_MODEL=/path/to/ggml-base.bin
export PATH="$FLUTTER_SDK/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"

flutter --disable-analytics
flutter config --android-sdk "$ANDROID_HOME" --jdk-dir "$JAVA_HOME"
sdkmanager --licenses
sdkmanager 'platform-tools' 'emulator' 'platforms;android-36' 'build-tools;36.0.0' \
  'system-images;android-36;google_apis;arm64-v8a' 'ndk;28.2.13676358' 'cmake;3.22.1'

git clone --branch v1.9.5 --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WHISPER_SOURCE"
curl -fL https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin -o "$WHISPER_MODEL"
python3 scripts/prepare-flutter-probe.py --flutter-sdk "$FLUTTER_SDK" \
  --android-sdk "$ANDROID_HOME" --whisper-source "$WHISPER_SOURCE" --model "$WHISPER_MODEL"
cd flutter_probe
flutter pub get --enforce-lockfile
flutter analyze
flutter test --flavor preview
flutter build apk --flavor preview --debug --target-platform android-arm64
```

準備スクリプトはWhisperのコミット・未改変の追跡ファイル・モデルハッシュを検証し、macOSのKyoko音声で16kHz／mono／PCM16の試験WAVを生成します。個人の録音をコピーしません。モデルと音声・local.propertiesはコミット対象外です。モデルの検証後はネット接続なしで認識できます。ライブラリ・モデルの初回取得とSDK準備には通信します。

## Androidエミュレーターで実認識

```sh
printf 'no\n' | avdmanager create avd -n index_relay_api36 \
  -k 'system-images;android-36;google_apis;arm64-v8a' --device pixel_8
emulator -avd index_relay_api36 -gpu swiftshader -no-snapshot
```

別ターミナルで起動完了後に実行します。試作では準備スクリプトで照合したモデルをGit対象外のFlutter assetに配置し、APKへ同梱します。初回認識時にアプリ内保存領域へ展開してハッシュを再確認します。統合テストごとのアプリ再インストールでもモデルを準備でき、認識時のダウンロードは不要です。モデルだけで約148MBあるため試作APKは大きくなります。モデル準備UIと検証結果は[互換性と初回設定](../docs/FLUTTER_ANDROID_COMPATIBILITY.md)を参照してください。

```sh
adb -s emulator-5554 shell svc wifi disable
adb -s emulator-5554 shell svc data disable
flutter test --flavor preview integration_test/probe_test.dart -d emulator-5554
flutter run --flavor preview -d emulator-5554
```

ホームは新しい順の履歴と時刻・処理状態を表示します。歯車から表示件数、送信前確認、送り先候補、模擬受信、技術確認を開きます。模擬受信は何度でも追加でき、既定では最新30件を保持します。編集で複数選択・全選択削除、左スワイプで個別削除できます。削除確認は出しません。ⓘから標準補正の再生とWAV保存ができます。AndroidのSDK確認はHaversineクラスを解決します。実受信時には通知付きネイティブサービスがマネージャーを生成します。SDKロード成功をIndex01接続成功とは扱いません。

認識はKotlinからJNI経由でwhisper.cppを呼び、CPUで日本語として処理します。認識ライブラリはFlutterのDebugビルドでもRelease最適化を有効にしています。認識処理をUIスレッドで動かしません。PCM16 mono、最長5分の入力に対応し、元レートを保持した原音から16kHzへ変換します。5分の実録音の性能は未確認です。認識結果・処理状態・設定はAndroidネイティブのSQLiteへ保存します。Flutterは保存ファイルを直接更新しません。アプリ再起動後は中断した認識を待機へ戻して再開します。送信中の処理を回収できなければ結果不明とし、自動再送しません。送り先はAPIで照合し、資格情報はKeystoreによる暗号化保存へ接続します。確認あり／なしを新規ジョブへ適用し、確認待ち・再試行待ち・結果不明を送信一覧で操作できます。送り先の追加や有効化だけで過去の文章を投稿しません。空結果・不正音声・モデル不足は失敗として扱います。自動的にクラウド認識へ切り替えません。

統合テストは既知の合成文に「動作確認」「音声」「文字」が含まれることを検査します。日本語全般の精度保証ではありません。試験ログへ出す認識結果はこの合成文だけです。

## iOS接続の確認

```sh
flutter build ios --simulator --debug --no-codesign
flutter test integration_test/capabilities_test.dart -d <iOS-simulator-id>
```

既存のSwiftサービスとKotlin受信フレームワークを直接参照するため、先に`docs/BUILD.md`の手順でフレームワークを準備してください。認識機能・モデルが利用できないシミュレーターでは利用不可として扱い、偽の認識結果に置き換えません。試験方法と残る範囲は[step 4](../docs/FLUTTER_STEP4.md)に記載しています。

## 依存のライセンス

Flutterの生成コードとSDK、Haversine（Apache-2.0）、whisper.cpp（MIT）、モデルの配布条件はそれぞれに従います。whisper.cppのソースとLICENSEは外部の固定checkoutで保持します。本番への配布に進む際は同梱ネイティブバイナリのライセンス文書・モデル配布条件を改めて整備します。この試作APKは公開配布しません。

Flutter／Androidの検査・配布用ビルドの準備は[step 7](../docs/FLUTTER_STEP7.md)を参照してください。既存のSwift／Python CIも継続します。標準のprepare-github.pyは既存のネイティブiOS版だけを書き出し、Flutterアプリを含めません。Flutter版のソース一式は`codex/flutter`ブランチをcloneしてください。

## step 3の統合試験

```sh
flutter test --flavor preview integration_test/relay_flow_test.dart -d emulator-5554
```

このテストは専用プレビューパッケージ内の試験データを初期化します。個人利用中の環境と分け、専用AVDで実行してください。実際のWhisper認識、iOSで生成した標準補正の正解データとの一致、設定・候補保存、音声再生、認識中の削除による非復活、保存上限・古い音声削除を確認します。

Androidの保存先はnoBackupFilesDir/relayで、アプリの自動バックアップも無効です。音声ファイルをsyncしてからDBへ登録し、キューはネイティブの単一書込担当で更新します。認識は別のワーカーで実行します。削除後に遅れて届いた認識結果で履歴を再作成しません。WAV書き出しはシステムの保存先選択を使用し、保存した外部ファイルは履歴削除後も残ります。

## step 6の模擬API試験

専用AVDでDebug APKをビルド後、リポジトリ直下で`python3 scripts/test-android-delivery.py --device emulator-5554 --reset-test-data`を実行します。プレビューのデータを初期化し、合成資格情報とループバックのHTTPサーバーだけを使います。実送信のためINTERNET権限はReleaseにも追加しました。実APIへの確認通信は明示的な登録時、投稿は有効な送り先の新規ジョブだけに行います。詳しい仕様は[step 6](../docs/FLUTTER_STEP6.md)を参照してください。

模擬入力は16kHz／mono／PCM16です。元レートを保持した原音からのリサンプリングと既存iOSのadaptive-30hz処理を実装しています。9997Hzの時間保持を単体試験、16kHzの補正結果をSwiftの正解データと照合します。実際のIndex01のデコード結果は実機で照合する必要があります。
