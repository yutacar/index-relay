import 'package:flutter/material.dart';

import 'build_policy.dart';
import 'delivery_page.dart';
import 'relay_controller.dart';

class LiveDeliveryPage extends StatelessWidget {
  const LiveDeliveryPage({super.key, required this.controller});
  final RelayController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final state = controller.state;
      final enabled = state.destinations.where((d) => d.enabled).toList();
      final unfinished = state.deliveries.any(
        (j) => !['sent', 'cancelled'].contains(j['phase']),
      );
      final reason = !previewMode
          ? 'この画面はpreview版専用です。'
          : state.receiverEnabled
          ? 'リングの自動受信を停止してから試験してください。'
          : enabled.isEmpty || enabled.any((d) => !d.verified)
          ? '設定で試験用の送り先を登録・有効化してください。'
          : unfinished
          ? '先に送信一覧の未完了項目を確認してください。'
          : state.busy || controller.receiving
          ? '文字起こしが完了するまでお待ちください。'
          : null;
      return Scaffold(
        appBar: AppBar(title: const Text('Discord・Telegramの送信確認')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('試験用チャンネル・グループだけをオンにしてください。資格情報は送り先設定に入力します。'),
            const SizedBox(height: 12),
            Text(
              state.requiresConfirmation
                  ? '送信前の確認: オン。認識後、送信一覧で承認してください。'
                  : '送信前の確認: オフ。下の操作で、オンの送り先へ実際に自動投稿します。',
            ),
            const Text(
              '今回オンの送り先',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            ...enabled.map(
              (d) => ListTile(
                title: Text(d.name),
                subtitle: Text(
                  '${d.provider} · 接頭語: ${d.prefix.isEmpty ? 'なし' : d.prefix}',
                ),
              ),
            ),
            if (reason != null) Text(reason),
            FilledButton.icon(
              key: const Key('liveTrialReceive'),
              onPressed: reason != null
                  ? null
                  : () async {
                      if (await controller.receiveMock() && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('試験音声を保存しました。文字起こし後の送信状況を確認してください。'),
                          ),
                        );
                      }
                    },
              icon: const Icon(Icons.science_outlined),
              label: const Text('試験音声を1件取り込む'),
            ),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DeliveryPage(controller: controller),
                ),
              ),
              child: const Text('送信一覧・確認待ちを開く'),
            ),
            if (controller.error != null) Text(controller.error!),
            const Divider(),
            const Text('確認すること', style: TextStyle(fontWeight: FontWeight.bold)),
            const Text(
              '1. 確認ありで取り込み、承認するまで届かないことを確認。\n2. 本文が「接頭語＋半角スペース＋文字起こし」で各先に1件ずつ届くことを確認。\n3. Discordは表示と実際のメンション通知を別々に確認。Telegramはグループの到着を確認。\n4. 確認なしでも1件だけ試す。\n5. すべてオフで通常の模擬受信を行い、オンへ戻しても過去の内容が投稿されないことを確認。',
            ),
            const SizedBox(height: 12),
            const Text(
              '通信が切れた場合',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text(
              '接続前のオフラインは送信待ちになり、復旧後に再開します。送信途中の中断は結果不明になる場合があります。投稿先を確認してから対応し、結果不明を繰り返し再送しないでください。',
            ),
          ],
        ),
      );
    },
  );
}
