import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const probeChannel = MethodChannel('index_relay/probe');
const fixtureText = 'これはインデックスリレーの動作確認です。録音した音声を文字に変換します。';

class DiagnosticsApp extends StatelessWidget {
  const DiagnosticsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Index Relay 技術確認',
    theme: ThemeData(colorSchemeSeed: Colors.blue),
    home: const DiagnosticsPage(),
  );
}

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});
  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  bool busy = false;
  String status = 'SDK確認と日本語WAVの端末内文字起こしを試験します。';
  Future<void> run(bool transcribe) async {
    setState(() {
      busy = true;
      status = transcribe ? '端末内で認識しています…' : '確認しています…';
    });
    try {
      final args = transcribe
          ? {
              'wav': (await rootBundle.load('assets/japanese.wav')).buffer
                  .asUint8List(),
            }
          : null;
      final result = await probeChannel.invokeMethod<Object>(
        transcribe ? 'transcribeFixture' : 'capabilities',
        args,
      );
      if (mounted) {
        setState(() => status = result.toString());
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => status = '確認未完了: ${e.code} ${e.message ?? ''}');
      }
    } catch (_) {
      if (mounted) {
        setState(() => status = '確認未完了: 試験データまたはプラットフォーム接続を確認してください。');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Index Relay 技術確認')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('実BLE受信・送信・本番データ移行は行いません。'),
          const SizedBox(height: 20),
          const Text('試験文: $fixtureText'),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('capabilities'),
            onPressed: busy ? null : () => run(false),
            child: const Text('SDKを確認'),
          ),
          FilledButton(
            key: const Key('transcribe'),
            onPressed: busy ? null : () => run(true),
            child: const Text('日本語WAVを文字起こし'),
          ),
          if (busy) const LinearProgressIndicator(),
          const SizedBox(height: 20),
          SelectableText(status, key: const Key('result')),
        ],
      ),
    ),
  );
}
