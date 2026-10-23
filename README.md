# Index Relay

<img src="ios/IndexRelay/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="Index Relay icon" width="96">

[![Swift tests](https://github.com/yutacar/index-relay/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/yutacar/index-relay/actions/workflows/tests.yml)
[MIT](LICENSE) · [ビルド手順](docs/BUILD.md) · [確認結果](docs/PUBLICATION_VERIFICATION.md)

Index01のボタンを押して話すだけで、iPhoneに文字起こしを蓄積し、Discord・Telegramへ送る個人開発のiOSアプリです。

**0.9.8 / build 36 · iOS 26以降 · 日本語文字起こし · MIT**

非公式のアプリです。Pebble / Core Devicesの公式製品・公式サポートとは関係ありません。日常の受信は公式アプリを介さずIndex01と直接Bluetooth接続します。未設定個体の初期アクティベーション、ファームウェア更新・DFUの代替は提供しません。

## 使う版を選ぶ

| 版 | ブランチ | 確認範囲 |
| --- | --- | --- |
| ネイティブiOS 0.9.8／36 | [`main`](https://github.com/yutacar/index-relay/tree/main) | iPhoneで受信・文字起こし・投稿を確認。電池電圧の表示を追加 |
| Flutter iOS／Android 0.12.1／34 | [`codex/flutter`](https://github.com/yutacar/index-relay/tree/codex/flutter) | iOSは実機で受信・復帰を確認。Androidはエミュレーターと基本投稿を確認し、実機BLEは未確認 |

初回公開はソースのみです。App Store／Google Playやインストール用バイナリの配布は行っていません。ビルドには各SDKと、実機インストール時は利用者自身の署名設定が必要です。

```sh
git clone https://github.com/yutacar/index-relay.git
cd index-relay
# Flutter版の場合のみ選択
git switch codex/flutter
```

## できること

- リングを一度登録すると録音を自動受信・保存し、Apple SpeechAnalyzerで日本語を文字起こし。
- ロック中・バックグラウンドの処理に対応。中断した処理は再開時に継続。
- Discord Webhook、Telegram Botのグループ・スーパーグループへ複数同時送信。
- 送信前の確認／自動送信、送り先別の接頭語、明示したDiscord IDへのメンション。
- ホームに新しい順で日時と連携状況を表示。保存件数は初期値30件で変更可能。
- 複数選択による削除、標準補正した音声の再生・WAV書き出し。
- 「音声・録音情報」に録音データの電池電圧を表示。値がない録音は「不明」。

バックグラウンドの即時完了はiOSの実行枠・接続・モデル準備状況に依存します。強制終了後はアプリを開き直してください。再起動直後の初回ロック解除前は保存領域にアクセスできません。詳しくは[制約とテスト](docs/TESTING.md)。

## 開発を始める

Apple Silicon Mac、Xcode 27.1、Python 3.9以降を推奨します。実機はiOS 26以降とIndex01が必要です。受信ライブラリの初回生成にはJDK 17と同梱WrapperによるGradle 8.14.3を使用します。Gradleの別途インストールは不要です。

```sh
# JAVA_HOMEは自分のJDK 17のインストール先を指定
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
python3 scripts/verify-gradle-wrapper.py
bash scripts/build-receiver-framework.sh
open ios/IndexRelay.xcodeproj
```

Xcodeで自分のTeamと一意なBundle Identifierを設定してiPhoneへRunします。GitHub用のソースには生成済みXCFrameworkと個人の署名Teamを含めません。初回ビルド、署名、シミュレーターの制約は[ビルド手順](docs/BUILD.md)を参照してください。

## アプリの設定

1. 競合する公式アプリのBluetoothアクセスを止め、Index RelayにBluetoothを許可する。
2. 歯車 → 「リング・自動文字起こし」でリングを探索して選択し、自動処理をオンにする。
3. アプリを前面に置いて日本語モデルの準備を完了し、3〜5秒の録音で確認する。
4. 歯車 → 「送り先・送信方法」でDiscordまたはTelegramを追加する。最初は「送信前に確認する」をオンにする。

Telegramはグループ専用です。Botを追加してメッセージ送信を許可し、グループIDまたは公開スーパーグループの@ユーザー名を入力します。個別DM・チャンネル・開始リンク・候補取得は対象外です。トークンをソースやIssueへ貼らないでください。[詳しい操作手順](docs/USER_GUIDE.md)。

## テスト

```sh
python3 scripts/run-tests.py
python3 -m unittest discover -s tests/BridgeNetwork -v
```

macOSで12種類のSwiftテストを実行します。Bluetooth・音声認識モデル・実際の投稿は使いません。GitHub Actionsでも同じテストと通信検査ツールの合成テストを実行します。[実機の確認項目](docs/TESTING.md)。

## 構成とドキュメント

| 場所 | 内容 |
| --- | --- |
| `ios/IndexRelay/` | SwiftUI画面、自動処理、音声処理、永続化、投稿 |
| `bridge/` | Haversineを利用するKotlin/Native受信ブリッジ |
| `tests/` | 状態遷移・音声・保存などのテスト |
| `scripts/` | ビルド・テスト・公開前チェック・公開用コピーの生成 |
| `ThirdPartyNotices/` | 外部ライブラリの配布情報とライセンス |

- [設計と処理の流れ](docs/ARCHITECTURE.md)
- [データとプライバシー](docs/PRIVACY.md)
- [GitHub登録手順](docs/PUBLISHING.md)
- [変更履歴](CHANGELOG.md) / [開発への参加](CONTRIBUTING.md) / [セキュリティ](SECURITY.md)

## ライセンスと参照

独自コード・ドキュメントは[MIT](LICENSE)。外部ライブラリには各ライセンスが適用され、MITへの変更を意味しません。[依存情報](ThirdPartyNotices/README.md)を参照してください。

録音受信はHaversine `2541a33` を利用します。通信・音声デコーダーすべてを独自実装した構成ではありません。[Index01公式開発情報](https://developer.repebble.com/index-01/)と[AlphaFinger](https://github.com/ddlsmurf/AlphaFinger)を仕様調査の参考にしました。AlphaFingerのコードは含めていません。
