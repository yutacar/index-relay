// Run only with scripts/test-flutter-ios-upgrade.py on a disposable simulator.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:index_relay_probe/main.dart';
import 'package:index_relay_probe/relay_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'legacy stores remain native and recovery does not requeue uncertain posts',
    (tester) async {
      final controller = RelayController();
      await tester.pumpWidget(RelayApp(controller: controller));
      await tester.pumpAndSettle();
      await controller.refresh();
      expect(controller.loaded, true);
      expect(controller.state.nativeIOS, true);
      expect(controller.state.historyLimit, 20);
      expect(controller.state.requiresConfirmation, true);
      expect(controller.state.recordings.length, 9);
      expect(controller.state.destinations.single.name, '移行試験・停止中');
      expect(controller.state.recordings.every((r) => !r.simulation), true);
      final sent = controller.state.recordings.singleWhere(
        (r) => r.id.startsWith('1'),
      );
      expect(sent.title, '連携済み');
      expect(sent.deliveryComplete, true);
      expect(
        controller.state.recordings.where((r) => r.title == '結果不明').length,
        2,
      );
      expect(
        controller.state.recordings
            .singleWhere((r) => r.id.startsWith('4'))
            .title,
        '確認待ち',
      );
      expect(
        controller.state.recordings
            .singleWhere((r) => r.id.startsWith('5'))
            .title,
        '送信待ち',
      );
      expect(
        controller.state.recordings
            .singleWhere((r) => r.id.startsWith('9'))
            .phase,
        'queued',
      );
      expect(sent.sampleRate, 9997);
      final audio = await relayChannel.invokeMethod<Uint8List>('audioBytes', {
        'id': sent.id,
      });
      expect(String.fromCharCodes(audio!.take(4)), 'RIFF');
      expect(ByteData.sublistView(audio).getUint32(24, Endian.little), 16000);
      expect(audio.length, 64044);
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('simulateReceive')), findsNothing);
      expect(await controller.command('openNativeSettings'), true);
      // Snapshot contains display data only; credentials and pending request bodies stay native.
      expect(
        await controller.command('saveSettings', {
          'historyLimit': 20,
          'requiresConfirmation': false,
        }),
        true,
      );
      expect(
        controller.state.recordings
            .singleWhere((r) => r.id.startsWith('4'))
            .title,
        '確認待ち',
      );
      expect(
        await controller.command('saveSettings', {
          'historyLimit': 20,
          'requiresConfirmation': true,
        }),
        true,
      );
      final snapshot = await relayChannel.invokeMapMethod<String, Object?>(
        'snapshot',
      );
      expect(
        snapshot.toString(),
        isNot(contains('synthetic-non-network-credential')),
      );
      expect(snapshot.toString(), isNot(contains('synthetic-receipt-1')));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
