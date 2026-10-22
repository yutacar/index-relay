# GitHub登録の準備と手順

## 公開用コピー

実機用の作業フォルダーをそのままpushせず、公開対象を限定したコピーを作ります。

```sh
python3 scripts/prepare-github.py ../index-relay-public
cd ../index-relay-public
python3 scripts/check-publication.py
python3 scripts/run-tests.py
```

コピーするのはSwift／Kotlinソース、Xcodeプロジェクト、アセット、テスト、スクリプト、現行ドキュメント、外部ライセンスです。個人の署名Teamを除去し、Bundle Identifierは例示用に置換します。元のプロジェクトの署名・Bundle Identifierは変えません。

生成済みXCFramework、work、過去のoutputs、xcuserdata、録音・診断ログはコピーしません。Gradle Wrapperと依存照合XMLは含め、書き出したWrapperを再検証します。既存のコピーを上書きしないため、再実行時は新しい出力先を指定します。削除や自動pushは行いません。

Wrapper JARは固定パスと公式SHA-256が一致する場合だけ許可し、その他のJARは拒否します。

`check-publication.py`は秘密情報らしいパターン・個人パス・署名Team・音声・大型バイナリを検査し、値そのものは出力しません。Git管理下では未追跡・追跡済みファイルを対象にします。ステージ内容と作業ツリーが違う場合もあるため、最終的に`git diff --cached`で確認してください。検査だけで秘密情報の完全な不在を証明するものではありません。

## ライセンスと配布

所有者の選択により独自コード・文書はMITです。著作権表記は`2026 Index Relay contributors`とし、個人の実名は追加していません。Haversineなどは元のライセンスが適用されます。再生成したバイナリを別途配布する場合はThirdPartyNoticesと配布物内の表記を同梱してください。

約123MBのXCFrameworkはソースリポジトリに含めず、利用者が生成します。GitHubは通常Gitで50MiB超を警告・100MiB超を拒否するため、将来バイナリ配布を追加する場合はReleaseアセットなどを別途検討します。[GitHub公式](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)

## ローカルGitと初回登録

公開用コピー内で実施します。実行前に、公開先アカウント・リポジトリ名・公開／非公開を決めてください。

```sh
git init -b main
git add .
git diff --cached --stat
git diff --cached --check
# 氏名・メールの公開範囲も確認してからコミット
git commit -m "Initial import of Index Relay"
```

GitHub上で空のリポジトリを作り、案内されたURLを使って登録します（README／LICENSEの自動生成は選ばない）。次は利用者が実行する例です。

```sh
git remote add origin https://github.com/OWNER/REPOSITORY.git
git push -u origin main
```

この準備作業だけではGitHubリポジトリ作成・push・Release公開を行いません。新しいGitHub Actionsの結果はpush後に確認します。設定の「Private vulnerability reporting」はSECURITY.mdの案内に合わせて有効化してください。

## 登録前の確認

- README、MIT、第三者ライセンス、ビルド手順を確認。
- 自動テスト、署名なしアプリビルド、公開候補チェック。
- 意図したファイルだけがステージされ、個人Team・音声・資格情報がないことを確認。
- 実機確認済み範囲とTelegramなど未確認範囲を明記。
- GitHubのアカウント／名前／公開範囲を決めてから登録。
