import 'package:flutter/material.dart';

import 'relay_controller.dart';
import 'setup_guidance.dart';

class DeliveryPage extends StatelessWidget {
  const DeliveryPage({super.key, required this.controller, this.recordingID});
  final RelayController controller;
  final String? recordingID;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final jobs = controller.state.deliveries.where(
        (j) => recordingID == null || j['recordingID'] == recordingID,
      );
      return Scaffold(
        appBar: AppBar(title: const Text('送信一覧・確認待ち')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (controller.state.capabilities['network'] == false)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'インターネット接続を確認できません。送信待ちは接続が戻ると再開します。結果不明は自動再送しません。',
                ),
              ),
            const Text(
              '送り先をオフにすると待機中の送信を停止します。開始済みの投稿や外部メッセージは取り消せません。結果不明は投稿先を確認してください。',
            ),
            if (controller.error != null)
              Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (jobs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('送信項目はありません。'),
              ),
            ...jobs.map(
              (j) => Card(
                child: ListTile(
                  key: Key('delivery-${j['id']}'),
                  title: Text('${j['destinationName']} · ${j['title']}'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        j['text'] as String,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        DateTime.fromMillisecondsSinceEpoch(
                          (j['createdAt'] as num).toInt(),
                        ).toLocal().toString(),
                      ),
                      if (j['detail'] != null) Text(j['detail'] as String),
                      if (deliveryGuidance(j['phase'] as String).isNotEmpty)
                        Text(deliveryGuidance(j['phase'] as String)),
                      if (j['receipt'] != null)
                        Text('メッセージID: ${j['receipt']}'),
                      if (j['retryAfter'] != null)
                        Text(
                          '再試行予定: ${DateTime.fromMillisecondsSinceEpoch((j['retryAfter'] as num).toInt()).toLocal()}',
                        ),
                    ],
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _DeliveryEditor(
                        controller: controller,
                        id: j['id'] as String,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _DeliveryEditor extends StatefulWidget {
  const _DeliveryEditor({required this.controller, required this.id});
  final RelayController controller;
  final String id;
  @override
  State<_DeliveryEditor> createState() => _DeliveryEditorState();
}

class _DeliveryEditorState extends State<_DeliveryEditor> {
  late final TextEditingController text;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    text = TextEditingController(
      text:
          widget.controller.state.deliveries
                  .where((j) => j['id'] == widget.id)
                  .firstOrNull?['text']
              as String? ??
          '',
    );
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> action(String method, {bool unknown = false}) async {
    if (unknown) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重複して投稿される可能性があります'),
          content: const Text('投稿先で結果を確認しましたか？既に投稿されていた場合、同じ内容が再度投稿されます。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('戻る'),
            ),
            FilledButton(
              key: const Key('confirmUnknownRetry'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('確認して再送する'),
            ),
          ],
        ),
      );
      if (approved != true) return;
    }
    setState(() => busy = true);
    final ok = await widget.controller.command(method, {
      'id': widget.id,
      'text': text.text,
      if (unknown) 'allowUnknown': true,
    });
    if (mounted) {
      setState(() => busy = false);
      if (ok) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final job = widget.controller.state.deliveries
          .where((j) => j['id'] == widget.id)
          .firstOrNull;
      if (job == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('送信詳細')),
          body: const Text('履歴は削除されました。'),
        );
      }
      final phase = job['phase'] as String;
      final editable = [
        'confirmation',
        'needsAttention',
        'unknown',
      ].contains(phase);
      return Scaffold(
        appBar: AppBar(
          title: Text('${job['destinationName']} · ${job['title']}'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              stylusHandwritingEnabled: false,
              key: const Key('deliveryText'),
              controller: text,
              readOnly: !editable || busy,
              minLines: 3,
              maxLines: 12,
              maxLength: job['provider'] == 'discord' ? 2000 : 4096,
              decoration: const InputDecoration(labelText: '投稿する本文（接頭語を含む）'),
            ),
            const Text('メンション許可は確定済みの接頭語のIDだけを使います。本文編集で追加した別のIDへの通知は許可しません。'),
            if (job['detail'] != null) Text(job['detail'] as String),
            if (widget.controller.error != null)
              Text(
                widget.controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (['confirmation', 'needsAttention'].contains(phase))
              FilledButton(
                key: const Key('approveDelivery'),
                onPressed: busy ? null : () => action('approveDelivery'),
                child: const Text('この内容で送信する'),
              ),
            if (phase == 'retryWaiting')
              FilledButton(
                onPressed: busy ? null : () => action('retryDelivery'),
                child: const Text('待機時間後に再試行'),
              ),
            if (phase == 'unknown') ...[
              FilledButton(
                key: const Key('retryUnknown'),
                onPressed: busy
                    ? null
                    : () => action('retryDelivery', unknown: true),
                child: const Text('投稿先を確認して再送する'),
              ),
              TextButton(
                onPressed: busy ? null : () => action('dismissUnknown'),
                child: const Text('確認済み・再送しない'),
              ),
            ],
            if ([
              'confirmation',
              'queued',
              'retryWaiting',
              'needsAttention',
            ].contains(phase))
              TextButton(
                key: const Key('cancelDelivery'),
                onPressed: busy ? null : () => action('cancelDelivery'),
                child: const Text('送信しない'),
              ),
            if (phase == 'sending')
              const Text('送信中です。履歴を削除しても投稿自体を撤回できない場合があります。'),
            if (job['receipt'] != null) Text('メッセージID: ${job['receipt']}'),
          ],
        ),
      );
    },
  );
}
