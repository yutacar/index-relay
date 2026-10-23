import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:index_relay_probe/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(probeChannel, null);
  });
  testWidgets('SDK response is displayed through the native boundary', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(probeChannel, (call) async {
          expect(call.method, 'capabilities');
          return 'native probe ready';
        });
    await tester.pumpWidget(const DiagnosticsApp());
    await tester.tap(find.byKey(const Key('capabilities')));
    await tester.pumpAndSettle();
    expect(find.text('native probe ready'), findsOneWidget);
  });
  testWidgets('native failure remains a visible failure', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(probeChannel, (call) async {
          throw PlatformException(code: 'MODEL_MISSING');
        });
    await tester.pumpWidget(const DiagnosticsApp());
    await tester.tap(find.byKey(const Key('capabilities')));
    await tester.pumpAndSettle();
    expect(find.textContaining('MODEL_MISSING'), findsOneWidget);
  });
}
