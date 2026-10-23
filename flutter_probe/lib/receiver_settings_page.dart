import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'relay_controller.dart';

class ReceiverSettingsPage extends StatelessWidget {
  const ReceiverSettingsPage({super.key, required this.controller});
  final RelayController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final state = controller.state;
      return Scaffold(
        appBar: AppBar(title: const Text('リング・自動受信')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (state.capabilities.isNotEmpty) ...[
              Text('Android API ${state.capabilities['api']}'),
              if (state.capabilities['supported'] != true)
                const Text('自動受信にはAndroid 12以降が必要です。'),
              Text(
                state.capabilities['bluetooth'] == true
                    ? '近くのデバイス: 許可済み'
                    : '近くのデバイス: 未許可。探索時に許可してください。',
              ),
              Text(
                state.capabilities['radio'] == true
                    ? 'Bluetooth: オン'
                    : 'Bluetooth: オフ、未許可、または非対応',
              ),
              Text(
                state.capabilities['notifications'] == true
                    ? '通知: 許可済み'
                    : '通知: オフ。確認待ち・要対応を通知できません。受信は継続できます。',
              ),
              TextButton(
                key: const Key('applicationSettings'),
                onPressed: () => controller.command('openApplicationSettings'),
                child: const Text('アプリの権限・通知設定を開く'),
              ),
            ],
            const Text('Android実機のBLE接続・長時間のロック中動作は未検証です。'),
            ListTile(
              title: const Text('登録したリング'),
              subtitle: Text(state.receiverName),
            ),
            SwitchListTile(
              key: const Key('receiverEnabled'),
              title: const Text('自動で受信する'),
              value: state.receiverEnabled,
              onChanged: (v) =>
                  controller.command(v ? 'enableReceiver' : 'disableReceiver'),
            ),
            Text(state.receiverStatus),
            Text(state.receiverRunning ? '受信サービス実行中' : '受信サービス停止中'),
            if (state.receiverEnabled && !state.receiverRunning)
              FilledButton(
                onPressed: () => controller.command('enableReceiver'),
                child: const Text('受信を再開'),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Android 12以降で「近くのデバイス」を許可して開始します。通知も許可すると確認待ちを見逃しにくくなります。通知が表示されない場合はこの画面で受信を停止できます。強制停止や再起動後はアプリを開いて受信を再開してください。',
              ),
            ),
            OutlinedButton.icon(
              key: const Key('scanReceiver'),
              icon: const Icon(Icons.search),
              label: const Text('リングを探索'),
              onPressed: state.receiverRunning
                  ? null
                  : () => controller.command('scanReceiver'),
            ),
            TextButton(
              onPressed: () => controller.command('openBluetoothSettings'),
              child: const Text('Bluetooth設定を開く'),
            ),
            ...state.receiverCandidates.map(
              (device) => Card(
                child: ListTile(
                  title: Text(device['name'] as String),
                  subtitle: Text(device['address'] as String),
                  trailing: const Icon(Icons.bluetooth_connected),
                  onTap: () => controller.command('enableReceiver', {
                    'address': device['address'],
                  }),
                ),
              ),
            ),
            if (controller.error != null)
              Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const Divider(),
            const Text('受信診断（音声・本文・資格情報は含みません）'),
            TextButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(
                  text: state.receiverEvents
                      .map(
                        (e) =>
                            '${e['time']} ${e['code']} ${e['recordingKey'] ?? ''}',
                      )
                      .join('\n'),
                ),
              ),
              child: const Text('ログをコピー'),
            ),
            ...state.receiverEvents
                .take(30)
                .map(
                  (e) => Text(
                    '${e['code']} ${e['recordingKey'] ?? ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
          ],
        ),
      );
    },
  );
}
