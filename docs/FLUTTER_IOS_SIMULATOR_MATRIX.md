# Flutter版iPhoneアプリ：更新・復旧のシミュレーター検証

対象は0.12.1／34。利用者の指定により、今回の工程はシミュレーターに限定する。iPhone実機への接続・インストール・コンテナー取得・署名変更を行わない。

## 対象と確認内容

iOS 26.5、27.0ではiPhone 17 Pro、27.1ではインストール済みruntimeが対応するiPhone Duoの使い捨てSimulatorを作り、同じBundle IDの合成旧版fixtureからFlutter版へ上書き更新する。既存シミュレーターとAndroidの確認用アプリ・送り先設定は変更しない。

- 録音9件、文字起こし8件、原音・メタデータ・文字起こし計26ファイルの内容を保持。
- 保存件数20、受信位置、削除済みID、送り先、確認設定を保持。
- 送信8状態のうち、回収できない「送信中」を「結果不明」へ戻す。試行回数・試行ID・受領IDを保持し、再送待ちへ勝手に戻さない。
- 認識途中の1件を待機へ戻す。確認待ちを、設定変更で自動承認しない。
- 合成コンテナーの全ファイルを照合し、WAVの1バイト改変を検出。
- 更新前の5つの保存領域を戻し、内容と状態の一致を確認。
- 同一のネイティブKeychain読出しで合成資格情報を読めることを確認。
- 試験用Simulatorと一時退避を終了後に削除。

送り先は停止し、資格情報も送信に使えない合成値を使用する。実サービスへの投稿は行わない。

## 再実行

Flutter／iOSブリッジを準備し、必要なSimulator runtimeをXcodeへインストールする。リポジトリ直下から実行する。

```sh
python3 -m unittest discover -s tests/IOSMigration -v
mkdir -p work/ios-migration-matrix
for os in 26-5 27-0; do
  python3 scripts/test-flutter-ios-upgrade.py \
    --runtime "com.apple.CoreSimulator.SimRuntime.iOS-$os" || exit 1
  cp work/flutter-ios-upgrade/evidence.json "work/ios-migration-matrix/ios-$os.json"
done
python3 scripts/test-flutter-ios-upgrade.py \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-1 \
  --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-Duo
cp work/flutter-ios-upgrade/evidence.json work/ios-migration-matrix/ios-27-1.json
```

試験はFlutterのintegration用エントリーポイントでビルドするため、終了後は通常のエントリーポイントへ戻す。

```sh
cd flutter_probe
flutter build ios --simulator --debug --no-codesign --target lib/main.dart
```

実機用の `Migration.local.xcconfig` が存在する場合、試験スクリプトは実行を拒否する。実機の設定を消して続行せず、プレビュー用の別作業環境を用意する。

## 確認の限界

この試験は合成fixtureと保存形式の互換性・復旧状態の確認であり、実際の旧アプリの全バージョンや利用者データを試したものではない。Keychainはバックアップに含まれず、同一Simulator内での継続性だけを確認する。

実機の署名・プロビジョニング、実データの退避／復元、BLE、ロック中の受信・SpeechAnalyzer、バッテリー、iOS版からの実投稿は未確認。Simulator成果物を実機更新候補として扱わない。

## iOS 27の試験環境の修正

初回のiOS 27.0試験は、Flutter更新前の合成旧版fixtureがシーン方式に未対応だったため起動段階で停止した。fixtureに`UIApplicationSceneManifest`と`UIWindowSceneDelegate`を追加した。Flutter本体は既にシーン方式に対応しており、製品側の起動コードは変更していない。このfixtureは旧保存形式を再現するためのもので、配布済み旧アプリのバイナリーそのものではない。

最新SDKでビルドしたアプリに対する要件は[AppleのUIScene移行資料](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)を参照。

手元の27.1 runtimeの`simctl list runtimes --json`にある対応機種はiPhone Duoのみで、iPhone 17 Proとの作成要求は`SimError 403: Incompatible device`になった。`--device-type`を追加し、対応機種を指定して試験する。別環境ではインストール済みruntimeの対応一覧を確認して指定する。

## 実施結果（2026-10-22）

| OS | Simulator機種 | 更新・26ファイル保持 | データ復旧・Keychain継続 | 専用環境の削除 |
| --- | --- | --- | --- | --- |
| 26.5 | iPhone 17 Pro | 成功 | 成功 | 確認済み |
| 27.0 | iPhone 17 Pro | 成功 | 成功 | 確認済み |
| 27.1 | iPhone Duo | 成功 | 成功 | 確認済み |

移行チェック14テスト、公開検査9テストが成功。各試験で送信状態の復旧、受信位置・削除済みIDの維持、確認待ちの非自動承認、改変した退避の拒否も確認した。

試験用シーン対応は`8928239`、機種指定の追加は`5ef09a5`。OSごとの実行コードと確認項目は[検証記録](FLUTTER_IOS_SIMULATOR_MATRIX_EVIDENCE.json)に保存した。音声・文字起こし本文・資格情報・Simulatorの固有ID・ローカルパスは記録に含めない。

試験後に`lib/main.dart`で通常版Simulatorアプリをビルドし、版0.12.1／34を照合した。Simulator成果物は実機用preflightで署名・プロビジョニングの検証に失敗し拒否された。最新の試験コードのSwift CI（旧Privateリポジトリでの過去記録。公開先のCIは[Actions](https://github.com/yutacar/index-relay-public/actions)を参照）は成功、Flutter／Android CI（旧Privateリポジトリでの過去記録。公開先のCIは[Actions](https://github.com/yutacar/index-relay-public/actions)を参照）は実行中。
