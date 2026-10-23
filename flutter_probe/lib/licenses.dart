import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool _registered = false;
void registerRelayLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    for (final file in [
      'IndexRelay-MIT.txt',
      'whisper.cpp-MIT.txt',
      'Whisper-model-MIT.txt',
      'Android-Apache-2.0.txt',
      'Android-NOTICE.txt',
    ]) {
      yield LicenseEntryWithLineBreaks([
        file.replaceAll('.txt', ''),
      ], await rootBundle.loadString('assets/notices/$file'));
    }
  });
}

Future<void> showRelayLicenses(BuildContext context) async {
  registerRelayLicenses();
  Map<String, dynamic>? info;
  try {
    info = await const MethodChannel('index_relay/relay')
        .invokeMapMethod<String, dynamic>('applicationInfo');
  } catch (_) {}
  if (!context.mounted) return;
  showLicensePage(
    context: context,
    applicationName: 'Index Relay',
    applicationVersion: info == null
        ? null
        : '${info['version']} (${info['build']})',
    applicationLegalese: 'Android: whisper.cpp / Whisper base multilingual（端末内処理）。iOS: Apple SpeechAnalyzer。各外部依存のライセンスは以下を参照してください。',
  );
}
