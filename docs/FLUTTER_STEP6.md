# Flutter step 6：AndroidのDiscord／Telegram投稿

Androidの送り先登録、送信前確認、複数送り先、永続送信キュー、Flutterの送信一覧を接続した。SQLite／WorkManager／Keystoreがネイティブ側の処理を担当し、Flutterは表示とユーザー操作を受け持つ。既存のiOS送信処理・設定画面は維持する。

## 操作

歯車から「送り先を追加」を開き、表示名・資格情報・接頭語・有効／停止を登録する。Discordは通常のテキストチャンネル用Webhook、TelegramはBotトークンとグループIDまたは公開スーパーグループの`@名前`を指定する。登録時のAPI照合では投稿しない。資格情報は画面へ再読込せず、編集時の空欄は現在の暗号化保存値を使う。

送信前確認のスイッチは、新しく文字起こしが完了して作られる送信ジョブへ適用する。既存の確認待ちは自動承認しない。有効な送り先ごとにジョブを作る。過去の文字起こし、送り先追加時の既存文章、送り先がすべてオフの間に完了した文章は、後から勝手に投稿しない。模擬受信でも、有効な送り先があれば同じ送信設定が適用される。

「送信一覧・確認待ち」で本文の確認・編集・承認、送り先ごとの再試行・取消、受領したメッセージIDを確認できる。ホームは録音ごとの連携状況を表示する。音声詳細の「送り先ごとの送信状況・確認」から、その録音だけの一覧を開ける。ローカル通知は本文や送り先名を含めず、確認が必要な項目があることだけを知らせる。Android 13以降は設定のボタンから通知許可を要求する。許可がなければアプリ内で確認する。

送り先のオフは待機中の投稿を止める。既に開始した投稿や外部サービス上のメッセージは撤回できない。未完了のジョブがある送り先は削除できないため、停止または送信一覧で確認・取消を行う。履歴の削除／保持件数による削除は関連するローカル送信ジョブも消し、外部投稿は消さない。

## 送り先の照合と本文

- Discord：WebhookへのGETで取得する`guild_id`／`channel_id`をidentityとする。同じチャンネルへのWebhook更新は許可し、別の送り先への付け替えは拒否する。同じ送り先の重複登録も拒否する。フォーラム・スレッド指定用のURLクエリは受け付けない。
- Telegram：`getMe`でBot、`getChat`でチャットIDと`group`／`supergroup`種別を照合する。個別DM・チャンネル・開始リンクによる候補取得は対象外。Botとチャットのidentityが違えば新規登録とする。Botの投稿権限不足は送信時の応答で要対応になる。
- 接頭語があれば「接頭語＋半角スペース＋文字起こし本文」。ジョブ作成時に本文・送り先identity・メンション許可を固定する。設定変更は既存の本文を作り直さない。
- Discord：`wait=true`で受領IDを取得する。`allowed_mentions.parse=[]`とし、設定した接頭語の`<@ID>`／`<@!ID>`／`<@&ID>`だけをusers／rolesへ入れる。認識本文や確認画面で追加した別のID、`@everyone`、`@here`を通知対象へ追加しない。
- Telegram：`parse_mode`なしのプレーンテキスト。リンクプレビューは無効。本文はDiscord 2000／Telegram 4096のUTF-16長で保守的に検査し、超過は分割せず「要対応」で編集を待つ。

APIの根拠：[Discord Webhook](https://docs.discord.com/developers/resources/webhook)、[Telegram Bot API](https://core.telegram.org/bots/api)。

## 保存・送信・復旧

SQLite v2→v3で送り先の照合情報、送信ジョブ、認識済みのbaseline、サービス単位の待機期限を追加する。v1からも段階的に移行する。元の音声・文字起こし・設定・未接続の送り先候補を維持する。既存の候補は無効のままとし、資格情報の入力とAPI照合後に有効化できる。

認識結果の確定と送信ジョブの作成は、同じDBトランザクションへ記録する。送信前に試行UUIDとsendingを永続化し、応答は同じ試行・sendingにだけ反映する。削除後の非同期結果で記録を再作成しない。資格情報はジョブへ複製せず、送信のclaim時に現在の送り先からKeystoreの暗号文を解決する。資格情報更新は新しい暗号文を保存→DB参照を切替→古い暗号文を削除の順とし、DB失敗時は新しい暗号文を破棄する。

WorkManagerの送信Workerはネットワーク接続を条件とし、通常のネイティブHTTP接続で送信する。OS管理の再実行でFlutter画面に依存せず処理を再開する。FGSを送信専用の常駐処理に転用しない。OS制約により即時送信は保証しない。APIアクセス用のINTERNET／ACCESS_NETWORK_STATE権限を追加した。

接続先は公式HTTPSホストに限定し、リダイレクトを追わない。固定長ストリーミングPOSTを使い、HttpURLConnectionによる自動の再認証／リダイレクト再送を許さない。接続・読出しは各15秒、応答は最大256KiB、応答読出しの継続時間にも上限を設ける。本文を書き始める前の接続失敗だけを安全な再試行候補とし、ゼロバイトという推測だけで送信後の失敗を未投稿と断定しない（[HttpURLConnection](https://developer.android.com/reference/java/net/HttpURLConnection#setFixedLengthStreamingMode(int))）。

- 受領IDを含む成功応答：送信済み。
- HTTP 429：`retry_after`／Retry-Afterヘッダーの保守的な値に従って待機し、サービス単位の待機期限も永続化する。7日を超える異常に長い指定は勝手に短縮せず、そのサービスの送り先を停止して要対応とする。ジョブの取消・送り先停止・履歴削除でこの期限を消さない。自動試行は最大5回。
- 本文書込前の通信失敗：30秒からの再試行待ち。
- その他の4xx／リダイレクト拒否：要対応。Telegramの`migrate_to_chat_id`は新しいIDでの再登録を案内し、自動で付け替えない。
- 5xx、本文を書き始めた後の切断／タイムアウト、受領IDのない成功応答、Worker中断、再起動時のsending：結果不明。自動再送しない。
- 結果不明の再送：投稿先を確認し、重複投稿の注意を明示的に承認した場合だけ実行する。「確認済み・再送しない」も選べる。

## 試験方法

個人データ・本物の資格情報がない専用ARM64 AVDで実行する。初期化フラグはプレビューアプリのデータを消すため必須。試験用assets／モデルの準備は`flutter_probe/README.md`を参照。

```sh
cd flutter_probe
flutter analyze
flutter test --flavor preview
flutter test --flavor preview integration_test/relay_flow_test.dart -d emulator-5554
flutter build apk --flavor preview --debug --target-platform android-arm64
cd android
./gradlew :app:testPreviewDebugUnitTest
cd ../..
python3 scripts/test-android-receiver.py --device emulator-5554 --reset-test-data
python3 scripts/test-android-receiver.py --device emulator-5554 --reset-test-data --legacy-version 2 --migration-only
python3 scripts/test-android-delivery.py --device emulator-5554 --reset-test-data
cd flutter_probe
flutter build apk --flavor preview --release --target-platform android-arm64
```

送信試験はローカルの模擬HTTPサーバーへADBで接続する。Debug専用・DUMP権限で保護したハーネスが公式URLをループバックの模擬APIへ差し替える。通常のネイティブHTTP処理、DB、Keystore、WorkManagerを通し、Debugだけにlocalhostの平文HTTPを許可する。Releaseは試験コンポーネント・設定・差し替えを使わない。合成の認識完了fixtureに加え、1件は受信サービスから実Whisper認識・複数送り先の確認待ち・模擬API投稿まで通す。外部Discord／Telegramへは投稿しない。

結果は[FLUTTER_STEP6_EVIDENCE.json](FLUTTER_STEP6_EVIDENCE.json)。実際のサービス権限、実送信の到着とメンション通知、Android実機のロック中・OEM省電力制約は別途確認が必要。以前のSwiftUI版の実機確認を、今回のFlutter／Android版の確認済みとして扱わない。現CIの対象はSwift／Pythonで、Flutter／AVDの検査は手動実行。

## 今回の結果（2026-10-21）

- Flutter analyze：指摘なし。Flutter 16テスト、Kotlin 10テスト、既存Android統合2テスト成功。
- API 36 ARM64の専用AVD：模擬APIによる登録・照合、DM／チャンネル拒否、送り先変更拒否、実Whisperから複数送り先への確認・投稿まで成功。
- 停止中の文章を後から投稿しないこと、本文・メンション許可の固定、資格情報更新後の送信、長文編集、受領ID保存を確認。
- 本文送信後の切断と5xx、送信中のプロセス終了は結果不明で停止。手動再送に明示確認を要求。本文書込前の接続拒否は再試行待ち。
- 429の待機、自動試行5回の上限、ジョブ取消後も残るサービス単位の待機、グループ移行の案内、送信中削除の非復活、リダイレクト拒否を確認。
- v1／v2→v3移行で、音声・文章・設定・受信位置・tombstone・無効の送り先候補を維持。step 5の受信・障害復旧・暗号化保存の回帰試験も成功。
- Android Debug／Releaseビルド成功。Releaseに試験コンポーネント・Debug用HTTP設定がなく、受信サービスが非公開であることを確認。
- 既存Swift 506チェック、Python 48テスト、Wrapper・公開検査、既存iOSブリッジのネットワーク静的検査も成功。

実際のDiscord／Telegramへの投稿・通知確認は行っていない。Release APKは引き続きプレビュー用署名であり、公開配布向けの署名・モデル配布・CI整備は後続工程。

step 7以降はpreview／productionを分離したため、上記の再現コマンドもpreviewを指定します。新しいCIと配布用ビルドは[step 7](FLUTTER_STEP7.md)を参照してください。
