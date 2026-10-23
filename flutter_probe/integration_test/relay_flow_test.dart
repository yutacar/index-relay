import 'dart:convert';
import 'dart:typed_data' show Endian;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:index_relay_probe/main.dart';
import 'package:index_relay_probe/relay_controller.dart';

Future<Map<Object?, Object?>> state() async =>
    (await relayChannel.invokeMapMethod<Object?, Object?>('snapshot'))!;
Future<void> command(String method, [Map<String, Object?>? args]) async {
  await relayChannel.invokeMethod<Object>(method, args);
}

List<Map<Object?, Object?>> recordings(Map<Object?, Object?> s) =>
    (s['recordings'] as List).cast<Map<Object?, Object?>>();
Future<Map<Object?, Object?>> waitFor(
  bool Function(Map<Object?, Object?>) ready,
) async {
  final until = DateTime.now().add(const Duration(minutes: 4));
  while (DateTime.now().isBefore(until)) {
    final s = await state();
    if (ready(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError('Native queue did not reach expected state');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('adaptive audio matches the existing Swift oracle exactly', (
    tester,
  ) async {
    final fixture = jsonDecode(
      await rootBundle.loadString('assets/audio-golden.json'),
    ) as Map;
    final samples = (fixture['inputPCM'] as List).cast<int>();
    final wav = ByteData(44 + samples.length * 2);
    void tag(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        wav.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    wav.setUint32(4, wav.lengthInBytes - 8, Endian.little);
    tag(8, 'WAVEfmt ');
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, 1, Endian.little);
    wav.setUint32(24, 16000, Endian.little);
    wav.setUint32(28, 32000, Endian.little);
    wav.setUint16(32, 2, Endian.little);
    wav.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    wav.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      wav.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    final prepared = await probeChannel.invokeMethod<Uint8List>(
      'prepareAudio',
      {'wav': wav.buffer.asUint8List()},
    );
    expect(
      prepared,
      orderedEquals(base64Decode(fixture['expectedWAV'] as String)),
    );
  });
  testWidgets(
    'mock receive -> real recognition -> durable history and safe deletion',
    (tester) async {
      // This dedicated preview package/AVD contains no production data.
      final old = await state();
      await command('deleteRecordings', {
        'ids': recordings(old).map((r) => r['id']).toList(),
      });
      for (final d in old['destinations'] as List) {
        await command('deleteDestination', {'id': d['id']});
      }
      await command('saveSettings', {
        'historyLimit': 30,
        'requiresConfirmation': true,
      });
      await expectLater(
        relayChannel.invokeMethod<Object>('saveSettings', {
          'historyLimit': 0,
          'requiresConfirmation': false,
        }),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        relayChannel.invokeMethod<Object>('saveDestination', {
          'name': 'invalid',
          'provider': 'telegram',
          'targetHint': '123',
          'prefix': '',
        }),
        throwsA(isA<PlatformException>()),
      );
      expect((await state())['historyLimit'], 30);
      expect((await state())['destinations'], isEmpty);
      final controller = RelayController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(RelayApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('simulateReceive')));
      await tester.tap(find.byKey(const Key('simulateReceive')));
      await tester.pump();
      final finished = await waitFor(
        (s) =>
            recordings(s).isNotEmpty && recordings(s).first['phase'] == 'done',
      );
      final first = recordings(finished).single;
      expect(first['text'], contains('動作確認'));
      expect(first['text'], contains('音声'));
      expect(first['engine'], contains('whisper.cpp'));
      await controller.refresh();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(first['text'] as String), findsOneWidget);
      expect(find.text('未連携'), findsOneWidget);
      await command('saveDestination', {
        'name': '試験グループ',
        'provider': 'telegram',
        'targetHint': '-1001234567890',
        'prefix': 'メモ',
      });
      final withDestination = await state();
      expect((withDestination['destinations'] as List).single['prefix'], 'メモ');
      expect(withDestination['postingAvailable'], true);
      final audio = (await relayChannel.invokeMethod<Uint8List>('audioBytes', {
        'id': first['id'],
      }))!;
      expect(ascii.decode(audio.sublist(0, 4)), 'RIFF');
      expect(ByteData.sublistView(audio).getUint32(24, Endian.little), 16000);
      expect(
        await relayChannel.invokeMethod<bool>('playAudio', {'id': first['id']}),
        true,
      );
      await command('stopAudio');
      final wav = (await rootBundle.load('assets/japanese.wav')).buffer
          .asUint8List();
      await command('receiveMock', {'wav': wav});
      final during = await state();
      final removedID = recordings(during).first['id'];
      expect(removedID, isNot(first['id']));
      await command('deleteRecordings', {
        'ids': [removedID],
      });
      await waitFor((s) => s['busy'] == false);
      expect(
        recordings(await state()).map((r) => r['id']),
        isNot(contains(removedID)),
      );
      await command('receiveMock', {'wav': wav});
      await command('saveSettings', {
        'historyLimit': 1,
        'requiresConfirmation': false,
      });
      final retained = await waitFor((s) => s['busy'] == false);
      expect(recordings(retained).length, 1);
      expect(recordings(retained).single['id'], isNot(first['id']));
      expect(retained['requiresConfirmation'], false);
      expect(retained['historyLimit'], 1);
      await expectLater(
        relayChannel.invokeMethod<Object>('audioBytes', {'id': first['id']}),
        throwsA(isA<PlatformException>()),
      );
      final last = recordings(retained).single['id'];
      await command('deleteRecordings', {
        'ids': [last],
      });
      await command('saveSettings', {
        'historyLimit': 30,
        'requiresConfirmation': true,
      });
      expect(recordings(await state()), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
