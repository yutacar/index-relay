class Recording {
  Recording.fromMap(Map<Object?, Object?> map)
    : id = map['id'] as String,
      createdAt = DateTime.fromMillisecondsSinceEpoch(
        (map['createdAt'] as num).toInt(),
      ),
      phase = map['phase'] as String,
      text = map['text'] as String,
      samples = (map['samples'] as num).toInt(),
      engine = map['engine'] as String,
      elapsedMs = (map['elapsedMs'] as num).toInt(),
      detail = map['detail'] as String?,
      sampleRate = (map['sampleRate'] as num?)?.toInt() ?? 16000,
      simulation = map['simulation'] as bool? ?? true,
      deliveryTitle = map['deliveryTitle'] as String?,
      deliveryComplete = map['deliveryComplete'] as bool? ?? false;
  final String id, phase, text, engine;
  final DateTime createdAt;
  final int samples, elapsedMs, sampleRate;
  final bool simulation, deliveryComplete;
  final String? deliveryTitle;
  final String? detail;
  String get title => switch (phase) {
    'queued' => '文字起こし待ち',
    'processing' => '文字起こし中',
    'done' => deliveryTitle ?? '未連携',
    _ => '要対応',
  };
}

class Destination {
  Destination.fromMap(Map<Object?, Object?> map)
    : enabled = map['enabled'] as bool? ?? false,
      verified = map['verified'] as bool? ?? false,
      id = map['id'] as String,
      name = map['name'] as String,
      provider = map['provider'] as String,
      prefix = map['prefix'] as String,
      targetHint = map['targetHint'] as String;
  final String id, name, provider, prefix, targetHint;
  final bool enabled, verified;
}

class RelayState {
  const RelayState({
    this.historyLimit = 30,
    this.requiresConfirmation = true,
    this.recordings = const [],
    this.destinations = const [],
    this.busy = false,
    this.nativeIOS = false,
    this.receiverEnabled = false,
    this.receiverStatus = '',
    this.postingAvailable = false,
    this.deliveries = const [],
    this.androidReceiver = false,
    this.receiverRunning = false,
    this.receiverName = '',
    this.receiverCandidates = const [],
    this.receiverEvents = const [],
    this.capabilities = const {},
    this.modelStatus = 'unprepared',
  });
  factory RelayState.fromMap(Map<Object?, Object?> map) => RelayState(
    historyLimit: (map['historyLimit'] as num).toInt(),
    requiresConfirmation: map['requiresConfirmation'] as bool,
    recordings: (map['recordings'] as List)
        .map((e) => Recording.fromMap(e as Map))
        .toList(),
    destinations: (map['destinations'] as List)
        .map((e) => Destination.fromMap(e as Map))
        .toList(),
    busy: map['busy'] as bool,
    nativeIOS: map['nativeIOS'] as bool? ?? false,
    receiverEnabled: map['receiverEnabled'] as bool? ?? false,
    receiverStatus: map['receiverStatus'] as String? ?? '',
    postingAvailable: map['postingAvailable'] as bool? ?? false,
    deliveries: ((map['deliveries'] as List?) ?? []).cast<Map>(),
    androidReceiver: map['androidReceiver'] as bool? ?? false,
    receiverRunning: map['receiverRunning'] as bool? ?? false,
    receiverName: map['receiverName'] as String? ?? '',
    receiverCandidates: ((map['receiverCandidates'] as List?) ?? [])
        .cast<Map>(),
    receiverEvents: ((map['receiverEvents'] as List?) ?? []).cast<Map>(),
    capabilities: (map['capabilities'] as Map?) ?? const {},
    modelStatus: map['modelStatus'] as String? ?? 'unprepared',
  );
  final Map capabilities;
  final String modelStatus;
  final int historyLimit;
  final bool requiresConfirmation, busy, nativeIOS, receiverEnabled;
  final bool androidReceiver, receiverRunning, postingAvailable;
  final List<Map> deliveries;
  final String receiverStatus, receiverName;
  final List<Map> receiverCandidates, receiverEvents;
  final List<Recording> recordings;
  final List<Destination> destinations;
}
