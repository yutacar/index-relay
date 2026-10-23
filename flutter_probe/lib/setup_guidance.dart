import 'package:flutter/material.dart';

import 'relay_controller.dart';

String modelGuidance(String status) => switch (status) {
  'ready' => '準備済み。音声を端末内で文字起こしします。',
  'copying' => 'モデルを端末内に配置しています。完了までお待ちください。',
  'checking' => 'モデルの整合性を確認しています。',
  'failed' => '準備に失敗しました。空き容量を確認して再実行してください。',
  'unchecked' => '配置済み。初回の利用時に整合性を確認します。',
  _ => '初回に約150MBのモデルを端末内に配置します。ネット接続は不要です。',
};

String deliveryGuidance(String phase) => switch (phase) {
  'confirmation' => '項目を開いて本文を確認し、送信してください。',
  'needsAttention' => 'エラー内容に従って送り先設定または本文を直し、項目を開いて再試行してください。',
  'unknown' => '投稿先で届いたか確認してください。再送すると重複する可能性があります。',
  'retryWaiting' => '再試行予定までお待ちください。アプリが自動で再試行します。',
  _ => '',
};

class ModelSetupCard extends StatelessWidget {
  const ModelSetupCard({super.key, required this.controller});
  final RelayController controller;
  @override
  Widget build(BuildContext context) {
    final status = controller.state.modelStatus;
    final preparing = status == 'copying' || status == 'checking';
    return Card(
      key: const Key('modelSetup'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('端末内モデル', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(modelGuidance(status)),
            if (preparing) const LinearProgressIndicator(),
            if (status != 'ready')
              TextButton(
                key: const Key('prepareModel'),
                onPressed: preparing
                    ? null
                    : () => controller.command('prepareModel'),
                child: const Text('モデルを準備する'),
              ),
            if (controller.error != null) Text(controller.error!),
          ],
        ),
      ),
    );
  }
}
