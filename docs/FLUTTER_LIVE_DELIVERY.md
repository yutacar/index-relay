# Flutter／Android：実サービスへの送信確認（step 7・項目3）

対象は、所有者が試験に同意したDiscordのテスト用チャンネルとTelegramのテスト用グループ。アプリで登録・API照合した送り先を使い、通常のネイティブ認識・保存・送信キューを通す。iPhone実機への更新、Android実BLE試験、本番署名、mainへの統合はこの工程に含めない。

2026-10-22にDiscordとTelegramグループへの実API投稿を実施し、確認あり・自動送信で各先の受領IDを確認した。利用者が両サービスに各2件の到着を確認済み。今回の登録では接頭語・メンションは未設定。資格情報をチャット、コマンド引数、ソース、検証JSONに入れない。

## 準備

個人データのない専用API 36エミュレーターと、更新したpreviewDebugを使用する。productionには診断ハーネスが含まれない。アプリの設定へ資格情報を直接入力する。登録時には実APIへのGET等の照合通信が発生するが、投稿は行わない。

```sh
# リポジトリ直下。Flutter／Android環境はflutter_probe/README.mdで準備する。
cd flutter_probe
flutter build apk --debug --flavor preview --target-platform android-arm64
cd ..
adb -s emulator-5556 install -r flutter_probe/build/app/outputs/flutter-apk/app-preview-debug.apk
adb -s emulator-5556 shell svc wifi enable
adb -s emulator-5556 shell am start -W -n dev.example.index_relay_probe/.MainActivity
```

x86_64のエミュレーターではビルド時に`ORG_GRADLE_PROJECT_indexAbis=x86_64`と`--target-platform android-x64`を指定する。既存の合成テストを使ったAVDには模擬APIの設定が残ることがある。その場合は別の専用AVDを用意する。利用者が入力した資格情報やデータを自動で初期化する手順は提供しない。

- Discord：テスト専用Webhookを登録し、接頭語に自分が通知を受け取れる`<@ユーザーID>`を指定する。ロール通知を試す場合は対象ロール・受信者の設定も確認する。
- Telegram：Botをテスト用グループへ追加し、送信権限とグループIDを確認して登録する。DM・チャンネルは対象外。
- リングの自動受信は停止し、試験先以外の送り先もすべてオフにする。
- 保留中の認識や未完了の投稿がある場合は、先にアプリの一覧で確認する。結果不明を自動再送しない。
- ホスト上の準備スクリプトが生成したKyokoの合成音声を使う。「模擬受信する」から実Whisper認識を行う。Linux CIのトーン音声はこの試験には使わない。

## アプリ画面での確認（0.12.0／33）

確認用エミュレーターは5556を使う。設定の「送り先」からDiscordのテスト用WebhookとTelegramグループを登録し、試験先だけをオンにする。資格情報はアプリに直接入力する。既存データを消去する必要はない。

設定 → **Discord・Telegramの送信確認**を開くと、有効な送り先・接頭語・送信前確認の設定を表示する。「試験音声を1件取り込む」を押すまで取り込み・承認・投稿は行わない。確認がオフなら、押した後の認識完了で実際に自動投稿する。リング自動受信中、認識処理中、未完了の送信がある場合は新しい試験を開始できない。

「送信一覧・確認待ちを開く」から既存の承認・結果不明への対応ができる。到着・本文・Discordのメンション通知は各サービス側でも確認する。すべてオフの試験Cは、通常の「模擬受信する」を使用する。

以下の記録ツールの既定端末も5556。合成障害試験用5558と混同しない。

## 記録ツールの範囲

`scripts/record-android-live-check.py`は診断スナップショットを読み、設定変更・録音投入・送信承認・再試行・投稿を指示しない。操作と投稿はアプリ画面で行う。アプリが元から持つキュー処理を止めるものではない。

試験開始時に、専用エミュレーター、更新済みpreviewDebug、模擬API差し替えの不在、受信停止、未完了ジョブの不在、指定先と有効先の一致を検査する。変更を検出したら成功と扱わない。資格情報の有無や本文・名前・チャットID・Webhook・受領メッセージIDをファイルへ出力しない。検証JSONは識別子のハッシュ・状態・時刻・受領IDの有無・手動観測結果だけを保存し、権限を0600にする。アプリ内部の診断ファイルはアプリの非バックアップ領域に残る。

```sh
python3 scripts/record-android-live-check.py status
```

表示する`id`はアプリ内部の送り先UUID。APIトークンではない。以下の`DISCORD_UUID`／`TELEGRAM_UUID`を置き換える。Discordだけ試す場合はTelegramの引数を省き、未確認のサービスを確認済みと扱わない。

## A：確認あり・複数送り先

両方の試験先をオン、「送信前に確認する」もオンにする。

```sh
python3 scripts/record-android-live-check.py begin --case confirmation \
  --destination-id DISCORD_UUID --destination-id TELEGRAM_UUID \
  --session work/android-live-verification/confirmation.json
```

アプリの「模擬受信する」を1回押す。文字起こしが終わり、両先が確認待ちの状態で次を実行する。ここでは`apiChecksPassed`はfalseが正常で、未送信の確認待ちを記録する。

```sh
python3 scripts/record-android-live-check.py observe \
  --session work/android-live-verification/confirmation.json
```

アプリの送信一覧で本文が「接頭語＋半角スペース＋文字起こし」になっていることを確認し、各先を1回ずつ承認する。送信済みになったら同じ`observe`を実行する。各先の受領IDあり・試行1回・確認設定・接頭語の一致を確認すると`apiChecksPassed`がtrueになる。承認前の観測を省略した場合は成功と扱わない。

Discord／Telegramを開き、各先に同じ試験文が1件ずつ到着したこと、Discordの表示が実際のメンションになり受信者に通知されたことを手動で確認する。OS・サーバー・個人の通知設定で通知されない場合も、API成功とは分けて記録する。

```sh
# 実際に到着・メンション通知を確認できた場合だけverifiedにする。
python3 scripts/record-android-live-check.py attest \
  --session work/android-live-verification/confirmation.json \
  --arrival verified --mention verified
```

確認できなければ`failed`または`unverified`を指定する。API成功だけで手動確認を自動的にverifiedへ変更しない。

## B：自動送信・複数送り先

アプリで「送信前に確認する」をオフにし、Aのジョブが送信済みであることを確認する。

```sh
python3 scripts/record-android-live-check.py begin --case automatic \
  --destination-id DISCORD_UUID --destination-id TELEGRAM_UUID \
  --session work/android-live-verification/automatic.json
```

模擬受信を1回実行し、承認操作なしで両先が送信済みになることを確認する。次を実行し、外部アプリで新しい投稿1件ずつと通知を確かめて`attest`する。

```sh
python3 scripts/record-android-live-check.py observe \
  --session work/android-live-verification/automatic.json
python3 scripts/record-android-live-check.py attest \
  --session work/android-live-verification/automatic.json \
  --arrival verified --mention verified
```

## C：全件オフ→再びオンでも過去の文章は投稿しない

送り先をすべてオフにし、未完了ジョブがないことを確認する。

```sh
python3 scripts/record-android-live-check.py begin --case paused \
  --destination-id DISCORD_UUID --destination-id TELEGRAM_UUID \
  --session work/android-live-verification/paused.json
```

模擬受信を1回実行。文字起こし完了後、全件オフのまま次を実行して投稿ジョブがないことを記録する。

```sh
python3 scripts/record-android-live-check.py observe \
  --session work/android-live-verification/paused.json
```

次に指定した試験先をオンへ戻し、新しい模擬受信はせず、同じ`observe`を再実行する。過去の文章にジョブが作られていなければ成功。Discord／Telegramにも投稿が増えていないことを確認する。終了時は試験先をオフに戻す。

## 結果の扱いと中断

- `apiChecksPassed`：アプリ内部と受領IDの検査。実際の到着・通知の代わりにはならない。
- `allSelectedChecksPassed`：A／BはAPI検査に加え、利用者が到着と必要なメンション通知をverifiedと記録した場合だけtrue。Cは停止中と再有効化後の両方でジョブがない場合にtrue。
- 3ケースのJSONを確認し、試験したサービス・アプリ版・日時・OS・通知条件も報告する。JSONは改変耐性を持つ監査証明ではなく、手動試験の記録である。
- 複数の模擬受信を行った、送り先や接頭語が変わった、受領IDなし、結果不明、再試行発生時は合格扱いにしない。投稿先を確認してから対応する。ツールは自動再送しない。
- 実サービスへ意図的な429・5xx・切断・グループ移行は発生させない。障害系は[模擬API試験](FLUTTER_STEP6.md)で扱う。
- 今回の記録は合成音声からの実API投稿確認に限定する。Android実リング・ロック中・省電力、iOSのFlutter版更新、長い録音の性能は別の確認が必要。

準備時点の検証結果：[FLUTTER_LIVE_DELIVERY_EVIDENCE.json](FLUTTER_LIVE_DELIVERY_EVIDENCE.json)。実API投稿の結果と、到着・通知の確認範囲は同JSONの最新結果を参照。

追記（2026-10-22）：準備時のAndroid CIは、起動直後に携帯通信サービスがまだ使えず失敗した。準備待ちと4回帰テストを追加し、後続CI（旧Privateリポジトリでの過去記録。公開先のCIは[Actions](https://github.com/yutacar/index-relay/actions)を参照）で画面・JNI・模擬送信まで成功した。これは準備時点のCI記録。実サービスでの最新確認範囲は上記JSONを参照。

## 通常欄で文字キーボードが出ない場合

API36の確認用AVDで、表示名・グループIDなどではGboardの手書き入力補助UIだけが出て、Botトークン欄では通常のキーボードが出る症状を調査した。スタイラスとして認識されたタップでFlutterの手書き入力開始が呼ばれることを再現テストで確認した。

0.12.1／34では、送り先設定、保存件数、投稿本文の入力欄で `stylusHandwritingEnabled: false` を指定し、通常のキーボード入力を使う。通常欄をパスワード欄へ変更する対策は取らない。根拠：[Flutterの手書き入力設定](https://api.flutter.dev/flutter/material/TextField/stylusHandwritingEnabled.html)。同じスタイラスタップを標準TextFieldへ行う対照試験と、修正後の表示名・TelegramグループIDへの文字入力試験が成功した。

確認用エミュレーターだけで手書き入力をオフにする場合は、次の設定も利用できる。

```sh
adb -s emulator-5556 shell settings put secure stylus_handwriting_enabled 0
```

このOS設定はAVD内だけに適用する。アプリの入力欄の修正とは別の措置であり、Android実機全体の設定変更は必要ない。確認用アプリで入力途中の資格情報がある間は、アプリの再インストール・再起動を避ける。


## 実送信の結果（2026-10-22）

0.12.1／34へ通常更新し、登録済みの2送り先と資格情報を維持できた。確認ありでは両先とも試行0回・未受領の確認待ちを記録し、その後の承認で両先が試行1回・受領IDありとなった。確認なしでも同様に各先1回で送信が完了した。送り先をすべてオフにして認識した1件には投稿ジョブがなく、再びオンへ戻した後も作成されなかった。

試験後は「送信前に確認する」をオン、試験先2件をオンへ戻した。未完了ジョブは0件。接頭語は両先とも空欄だったため、接頭語付き本文・Discordメンション通知はこの試験では未確認。利用者がDiscordとTelegramの両方で2件ずつ到着したことを確認したため、確認あり・自動送信の基本試験を完了した。利用者の指定により、今回は接頭語・メンションの追加試験を行わない。公開結果には本文・宛先ID・受領ID・資格情報を含めない。
