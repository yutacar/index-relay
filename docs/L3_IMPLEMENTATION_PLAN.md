# L3：アプリ切替画面を保護するための実装指示

状態：0.9.5 / build 28で実装。利用者の指示により、実際の画面・操作の確認は実機で行います。以下は実装方針と実機確認手順です。ホーム画面の文字起こし、音声詳細、送り先設定、送信一覧を含め、アプリのスナップショットに本文や資格情報を残さないことを目標にします。録音受信・文字起こし・送信のバックグラウンド動作は維持します。

## 1. 保護対象と成立条件を先に固定する

- アプリ切替画面・ホーム移動・ロック・他アプリへ移動する間の、アプリ自身の表示を保護する。
- inactiveでも覆う。権限要求、コントロールセンター、通知センターなどでも一時的に本文が隠れる仕様を利用者へ説明する。
- 共有先やFilesなど、他プロセス・OSが表示するプレビュー、共有後のデータ、通常のスクリーンショット／画面収録を遮断する機能とは区別する。
- iOSのsnapshotはバックグラウンド遷移時に作られるため、非同期で後から隠す処理だけにしない。[Apple：バックグラウンド移行時のUI](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background)。

## 2. 対象のSceneへ結び付ける

1. `PrivacyShield.swift`を独立したファイルで追加する。`@MainActor`の管理クラスを用意し、XcodeのSourcesへ追加する。
2. `AutomaticRelayView`の外側に、表示中の`UIView.window?.windowScene`を得る小さなUIKitブリッジを設ける。Sceneへ付いた時に管理クラスへ渡し、外れた時は解除する。
3. `UIApplication.shared.connectedScenes.first`やプロセス全体のsingletonで対象を推測しない。管理はSceneごとに行う。Sceneが交換・破棄された際は古いウィンドウと監視を破棄する。
4. SwiftUIの`.sheet`の内側だけにoverlayを付けない。設定・音声詳細などのシートも同じSceneに属するため、そのSceneへ結び付けた別ウィンドウで覆う構成を試す。

現行の`AutomaticRelayView`の`scenePhase`処理は自動受信・送信のライフサイクル管理に使っている。保護画面のために`enterBackground()`などの呼出しを削除・延期しない。

## 3. 入力を奪わない覆いを作る

- `UIWindow(windowScene: 対象Scene)`を作り、単色の不透明背景とアプリ名・ロックアイコンだけを表示する。本文をぼかすだけの実装にはしない。
- アプリの通常ウィンドウ／シートより上のレベル（まず`.alert + 1`）を試す。OSの権限UIやキーボードも必ず想定どおりになるとは扱わず、手順5で検証する。
- `makeKeyAndVisible()`を使わず、`isHidden = false`で表示する。必要なら`canBecomeKey = false`の専用Windowを使い、元のkeyWindow・firstResponderを奪わない。
- ウィンドウはユーザー操作を受け取らない構成とする。`isUserInteractionEnabled = false`に加え、Windowの`hitTest`はnilを返すことを候補にする。権限・共有・Filesの実操作で非干渉を確認する。
- カバーをアクセシビリティのmodalにしない。activeへ復帰したら覆いを隠し、通常のアクセシビリティ操作も戻ることを確認する。
- Sceneのboundsに追従し、回転・ウィンドウサイズ変更に対応する。表示・解除にアニメーションや待機時間を設けない。

keyWindowはキーボード等のイベント先になるため、覆いをkeyにしない設計にする。[Apple：UIWindow](https://developer.apple.com/documentation/uikit/uiwindow)。

## 4. 遷移を同期的に処理する

- 対象Sceneがactiveを離れる通知／delegateで、メインスレッド上から同期的にカバーを表示する。`Task`、`DispatchQueue.main.async`、遅延タイマーへ丸投げしない。
- backgroundに入る時もカバーを維持する。foregroundへ戻る途中では維持し、対象SceneのdidBecomeActiveで解除する。
- 接続時点でSceneが非activeなら、最初から覆う。同じ通知を複数回受けてもWindowを増殖させない。
- Scene切断時に監視とカバーを解放する。別Sceneのactivation通知で解除しない。
- アプリが権限を求めたという理由だけでカバーを解除しない。権限中の操作問題は、keyWindow・hit testing・Windowレベルを修正して解消する。
- AppleはScene単位で通知する。SwiftUI全体の`scenePhase`だけでタイミングを満たせない場合は、対象SceneのUIKitライフサイクル通知を使う。[Apple：sceneWillResignActive](https://developer.apple.com/documentation/uikit/uiscenedelegate/scenewillresignactive(_:))。

## 5. 合成データを使って確認する

個人の音声や実トークンを試験画像へ入れず、`L3_TEST_SECRET_123`などの合成本文を使う。

| 開始画面・操作 | 必須の確認 |
| --- | --- |
| ホームに合成文字起こしを表示 → App Switcher | サムネイルに文字・時刻・相手などが残らず、カバーだけ見える |
| 音声詳細／送り先編集／送信一覧を開く → App Switcher | シートも含めて同様に隠れる |
| Home、ロック、他アプリへ移動 → 復帰 | カバーが解除され、スクロール・編集・再生などを操作できる |
| 通知・Bluetooth・音声認識の初回許可 | OSボタンの許可／拒否を押せ、終了後に通常画面へ戻れる |
| 通知センター／コントロールセンターを開閉 | 開いている間は覆い、閉じた後は操作できる |
| ShareLinkで共有 → コピー／キャンセル → 復帰 | 共有処理が完了し、背面の別ボタンを実際に操作できる |
| 原音・補正音をfileExporter → キャンセル | Pickerが閉じ、履歴などの操作ができる |
| fileExporter → このiPhone内へ保存 | 保存ファイルの存在・再生とアプリ復帰後の操作を確認する |
| fileExporter → iCloud Driveへ保存 | 保存・失敗・キャンセル時の戻りを確認する |
| 上記を縦横、明暗、繰返しで試す | はみ出し・古いカバー・keyWindowの変化がない |
| ロック中にリングで録音 → 復帰 | 音声保存・文字起こしの蓄積が継続している |

最低限、iOS 26と現在使用中のiOS 27の実機で確認する。用意できないOSは未検証として記録する。シミュレーター成功だけでApp Switcherやロックの成立を判断しない。

## 6. 過去のUI試験と今後の自動化

前回の試験はfileExporterのキャンセル要素をButtonとして扱えず、hit pointが`{-1,-1}`になった。その結果はカバーの不具合とも正常動作とも断定できない。

- テストの言語を固定し、権限ダイアログをinterruption handlerで処理する。
- OSのPickerはAX上でOtherになる場合もある。現在の要素ツリーに沿って判定し、存在と`isHittable`を待ってから押す。固定座標や-1座標でのタップは使わない。
- キャンセルを押しただけで成功にしない。Pickerの消失と、その後ホーム上の別操作が成立するところまでassertする。
- ShareLinkも共有メニューの表示だけで終えず、コピー／キャンセル後の復帰まで検証する。
- カバー自体の状態遷移・Scene分離・繰返し通知は自動テストする。App Switcherの画像は実機で採取し、合成の秘密文字列が見えないことを人が確認する。

## 7. 取り込み条件

利用者の指示により、開発版ではL3を有効にし、UIフローと実機snapshotの確認を利用者が行う。Debug／Releaseのコンパイルと12スイート・452チェックを検証する。未実施項目を実施済みと扱わず、端末・OS・開始画面・操作・結果を記録する。実機試験が完了するまで、画面保護がすべてのシステムUIと正常に共存すると保証しない。


## 実装済みの構成

- `PrivacyShieldAnchor`をホームのNavigationStackへ付け、表示中の`windowScene`へ接続。
- `ScenePrivacyShield`は対象SceneのUIKit通知をselectorで同期的に受ける。非active化・background・foreground復帰途中は覆い、didActivateで解除。Scene切断とAnchor破棄で監視・ウィンドウを片付ける。
- `PrivacyShieldWindow`はkeyWindowにならず、hitTestはnil。`PrivacyShieldViewController`が単色背景・アプリ名・ロックアイコンを表示。
- `PrivacyShieldState`の28チェックでSceneの分離と遷移を検証。画面の実際の見え方・権限・共有・保存操作は実機確認待ち。

## 実装後の実機確認表

XcodeでRunして**0.9.5 / build 28**へ更新します。実際の秘密情報を使わず、テスト用の録音・文章で確認してください。

1. ホームに文字起こしを表示してApp Switcherを開く。本文が見えず、Index Relayとロックアイコンだけになること。
2. アプリへ戻り、設定を開く。音声詳細、送り先設定、送信一覧でも1と同じ操作を繰り返す。
3. 通知センター／コントロールセンターを開閉し、戻った後に画面を操作できること。
4. 文字起こし・音声の共有を開き、コピーまたはキャンセルを実行。戻った後に設定など別のボタンを操作できること。
5. 音声のファイル保存でキャンセルと実際の保存を試す。Pickerが閉じ、アプリを操作できること。可能ならiCloud Driveでも確認する。
6. 未許可の権限要求がある場合、許可／拒否を操作でき、戻ると元の画面が見えること。設定のリセットや再インストールは必須にしない。
7. ロック中にリングで録音し、解除して文字起こしが増えていること。
8. 文字入力中、端末回転後、繰返しのアプリ切替でも、カバーの隙間・残留・操作不能がないこと。

記録：OS／機種、試した番号、問題が起きた画面・操作、結果。iOS 26など試せない環境は未確認として残します。
