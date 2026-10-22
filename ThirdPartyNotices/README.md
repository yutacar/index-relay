# 録音受信ブリッジの依存

IndexReceiverBridgeは自作のKotlin/Nativeブリッジです。公開配布された以下のライブラリと、その推移的依存を静的リンクしています。

| コンポーネント | 固定版 | 公開メタデータ上のライセンス |
|---|---|---|
| io.github.coredevices.haversine:haversine | 2541a33 | Apache License 2.0 |
| Kotlin / Kotlin Native runtime | 2.2.20 | Apache License 2.0 |
| kotlinx-coroutines | 1.10.2 | Apache License 2.0 |
| kotlinx-serialization | 1.9.0 | Apache License 2.0 |
| kotlinx-io | 0.7.0 | Apache License 2.0 |
| Ktor | 3.2.1 | Apache License 2.0 |
| Kermit | 2.0.6 | Apache License 2.0 |

HaversineのiOS配布物にはHaversineSatelliteLibraryとPPCommonのネイティブライブラリが含まれます。公開配布物に記載されたライセンス情報をPOMとともに残しています。ソースJARに実装は含まれていません。公式アプリ全体のGPLコードやAlphaFingerのコードをコピーして組み込んだものではありません。

配布元：

- https://repo.maven.apache.org/maven2/io/github/coredevices/haversine/haversine/2541a33/
- https://kotlinlang.org/
- https://github.com/Kotlin/kotlinx.coroutines
- https://github.com/Kotlin/kotlinx.serialization
- https://github.com/Kotlin/kotlinx-io
- https://github.com/ktorio/ktor
- https://github.com/touchlab/Kermit

Apache License全文はApache-2.0.txt、Haversineの公開POMはHaversine-2541a33.pomを参照してください。ブリッジの再ビルド手順と固定依存はbridge/およびscripts/build-receiver-framework.shにあります。


## リポジトリのMITとの関係

ルートのMITは独自実装・文書に適用します。この表の外部依存やKotlin Native同梱ファイルをMITへ変更するものではありません。Haversineの表記は保存した公開POMの情報で、含まれるネイティブコンポーネントのソース公開やビルド再現性まで保証するものではありません。

公開ソースリポジトリには生成済みXCFrameworkを含めません。再ビルドはMaven配布物に依存します。バイナリを配布する場合は、このフォルダーのライセンス・NOTICEと配布物に追加の表記がないかを確認して同梱してください。

アプリアイコンは本プロジェクト用にAIで新規生成した図案です。公式ロゴの配布物は含めていません。
