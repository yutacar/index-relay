import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:index_relay_probe/main.dart';
import 'package:index_relay_probe/relay_controller.dart';

import 'home_test.dart' show FakeBackend;

class SendingBackend extends FakeBackend {
  SendingBackend() {
    data['postingAvailable'] = true;
    data['deliveries'] = <Map<String, Object?>>[];
  }
  Map<String, Object?>? submitted;
  Map<String, Object?>? lastAction;
  @override
  Future<Object?> call(String method, [Map<String, Object?>? args]) async {
    if (method == 'saveConnectedDestination') {
      submitted = {...args!};
      calls.add(method);
      (data['destinations'] as List).add({
        'id': 'dest-1',
        'name': args['name'],
        'provider': args['provider'],
        'prefix': args['prefix'],
        'targetHint': '100',
        'enabled': true,
        'verified': true,
      });
      return data;
    }
    if (method == 'retryDelivery' || method == 'approveDelivery') {
      lastAction = args;
    }
    return super.call(method, args);
  }
}

void main() {
  testWidgets(
    'connected editor requests a secret once and never reads it back',
    (tester) async {
      final backend = SendingBackend();
      final controller = RelayController(backend: backend);
      addTearDown(controller.dispose);
      await tester.pumpWidget(RelayApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('addDestination')));
      await tester.tap(find.byKey(const Key('addDestination')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('destinationName')),
        'テストDiscord',
      );
      await tester.enterText(
        find.byKey(const Key('credential')),
        'synthetic-secret',
      );
      await tester.enterText(find.byKey(const Key('prefix')), '<@123> メモ');
      await tester.ensureVisible(find.byKey(const Key('saveDestination')));
      await tester.tap(find.byKey(const Key('saveDestination')));
      await tester.pumpAndSettle();
      expect(backend.submitted?['secret'], 'synthetic-secret');
      expect(backend.submitted?['enabled'], true);
      expect(controller.state.destinations.single.verified, true);
      await tester.tap(find.byKey(const Key('destination-dest-1')));
      await tester.pumpAndSettle();
      final credential = tester.widget<TextFormField>(
        find.byKey(const Key('credential')),
      );
      expect(credential.controller!.text, isEmpty);
    },
  );
  testWidgets('unknown resend requires explicit duplicate-risk confirmation', (
    tester,
  ) async {
    final backend = SendingBackend();
    (backend.data['deliveries'] as List).add({
      'id': 'job',
      'recordingID': 'record',
      'destinationID': 'dest',
      'destinationName': '試験先',
      'provider': 'discord',
      'text': '投稿文',
      'createdAt': 1760000000000,
      'title': '結果不明',
      'phase': 'unknown',
    });
    final controller = RelayController(backend: backend);
    addTearDown(controller.dispose);
    await tester.pumpWidget(RelayApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('deliveryQueue')));
    await tester.tap(find.byKey(const Key('deliveryQueue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delivery-job')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('retryUnknown')));
    await tester.tap(find.byKey(const Key('retryUnknown')));
    await tester.pumpAndSettle();
    expect(backend.calls, isNot(contains('retryDelivery')));
    expect(find.text('重複して投稿される可能性があります'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmUnknownRetry')));
    await tester.pumpAndSettle();
    expect(backend.lastAction?['allowUnknown'], true);
    expect(backend.lastAction?['text'], '投稿文');
  });
  test('unrecognized native error messages never expose secrets', () async {
    final backend = ErrorBackend();
    final controller = RelayController(backend: backend);
    addTearDown(controller.dispose);
    expect(await controller.command('anything'), false);
    expect(controller.error, isNot(contains('synthetic-secret')));
  });
}

class ErrorBackend extends FakeBackend {
  @override
  Future<Object?> call(String method, [Map<String, Object?>? args]) async =>
      throw PlatformException(code: 'UNTRUSTED', message: 'synthetic-secret');
}
