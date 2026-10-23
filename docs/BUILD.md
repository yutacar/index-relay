# ビルドと開発環境

## ソースを取得する

```sh
git clone https://github.com/yutacar/index-relay.git
cd index-relay
git switch codex/flutter
```


## ブランチとアプリの選択

Flutter対応完了版は`codex/flutter`（0.12.1／34）、既存ネイティブiOS版は`main`（0.9.8／36）で管理します。以下のブリッジ生成は両方のiOSアプリで共通です。Flutter SDKとAndroid環境は[Flutterアプリの手順](../flutter_probe/README.md)、検証範囲は[対応状況](FLUTTER_STATUS.md)を参照してください。

## 対象

- Apple Silicon Mac。iOS arm64実機／arm64シミュレーター。Intel Mac・x86_64シミュレーターは対象外。
- アプリのDeployment Target：iOS 26.0。Xcode 27.1 / Swift 6でビルド確認。
- Python 3.9以上。ブリッジ再生成にはJDK 17と初回のネットワーク接続が必要。Gradle 8.14.3は同梱Wrapperで取得する。
- 実機試験：Index01、iPhone、Apple Accountによる署名。常用時のプロビジョニング管理は利用者が行う。

JDK 17を先にインストールしてください。`/usr/libexec/java_home -v 17`で検出できない配置の場合は、以下の`JAVA_HOME`をJDK 17の実際のホームへ変更します。`java -version`で17系を確認してから進めます。

## 1. 受信ブリッジを生成する

公開用ソースは大型バイナリを含みません。Xcodeを先にビルドするとXCFramework不在で失敗するため、最初に生成します。

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
# 同梱Wrapperの起動ファイル・JAR・設定をオフラインで検証
python3 scripts/verify-gradle-wrapper.py
bash scripts/build-receiver-framework.sh
python3 scripts/verify-framework.py
```

通常ビルドと依存候補採取は、`bridge/gradlew`を標準で使用します。起動前に両ランチャーのハッシュ、[Gradle公式値](https://gradle.org/release-checksums/)と一致するJARハッシュ、配布URL・ZIPハッシュを検証します。初回は公式のGradle 8.14.3 bin ZIPを自動取得し、WrapperがSHA-256を照合します。JDK 17とXcodeは利用環境で用意します。

依存は`bridge/build.gradle.kts`で版を指定。ビルドコマンドはGradle 8.14.3を要求し、コミット済みの`bridge/gradle/verification-metadata.xml`を必須として`--dependency-verification strict`を指定します。検証ファイルがない場合に自動で記録・承認する経路はありません。`--no-build-cache --rerun-tasks`で現在の入力から両スライスを生成します。Gradle／Kotlinキャッシュは既定で`work/gradle-cache`と`work/konan`に保存します。`GRADLE_USER_HOME`・`KONAN_DATA_DIR`で変更できます。環境固有のパスをコードへ書き込まないでください。

生成先は`ios/Frameworks/IndexReceiverBridge.xcframework`。実機・シミュレーター各Debugフレームワークをまとめます。生成物内の`IndexRelay-integrity.json`は今回の両バイナリの整合性記録です。ソースからの再現性や配布元の署名を証明するものではありません。旧`bridge/framework-checksums.json`は廃止しました。既存のフレームワークには新しい記録がないため、この版で再生成してください。

## 2. Flutter版をXcodeで開く

受信ブリッジ生成後、FlutterのbinをPATHへ追加して実行します。iOSではAndroidのWhisperモデルを同梱するflavorを指定しません。

```sh
cd flutter_probe
flutter pub get
flutter build ios --release --no-codesign --target lib/main.dart
open ios/Runner.xcworkspace
```

Runnerスキームを選択。Signing & CapabilitiesでTeamを自分のものに設定し、例示用`dev.example.indexrelay`を一意なBundle Identifierに変更します。個人の署名設定を公開コミットへ入れないでください。既存のローカル作業プロジェクトでは署名設定を保持しています。

背景タスクの識別子はBundle Identifierから組み立て、Info.plistも同じ変数を使います。Bundle Identifierを変えた場合、iOSは別アプリとして扱い、旧アプリのデータは自動移行しません。

## 3. 既存ネイティブiOS版のビルド

`ios/IndexRelay.xcodeproj`は既存SwiftUI版のビルド先です。Flutter版を更新する際は上のRunnerを使用します。既存版を開く場合は`open ios/IndexRelay.xcodeproj`、スキームはIndexRelayです。署名なしビルド例：

```sh
xcodebuild -project ios/IndexRelay.xcodeproj -scheme IndexRelay \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath work/DerivedData CODE_SIGNING_ALLOWED=NO build
```

これはインストール・BLE受信・バックグラウンド処理の成功確認ではありません。シミュレーターでは画面と一部ロジックを確認できますが、リング受信・日本語モデルは実機で確認します。

## ブリッジを変更したとき

Kotlinソースを変更したら再生成が必要です。Swiftだけの変更では再生成は不要。ビルド中のGradleやダウンロードエラーは内容を確認し、固定版を安易に変更しないでください。Xcode／Kotlin／端末OSの組み合わせを変えた場合は実機受信も再確認します。


## 通信痕跡の検査と基準値の更新

ビルドは新しいXCFrameworkのstaging内で、実機arm64とシミュレーターarm64をそれぞれ`bridge/network-surface.json`と照合します。新しいURL文字列・既知マーカーがあれば停止し、現在配置済みのXCFrameworkを置換しません。どちらかのスライスや基準値がなくても停止します。通常ビルドは通信の基準値を更新しません。

```sh
python3 scripts/inspect-bridge-network.py
# 差分を調べるとき（出力するだけで基準値は変えない）
python3 scripts/inspect-bridge-network.py --report > work/network-review.json
```

更新が意図したものか、両スライスのレポートのURL・マーカーを読んで確認します。確認したレポートを、ビルドとは別の操作で承認します。

```sh
python3 scripts/inspect-bridge-network.py --approve-baseline work/network-review.json
```

承認時にも現在の両バイナリを再検査し、確認したレポートと違えば停止します。失敗したstagingを調べる場合は`--framework work/IndexReceiverBridge.xcframework`をレポート出力・承認の両方に指定します。基準値の差分も確認してコミットします。ソースからブリッジを作る工程、配布物のSHA-256整合性確認、通信痕跡の承認はそれぞれ別の目的です。再ビルド出力を過去の固定ハッシュと比較する処理や、通信基準値の自動更新は導入していません。自前のstatic archiveは時刻情報でもハッシュが変わるためです。

この検査は平文のURLと固定のマーカー集合に限られ、通信がないことを証明しません。CIでは合成バイナリを使う検査ツールのテストを実行し、実際のブリッジ走査はブリッジを生成したローカル環境で行います。


## 依存照合データの更新（M3）

通常はコミット済みの照合データをそのまま使用します。現在の記録は127コンポーネント・304アーティファクトです。Haversineの固定版と両iOS版、Kotlinプラグイン・Nativeコンパイラー等を含み、metadataも照合します。今回、以前に使用したキャッシュ304件と全SHA-256を比較し、strictビルドでも確認しました。これは配布者の署名確認や独立した真正性監査の代替ではありません。

依存を意図的に更新する場合だけ、候補を隔離コピーで作ります。

```sh
bash scripts/record-bridge-dependencies.sh
# 表示されたwork/dependency-review.XXXXXX/gradle/verification-metadata.xmlを確認する
# 既存との差分、版、アーティファクト名、配布元のハッシュ／署名などを照合する
# 確認後に限り、候補XMLをbridge/gradle/verification-metadata.xmlへコピーしてコミットする
bash scripts/build-receiver-framework.sh
```

候補作成は隔離プロジェクトでの依存読込み・コンパイルを伴いますが、製品側のXML、通信基準値、配置済みXCFrameworkは変更しません。初回の生成や更新で採取したハッシュは、その時点の配布物を信頼しているため、内容の確認が必要です。[Gradleの依存検証](https://docs.gradle.org/current/userguide/dependency_verification.html)。Kotlin/Nativeが独自に取得するLLVM・sysroot、Gradle実行ファイル・JDK・Xcode、任意のローカル初期化スクリプトまで、このXMLで網羅したとは扱いません。

通常ビルドでは、strict照合 → 両スライスの生成 → stagingで通信検査 → 今回の整合性記録 → コピー先の再照合 → 旧配置の退避と置換、の順です。コピー失敗・検査失敗なら旧配置を維持し、置換失敗なら旧配置を戻します。復元まで失敗した場合は旧配置を退避先に残し、そのパスを表示します。強制終了・電源断に対するディレクトリと記録の完全なトランザクション保証ではありません。

`--bootstrap-verification`や`--update-checksums`は通常ビルドで受け付けません。新しく生成した整合性記録が照合できても、それは依存の承認や無通信の証明ではありません。


## Gradle Wrapperの運用

`bridge/gradlew`、`gradlew.bat`、`gradle/wrapper/gradle-wrapper.properties`とJARをコミットしています。`scripts/verify-gradle-wrapper.py`はネットワークを使わず検証でき、CIと公開書き出しでも実行します。JARは公開検査でも固定パス・公式ハッシュが一致する場合だけ許可します。

`GRADLE_CMD`は、保守担当者が意図的に外部のGradleを指定する互換用の上書きとして残しています。標準のWrapperを使う場合は設定しないでください。上書きしてもコミット済みWrapperの検査とGradle 8.14.3の版確認、依存strict検証は維持します。配布ZIPのハッシュ検証はWrapperによる初回取得時に行うもので、展開済みキャッシュ全体を毎回再照合するものではありません。

更新する場合は公式値を確認し、Wrapperを生成した後、配布ZIP・JAR・ランチャー・設定の検査値をレビューして変更します。対象のGradle/Kotlin/Nativeの互換性・依存照合・実機受信を確認し、生成したファイルを無条件に承認しないでください。
