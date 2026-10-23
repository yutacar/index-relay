import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:index_relay_probe/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native capability channel reaches the existing backend', (
    tester,
  ) async {
    await tester.pumpWidget(const DiagnosticsApp());
    await tester.pumpAndSettle();
    final result = await probeChannel.invokeMapMethod<String, Object?>(
      'capabilities',
    );
    expect(result?['bleVerified'], false);
    expect(result?['platform'], anyOf('ios', 'android'));
    if (result?['platform'] == 'ios') {
      expect(result?['backend'], 'existing SpeechFileTranscriber');
      expect(result?['speechAvailable'], isA<bool>());
    }
  });
}
