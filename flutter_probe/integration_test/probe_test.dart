import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:index_relay_probe/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('invalid audio is rejected without native crash', (tester) async {
    await expectLater(
      probeChannel.invokeMethod<Object>('transcribeFixture', {
        'wav': Uint8List(0),
      }),
      throwsA(isA<PlatformException>()),
    );
    final wav = (await rootBundle.load('assets/japanese.wav')).buffer
        .asUint8List();
    final invalid = Uint8List.fromList(wav);
    invalid[0] = 0;
    await expectLater(
      probeChannel.invokeMethod<Object>('transcribeFixture', {'wav': invalid}),
      throwsA(isA<PlatformException>()),
    );
  });
  testWidgets('real native SDK and Japanese file recognition', (tester) async {
    final capabilities = await probeChannel.invokeMapMethod<String, Object?>(
      'capabilities',
    );
    expect(capabilities?['platform'], Platform.isAndroid ? 'android' : 'ios');
    if (Platform.isAndroid) {
      expect(capabilities?['haversineVersion'], '2541a33');
    }
    final wav = (await rootBundle.load('assets/japanese.wav')).buffer
        .asUint8List();
    final result = await probeChannel.invokeMapMethod<String, Object?>(
      'transcribeFixture',
      {'wav': wav},
    );
    final text = result?['text'] as String;
    expect(text, contains('動作確認'));
    expect(text, contains('音声'));
    expect(text, contains('文字'));
    expect(result?['offline'], true);
    // Only this synthetic fixture's output is logged. Never log personal recordings.
    // ignore: avoid_print
    print('PROBE_RESULT: $result');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
