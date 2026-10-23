# 公開前の確認結果

確認日：2026-10-23。公開候補は[index-relay](https://github.com/yutacar/index-relay)です。Privateで準備した後、2026-10-23にPublicへ変更しました。未ログインでリポジトリと両ブランチのREADMEを取得でき、旧メールを含む書き換え前の先端コミット2件は未ログインでも取得できないことを確認しました。Private vulnerability reporting、Secret scanning、Push protectionは有効です。最新の自動実行結果は[GitHub Actions](https://github.com/yutacar/index-relay/actions)を参照してください。以下はローカルで実行した確認の記録です。

## 取得元と確認環境

- 修正済みの履歴から新規cloneしたソースを使用。ネイティブ版とFlutter版を別の作業ディレクトリでビルドし、生成済みアプリや個人の署名設定はコピーしていない。
- 移行先のGitHubリポジトリからも別の新規cloneを作成し、`main`のブリッジ生成・iPhone向けReleaseビルド・公開候補チェックを再確認した。
- Apple Silicon Mac、Xcode 27.1（27A9275）、JDK 17、Gradle 8.14.3、Flutter 3.47.7／Dart 3.13.5。Android側は同梱設定のGradle 9.3.1とAPI 36のSDKを使用。
- インストール済みSDKと依存ダウンロードのキャッシュは再利用。完全に空のSDK／依存キャッシュからの取得を検証した記録ではない。
- ビルド対象コードはネイティブ版`5151321`、Flutter版`dbc9b36`。今回の公開準備の後続変更はREADME、手順、セキュリティ案内、確認記録などの文書のみ。

## ビルド・検査

| 対象 | 結果 |
| --- | --- |
| `main`：受信ブリッジ | strict依存照合付きで実機arm64／Simulator arm64を再生成。通信基準・生成物の整合性検査に成功 |
| `main`：ネイティブiOS | iPhone向けRelease・署名なしビルド成功。版0.9.8／36 |
| `main`：Swift | 全12スイート・519チェック成功 |
| `main`：Python | Wrapper 10、通信検査12、ビルド検査18、公開検査8の計48テスト成功 |
| `codex/flutter`：受信ブリッジ | Flutter版のソースから両スライスを再生成。依存照合・通信基準・整合性検査に成功 |
| `codex/flutter`：Flutter | 整形チェック・分析成功。previewは26テスト成功・2テストskip、productionの表示／梱包テスト2件成功 |
| `codex/flutter`：Swift | 全12スイート・529チェック成功 |
| `codex/flutter`：Python | 上記48テストに加え、ReleasePackaging 8・LiveVerification 18の計74テスト成功 |
| `codex/flutter`：Androidネイティブ | `testPreviewDebugUnitTest` 10テスト成功、解決済み依存一覧の照合成功 |
| `codex/flutter`：iOS | `flutter build ios --release --no-codesign --target lib/main.dart`成功。版0.12.1／34、アプリ約34.5 MB、`ggml-base.bin`の混入なし |
| `codex/flutter`：Android | ARM64 production Release・署名なしAPKのビルド成功。版0.12.1／34、約155.9 MB（端末内認識モデルを含む） |
| Android APK監査 | 試験用アセット・注入クラスの除外、ライセンス表示、モデルの固定ハッシュ、ARM64、未署名を確認 |
| 公開候補 | 両ブランチの公開候補チェック成功。個人の署名設定・資格情報・録音・SDK・モデル・アプリ生成物をコミットしていない |

Flutterのskip 2件はpreview実行では対象外のproduction専用テストで、別途productionで2件を実行した。ビルド成功はインストール・BLE接続・OSのバックグラウンド動作の保証ではない。署名なし成果物は一般配布用のインストーラーとして公開しない。

## 履歴とメール

移行対象の修正済み3コミットと311個のGit blobを照合し、旧メール2件の一致はなかった。author／committerはGitHubのnoreplyメール。上記2ブランチだけを新しい独立リポジトリにpushし、旧Actions、PR、退避ブランチ、ローカルのバックアップは移していない。

書き換え前の2ブランチの先端コミットは、移行先のGitHub APIでは`No commit found for SHA`になった。旧リポジトリの両ブランチは新リポジトリに包含され、独自のRelease・PR・未解決Issueはありませんでした。検証済みのローカルbundleへ退避し、公開用リポジトリの保守には不要と確認しました。この確認は、他の公開リポジトリ・第三者のコピー・GitHub全体から過去のメールが消えたことを意味しない。

## 実機確認との区別

iOSの受信・文字起こし・ロック解除後の復帰、自動受信オフ→オン後の再開、基本投稿は開発時の利用者報告による確認。今回のソース公開準備で実機へのインストールや実投稿は行っていない。

Androidの実機BLE、長時間の背景動作、実録音の精度・電池消費は未確認。過去のエミュレーター・実サービス基本送信の結果はFlutter版の[対応状況](https://github.com/yutacar/index-relay/blob/codex/flutter/docs/FLUTTER_STATUS.md)を参照。ネイティブ版の電池電圧表示も今回のビルド確認だけでは実機での表示を検証していない。

## 公開操作

ソース公開の操作と公開後の設定は[公開手順](PUBLISHING.md)にまとめた。履歴を修正する前の作業コピーや退避ブランチから、公開先へmirror pushしないこと。

## 旧リポジトリの整理

2026-10-23、必要な両ブランチの包含とローカルbundleの検証後、`index-relay-private-archive`を削除しました。公開先の`index-relay`は引き続き利用できます。退避データはローカルのGit管理対象外に保持し、GitHubへアップロードしません。
