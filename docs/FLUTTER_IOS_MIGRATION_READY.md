# iPhoneのFlutter版更新：退避・照合・復旧準備

現在のFlutter対応完了版は`codex/flutter`（0.12.1／34）で管理します。iOS実機の受信・文字起こしと復帰確認を含む現状は[対応状況](FLUTTER_STATUS.md)を参照してください。この文書の過去の確認結果・移行手順とは区別します。

step 7の項目4へ進むための準備。実機へインストールする処理は追加しない。既存の署名済みアプリ、ダウンロードしたコンテナー、新しい署名済みアプリを手元で照合し、専用シミュレーターで合成データの更新・復旧を試す。iOS版からの実サービス投稿は未確認で、実機更新の実施とも分ける。Android版では基本送信を確認済み。

## 先に退避するもの

1. 旧版で自動受信を停止し、送り先を全件オフにする。送信中の要求が終わったか、結果不明として確認すべきかを送信一覧と投稿先で確認する。オフ操作だけでOSに登録済みの転送まで消えたとは扱わない。
2. 新しい録音・認識・削除操作を止め、アプリを終了した状態で、XcodeのDevices and Simulators（版によってDevice Hub）の対象アプリからDownload Containerを実行する。`.xcappdata`は暗号化したローカル保存先で保管し、チャットやGitへ入れない。旧版の署名済み`.app`と再ビルドできるソースも保存する。
3. Webhook／Botトークンを外部の管理元から再設定できることを確認する。コンテナーの退避をKeychainの退避とは扱わない。

XcodeはコンテナーのDownload／Replaceに対応する（[Appleの操作案内](https://help.apple.com/xcode/mac/current/en.lproj/dev816c242e1.html)）。このアプリの音声・状態の保存先は`isExcludedFromBackup`を設定しているため、通常の端末バックアップだけに依存しない（[Appleの除外属性](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey)）。

`DestinationKeychain`はBundle IDに由来するserviceと`AfterFirstUnlockThisDeviceOnly`を使用する。コンテナーにはKeychainやOS管理のURLSession転送は含まれない。同じTeamでもApp ID prefixを変えるとKeychainにアクセスできなくなる場合があるため、prefixとアクセスグループを別途照合する（[Apple TN2311](https://developer.apple.com/library/archive/technotes/tn2311/)）。アンインストール、端末交換、別の署名identityへの切替は今回の同一アプリ更新試験に含めない。

## コンテナーの整合性を記録する

```sh
python3 scripts/ios-migration-check.py seal \
  --container /private/path/before.xcappdata \
  --manifest work/ios-migration/before-manifest.json
python3 scripts/ios-migration-check.py verify \
  --container /private/path/before.xcappdata \
  --manifest work/ios-migration/before-manifest.json
```

ツールは元のコンテナーを変更しない。全ファイルのハッシュ・サイズとパスのハッシュを記録し、録音メタデータとWAVの形式・サンプル数、文字起こしとの対応、認識／送信状態を検査する。本文・音声・資格情報・送り先名・生のパスはマニフェストへ保存せず、出力ファイルは0600で作成する。既存のマニフェストは上書きしない。ファイルの追加・削除・変更やシンボリックリンクは検査で拒否する。

`quiescentSnapshot`は、既知の保存領域があり、受信と送り先が停止し、認識中／送信中／未完了削除がない場合だけtrue。falseの場合もコンテナーそのものは保存し、元データを消さずに理由を確認する。未使用のアプリでは領域がまだ作られていない場合もある。元アプリを開いて問題を整理した場合は、その後に別名でコンテナーとマニフェストを採取し直す。

このマニフェストは改変検出用のローカル記録で、暗号化・署名・Keychainの復元を提供しない。元のコンテナーとマニフェストを一緒に改変された場合の監査証明にもならない。

## 署名済み候補を照合する

通常のFlutterプレビューは別のBundle ID。既存アプリの更新用として、Git対象外の`flutter_probe/ios/Flutter/Migration.local.xcconfig`に既存のIDとTeamを設定し、Xcodeで実機用のプロファイルとentitlementsを確認する。ビルド番号は実際の旧版より大きくする。例の31を無条件に使わない。

```xcconfig
INDEX_RELAY_BUNDLE_IDENTIFIER = your.existing.bundle
INDEX_RELAY_DEVELOPMENT_TEAM = YOUR_TEAM_ID
INDEX_RELAY_DISPLAY_NAME = Index Relay
```

署名済み旧版と候補の`.app`が揃った後に実行する。

```sh
python3 scripts/ios-migration-check.py preflight \
  --old-app /private/path/OldIndexRelay.app \
  --new-app /private/path/NewIndexRelay.app \
  --report work/ios-migration/signing-report.json
```

`codesign`による静的検証、Bundle ID・ビルド番号、App ID prefix／Team、Keychainグループと順序、共有保存領域のentitlements、バックグラウンドモードとBGTask識別子、候補プロファイルの期限・Team・許可グループを照合する。IDやTeam、プロファイルの内容は結果へ書き出さない。未署名のiPhone向けビルドやSimulatorの署名を、実機更新用の候補として合格にしない。

`artifactChecksPassed=true`でも`readyForDeviceUpdate=false`のまま。対象iPhoneがプロファイルで許可されていること、OS・署名証明書・インストール権限、現在の端末内Keychainが読めること、退避・復旧の可用性はこれだけでは証明できない。特に旧版を再ビルドした成果物だけでは、実際にインストール済みの署名情報を再確認したことにはならない。

## シミュレーターでの更新・復旧リハーサル

```sh
python3 -m unittest discover -s tests/IOSMigration -v
python3 scripts/test-flutter-ios-upgrade.py \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

毎回作る使い捨てシミュレーターだけに、旧形式の音声9件・文字起こし8件・送信8状態・受信位置・削除済みID・設定・無効な合成資格情報を用意する。送り先は停止する。以下を検査して、終了時は専用シミュレーターと一時退避を削除する。

- 更新前のAppDataを合成`.xcappdata`へコピーし、マニフェストで照合。
- コピーしたWAVの1バイトを変えると照合が失敗し、元の退避は引き続き一致。
- 同じIDのFlutter版へ上書き更新し、原音・メタデータ・文字起こし、設定・受信位置・削除済み情報を維持。
- 認識中は待機へ、回収できない送信中は結果不明へ復旧し、送信試行と受領IDを維持。
- Flutterを停止し、使い捨てシミュレーター内の5つの保存領域だけを更新前の退避から戻し、ファイルと状態を照合。
- 合成fixtureへ戻して同じネイティブKeychain読出しを確認。

リハーサルはファイルと状態の互換性の確認。実機のXcode Replace Container、実プロファイル、Data Protection属性の復元、実際のKeychain資格情報、OS転送、BLE、SpeechAnalyzer、ロック中動作を確認した証拠にはしない。故障状態もfixtureに含めるので、fixtureの退避は`quiescentSnapshot=false`が想定どおりである。

## 実機で更新するときと戻すとき

実機更新は、対象の署名・ID、退避結果、資格情報を再設定できる手段を揃えてから利用者が実施する。既存アプリをアンインストールせず、同じID・署名で上書きする。初回起動は送り先をオフのまま、件数・設定・過去の連携状態・音声・既存資格情報の利用を確認する。その後にリングの新しい短い録音とロック中動作を確認する。

不具合時は自動受信と送り先を止め、更新後の状態も別名で退避する。戻す候補は同じID・署名で用意し、ビルド番号・プロファイルの制約をXcodeで確認する。単に小さい番号の旧版を再インストールできるとは保証しない。Xcodeでコンテナーを戻せる条件が整っている場合だけ、保存済みの退避を照合して使用する。

退避後に外部投稿が発生していた場合、古い送信状態をそのまま戻すと投稿済みの要求を再び待機へ戻すおそれがある。OS転送・外部の到着・Keychainを含めて照合し、機械的に退避へ巻き戻さない。ツールは実機の上書きインストールや復旧操作を自動実行しない。

検証記録：[FLUTTER_IOS_MIGRATION_READY_EVIDENCE.json](FLUTTER_IOS_MIGRATION_READY_EVIDENCE.json)。

## 実施結果（2026-10-22）

合成データの専用iOS 26.5 Simulatorで、26ファイルの維持、退避の照合・改変検出、Flutter更新、5保存領域の復旧、合成Keychainの読出しに成功した。終了後の専用Simulatorと一時退避の削除も確認した。移行チェック14、送信確認・サービス準備待ち16、公開検査9テストと既存Swift 506チェックが成功。実機用候補の照合へSimulator成果物を渡すと拒否された。

コード`ea9d3ca0eb082d7ea8606cf8ef379f02765f068b`で[Swift／移行チェックCI](https://github.com/yutacar/index-relay/actions/runs/39698822932)と[Flutter／Android CI](https://github.com/yutacar/index-relay/actions/runs/39698822928)が成功。Androidの前回失敗は起動完了直後の携帯通信サービス準備であり、サービスと通信無効化コマンドの準備待ちを追加した。追試ではサービス準備1.03秒、Flutter統合155.03秒、模擬送信114.61秒だった。この準備時点では実機署名・更新、実サービス投稿は未実施だった。Android版の最新の実送信結果は[実送信確認](FLUTTER_LIVE_DELIVERY.md)を参照。

最新の0.12.1／34を対象とする複数OSの検証は[シミュレーター検証](FLUTTER_IOS_SIMULATOR_MATRIX.md)を参照。上記は準備時点の記録として残し、実機での結果と混同しない。

レビュー後の単件再試行修正、本物の0.9.7起動を経る追加試験、復旧用ビルドとFlutter版の画面保護の確認事項は[レビュー対応](FLUTTER_REVIEW_FOLLOWUPS.md)を参照。
