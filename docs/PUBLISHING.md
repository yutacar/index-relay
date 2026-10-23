# ソース公開と保守の手順

## リポジトリとブランチ

公開先は[Index Relay](https://github.com/yutacar/index-relay)です。2026-10-23にPublicへ変更し、未ログインで両ブランチのREADMEを取得できることを確認しました。旧メールを含む開発履歴・ローカル退避データは公開対象に含めません。

| ブランチ | 内容 | バージョン |
| --- | --- | --- |
| `main`（既定） | ネイティブiOS版・SwiftUI | 0.9.8／36 |
| `codex/flutter` | Flutter版・iOS／Android | 0.12.1／34 |

両ブランチを取得できます。ビルド中に同じ作業ディレクトリのブランチを切り替えず、必要なら別のcloneを使います。

```sh
git clone https://github.com/yutacar/index-relay.git
cd index-relay
# Flutter版を選ぶ場合だけ実行
git switch codex/flutter
```

## 移行時に持ち込まないもの

旧メールを修正した3コミットを起点に、上記2ブランチだけを新しいリポジトリへ移しました。古いActions、PR、退避ブランチ、旧メールを含むローカルバックアップは移しません。旧コピーからの`git push --mirror`や退避ブランチのpushは避けてください。今後のコミットにもGitHubのnoreplyメールを使います。

`work/`、署名情報、資格情報、個人の録音・文字起こし・診断ログ、生成済みXCFramework、SDK、WhisperモデルはGit管理対象外です。ビルド結果の共有にはこれらのディレクトリを丸ごと添付せず、公開用に点検した要約を使います。

## 公開候補の確認

[ビルド手順](BUILD.md)と[公開前の確認結果](PUBLICATION_VERIFICATION.md)を参照してください。

```sh
python3 scripts/verify-gradle-wrapper.py
python3 scripts/check-publication.py
python3 scripts/run-tests.py
python3 -m unittest discover -s tests/GradleWrapper -v
python3 -m unittest discover -s tests/BridgeNetwork -v
python3 -m unittest discover -s tests/BridgeBuild -v
python3 -m unittest discover -s tests/Publication -v
```

`check-publication.py`は作業ツリーも検査します。最終的な公開対象はコミット済みのファイルです。個人のTeamや一意なBundle IDをXcodeで設定した後は、設定差分を公開コミットへ入れないでください。パターン検査だけで秘密情報の完全な不在を証明するものではありません。

Flutter版では`flutter_probe/README.md`に従い、Flutter分析・テスト、iOS署名なしビルド、Android署名なしproduction APKの検査も実行します。Androidの実機BLE・ロック中動作は未確認です。API投稿試験は専用の送り先で行い、CIやビルド確認で実際の資格情報を使用しません。

## GitHubの公開設定と確認

公開時にPrivate vulnerability reporting、Secret scanning、Push protectionを有効化しました。以下は公開・保守時の確認手順です。

1. README、MIT、外部ライセンス、確認済み／未確認の範囲を確認する。
2. 最新コミットのCI、Actionsログ・アーティファクトを確認する。公開後はActions履歴も閲覧可能になる。
3. Settings → General → Danger Zone → Change repository visibilityからPublicへ変更する。
4. SecurityのPrivate vulnerability reportingを有効化する。Secret scanning、Push protection、Dependabot alertsは利用可能な設定を確認する。
5. 未ログインのブラウザーでREADME・ブランチへの導線・clone URLを確認する。

可視性変更の効果は[GitHub公式](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)、脆弱性報告窓口は[設定手順](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)を参照してください。公開後にPrivateへ戻しても、第三者が取得したコピーは取り消せません。

## ライセンスとバイナリ配布

独自コード・文書はMITです。Haversine、Flutter、whisper.cpp等には各ライセンスが適用されます。[ThirdPartyNotices](../ThirdPartyNotices/README.md)を参照してください。初回公開はソースのみとし、署名済みIPA・APK、モデル、XCFrameworkをReleaseへ添付しません。

バイナリを配布するときは、署名・同梱ライセンス・モデル配布条件・実機検証を別途確認します。未署名APKのビルド成功は、Android実機の動作確認や一般配布の準備完了を意味しません。

## 従来の書き出しスクリプト

`scripts/prepare-github.py`はネイティブiOS版だけを別フォルダーへ書き出す保守用ツールです。`flutter_probe/`を含まず、履歴・リモートも作りません。今回の2ブランチの移行やFlutter版の取得には使用せず、上記のcloneを使用してください。
