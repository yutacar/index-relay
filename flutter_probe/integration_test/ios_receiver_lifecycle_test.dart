// Only run on a new disposable simulator; this does not verify physical BLE.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:index_relay_probe/main.dart';
import 'package:index_relay_probe/relay_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native receiver reuses each manager through three pause/resume cycles',
    (tester) async {
      expect(
        const bool.fromEnvironment('INDEX_RELAY_RECEIVER_LIFECYCLE_TEST'),
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
      final outcome = await const MethodChannel('index_relay/probe')
          .invokeMapMethod<String, dynamic>('receiverLifecycleProbe');
      expect(outcome?['cycles'], 3);
      expect(outcome?['cleanupFailures'], 0);
      expect(outcome?['managersCreated'], 3);
      expect(outcome?['resumed'], 9);
      await controller.refresh();
      expect(controller.state.receiverEnabled, isFalse);
      expect(controller.state.recordings, isEmpty);
      controller.dispose();
    },
  );
}
