import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:index_relay_probe/delivery_page.dart';
import 'package:index_relay_probe/live_delivery_page.dart';
import 'package:index_relay_probe/relay_controller.dart';

import 'home_test.dart' show FakeBackend;

FakeBackend configured() => FakeBackend()
  ..data['postingAvailable'] = true
  ..data['destinations'] = [
    {
      'id': 'test-d',
      'name': '試験チャンネル',
      'provider': 'discord',
      'prefix': '<@123> メモ',
      'targetHint': '',
      'verified': true,
      'enabled': true,
    },
  ];

void main() {
  testWidgets(
    'opening trial page never posts and explicit tap uses normal audio pipeline',
    (tester) async {
      final backend = configured();
      final controller = RelayController(backend: backend);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(home: LiveDeliveryPage(controller: controller)),
      );
      expect(backend.calls, isNot(contains('receiveMock')));
      expect(find.textContaining('<@123> メモ'), findsOneWidget);
      expect(find.textContaining('承認してください'), findsOneWidget);
      await tester.tap(find.byKey(const Key('liveTrialReceive')));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c == 'receiveMock'), hasLength(1));
      expect(backend.calls, isNot(contains('approveDelivery')));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets('unknown item blocks a second trial until reviewed', (
    tester,
  ) async {
    final backend = configured();
    backend.data['deliveries'] = [
      {'id': 'ambiguous', 'phase': 'unknown'},
    ];
    final controller = RelayController(backend: backend);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(home: LiveDeliveryPage(controller: controller)),
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('liveTrialReceive')),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('未完了項目を確認'), findsOneWidget);
    expect(backend.calls, isNot(contains('receiveMock')));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('no destinations cannot trigger an actual trial', (tester) async {
    final controller = RelayController(backend: FakeBackend());
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(home: LiveDeliveryPage(controller: controller)),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('liveTrialReceive')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('offline guidance keeps unknown separate from queued recovery', (
    tester,
  ) async {
    final backend = FakeBackend()..data['capabilities'] = {'network': false};
    final controller = RelayController(backend: backend);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(home: DeliveryPage(controller: controller)),
    );
    expect(find.textContaining('結果不明は自動再送しません'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
