// Run on a new disposable iOS simulator only; no receiver or destination is enabled.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:index_relay_probe/main.dart';
import 'package:index_relay_probe/relay_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'protected-data availability callback survives repeated unlocks',
    (tester) async {
      expect(
        const bool.fromEnvironment('INDEX_RELAY_PROTECTED_DATA_TEST'),
        isTrue,
      );
      final controller = RelayController();
      await tester.pumpWidget(RelayApp(controller: controller));
      await tester.pumpAndSettle();
      await controller.refresh();
      expect(controller.state.nativeIOS, isTrue);
      expect(controller.state.receiverEnabled, isFalse);
      expect(controller.state.recordings, isEmpty);
      expect(controller.state.destinations, isEmpty);

      // Invoke the actual AppDelegate callback, not a mock of the recovery service.
      // The former super call aborts the process with an unrecognized selector.
      for (var unlock = 0; unlock < 3; unlock++) {
        expect(
          await const MethodChannel('index_relay/probe')
              .invokeMethod<bool>('protectedDataAvailableProbe'),
          isTrue,
        );
        await controller.refresh();
        expect(controller.state.receiverEnabled, isFalse);
        expect(controller.state.recordings, isEmpty);
        expect(controller.state.destinations, isEmpty);
      }
      controller.dispose();
    },
  );
}
