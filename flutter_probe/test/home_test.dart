import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:index_relay_probe/main.dart';
import 'package:index_relay_probe/relay_controller.dart';

class FakeBackend implements RelayBackend {
  VoidCallback? changed;
  final calls = <String>[];
  final data = <String, Object?>{
    'historyLimit': 30,
    'requiresConfirmation': true,
    'busy': false,
    'recordings': <Map<String, Object?>>[],
    'destinations': <Map<String, Object?>>[],
  };
  bool fail = false;
  @override
  void observe(VoidCallback? callback) {
    changed = callback;
  }

  @override
  Future<Object?> call(String method, [Map<String, Object?>? args]) async {
    calls.add(method);
    if (fail) throw StateError('storage failure');
    if (method == 'saveSettings') {
      data['historyLimit'] = args!['historyLimit'];
      data['requiresConfirmation'] = args['requiresConfirmation'];
    }
    if (method == 'deleteRecordings') {
      (data['recordings']! as List).removeWhere(
        (r) => (args!['ids'] as List).contains(r['id']),
      );
    }
    if (method == 'saveDestination') {
      (data['destinations']! as List).add({...args!, 'id': 'dest-1'});
    }
    if (method == 'playAudio' ||
        method == 'exportAudio' ||
        method == 'stopAudio') {
      return true;
    }
    return jsonDecode(jsonEncode(data));
  }
}

Map<String, Object?> record(String id, String text) => {
  'id': id,
  'createdAt': 1760000000000,
  'phase': 'done',
  'text': text,
  'samples': 16000,
  'engine': 'fake for UI test',
  'elapsedMs': 10,
  'detail': null,
};

class DelayedBackend extends FakeBackend {
  Completer<Object?>? pending;
  @override
  Future<Object?> call(String method, [Map<String, Object?>? args]) {
    if (method == 'snapshot' && pending != null) {
      final p = pending!;
      pending = null;
      return p.future;
    }
    return super.call(method, args);
  }
}

void main() {
  testWidgets(
    'iOS shows native delivery status and settings without mock drafts',
    (tester) async {
      final backend = FakeBackend();
      backend.data['nativeIOS'] = true;
      backend.data['receiverEnabled'] = true;
      backend.data['receiverStatus'] = '受信を待機中';
      (backend.data['recordings'] as List).add({
        ...record('a', '引き継いだ文章'),
        'simulation': false,
        'sampleRate': 9997,
        'samples': 19994,
        'deliveryTitle': '結果不明',
        'deliveryComplete': false,
      });
      final controller = RelayController(backend: backend);
      await tester.pumpWidget(RelayApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('結果不明'), findsOneWidget);
      expect(find.text('模擬録音'), findsNothing);
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('simulateReceive')), findsNothing);
      expect(find.byKey(const Key('addDestination')), findsNothing);
      await tester.tap(find.byKey(const Key('historyLimit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('limitInput')), '500');
      await tester.tap(find.byKey(const Key('saveLimit')));
      await tester.pumpAndSettle();
      expect(controller.state.historyLimit, 500);
      await tester.tap(find.byKey(const Key('nativeSettings')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('openNativeSettings'));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'Android receiver settings dispatch native commands without changing iOS UI',
    (tester) async {
      final backend = FakeBackend();
      backend.data.addAll({
        'androidReceiver': true,
        'receiverEnabled': true,
        'receiverRunning': true,
        'receiverName': '試験用リング',
        'receiverStatus': '録音待機中',
      });
      final controller = RelayController(backend: backend);
      addTearDown(controller.dispose);
      await tester.pumpWidget(RelayApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('androidReceiver')));
      await tester.pumpAndSettle();
      expect(find.text('受信サービス実行中'), findsOneWidget);
      expect(find.text('試験用リング'), findsOneWidget);
      final scan = tester.widget<OutlinedButton>(
        find.byKey(const Key('scanReceiver')),
      );
      expect(scan.onPressed, isNull);
      await tester.tap(find.byKey(const Key('receiverEnabled')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('disableReceiver'));
    },
  );

  Future<(FakeBackend, RelayController)> home(
    WidgetTester tester, {
    bool records = false,
  }) async {
    final backend = FakeBackend();
    if (records) {
      (backend.data['recordings'] as List).addAll(<Map<String, Object?>>[
        record('a', '新しい文章'),
        record('b', '前の文章'),
      ]);
    }
    final controller = RelayController(backend: backend);
    addTearDown(controller.dispose);
    await tester.pumpWidget(RelayApp(controller: controller));
    await tester.pumpAndSettle();
    return (backend, controller);
  }

  testWidgets(
    'home keeps settings behind the gear and shows status and dates',
    (tester) async {
      await home(tester, records: true);
      expect(find.text('新しい文章'), findsOneWidget);
      expect(find.text('未連携'), findsNWidgets(2));
      expect(find.byKey(const Key('historyLimit')), findsNothing);
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('historyLimit')), findsOneWidget);
      expect(find.text('30件'), findsOneWidget);
    },
  );
  testWidgets(
    'multiple rows and all rows can be deleted without confirmation',
    (tester) async {
      final (backend, _) = await home(tester, records: true);
      await tester.tap(find.byKey(const Key('edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-a')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('select-b')));
      await tester.pump();
      expect(find.text('2件選択'), findsOneWidget);
      await tester.tap(find.byKey(const Key('deleteSelected')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(backend.data['recordings'], isEmpty);
      expect(backend.calls.where((c) => c == 'deleteRecordings').length, 1);
    },
  );
  testWidgets('select all and clear are independent of row taps', (
    tester,
  ) async {
    await home(tester, records: true);
    await tester.tap(find.byKey(const Key('edit')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('selectAll')));
    await tester.pump();
    expect(find.text('2件選択'), findsOneWidget);
    await tester.tap(find.byKey(const Key('selectAll')));
    await tester.pump();
    expect(find.text('0件選択'), findsOneWidget);
  });
  testWidgets('history limit validates and persists', (tester) async {
    final (backend, _) = await home(tester);
    await tester.tap(find.byKey(const Key('settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('historyLimit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('limitInput')), '0');
    await tester.tap(find.byKey(const Key('saveLimit')));
    await tester.pump();
    expect(find.text('1〜200の整数を入力してください'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('limitInput')), '50');
    await tester.tap(find.byKey(const Key('saveLimit')));
    await tester.pumpAndSettle();
    expect(backend.data['historyLimit'], 50);
    expect(find.text('50件'), findsOneWidget);
  });
  testWidgets(
    'audio info invokes native playback with the selected recording',
    (tester) async {
      final (backend, _) = await home(tester, records: true);
      await tester.tap(find.byKey(const Key('info-a')));
      await tester.pumpAndSettle();
      expect(find.text('音声詳細'), findsOneWidget);
      await tester.tap(find.byKey(const Key('playAudio')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('playAudio'));
    },
  );
  testWidgets(
    'destination draft validates ID and saves prefix without credentials',
    (tester) async {
      final (backend, _) = await home(tester);
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('addDestination')));
      await tester.tap(find.byKey(const Key('addDestination')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('destinationName')), 'テスト宛先');
      await tester.enterText(find.byKey(const Key('prefix')), 'メモ');
      await tester.enterText(
        find.byKey(const Key('targetHint')),
        'https://example.invalid',
      );
      await tester.ensureVisible(find.byKey(const Key('saveDestination')));
      await tester.tap(find.byKey(const Key('saveDestination')));
      await tester.pumpAndSettle();
      expect(backend.data['destinations'], isEmpty);
      await tester.enterText(find.byKey(const Key('targetHint')), '123');
      await tester.tap(find.byKey(const Key('saveDestination')));
      await tester.pumpAndSettle();
      final d = (backend.data['destinations'] as List).single as Map;
      expect(d['prefix'], 'メモ');
      expect(d.containsKey('token'), false);
    },
  );
  testWidgets('swipe deletes one row without a confirmation dialog', (
    tester,
  ) async {
    final (backend, _) = await home(tester, records: true);
    await tester.drag(find.byKey(const ValueKey('a')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect((backend.data['recordings'] as List).length, 1);
    expect(find.text('新しい文章'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });
  test('late snapshot cannot resurrect a deleted row', () async {
    final backend = DelayedBackend();
    (backend.data['recordings'] as List).add(record('a', '削除対象'));
    final controller = RelayController(backend: backend);
    addTearDown(controller.dispose);
    await controller.refresh();
    final old = jsonDecode(jsonEncode(backend.data));
    final pending = Completer<Object?>();
    backend.pending = pending;
    final loading = controller.refresh();
    final removing = controller.command('deleteRecordings', {
      'ids': ['a'],
    });
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.recordings, isEmpty);
    pending.complete(old);
    await loading;
    await removing;
    expect(controller.state.recordings, isEmpty);
  });
  test('storage failure retains the previously loaded history', () async {
    final backend = FakeBackend();
    (backend.data['recordings'] as List).add(record('a', '保存済み'));
    final controller = RelayController(backend: backend);
    addTearDown(controller.dispose);
    await controller.refresh();
    backend.fail = true;
    await controller.refresh();
    expect(controller.error, isNotNull);
    expect(controller.state.recordings.single.text, '保存済み');
  });
}
