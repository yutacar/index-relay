import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:index_relay_probe/relay_controller.dart';
import 'package:index_relay_probe/settings_page.dart';

import 'home_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'control: default field starts handwriting for the same stylus tap',
    (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.scribe,
        (call) async {
          calls.add(call.method);
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.scribe,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TextField(key: Key('control'))),
        ),
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
      );
      await gesture.down(tester.getCenter(find.byKey(const Key('control'))));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(calls, contains('Scribe.startStylusHandwriting'));
    },
  );
  testWidgets(
    'stylus taps retain text keyboard input for name and Telegram group',
    (tester) async {
      final backend = FakeBackend()..data['postingAvailable'] = true;
      final controller = RelayController(backend: backend);
      await controller.refresh();
      final scribeCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.scribe,
        (call) async {
          scribeCalls.add(call.method);
          return true;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.scribe,
          null,
        );
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(home: DestinationPage(controller: controller)),
      );
      await tester.tap(find.byKey(const Key('provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Telegramグループ').last);
      await tester.pumpAndSettle();
      for (final entry in {
        'destinationName': '試験グループ',
        'targetHint': '-100123456',
      }.entries) {
        final field = find.byKey(Key(entry.key));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.stylus,
        );
        await gesture.down(tester.getCenter(field));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.testTextInput.hasAnyClients, isTrue);
        tester.testTextInput.enterText(entry.value);
        await tester.pump();
        expect(find.text(entry.value), findsOneWidget);
      }
      expect(scribeCalls, isNot(contains('Scribe.startStylusHandwriting')));
      expect(backend.calls, isNot(contains('saveConnectedDestination')));
    },
  );
}
