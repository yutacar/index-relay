import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:index_relay_probe/relay_controller.dart';
import 'package:index_relay_probe/relay_model.dart';
import 'package:index_relay_probe/receiver_settings_page.dart';
import 'package:index_relay_probe/setup_guidance.dart';

import 'home_test.dart' show FakeBackend;

void main() {
  test('old snapshots keep compatible setup defaults', () {
    final state = RelayState.fromMap(FakeBackend().data);
    expect(state.capabilities, isEmpty);
    expect(state.modelStatus, 'unprepared');
  });
  test('posting guidance distinguishes ambiguity from scheduled retries', () {
    expect(deliveryGuidance('unknown'), contains('重複'));
    expect(deliveryGuidance('retryWaiting'), contains('お待ち'));
    expect(deliveryGuidance('confirmation'), contains('本文を確認'));
    expect(deliveryGuidance('sent'), isEmpty);
  });
  testWidgets(
    'permission denial offers app settings independently of notification',
    (tester) async {
      final backend = FakeBackend();
      backend.data['capabilities'] = {
        'api': 33,
        'supported': true,
        'bluetooth': false,
        'radio': false,
        'notifications': false,
      };
      final controller = RelayController(backend: backend);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(home: ReceiverSettingsPage(controller: controller)),
      );
      expect(find.textContaining('近くのデバイス: 未許可'), findsOneWidget);
      expect(find.textContaining('受信は継続できます'), findsOneWidget);
      await tester.tap(find.byKey(const Key('applicationSettings')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('openApplicationSettings'));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets('model preparation disables repeated commands during copy', (
    tester,
  ) async {
    final controller = RelayController(backend: FakeBackend());
    controller.state = const RelayState(modelStatus: 'copying');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ModelSetupCard(controller: controller)),
      ),
    );
    final button = tester.widget<TextButton>(
      find.byKey(const Key('prepareModel')),
    );
    expect(button.onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
