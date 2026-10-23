# Flutter移行レビューへの対応

現在の継続管理ブランチは`codex/flutter`です。移行準備・実機更新前という記述は各段階の記録です。後続の実機確認と残る範囲は[対応状況](FLUTTER_STATUS.md)を参照してください。

## 構成と今後の修正

Android対応を継続する。Flutterは主に画面を共通化し、iOSはSwiftの既存サービス、AndroidはKotlinの受信・認識・送信サービスを使う。プラットフォーム間の保存領域や資格情報を共有する構成ではない。

送信結果不明、429、Telegramグループ移行、受信位置、取消・再起動の規則を変更するときはSwift／Kotlin双方の該当実装とテストを確認する。全履歴のスナップショット送信は現在の上限内では維持する。

## 手動の文字起こし再試行

Flutterの再試行は`AutomaticRelayService.retryTranscription`を呼び、`AutomaticQueue.retry(id:)`で対象だけを永続待ち列へ戻す。完了・失敗・取消は通常のrunnerで保存する。認識中のリセットと並行実行を拒否する。

自動受信停止中は前面で明示指定した1件だけ処理し、他の待機録音やBluetooth受信を開始しない。バックグラウンド移行で停止した場合は待ち列に保持し、停止設定中に自動再開しない。認識済みの文章は再試行開始時には消さず、成功した結果で置き換える。投稿済みのメッセージは再認識によって書き換えない。確認待ちの本文もジョブ作成時の文章で固定し、再認識結果は自動反映しない。必要なら送信一覧で本文を編集する。

## 本物のネイティブ版からのSimulator更新

元ソースの固定コミットを指定し、作業用の別ディレクトリへ展開する。今回の0.9.7のソースは`087d49a43b8785c3e8533fe4db30a412941f6180`。ソースには変更を加えず、Simulator用Bundle IDだけビルド設定で変更する。ビルドには検査済みのブリッジを使用する。

```sh
mkdir -p work/native-legacy-review
git archive 087d49a43b8785c3e8533fe4db30a412941f6180 ios | tar -x -C work/native-legacy-review
# 検査済みios/Frameworks/IndexReceiverBridge.xcframeworkを
# work/native-legacy-review/ios/Frameworks/へコピーする。
xcodebuild -project work/native-legacy-review/ios/IndexRelay.xcodeproj \
  -scheme IndexRelay -configuration Debug -sdk iphonesimulator \
  -derivedDataPath work/native-legacy-review/build \
  PRODUCT_BUNDLE_IDENTIFIER=dev.example.indexRelayProbe CODE_SIGNING_ALLOWED=NO build
python3 scripts/test-flutter-ios-upgrade.py \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
  --native-legacy-app work/native-legacy-review/build/Build/Products/Debug-iphonesimulator/IndexRelay.app
```

専用Simulatorにfixtureで合成データを用意し、アプリを停止して本物の0.9.7を上書きする。起動後、認識途中から待機、送信途中から結果不明への照合処理を保存ファイルで確認してからFlutter版へ更新する。9録音・8文字起こしの原本、送信状態、受信位置と削除済みID、退避・復元、Keychain継続性を検査する。

これは本物の起動経路を通す追加試験であり、実ユーザーの履歴、Bluetooth復元イベント、OS管理の送信タスク、実機のData Protectionは再現しない。元から送り先と受信は停止した合成データだけを用い、実投稿しない。

## iOS成果物の検査

```sh
cd flutter_probe
flutter build ios --release --no-codesign --target lib/main.dart
cd ..
python3 scripts/audit-ios-release.py flutter_probe/build/ios/iphoneos/Runner.app
python3 -m unittest discover -s tests/IOSRelease -v
```

モデル・試験音声の混入と内部名／表示名の一致を検査する。署名・配布・実機更新の検査には代用しない。CIでは合成バンドルによる検査器の回帰テストを実行し、実際のiOS成果物は上記コマンドで検査する。

## 実機移行前に残る確認

この節はSimulatorまでを対象としていたレビュー時点の記録。現在は実機の受信・文字起こし・復帰を確認済みだが、署名済み復旧版の準備、双方向の事前照合、Flutter版App Switcherの確認は完了報告がないため、以下の手順を残す。

1. 既存のネイティブ版ソースを別の作業領域で保管し、復旧候補としてビルドする。Flutter候補のビルド番号より大きい値を指定する。現在のFlutter候補34なら35が例だが、今後候補が上がったら固定値を使い回さない。
2. 既存アプリと同じBundle ID、Team、App ID prefix、Keychainグループで署名し、プロファイル期限と対象端末の許可を確認する。署名済み`.app`、ソース、コンテナーをGit外の保護した保存先へ保管する。
3. `ios-migration-check.py preflight`を「現在のネイティブ版→Flutter候補」と「Flutter候補→復旧用ネイティブ版」の両方で実行する。成功しても実機更新可能の保証とは扱わない。
4. [移行手順](FLUTTER_IOS_MIGRATION_READY.md)に従って退避し、実機更新後は送り先・受信を停止したまま件数、音声、資格情報の継続性を確認する。
5. Flutter版のホーム・設定・音声詳細を表示してApp Switcherを開き、本文が覆われることを確認する。共有シート・ファイル保存の取消／完了後も操作できること、復帰時に覆いが外れることを確認する。SwiftUI版の確認済み記録と混同しない。

実機復旧時に新たな外部投稿があれば、投稿先と送信履歴を照合する。コンテナーだけを機械的に過去へ戻さない。署名済み復旧版の確保はリスクを減らすが、OS転送・Keychain・外部サービスまで含む完全な巻戻しは保証しない。

## 旧版Sceneの復元

互換性fixtureのSceneを本物の0.9.7へ引き継ぎ、起動後にFlutter版へ更新する試験では、OSが保存済みの`SwiftUI.AppSceneDelegate`を復元し、Flutter画面が生成されず黒くなる問題を確認した。`configurationForConnecting`を実装するだけでは既存セッションには適用されなかった。後述の、fixtureのUIを一度も起動しない旧版のみの更新試験とは区別する。

新規接続はFlutter用Scene構成を明示する。旧構成のアプリ用Sceneがactiveになった場合は、公開された`UIScene.delegate`と`UIWindow(windowScene:)`を使ってFlutter用のdelegate・ウィンドウに接続し直す。現在のFlutter Sceneは対象外とし、既存ウィンドウは非表示にする。ファイル・Keychain・送信状態・OSの保存領域は削除しない。画面保護と前面／背景処理も新しいdelegateへ接続する。

Scene構成の基本は[AppleのScene移行資料](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle)、Flutter側の接続とエンジン登録は[FlutterのScene移行資料](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate)を参照。この更新固有の再接続処理は実際の旧版からの統合試験で確認し、実機での画面保護は別途確認する。

## 実施結果（2026-10-22）

- iOS 27.0の専用Simulatorで、本物の0.9.7／30起動・照合→Flutter 0.12.1／34上書き→復旧が成功した。旧Sceneの再接続後、Flutter画面からの設定操作を含む統合テストが成功。
- 9録音・8文字起こし、計26ファイル、送信試行・受領ID、受信位置、削除済みIDを保持し、退避改変の拒否とKeychain継続性を確認。
- 通常エントリーポイントの未署名iOS Releaseビルドが成功。容量34,471,906 bytes、Whisperモデルなし、内部名と表示名の一致を検査した。
- Swift 12スイート・513チェック、移行14テスト、iOS成果物検査器4テスト、公開検査9テストが成功。
- 試験用Simulatorと一時コンテナーを削除し、通常の`lib/main.dart`へビルド設定を戻した。実機の接続・更新と実投稿は行っていない。

[検証記録](FLUTTER_REVIEW_FOLLOWUPS_EVIDENCE.json)。署名済み復旧版とFlutter版の実機App Switcher確認は、上記の実機移行前チェックとして未完了。

## 再起動・Dartライフサイクルの追加確認

`adoptRestoredScene`の画面生成を`Main.storyboard`の初期ViewControllerへ統一した。再認識後も確認待ち本文を自動更新しない仕様も上記に追記した。

再起動ごとに「通常の接続」「旧Sceneの再接続」を区別し、構成名が`flutter`か否か、Dartの実際の`didChangeAppLifecycleState`呼出しを記録する診断を追加した。録音・本文・資格情報・Scene固有IDは記録しない。SwiftはDebug限定かつ環境変数、DartはDebugの専用defineでのみ有効となる。RunnerのDebug構成にSwiftの`DEBUG`条件がなかったため設定を追加し、Releaseと区別した。

初期のCLI試験ではMacのロックが判明し、結果を採用しなかった。解除後のXCTestでは別途、背景移行時の`SIGABRT`を確認した。クラッシュの例外スタックはFlutterの`stateRestorationActivityForScene:`から`NSUserActivity`生成を示した。[Flutter公式実装](https://api.flutter.dev/ios-embedder/_flutter_scene_life_cycle_8mm_source.html)もScene構成名をactivity種別として使っている。

旧構成では`stateRestorationActivity(for:)`から`nil`を返し、Flutterによる画面復元情報の生成を省略する。新規の`flutter`構成は従来どおりsuperへ渡す。これは画面の復元だけを対象とし、録音・文字起こし・待ち列・資格情報の永続保存やOSのSceneセッションは削除しない。実験的な通知の橋渡し・エンジン明示登録は採用していない。

```sh
cd flutter_probe
flutter build ios --simulator --debug --no-codesign --target lib/main.dart \
  --dart-define=INDEX_RELAY_SCENE_PROBE=true
cd ..
caffeinate -di python3 scripts/test-ios-scene-lifecycle.py \
  --native-app work/native-legacy-review/build/Build/Products/Debug-iphonesimulator/IndexRelay.app \
  --flutter-app flutter_probe/build/ios/iphonesimulator/Runner.app \
  --xctest-ui \
  --evidence work/ios-migration-matrix/lifecycle-evidence.json
```

Macのロックを解除して実行する。`caffeinate`は実行中だけ自動スリープを抑制し、スクリプトはUI試験の前後にOSのロック状態も検査する。独立したSimulator専用のXCTestプロジェクトを`work/`に生成し、Home→設定アプリ→元のアプリへの復帰を操作する。復帰直前も同じプロセスが生存すること、各起動のDartで`paused`の後に`resumed`が届くことを検査する。初回起動と2回の終了・再起動で繰り返す。

既定の試験は本物の0.9.7のみを起動し、その停止中に合成の音声・メタデータ・文字起こしを注入する。別のUI fixtureのSceneは持ち込まない。原本3ファイルの保持も照合し、失敗時も専用Simulatorを削除する。`--legacy-ui-fixture work/flutter-ios-upgrade/LegacyFixture.app`を追加すると、fixture由来の旧Sceneを本物の0.9.7へ引き継ぐ別のストレス試験になる。こちらは純粋な旧版のみの更新試験と区別する。

構成名と再接続回数を別々に判定し、名前が`flutter`以外であることだけで再接続が繰り返されたとは扱わない。旧版単独の更新では3回とも構成名が空のままだったが、`SceneDelegate.willConnectTo`を通り、`adoptRestoredScene`は呼ばれなかった。各回で同じプロセスの背景移行とDartの`paused`→`resumed`を確認し、原本3ファイルも一致した。旧delegateを再接続する別経路の測定は、これと区別して記録する。

fixture由来の旧delegate復元では、3回とも構成名が空のまま、各起動に1回ずつ`adoptRestoredScene`が呼ばれた。復帰時に再び作り直すことはなく、各回でSwiftの背景／前面処理とDartの`paused`→`resumed`が届いた。原本の全ファイルも一致した。したがって「作り直しは初回だけ」という前提は置かず、毎回の起動で必要になる経路として維持する。

セッション破棄は未採用。上記2経路で通知と原本保持を検証できたため、背景移行時にセッションを破棄する変更は不要と判断した。[AppleのAPI資料](https://developer.apple.com/documentation/uikit/uiapplication/requestscenesessiondestruction(_:options:errorhandler:))にあるScene削除を導入して、起動やApp Switcherの動作を変更することは避ける。構成名を一度だけ切り替える方式に変更する場合は別の移行処理として検証する。

通常エントリーポイントの未署名Releaseビルドと成果物検査、Flutter previewの26テスト・productionの2テスト、静的解析は成功した。モデル未同梱と内部名／表示名の一致も維持している。

この追加確認の[検査記録](FLUTTER_SCENE_LIFECYCLE_EVIDENCE.json)。合計6回の起動・背景復帰を検証し、専用Simulatorを削除した。ReleaseのRunnerとAppバイナリーに診断用マーカーがないことを確認し、Simulator成果物も診断フラグなしの通常ビルドに戻した。署名済み復旧版、双方向の事前照合、Flutter版の実機App Switcher確認は未完了のまま残る。

## 実機報告：解除後も画面の覆いが残る

利用者から、iPhoneをロック解除してもアプリの鍵マークの覆いが消えない報告があった。BLE受信の成否とは別の画面保護の問題として扱う。既存のScene通知に加え、Flutterの`sceneDidBecomeActive`とアプリの`didBecomeActiveNotification`からも復帰を試みる。所有するSceneとアプリの両方が実際にアクティブな場合だけ覆いを外す。通常のview更新・Data Protectionの解除・別Sceneの復帰だけでは外さない。

その後の実機エラーで、解除コールバックからの異常終了が判明した（次節）。覆いが残るという表示だけでは、アプリが動作中か、終了前の画面が残っているのかを判断しない。上記の画面保護対策だけでこのクラッシュが直ったとは扱わない。

PrivacyShieldの44チェックで、復帰通知を欠いた状態からの回復、アプリまたはSceneが非アクティブな場合、別Sceneの場合の保護継続、復帰後の再保護を検査した。これは実機での修正確認の代用とはしない。

実機追試は、同じBundle ID・署名で更新し、自動受信のオン／オフは変更せず、ホーム表示→端末ロック→解除してアプリ表示を行う。覆いが消えて編集・設定を操作できること、App Switcherでは覆いが維持されることを確認する。設定画面と共有・保存の取消／完了後も繰り返す。2026-10-22、`cad7113`の更新案内後に利用者から「問題なく期待通りの動き」と報告があり、端末ロック→解除後の復帰・操作を利用者確認済みとして記録した。App Switcherの遮蔽、共有・保存後の操作、長時間ロック中の受信・認識までは今回の報告から確認済みにしない。

## 実機解除時のクラッシュ

Xcodeで`applicationProtectedDataDidBecomeAvailable:`の`unrecognized selector`と、同メソッド内の`super.applicationProtectedDataDidBecomeAvailable(application)`での停止が報告された。[FlutterAppDelegateの公式実装](https://api.flutter.dev/ios-embedder/_flutter_app_delegate_8mm_source.html)にはこの任意のUIApplicationDelegateメソッドの実装がなく、親クラス呼出しが例外になる。`super`呼出しを削除し、自前のDeliveryController／AutomaticRelayServiceの再読込みを維持した。

回帰試験は`flutter_probe/integration_test/ios_protected_data_test.dart`。新しい専用Simulatorの空データで、Debug・Simulator限定のチャネルから実際のAppDelegateコールバックを3回呼ぶ。受信と送り先が停止したままで、異常終了せず再読込みできることを検査する。OSの端末ロック解除そのものを再現する試験ではなく、実機での再確認は別に必要。

```sh
# 新しく作成した専用SimulatorのIDを指定する。既存アプリの入った端末では実行しない。
cd flutter_probe
flutter test integration_test/ios_protected_data_test.dart \
  -d YOUR_DISPOSABLE_SIMULATOR_ID \
  --dart-define=INDEX_RELAY_PROTECTED_DATA_TEST=true
# 試験後は通常の実機用エントリーポイントへ戻す。
flutter build ios --release --no-codesign --target lib/main.dart
```

実施結果：iOS 27.0の専用Simulatorで1統合テスト（実コールバック3回）が成功し、専用Simulatorを削除した。従来のホーム切替試験ではこの保護データ解除コールバックを実行していなかったため、検証範囲を補う。実機のロック解除後の復帰・画面操作も、2026-10-22の利用者報告で確認済み。今回の報告には詳細な試行回数や追加のクラッシュログは含まれない。自動受信のオフ→オン後の再開は別件で、次節に実機追試の失敗と再対策を記録する。

## 自動受信のオフ→オン後の再開

利用者のログでは、起動後の探索・受信・文字起こしは進むが、手動のオフ→オンでマネージャーを作り直すと`Bluetoothの準備を待機します。`のままになる。起動直後の成功を再開処理の成功とは扱わない。

停止時にネイティブの`stopScanning()`を明示し、その後に処理を取り消す。旧受信器が所有する環境のtransfer／permissions／debug／update／hacksの5つのdelegateを外し、音声バッファとプロキシ参照を解放する。元のtransfer delegateを復元して古いマネージャーへの参照を残す処理を取り除いた。一部の停止処理に例外があっても残りの解放を実行し、外部の例外文ではなく固定された警告だけを記録する。受信位置・保存済み音声・文章・資格情報は変更しない。

アプリ側でも開始要求と停止操作をログに記録し、停止済みセッションからの進捗通知は無視する。停止後に届く固定の後片付け失敗警告だけは記録する。リングの消去・DFU・ボンディング解除は行わない。

停止順序と途中失敗時の解放をKotlin/Nativeの28チェックで確認し、既存の診断20チェックも再実行した。受信ブリッジは固定済み依存で両スライスを再生成し、通信基準と整合性を照合した。

`flutter_probe/integration_test/ios_receiver_lifecycle_test.dart`は、新しい専用Simulatorで実際の受信器を3回作成・開始・停止し、各回で二重停止も行う。実際の停止APIとdelegate解放で異常終了・後片付け失敗が起きないことを検査する。Simulatorには物理Bluetoothがないため、準備完了・再接続・音声受信の成功を証明する試験ではない。

この統合試験はiOS 27.0で成功し、後片付け失敗は0件、専用Simulatorの削除も確認した。試験用チャネルはDebug・Simulator限定で、Release版には含めない。

```sh
cd flutter_probe
flutter test integration_test/ios_receiver_lifecycle_test.dart \
  -d YOUR_DISPOSABLE_SIMULATOR_ID \
  --dart-define=INDEX_RELAY_RECEIVER_LIFECYCLE_TEST=true
flutter build ios --release --no-codesign --target lib/main.dart
```

実機追試：更新後のアプリで一度受信できたことを確認し、アプリを終了せず自動受信をオフ→2秒待つ→オンにする。準備完了後に短い録音を行い、新しい文字起こしが増えることを確認する。これを3回繰り返す。停止したままなら、開始・停止ログを含む新しい診断結果で再評価する。この追試手順の提示後、停止処理対策だけでは解消しない報告を受け、次節の方式へ変更した。

### 再追試の結果とマネージャー保持方式

2026-10-22の追加ログで、前述の停止・delegate解放対策だけでは解消しないことを確認した。13:55:37Zには初回のBluetooth準備完了、13:55:44Zに停止、13:55:55Zに新規マネージャー生成と準備待ちが記録され、13:56:17Zの報告時点でも準備待ちだった。内部で通知が止まる正確な原因は未確定。

手動オフでは`RingReceiver.pause()`でネイティブ探索を停止し、同じマネージャー・SDKイベント購読・CoroutineScopeを保持する。オンでは`resume()`で同じネイティブマネージャーから探索を再開する。既に開始済みの購読を追加せず、開始前にオフになった場合は準備完了後もオンまで探索を開始しない。リングの変更・受信エラー時の破棄は従来の完全停止を使う。

オフ中はSDKの転送許可用リングIDをnullにし、新規転送を許可しない。転送中のデータが遅れて届いてもKotlinの収集時とSwiftの保存時で無効化を確認し、音声保存・認識・受信位置更新を行わない。接続済みのBLEリンク自体の即時切断は保証しない。リングの保持音声を削除せず、再開時は永続保存済みの受信位置を設定する。診断に`受信ブリッジ: pause-resume-v1`と`同じ受信マネージャーで再開します`を残し、実機に新ブリッジが組み込まれたことを区別する。

統合試験を拡張し、3つの受信器それぞれで一時停止・再開を3回行い、マネージャー生成が計3回、再開が計9回、二重操作で追加生成・再開しないことを検査する。Simulatorでは物理Bluetooth準備完了後の探索再開・録音成功は検証できず、実機確認が必要。

今回の再検証結果：iOS 27.0の専用Simulatorで上記の統合試験が成功し、マネージャー生成3回・再開9回・後片付け失敗0件だった。Swiftの既存12スイート、Kotlin/Nativeの停止28・診断20チェック、Flutter静的解析が成功。両スライスの受信ブリッジを再生成し、通信基準・ローカル整合性を照合した。これは実機のBluetooth準備完了後の再開成功を証明するものではない。

実機確認結果：マネージャー保持方式（コミット`cea4223`）への更新案内後、利用者から「問題なく回復し、文字起こしできました」と報告された。手動オフ→オン後の受信回復と文字起こし完了を利用者報告で確認済みとする。今回の報告には試行回数・待機時間・詳細ログは含まれないため、3回連続の追試や長時間ロック中の再開まで確認済みとは扱わない。
