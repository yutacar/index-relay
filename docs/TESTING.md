# テストと既知の制約

## 自動テスト

```sh
python3 scripts/run-tests.py
# 特定の範囲だけ
python3 scripts/run-tests.py Delivery History
```

12スイート・506チェック（0.9.7時点）：PrivacyShield 28、PairingProbe 26、PCM16WAV 12、ReceivedRecording 9、ReceiverCheckpoint 10、AudioSignal 52、ReceiverComparison 24、PlaybackCoordinator 13、Transcription 36、AutomaticQueue 40、Delivery 212、History 44。

合成データ・一時ファイル・FakeTranscriberを使い、実際の音声認識・ネットワーク投稿・BLEには接続しません。Swift 6でコンパイルします。GitHub Actionsはこの範囲と公開候補チェックを実行します。Xcodeでのアプリ全体のビルドや実機試験を代替しません。

`tests/HistoryUI/`は過去に複数選択・一括削除を検証したXCTestのソースです。通常スキームにはUIテストターゲットを含めておらず、この12スイートやCIの実行数には含めません。現在は参照用で、UIテストターゲットと合成履歴の準備が必要です。

## 実機で確認すること

| 範囲 | 確認内容 |
| --- | --- |
| 接続 | 初回選択・切断後再接続・アプリ再起動・Bluetooth許可拒否 |
| 音声 | 3秒／10秒／30秒などで録音し、原音・標準補正・文字起こしを照合 |
| 背景 | 前面／ホームへ移動／ロック中、再起動後初回解除前後の保存と再開 |
| 連続録音 | 複数回の録音で抜け・重複・保存位置の飛び越しがないこと |
| Discord | 確認あり／なし、接頭語、明示IDメンション、トークン失効 |
| Telegram | グループ・スーパーグループの登録と投稿、DM・チャンネルの拒否、旧設定の停止 |
| 配信復旧 | 通信断・429・応答喪失で重複投稿しないこと、結果不明の手動確認 |
| 履歴 | 30件からの上限変更、チェック複数選択、削除、再起動後の再取得抑制 |
| 常用 | 受信・認識・送信各時刻と、リング／iPhoneの電池消費 |

記録項目は録音秒数、受信開始・保存・認識完了・送信完了の時刻、前面／背景、OS／ファームウェア、エラーコード。公開資料には実際の本文・端末固有ID・資格情報を含めません。

## 確認済み範囲

開発時のiPhone 18 Pro / iOS 27.0.1 / Index01 firmware 3.75では、ロック中・バックグラウンドでの蓄積とDiscord連携を利用者が確認済みです。すべての機種・OS・長時間停止状態での保証ではありません。Telegramグループ投稿は2026-10-21に利用者が確認済みです。種別・移行・権限条件の網羅的検証ではありません。個別DMの候補取得試験は対象外になりました。

## 対象外・制約

- Mac版、複数端末同期、初期アクティベーション／DFU、未設定個体の完全な公式アプリ代替。
- 強制終了後や再起動後の初回ロック解除前の自動処理。
- バックグラウンド処理・投稿の即時完了保証。
- 長文の自動分割、Discordスレッド・フォーラム、Telegramトピック。
- 他サービスの投稿を含めたexactly-once保証。曖昧な結果は手動確認。


## 受信ブリッジの検査ツールのテスト

```sh
python3 -m unittest discover -s tests/BridgeNetwork -v
```

12件のPythonテストを別に実行します（Swiftの506チェックには含めません）。実機版／シミュレーター版の新URL・マーカー、スライス欠落、基準値欠落・不正schema、通常検査の非書換え、古いレポートの承認拒否を確認します。外部ビルドツールを模擬した試験では、stagingでの新URL検出後に既存の配置済みフレームワークと基準値が保持されることも検証します。

Deliveryの212チェックは資格情報の解決、group／supergroupの登録、DM・channelの拒否、不正なID、旧設定・ジョブの永続的な移行、対象外への再送拒否、遅延成功応答の保持などを含みます。受信メッセージの取得APIも拒否します。実際のグループへの送達や、実KeychainとAPIを組み合わせた編集は実機で確認してください。


## 依存照合・配置と診断分類の追加試験（0.9.4）

```sh
python3 -m unittest discover -s tests/BridgeBuild -v
# Kotlin/Native 2.2.20のkonancをPATHに置いた環境で実行（ツールは自動取得しない）
mkdir -p work
konanc bridge/src/iosMain/kotlin/ReceiverDiagnostics.kt tests/ReceiverDiagnostics/main.kt -o work/receiver-diagnostics-tests
work/receiver-diagnostics-tests.kexe
# 停止中の一部処理が失敗しても、残りの解放処理まで実行することを検査
konanc bridge/src/iosMain/kotlin/ReceiverShutdown.kt tests/ReceiverShutdown/main.kt -o work/receiver-shutdown-tests
work/receiver-shutdown-tests.kexe
```

Pythonの配置・コマンド検証は18テスト。Wrapperの標準利用と、改変を実行前に拒否するケースも含みます。欠落・不正な整合性記録、両スライス、コピー／置換／復元失敗時の旧配置保持、strict指定とバージョン制限を確認します。既存の通信検査12テストとともにCIで実行します。

Kotlin/Nativeの診断分類テストは20チェック。個人名・任意の秘密文字列・日本語・UUID・文字列化すると例外になる値を与え、固定値以外を出さないことを確認します。CIはNativeコンパイラーを準備しないため、この20チェックはローカルで実行します。ReceiverDiagnostics.kt・RingReceiver.kt、Kotlin／Haversineの依存・コンパイラーの変更時は再実行してください。Swiftの506チェックと別集計です。

実際のGradleでも隔離コピーのKotlinプラグインの期待SHAを変更し、strictが依存検証エラーで停止することを確認しました。Debug／ReleaseのiOSビルドも検証対象です。実機では更新後の受信・文字起こし、Debugの診断出力、Releaseで該当NSLogが出ないことを確認してください。


## L3の実機確認（0.9.5）

PrivacyShieldの28チェックは、別Sceneの通知を無視すること、inactiveからactiveへ直接戻ること、foreground復帰途中で覆いを外さないこと、同じSceneの再接続でwillDeactivate直後の覆いを外さないことを含みます。実際のウィンドウの重なり・keyWindow・OSダイアログ・snapshotを自動確認した結果ではありません。

2026-10-20に利用者の実機画像でApp Switcherの覆いと復帰後の操作を確認しました。すべてのシステムUI条件を確認した結果ではありません。[確認範囲](REMAINING_VERIFICATION.md)と[L3の実機確認表](L3_IMPLEMENTATION_PLAN.md#実装後の実機確認表)を参照してください。既存のシミュレーター用UIハーネスは旧実装の検証であり、この版のUI検証済み証拠として扱いません。


## 公開用書き出しの検査

```sh
python3 -m unittest discover -s tests/Publication -v
```

8件の回帰テスト。Wrapper JARの固定パス・ハッシュ照合も含みます。書き出し先が別の親Gitに無視されても実ファイルを検査し、合成秘密情報を拒否することを確認する。現在のPythonは通信検査12・ビルド配置18・公開検査8・Wrapper検証10の合計48件。Swiftの506チェックとは別集計。CIでも実行する。残る実機試験とWrapperの状態は[残作業の確認](REMAINING_VERIFICATION.md)を参照。


## Wrapper検証

```sh
python3 scripts/verify-gradle-wrapper.py
python3 -m unittest discover -s tests/GradleWrapper -v
```

10件のテストでJAR欠落・改変・symlink、起動スクリプト改変、実行権限、配布URL・SHA・版の固定、重複／未知の設定を確認します。Windows用ランチャーは改行差を正規化して検査します。Wrapper経由での実際のstrictビルドと、隔離コピーへの依存候補採取も確認しています。実機のTelegramと通信観測の完了とは別です。
