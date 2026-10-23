import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:index_relay_probe/main.dart';
import 'package:index_relay_probe/relay_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native state, JNI load and preview settings without speech claims',
    (tester) async {
      expect(await probeChannel.invokeMethod<bool>('nativeReady'), true);
      final info = await relayChannel.invokeMapMethod<String, dynamic>(
        'applicationInfo',
      );
      expect(info?['version'], '0.12.1');
      expect(info?['build'], '34');
      final snapshot = await relayChannel.invokeMapMethod<String, dynamic>(
        'snapshot',
      );
      expect(snapshot?['androidReceiver'], true);
      expect(snapshot?['postingAvailable'], true);
      final fixture = await rootBundle.load('assets/japanese.wav');
      expect(fixture.lengthInBytes, greaterThan(44));
      final controller = RelayController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(RelayApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('modelSetup')), findsOneWidget);
      if (find.byKey(const Key('prepareModel')).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const Key('prepareModel')));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('準備済み。音声を端末内で'), findsOneWidget);
      expect(find.byKey(const Key('androidReceiver')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('simulateReceive')),
        200,
      );
      expect(find.byKey(const Key('simulateReceive')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('licenses')), 200);
      expect(find.byKey(const Key('licenses')), findsOneWidget);
    },
  );
}
