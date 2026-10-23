import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'relay_model.dart';
import 'build_policy.dart';

const relayChannel = MethodChannel('index_relay/relay');

abstract class RelayBackend {
  Future<Object?> call(String method, [Map<String, Object?>? arguments]);
  void observe(VoidCallback? changed);
}

class NativeRelayBackend implements RelayBackend {
  @override
  Future<Object?> call(String method, [Map<String, Object?>? arguments]) =>
      relayChannel.invokeMethod<Object?>(method, arguments);
  @override
  void observe(VoidCallback? changed) {
    relayChannel.setMethodCallHandler(
      changed == null
          ? null
          : (call) async {
              if (call.method == 'stateChanged') changed();
            },
    );
  }
}

class RelayController extends ChangeNotifier {
  RelayController({RelayBackend? backend})
    : backend = backend ?? NativeRelayBackend() {
    this.backend.observe(() {
      refresh();
    });
  }
  final RelayBackend backend;
  RelayState state = const RelayState();
  String? error;
  bool loaded = false, receiving = false;
  bool _disposed = false, _again = false;
  Future<void>? _refreshFuture;
  int _revision = 0;
  Future<void> refresh() {
    if (_disposed) return Future.value();
    _again = true;
    return _refreshFuture ??= _load().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<void> _load() async {
    try {
      while (_again && !_disposed) {
        _again = false;
        final revision = _revision;
        final result = await backend.call('snapshot');
        if (_disposed) return;
        if (revision != _revision) {
          _again = true;
          continue;
        }
        state = RelayState.fromMap(result as Map);
        loaded = true;
        error = null;
        notifyListeners();
      }
    } catch (_) {
      if (!_disposed) {
        error = '保存情報を読み込めません。アプリを開き直してください。';
        notifyListeners();
      }
    }
  }

  Future<bool> command(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await backend.call(method, args);
      if (!_disposed && result is Map) {
        _revision += 1;
        state = RelayState.fromMap(result);
        loaded = true;
        error = null;
        notifyListeners();
      }
      await refresh();
      return true;
    } catch (failure) {
      if (!_disposed) {
        const receiverErrors = {
          'MODEL_ERROR',
          'DELIVERY_ERROR',
          'RECEIVER_UNAVAILABLE',
          'PERMISSION_REQUIRED',
          'BLUETOOTH_UNAVAILABLE',
          'RECEIVER_NOT_CONFIGURED',
          'RECEIVER_START_FAILED',
          'RECEIVER_STOP_FAILED',
        };
        error =
            failure is PlatformException &&
                receiverErrors.contains(failure.code)
            ? (failure.message ?? '受信設定を確認してください。')
            : '操作を完了できません。入力内容や空き容量を確認してください。';
        notifyListeners();
      }
      return false;
    }
  }

  Future<bool> receiveMock() async {
    if (!previewMode || receiving || _disposed) return false;
    receiving = true;
    notifyListeners();
    try {
      final data = await rootBundle.load('assets/japanese.wav');
      return await command('receiveMock', {
        'wav': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      });
    } catch (_) {
      if (!_disposed) {
        error = '試験音声を読み込めません。アプリの準備を確認してください。';
        notifyListeners();
      }
      return false;
    } finally {
      receiving = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> audio(String id, bool export) async {
    try {
      return await backend.call(export ? 'exportAudio' : 'playAudio', {
            'id': id,
          }) ==
          true;
    } catch (_) {
      if (!_disposed) {
        error = '音声を利用できません。録音が残っているか確認してください。';
        notifyListeners();
      }
      return false;
    }
  }

  void stopAudio() {
    backend.call('stopAudio').catchError((_) => null);
  }

  @override
  void dispose() {
    _disposed = true;
    backend.observe(null);
    super.dispose();
  }
}
