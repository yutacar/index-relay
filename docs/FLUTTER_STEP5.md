# Flutter step 5：Android受信・保存・バックグラウンド認識

Androidのネイティブ側に、Index01のBLE受信、永続キュー、通知付き受信サービス、WorkManagerによる文字起こし、Android Keystoreを使う資格情報保存を追加した。Flutterを唯一の処理担当にせず、画面がなくても同じネイティブ処理が動く。実機はないため、実際のBLE通信は未検証。Discord／Telegramの資格情報入力・API照合・実投稿はstep 6。

## 構成と操作

- 歯車 →「リング・自動受信」→ 探索 → 対象リングの選択で登録・開始する。探索は対象サービスUUIDに限定した15秒のスキャン。登録後はHaversineのAndroidマネージャーをサービスから実行する。接続先は端末内に保存する。
- 実受信の対象はAndroid 12／API 31以降。BluetoothのSCAN／CONNECT権限と、Android 13以降は通知権限をユーザー操作で要求する。通知許可は本アプリの開始条件であり、OSがすべてのFGSに要求する条件という意味ではない。Android 8〜11はオフライン／模擬入力だけのプレビュー。
- `connectedDevice`型のForeground Serviceを画面表示中に開始する。永続通知の「停止」と設定のスイッチから停止できる。画面を閉じても受信サービスが所有するCoroutineScopeで継続する。通常のバックグラウンド開始制限を迂回するアラームや起動時レシーバーは追加しない。
- Bluetoothオフでは待機し、オン通知で再接続する。サービスのシステム再生成は`START_STICKY`で復旧する。強制停止・再起動後の受信はアプリを開いて再開する。OS・メーカーの電池制限による停止から必ず自動復旧するとは保証しない。
- 認識は端末内のwhisper.cpp、CPU、日本語、既知のモデルハッシュを使用する。WorkManager 2.11.2の通常Workerで実行し、ネットワーク制約を要求しない。独自の8分上限でキャンセル・再試行し、OS停止時にもJNIのabort callbackで認識を中断する。再実行時は待機キューへ戻す。OSの実行時期は保証しない。受信のFGSを認識専用の無期限実行に転用しない。
- 音声はPCM16 mono・最長5分／最大32MiB。原音のレートを保持し、DC補正・16kHzリサンプリング・標準補正後に認識する。上限の実機性能・長時間の電池消費は未測定。空の認識結果・モデル不足などは「要対応」とする。

FGS、BLE、権限、WorkManagerの前提は[Android BLEのバックグラウンド処理](https://developer.android.com/develop/connectivity/bluetooth/ble/background)、[FGSの種類](https://developer.android.com/develop/background-work/services/fgs/service-types)、[Bluetooth権限](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)、[バックグラウンド開始制限](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)、[WorkManager](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started)に従う。

## 保存と安全側の動作

SQLiteと音声の唯一の書込担当は`RelayEngine`。原音を一時ファイルへ書き込み、fdをsync、rename、親ディレクトリをfsyncした後、録音行と受信位置を同じSQLiteトランザクションへ記録する。最後にメモリの再開位置を公開する。SDKからのカーソル更新通知だけでは保存済みと判定しない。リング側の消去・DFUは要求せず、初回消去も拒否、更新URLは渡さない。16bit境界を跨ぐ受信位置と未保存の隙間を管理し、保存していない区間を勝手にACKしない。

受信IDは登録セッション・レート・Collection区間・原音から生成する。再受信で同じ録音を作り直さず、削除／保持上限による削除はtombstoneと同じトランザクションへ記録する。遅れて完了した認識は、録音ID・試行ID・状態が一致した場合だけ更新する。削除された録音を再生成しない。tombstoneは自動削除しない。SQLite v1→v2は既存の音声・文字起こし・設定・送り先候補を維持する。DBを開けない場合は自動処理を停止し、破損時の自動ファイル削除もしない。

音声・SQLite・資格情報の暗号文は`noBackupFilesDir`配下に置き、アプリのバックアップも無効。資格情報はAndroid KeystoreのAES-256-GCM鍵で暗号化し、UUIDを追加認証データとする。改ざん・鍵消失時に平文へフォールバックしない。鍵はロック中処理用に認証要求なしで作成する。エミュレーターの検証は実機のハードウェア鍵保護を証明しない（[Android Keystore](https://developer.android.com/privacy-and-security/keystore)）。現段階では資格情報の本番入力UI・送信時参照は未接続。

診断イベントは時刻・固定コード・短い録音キーだけを端末内に最大150件保存し、画面では直近50件を取得・コピーできる。本文・音声・トークン・Webhook・機器MACを診断へ出さない。AndroidウィンドウにはFLAG_SECUREを設定する。設定上のリング候補にはユーザーが選択できるよう名前とMACを表示するが、診断書き出しには含めない。

## 再現手順

Flutter／Android SDK、合成音声、固定モデルは`flutter_probe/README.md`の手順で準備する。以下は個人データのない専用ARM64エミュレーターだけで実行する。ネイティブ試験はプレビューパッケージのデータを初期化するため、明示フラグを必須にしている。

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
cd flutter_probe
flutter build apk --flavor preview --release --target-platform android-arm64
```

合成音声の注入はDebug専用かつDUMP権限で保護したActivity／BroadcastReceiverから行う。Flutter画面を開かず、実際の受信サービス→同一の保存関数→WorkManager→実際のWhisper認識を通る。保存途中の障害・DBコミット後のプロセス停止もこの経路で注入する。ReleaseのManifestには注入用コンポーネントを含めない。試験用コードの到達条件にも`BuildConfig.DEBUG`を要求する。Release APKはこの段階ではプレビュー用署名であり、公開配布版ではない。

## 確認結果と未検証範囲

結果は[FLUTTER_STEP5_EVIDENCE.json](FLUTTER_STEP5_EVIDENCE.json)に記録する。AVDの画面オフ／idle試験はシェルから合成入力した保存の検証であり、無線からのDoze起床・実機ロック中BLE受信を実証したものではない。プロセス終了後のキュー復旧は、ネイティブ試験Activityで再起動する条件を含み、強制停止からの無操作復旧を証明しない。

残る実機確認は、登録／ボンディング、実BLE転送・復号音声の照合、再接続／Bluetooth切替、長い録音、ロック中受信と認識の遅延、通知拒否・権限取消、OEMの省電力制限、長時間の電池消費。受信ライブラリの静的検査やオフライン試験だけで、実機の全通信がないことは証明しない。Androidの実投稿・送信確認・複数送り先・結果不明は次工程で接続する。

## 今回の結果（2026-10-21）

- Android ARM64 Debug／Release APKのビルド成功。Release Manifestに注入用コンポーネント・INTERNET権限がなく、受信サービスが非公開であることを確認。
- Flutter analyze：指摘なし。UI／controller：13テスト、Kotlin：5単体テスト成功。
- API 36 ARM64の専用AVD：既存の統合試験2件成功。Swiftの正解データと標準補正の結果が一致。
- ネイティブ受信試験：Flutter画面なしの保存と実Whisper認識、v1データ移行、重複抑制、16bit境界と欠落区間、削除済み録音の非復活、ファイル／DBの障害、プロセス再起動からのキュー復旧を確認。
- Keystoreの再起動後読出しと暗号文改ざんの拒否、画面オフ／idle中の合成入力の保存、認識中のWorker取消とJNI終了、通知停止と同じ経路での停止を確認。
- Swift：12スイート506チェック、Python：48テスト成功。既存iOS受信バイナリの両スライスはネットワーク静的検査の既知の基準内。

外部のDiscord／Telegramへの投稿と、実リングの操作は行っていない。Flutter／Android試験は現時点では手動実行で、既存CIはSwift／Pythonを継続する。

step 7以降はpreview／productionを分離したため、上記の再現コマンドもpreviewを指定します。新しいCIと配布用ビルドは[step 7](FLUTTER_STEP7.md)を参照してください。
