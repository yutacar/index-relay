import 'package:flutter/material.dart';

import 'relay_controller.dart';
import 'relay_model.dart';
import 'diagnostics_page.dart';
import 'receiver_settings_page.dart';
import 'delivery_page.dart';
import 'build_policy.dart';
import 'licenses.dart';
import 'setup_guidance.dart';
import 'live_delivery_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});
  final RelayController controller;
  Future<void> changeLimit(BuildContext context) async {
    final value = await showDialog<int>(
      context: context,
      builder: (_) => _HistoryLimitDialog(
        initial: controller.state.historyLimit,
        maximum: controller.state.nativeIOS ? 500 : 200,
      ),
    );
    if (value != null) {
      await controller.command('saveSettings', {
        'historyLimit': value,
        'requiresConfirmation': controller.state.requiresConfirmation,
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (controller.state.androidReceiver) ...[
            const Text('はじめに', style: TextStyle(fontWeight: FontWeight.bold)),
            const Text(
              '1. モデルを準備 → 2. リングを探索して自動受信を開始 → 3. 必要な送り先を追加。送り先がなくても文字起こしは保存されます。',
            ),
            ModelSetupCard(controller: controller),
          ],
          if (controller.state.androidReceiver)
            ListTile(
              key: const Key('androidReceiver'),
              leading: const Icon(Icons.bluetooth),
              title: const Text('リング・自動受信'),
              subtitle: Text(controller.state.receiverStatus),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ReceiverSettingsPage(controller: controller),
                ),
              ),
            ),
          const Text('録音と履歴', style: TextStyle(fontWeight: FontWeight.bold)),
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const Key('historyLimit'),
                  title: const Text('表示・保存件数'),
                  subtitle: const Text('初期値30件。古い音声も削除します。'),
                  trailing: Text('${controller.state.historyLimit}件'),
                  onTap: () => changeLimit(context),
                ),
                SwitchListTile(
                  key: const Key('confirmation'),
                  title: const Text('送信前に確認する'),
                  subtitle: Text(
                    (controller.state.nativeIOS ||
                            controller.state.postingAvailable)
                        ? '新しい録音の送信に適用します。既存の確認待ちは自動承認しません。'
                        : '送り先へ接続した後の送信に適用します。',
                  ),
                  value: controller.state.requiresConfirmation,
                  onChanged: (value) => controller.command('saveSettings', {
                    'historyLimit': controller.state.historyLimit,
                    'requiresConfirmation': value,
                  }),
                ),
              ],
            ),
          ),
          if (controller.state.nativeIOS) ...[
            const SizedBox(height: 20),
            Text(controller.state.receiverStatus),
            ListTile(
              key: const Key('nativeSettings'),
              leading: const Icon(Icons.bluetooth),
              title: const Text('リング・送り先・送信一覧'),
              subtitle: const Text('既存のiOS設定画面を開きます。送信確認・結果不明への対応もこちらで行います。'),
              onTap: () => controller.command('openNativeSettings'),
            ),
          ] else ...[
            const SizedBox(height: 20),
            const Text('送り先', style: TextStyle(fontWeight: FontWeight.bold)),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '登録時にAPIで送り先を確認します。追加・設定変更によって過去の文字起こしを自動投稿することはありません。',
              ),
            ),
            ...controller.state.destinations.map(
              (d) => Card(
                child: ListTile(
                  key: Key('destination-${d.id}'),
                  title: Text(d.name),
                  subtitle: Text(
                    '${d.provider == 'discord' ? 'Discord' : 'Telegramグループ'} · ${d.verified ? (d.enabled ? '有効' : '停止中') : '未接続'}${d.prefix.isEmpty ? '' : '\n接頭語: ${d.prefix}'}',
                  ),
                  trailing: d.verified
                      ? Switch(
                          key: Key('destinationEnabled-${d.id}'),
                          value: d.enabled,
                          onChanged: (value) => controller.command(
                            'toggleDestination',
                            {'id': d.id, 'enabled': value},
                          ),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => DestinationPage(
                        controller: controller,
                        destination: d,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('addDestination'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DestinationPage(controller: controller),
                ),
              ),
              icon: const Icon(Icons.add),
              label: Text(
                controller.state.postingAvailable ? '送り先を追加' : '送り先候補を追加',
              ),
            ),
            if (controller.state.postingAvailable) ...[
              ListTile(
                key: const Key('deliveryQueue'),
                title: const Text('送信一覧・確認待ち'),
                subtitle: Text(
                  '${controller.state.deliveries.where((j) => !['sent', 'cancelled'].contains(j['phase'])).length}件の未完了項目',
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => DeliveryPage(controller: controller),
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    controller.command('requestDeliveryNotifications'),
                child: const Text('送信確認の通知を許可'),
              ),
            ],
            if (previewMode) ...[
              ListTile(
                key: const Key('liveDeliveryCheck'),
                leading: const Icon(Icons.send_outlined),
                title: const Text('Discord・Telegramの送信確認'),
                subtitle: const Text('試験先・接頭語・確認設定を見てから音声を取り込みます。'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => LiveDeliveryPage(controller: controller),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '受信の試験',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '既知の日本語音声を受信した状態を作ります。有効な送り先があれば送信設定が適用されます。リングを使う場合は「リング・自動受信」を設定してください。実機のBLE動作は未検証です。',
                ),
              ),
              FilledButton.icon(
                key: const Key('simulateReceive'),
                onPressed: controller.receiving
                    ? null
                    : () async {
                        if (await controller.receiveMock() && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('音声を保存しました。文字起こしを開始します。'),
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.science_outlined),
                label: const Text('模擬受信する'),
              ),
            ],
          ],
          if (controller.state.busy)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('端末内で文字起こし中です。'),
            ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ListTile(
            key: const Key('licenses'),
            leading: const Icon(Icons.info_outline),
            title: const Text('アプリ情報・ライセンス'),
            onTap: () => showRelayLicenses(context),
          ),
          if (previewMode)
            ListTile(
              key: const Key('diagnostics'),
              leading: const Icon(Icons.developer_mode),
              title: const Text('技術確認'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const DiagnosticsPage(),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class DestinationPage extends StatefulWidget {
  const DestinationPage({
    super.key,
    required this.controller,
    this.destination,
  });
  final RelayController controller;
  final Destination? destination;
  @override
  State<DestinationPage> createState() => _DestinationPageState();
}

class _DestinationPageState extends State<DestinationPage> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name, prefix, hint, secret;
  bool enabled = true;
  late String provider;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final d = widget.destination;
    name = TextEditingController(text: d?.name);
    prefix = TextEditingController(text: d?.prefix);
    secret = TextEditingController();
    enabled = d?.verified == true ? d!.enabled : true;
    hint = TextEditingController(text: d?.targetHint);
    provider = d?.provider ?? 'discord';
  }

  @override
  void dispose() {
    secret.dispose();
    name.dispose();
    prefix.dispose();
    hint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.destination == null ? '送り先を追加' : '送り先を変更'),
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          DropdownButtonFormField<String>(
            key: const Key('provider'),
            initialValue: provider,
            decoration: const InputDecoration(labelText: 'サービス'),
            items: const [
              DropdownMenuItem(value: 'discord', child: Text('Discord')),
              DropdownMenuItem(value: 'telegram', child: Text('Telegramグループ')),
            ],
            onChanged: saving || widget.destination != null
                ? null
                : (value) => setState(() {
                    provider = value!;
                    hint.clear();
                  }),
          ),
          const SizedBox(height: 16),
          TextFormField(
            stylusHandwritingEnabled: false,
            key: const Key('destinationName'),
            textInputAction: TextInputAction.next,
            controller: name,
            maxLength: 80,
            decoration: const InputDecoration(labelText: '表示名'),
            validator: (v) => (v ?? '').trim().isEmpty ? '表示名を入力してください' : null,
          ),
          if (widget.controller.state.postingAvailable) ...[
            TextFormField(
              stylusHandwritingEnabled: false,
              key: const Key('credential'),
              controller: secret,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: provider == 'discord' ? 'Webhook URL' : 'Botトークン',
                helperText: widget.destination?.verified == true
                    ? '変更する場合のみ入力。空欄なら現在の資格情報を使います。'
                    : '資格情報は暗号化して端末内に保存します。',
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty &&
                      widget.destination?.verified != true
                  ? '資格情報を入力してください'
                  : null,
            ),
            SwitchListTile(
              key: const Key('enableDestination'),
              title: const Text('この送り先を有効にする'),
              value: enabled,
              onChanged: saving ? null : (v) => setState(() => enabled = v),
            ),
          ],
          if (!widget.controller.state.postingAvailable ||
              provider == 'telegram')
            TextFormField(
              stylusHandwritingEnabled: false,
              key: const Key('targetHint'),
              textInputAction: TextInputAction.next,
              controller: hint,
              decoration: InputDecoration(
                labelText: provider == 'telegram'
                    ? 'グループID／@公開グループ名'
                    : 'チャンネルID（任意）',
                helperText: widget.controller.state.postingAvailable
                    ? 'Botを追加したグループ・スーパーグループのみ対応します。'
                    : 'トークンやWebhook URLは入力しないでください。',
              ),
              validator: (value) {
                final s = (value ?? '').trim();
                if (s.isEmpty) {
                  return widget.controller.state.postingAvailable &&
                          provider == 'telegram'
                      ? 'グループIDを入力してください'
                      : null;
                }
                if (widget.controller.state.postingAvailable &&
                    provider == 'telegram' &&
                    RegExp(r'^@[A-Za-z0-9_]{1,64}$').hasMatch(s)) {
                  return null;
                }
                if (provider == 'telegram') {
                  final n = int.tryParse(s);
                  return n != null && n < 0 && '$n' == s
                      ? null
                      : '負の数値IDを入力してください';
                }
                return RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(s)
                    ? null
                    : '数値IDを入力してください';
              },
            ),
          const SizedBox(height: 16),
          TextFormField(
            stylusHandwritingEnabled: false,
            key: const Key('prefix'),
            controller: prefix,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: '接頭語（任意）',
              helperText: '接頭語＋半角スペース＋文字起こし本文',
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '登録時には送り先を確認し、投稿しません。Discordメンションは接頭語に <@ユーザーID>／<@&ロールID> を指定してください。本文の任意メンションや @everyone は許可しません。接頭語変更は新しい録音から適用します。',
            ),
          ),
          FilledButton(
            key: const Key('saveDestination'),
            onPressed: saving
                ? null
                : () async {
                    if (!form.currentState!.validate()) return;
                    setState(() => saving = true);
                    final ok = await widget.controller.command(
                      widget.controller.state.postingAvailable
                          ? 'saveConnectedDestination'
                          : 'saveDestination',
                      {
                        'id': widget.destination?.id,
                        'name': name.text.trim(),
                        'provider': provider,
                        'prefix': prefix.text.trim(),
                        'targetHint': hint.text.trim(),
                        if (widget.controller.state.postingAvailable)
                          'secret': secret.text.trim(),
                        if (widget.controller.state.postingAvailable)
                          'enabled': enabled,
                      },
                    );
                    if (context.mounted) {
                      if (ok) {
                        Navigator.pop(context);
                      } else {
                        setState(() => saving = false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              widget.controller.error ??
                                  '保存できません。入力内容を確認してください。',
                            ),
                          ),
                        );
                      }
                    }
                  },
            child: Text(
              saving
                  ? '送り先を確認しています…'
                  : widget.controller.state.postingAvailable
                  ? '送り先を確認して保存'
                  : '保存',
            ),
          ),
          if (widget.destination != null)
            TextButton(
              key: const Key('deleteDestination'),
              onPressed: saving
                  ? null
                  : () async {
                      final ok = await widget.controller.command(
                        'deleteDestination',
                        {'id': widget.destination!.id},
                      );
                      if (context.mounted) {
                        if (ok) {
                          Navigator.pop(context);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                widget.controller.error ?? '未完了の送信を確認してください。',
                              ),
                            ),
                          );
                        }
                      }
                    },
              child: const Text('この送り先を削除'),
            ),
        ],
      ),
    ),
  );
}

class _HistoryLimitDialog extends StatefulWidget {
  const _HistoryLimitDialog({required this.initial, required this.maximum});
  final int initial, maximum;
  @override
  State<_HistoryLimitDialog> createState() => _HistoryLimitDialogState();
}

class _HistoryLimitDialogState extends State<_HistoryLimitDialog> {
  late final TextEditingController input = TextEditingController(
    text: '${widget.initial}',
  );
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('表示・保存件数'),
    content: Form(
      key: form,
      child: TextFormField(
        stylusHandwritingEnabled: false,
        key: const Key('limitInput'),
        controller: input,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: '1〜${widget.maximum}件',
          helperText: '件数を減らすと古い履歴と音声を削除します。',
        ),
        validator: (s) {
          final n = int.tryParse(s ?? '');
          return n == null || n < 1 || n > widget.maximum
              ? '1〜${widget.maximum}の整数を入力してください'
              : null;
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('戻る'),
      ),
      FilledButton(
        key: const Key('saveLimit'),
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, int.parse(input.text));
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
