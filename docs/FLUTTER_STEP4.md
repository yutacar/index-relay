# Flutter step 4：iOSの既存処理への接続

Flutterのホーム・履歴・音声詳細を、既存のSwiftサービスへ接続する。Androidの模擬受信版は維持する。iOS版のリング選択、送り先の照合・資格情報入力、確認待ち・結果不明の操作は既存のSwiftUI設定を開く。これらの画面のFlutter化は後続工程。

## 実装

- `index_relay/relay`のiOS側を追加。Swiftを唯一の保存担当とし、Dartには表示用スナップショットと変更通知だけを渡す。トークン、Webhook、投稿本文ファイル、送信試行の内部情報は渡さない。
- 既存SwiftソースをXcodeから直接参照する。`ReceivedRecordings`、`Transcripts`、`AutomaticRelay/state.json`、`History/deletions.json`、`Delivery/state.json`の形式と保存先を変更しない。既存の受信位置・削除済みID・送信試行・受領IDを再生成しない。
- AppDelegateでFlutterエンジンの生成前にBGタスク登録とBluetooth復元を開始。保護データの利用可能通知、バックグラウンドURLSessionイベントを既存サービスへ渡す。SceneDelegateで前面／背景遷移を連携する。
- Sceneごとの既存PrivacyShieldをFlutterのウィンドウにも取り付ける。保護ファイル、バックアップ除外、Keychainの保護クラスは既存処理を使う。
- ホームに実際の連携状態を表示。9997Hz等の元サンプルレートで音声時間を計算する。複数削除は既存のtombstone→キュー・投稿整理→ファイル削除を呼ぶ。標準補正の再生・システムの保存先選択へ接続する。
- 送信途中の復旧は既存のURLSession照合を使い、OSタスクを回収できない場合は「結果不明」にする。「送信待ち」へ戻して再投稿しない。過去の文字起こしから新しい投稿を作り直さない。

## 同じアプリとして更新する条件

通常のFlutterプレビューは`dev.example.indexRelayProbe`。既存iPhoneアプリを置き換えない。実機更新前には既存アプリのBundle ID、署名チーム、Keychainアクセスグループ／署名プロファイルを照合する。アンインストールすると履歴の引き継ぎ試験にならない。

ローカルだけの`flutter_probe/ios/Flutter/Migration.local.xcconfig`で設定できる。

```xcconfig
INDEX_RELAY_BUNDLE_IDENTIFIER = your.existing.bundle
INDEX_RELAY_DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

このファイルはGit対象外。既存アプリに追加のKeychainグループ等がある場合は、そのentitlementsも一致させる。通常の既存Index Relayは明示グループを使わず、Bundle ID由来のKeychain serviceと送り先UUIDを使用する。Bundle IDだけの一致では実機の資格情報アクセスを保証しない（[AppleのKeychainアクセスグループの説明](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)）。

初めての実機更新は自動実施しない。端末内データを退避し、同じ署名・IDでビルド番号を旧版より上げて上書きインストールする。例：`flutter build ios --debug --build-name 0.10.0 --build-number 31`。本番の送り先がオンなら、既存の未処理ジョブも既存仕様に従って再開するため、確認試験では送り先をオフにして条件を記録する。

## 再現できる試験

Flutter SDKとignoredの試験assets、検証済みの`ios/Frameworks/IndexReceiverBridge.xcframework`を先に準備する（`docs/BUILD.md`、`flutter_probe/README.md`）。Apple SiliconのARM64シミュレーターのみ対応。Kotlin静的フレームワークは`-ObjC`でリンクし、埋め込み動的フレームワークとしてコピーしない。

```sh
python3 scripts/verify-framework.py
cd flutter_probe
flutter analyze
flutter test
flutter build ios --simulator --debug
cd ..
python3 scripts/test-flutter-ios-upgrade.py --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5
python3 scripts/run-tests.py
python3 scripts/inspect-bridge-network.py
```

更新試験は新しい専用シミュレーターを作り、旧保存形式で合成データを作る小さなfixtureアプリから、同じIDのFlutterアプリへ更新する。試験後は専用シミュレーターを削除する。実機・利用中のシミュレーター・個人データに接続しない。資格情報は無効な合成値、送り先は全件オフ。シミュレーターSDKに限り、試験アプリとFlutterアプリへ同じ`SIMULATOR.<Bundle ID>`の模擬entitlements・Keychainグループを設定し、両方の実行ファイルの`__TEXT,__entitlements`も照合する。この試験用属性は実機SDKには指定しない。

無音の合成WAV 9件、固定の試験文を保存した文字起こし8件、認識途中1件、送信の8状態、16bit境界を跨ぐ受信位置、削除済みID、保持件数20件、Keychainを用意する。Keychainは、Flutterへの更新後に同じ読出し処理を持つfixtureへ戻して読み出し、Flutter実行ファイルの模擬entitlementsの一致も照合する。資格情報をDartへ渡す試験APIは作らない。原音・メタデータ・文字起こしのハッシュ、保持設定、tombstone、受信位置、送信試行と受領IDを照合する。認識途中は待機、OSタスクのない送信途中は結果不明になることを確認する。標準補正の出力は既存仕様どおり16kHzで、9997Hzの原音ファイルは保持する。認識精度の試験ではない。これは旧バイナリを使った本番データ更新の代替証明ではなく、既存形式のfixtureを使った互換性試験。

## 未検証の範囲

実機の署名／Keychain引き継ぎ、Index01のBLE接続・状態復元・ロック中受信、SpeechAnalyzerの日本語モデルを用いた認識、BGProcessingTaskの実行・期限切れ、実投稿、Flutter版App Switcherの実機表示を改めて確認する。以前のSwiftUI版の実機結果はFlutter版へ引き継がない。Android実BLE・常駐サービスはstep 5、Flutterの送り先編集・送信UIの統合は後続工程。現在のCIはSwift／Python検査で、Flutterと更新試験は手動実行。

## 今回の結果（2026-10-21）

- iOS Simulator Debug／iPhone向けRelease（署名なし、通常の`lib/main.dart`）：ビルド成功。
- Flutter analyze：指摘なし。UI／controllerの12テスト成功。
- iOS 26.5／iPhone 17 Proの専用ARM64 Simulator：更新統合試験1件、および終了後の照合に成功。
- 旧形式の音声9件・文字起こし8件を表示。原音・メタデータ・文字起こしの26ファイルがバイト単位で一致。
- 保持件数20・tombstone・16bit受信位置を維持。認識途中は待機へ復旧。
- 送信8状態、試行ID・回数・受領ID・本文・送り先identityを維持。OSタスクのない送信途中だけ結果不明へ復旧。確認設定を変えても既存の確認待ちを自動承認しない。
- 標準補正WAV（16kHz・2秒）の取得と、既存設定画面の表示に成功。Keychainはfixtureによる再読出しに成功し、Flutterの模擬entitlementsも一致。
- 既存Swift：12スイート506チェック成功。Python：48テスト成功。公開検査、Wrapper検証、受信フレームワークの両スライスの整合性／ネットワーク静的検査も成功。

機械可読の照合結果：[FLUTTER_STEP4_EVIDENCE.json](FLUTTER_STEP4_EVIDENCE.json)。試験用シミュレーターは終了後に削除した。実際の認識・投稿は行っていない。Flutter試験は現時点では既存CIに含めず、手動で実行している。

共通の試験assetsにはAndroid用のWhisperモデルも含まれるため、現在のiOS試験ビルドも大きい。配布に進む前にOS別のモデル配置と試験assetsの扱いを整理する。

## step 7以降の補足

iOS資産からAndroidモデルと試験音声を除外する処理は[step 7](FLUTTER_STEP7.md)で整備済み。上記の大容量資産・CIに関する記述はstep 4時点の履歴である。退避の整合性検査、署名照合、専用シミュレーターでのデータ復旧リハーサルは[実機移行の準備](FLUTTER_IOS_MIGRATION_READY.md)を参照する。
