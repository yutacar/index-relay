# Flutter対応状況とブランチ管理（2026-10-23）

Flutter対応完了版の継続管理ブランチは`codex/flutter`です。旧名`codex/flutter-ios-migration-rehearsal`を改名しました。既存のネイティブiOS版は`main`に保持し、今回mainへのマージや既定ブランチの変更は行いません。

| ブランチ | 用途 | アプリ版 |
| --- | --- | --- |
| `codex/flutter` | Flutter版の開発・修正・検証の基準 | 0.12.1／34 |
| `main` | 既存のネイティブiOS版 | 0.9.8／36 |

「対応完了」はFlutter画面と各OSサービスの実装を統合した状態を示します。Android実機の検証完了やストア公開を示すものではありません。Flutterは画面を共通化し、iOSはSwift、AndroidはKotlinが受信・保存・認識・投稿を担当します。状態遷移や投稿の再送規則を変更するときは両方の実装とテストを確認します。

ネイティブ版mainの0.9.8／36では、音声・録音情報に録音データの電池電圧を追加しました。この機能はネイティブ版への追加で、Flutter版への取り込みは未実施です。

## 確認済みの範囲

| 対象 | 確認結果 |
| --- | --- |
| iOS実機 | 利用者報告で録音受信・文字起こし、ロック解除後の画面復帰、自動受信の手動オフ→オン後の受信回復と文字起こしを確認 |
| iOS Simulator | 旧版データの更新・復旧、Sceneの背景／前面遷移、保護データ解除コールバック、一時停止・再開時のマネージャー再利用を確認 |
| Androidエミュレーター | API 31／33／36で合成音声の保存・認識と設定UIを確認。長さ別の計測条件は互換性資料を参照 |
| Androidからの実投稿 | DiscordとTelegramグループへ確認あり・自動送信で各2件の到着を利用者が確認。接頭語・メンションの追加実送信試験は未実施 |

iOS実機の利用端末は従来申告のiPhone 18 Pro／iOS 27.0.1です。最新の成功報告に試行回数・待機時間・詳細ログはなく、全条件での連続稼働保証とは扱いません。以前のSwiftUI版の実機確認は、Flutter版で再確認した範囲と区別します。

## 残る確認

- Android実機とIndex01間のBLE受信、ロック中・省電力・電池消費。
- Flutter版iOSのApp Switcherで本文が隠れることと、共有・保存の全操作経路での復帰。
- 署名済みネイティブ復旧版の保管と双方向の署名・更新事前照合。実機受信成功だけで復旧手順まで完了とは扱わない。
- 実機での長時間ロック・連続録音・接続断からの回復、長文認識の品質。個別の利用者報告やSimulator試験から全条件の成功を推定しない。

## 開発と資料の入口

```sh
git fetch origin
git switch codex/flutter
```

旧名を使っている別のローカルcloneでは、未コミットの変更を保持したまま次のように追従できます。

```sh
git branch -m codex/flutter-ios-migration-rehearsal codex/flutter
git fetch origin --prune
git branch --set-upstream-to=origin/codex/flutter codex/flutter
```

ディレクトリ名`flutter_probe/`、preview／productionのflavor名、Bundle ID、保存形式はこの改名で変更しません。アプリは[Flutterの手順](../flutter_probe/README.md)、共通ブリッジは[BUILD.md](BUILD.md)、iOSの更新・退避は[移行手順](FLUTTER_IOS_MIGRATION_READY.md)を参照してください。

step別資料とJSONの検証記録は、その段階の結果を記した履歴として残します。過去のブランチ名・コミット・「未確認」の記載を一括置換せず、現在の状況はこの文書と[レビュー対応](FLUTTER_REVIEW_FOLLOWUPS.md)、[実送信確認](FLUTTER_LIVE_DELIVERY.md)を参照してください。`prepare-github.py`は既存ネイティブiOS版の限定書き出し用で、Flutter版の取得にはこのブランチのcloneを使用します。
