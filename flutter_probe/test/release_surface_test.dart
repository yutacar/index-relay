import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:index_relay_probe/build_policy.dart';
import 'package:index_relay_probe/main.dart';
import 'package:index_relay_probe/relay_controller.dart';

import 'home_test.dart' show FakeBackend;

void main() {
  testWidgets('production keeps useful settings and removes trial operations', (
    tester,
  ) async {
    final backend = FakeBackend();
    backend.data['androidReceiver'] = true;
    backend.data['postingAvailable'] = true;
    final controller = RelayController(backend: backend);
    addTearDown(controller.dispose);
    await tester.pumpWidget(RelayApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.textContaining('はじめにでモデルを準備'), findsOneWidget);
    expect(find.textContaining('模擬受信'), findsNothing);
    await tester.tap(find.byKey(const Key('settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('simulateReceive')), findsNothing);
    expect(find.byKey(const Key('diagnostics')), findsNothing);
    expect(find.byKey(const Key('liveDeliveryCheck')), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const Key('licenses')), 300);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('licenses')), findsOneWidget);
    expect(await controller.receiveMock(), false);
    expect(backend.calls, isNot(contains('receiveMock')));
  }, skip: previewMode);
  test(
    'production bundles licenses but excludes synthetic speech/golden',
    () async {
      expect(
        await rootBundle.loadString('assets/notices/Whisper-model-MIT.txt'),
        contains('MIT'),
      );
      final assets = (await AssetManifest.loadFromAssetBundle(rootBundle))
          .listAssets();
      expect(assets, isNot(contains('assets/japanese.wav')));
      expect(assets, isNot(contains('assets/audio-golden.json')));
    },
    skip: previewMode,
  );
}
