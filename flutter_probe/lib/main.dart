import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'relay_controller.dart';
import 'settings_page.dart';
import 'audio_page.dart';
import 'licenses.dart';
export 'diagnostics_page.dart' show probeChannel, fixtureText, DiagnosticsApp;

// Opt-in simulator evidence only; excluded from ordinary debug runs and release builds.
void _recordSceneProbe(String state) {
  assert(() {
    if (const bool.fromEnvironment('INDEX_RELAY_SCENE_PROBE')) {
      const MethodChannel('index_relay/probe')
          .invokeMethod<void>('lifecycleProbeEvent', {'state': state})
          .then<void>((_) {}, onError: (Object _) {});
    }
    return true;
  }());
}

void main() {
  registerRelayLicenses();
  runApp(const RelayApp());
}

class RelayApp extends StatelessWidget {
  const RelayApp({super.key, this.controller});
  final RelayController? controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Index Relay',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff2070e8),
      scaffoldBackgroundColor: const Color(0xfff3f5fa),
    ),
    home: HomePage(controller: controller),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.controller});
  final RelayController? controller;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final RelayController controller;
  bool editing = false;
  final selected = <String>{};
  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? RelayController();
    WidgetsBinding.instance.addObserver(this);
    _recordSceneProbe("uiReady");
    controller.refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _recordSceneProbe(state.name);
    if (state == AppLifecycleState.resumed) controller.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  Future<void> remove(List<String> ids) async {
    if (await controller.command('deleteRecordings', {'ids': ids}) && mounted) {
      setState(() {
        selected.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final records = controller.state.recordings;
      final visible = selected.intersection(records.map((r) => r.id).toSet());
      return Scaffold(
        appBar: AppBar(
          title: const Text('Index Relay'),
          leadingWidth: 84,
          leading: TextButton(
            key: const Key('edit'),
            onPressed: () => setState(() {
              editing = !editing;
              selected.clear();
            }),
            child: Text(editing ? '完了' : '編集'),
          ),
          actions: [
            IconButton(
              key: const Key('settings'),
              tooltip: '設定',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage(controller: controller),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            if (controller.error != null)
              MaterialBanner(
                content: Text(controller.error!),
                actions: [
                  TextButton(
                    onPressed: controller.refresh,
                    child: const Text('再読込'),
                  ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Row(
                children: [
                  Chip(
                    label: Text(
                      controller.state.nativeIOS
                          ? 'iOS受信'
                          : controller.state.androidReceiver
                          ? 'Android受信プレビュー'
                          : '模擬受信プレビュー',
                    ),
                    avatar: Icon(
                      controller.state.nativeIOS
                          ? Icons.bluetooth
                          : Icons.science_outlined,
                      size: 18,
                    ),
                  ),
                  const Spacer(),
                  Text('${records.length} / ${controller.state.historyLimit}件'),
                ],
              ),
            ),
            if (editing)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    TextButton(
                      key: const Key('selectAll'),
                      onPressed: records.isEmpty
                          ? null
                          : () => setState(() {
                              if (visible.length == records.length) {
                                selected.clear();
                              } else {
                                selected.addAll(records.map((r) => r.id));
                              }
                            }),
                      child: Text(
                        visible.length == records.length && records.isNotEmpty
                            ? '選択解除'
                            : '全選択',
                      ),
                    ),
                    const Spacer(),
                    Text('${visible.length}件選択'),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      key: const Key('deleteSelected'),
                      onPressed: visible.isEmpty
                          ? null
                          : () => remove(visible.toList()),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('削除'),
                    ),
                  ],
                ),
              ),
            if (!controller.loaded && controller.error == null)
              const LinearProgressIndicator(),
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(30),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.graphic_eq,
                              size: 60,
                              color: Color(0xff2070e8),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              '音声を文字に、思いつきを履歴に。',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              controller.state.nativeIOS
                                  ? '歯車 → リング・送り先・送信一覧でリングを設定してください。'
                                  : controller.state.androidReceiver
                                  ? '歯車 → はじめにでモデルを準備し、リング・自動受信を設定してください。'
                                  : '歯車 → 模擬受信で試験音声を取り込むと、端末内で文字起こしして保存します。',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: controller.refresh,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: records.length,
                        itemBuilder: (context, index) {
                          final record = records[index];
                          final card = Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: InkWell(
                              onTap: editing
                                  ? () => setState(() {
                                      if (!selected.add(record.id)) {
                                        selected.remove(record.id);
                                      }
                                    })
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (editing)
                                      Checkbox(
                                        key: Key('select-${record.id}'),
                                        value: visible.contains(record.id),
                                        onChanged: (_) => setState(() {
                                          if (!selected.add(record.id)) {
                                            selected.remove(record.id);
                                          }
                                        }),
                                      ),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            dateLabel(record.createdAt),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                          const SizedBox(height: 10),
                                          Text(
                                            record.text.isEmpty
                                                ? record.title
                                                : record.text,
                                            key: Key('text-${record.id}'),
                                            style: const TextStyle(
                                              fontSize: 18,
                                              height: 1.5,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Row(
                                            children: [
                                              Icon(
                                                record.phase == 'needsAttention'
                                                    ? Icons.error_outline
                                                    : record.phase == 'done'
                                                    ? (record.deliveryComplete
                                                          ? Icons.check_circle
                                                          : Icons.link_off)
                                                    : Icons.hourglass_top,
                                                size: 18,
                                                color:
                                                    record.phase ==
                                                        'needsAttention'
                                                    ? Colors.orange.shade800
                                                    : Colors.blueGrey,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(record.title),
                                              const SizedBox(width: 10),
                                              Text(
                                                record.simulation
                                                    ? '模擬録音'
                                                    : 'リング録音',
                                                style: TextStyle(
                                                  color: Colors.grey,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (!editing)
                                      IconButton(
                                        key: Key('info-${record.id}'),
                                        tooltip: '音声詳細',
                                        icon: const Icon(Icons.info_outline),
                                        onPressed: () => Navigator.push(
                                          context,
                                          MaterialPageRoute<void>(
                                            builder: (_) => AudioPage(
                                              controller: controller,
                                              recordingID: record.id,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                          if (editing) return card;
                          return Dismissible(
                            key: ValueKey(record.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.all(24),
                              color: Colors.red,
                              child: const Icon(
                                Icons.delete,
                                color: Colors.white,
                              ),
                            ),
                            // Native state removal rebuilds the list before the dismissed widget is reused.
                            confirmDismiss: (_) async {
                              await remove([record.id]);
                              return false;
                            },
                            child: card,
                          );
                        },
                      ),
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                12 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: Text(
                '最新${controller.state.historyLimit}件を保存。古い履歴と音声は自動削除します。削除の確認は表示しません。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    },
  );
}

String dateLabel(DateTime date) =>
    '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
