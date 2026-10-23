import 'package:flutter/material.dart';

import 'relay_controller.dart';
import 'delivery_page.dart';

class AudioPage extends StatefulWidget {
  const AudioPage({
    super.key,
    required this.controller,
    required this.recordingID,
  });
  final RelayController controller;
  final String recordingID;
  @override
  State<AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends State<AudioPage> {
  String? message;
  bool busy = false;
  @override
  void dispose() {
    widget.controller.stopAudio();
    super.dispose();
  }

  Future<void> audio(bool export) async {
    setState(() => busy = true);
    final ok = await widget.controller.audio(widget.recordingID, export);
    if (mounted) {
      setState(() {
        busy = false;
        message = ok
            ? export
                  ? 'WAVを保存しました。'
                  : '標準補正の音声を再生しています。'
            : '処理を中止したか、音声を利用できませんでした。';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final found = widget.controller.state.recordings.where(
        (r) => r.id == widget.recordingID,
      );
      final r = found.isEmpty ? null : found.first;
      return Scaffold(
        appBar: AppBar(title: const Text('音声詳細')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (r == null)
              const Text('この録音は削除されました。')
            else ...[
              Text(
                r.text.isEmpty ? r.title : r.text,
                style: const TextStyle(fontSize: 20, height: 1.5),
              ),
              const SizedBox(height: 16),
              Text(
                '${(r.samples / r.sampleRate).toStringAsFixed(2)}秒 · ${r.simulation ? '模擬受信' : 'リング受信'} · ${r.title}',
              ),
              if (widget.controller.state.postingAvailable)
                TextButton(
                  key: const Key('recordingDeliveries'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => DeliveryPage(
                        controller: widget.controller,
                        recordingID: r.id,
                      ),
                    ),
                  ),
                  child: const Text('送り先ごとの送信状況・確認'),
                ),
              if (r.engine.isNotEmpty) Text('認識: ${r.engine}'),
              const SizedBox(height: 24),
              const Text('標準補正: 16bit DC補正・30Hzハイパス・自動音量。原音は端末内に保持します。'),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('playAudio'),
                onPressed: busy ? null : () => audio(false),
                icon: const Icon(Icons.play_arrow),
                label: const Text('標準補正を再生'),
              ),
              OutlinedButton.icon(
                key: const Key('exportAudio'),
                onPressed: busy ? null : () => audio(true),
                icon: const Icon(Icons.save_alt),
                label: const Text('WAVを保存'),
              ),
              TextButton(
                onPressed: widget.controller.stopAudio,
                child: const Text('再生を停止'),
              ),
              if (r.phase == 'needsAttention') ...[
                Text(r.detail ?? '音声を確認してください。'),
                FilledButton(
                  onPressed: () => widget.controller.command(
                    'retryTranscription',
                    {'id': r.id},
                  ),
                  child: const Text('文字起こしを再試行'),
                ),
              ],
            ],
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(message!),
              ),
          ],
        ),
      );
    },
  );
}
