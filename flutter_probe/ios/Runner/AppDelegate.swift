@preconcurrency import Flutter
import UIKit
import Speech
#if DEBUG && targetEnvironment(simulator)
@preconcurrency import IndexReceiverBridge
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, @preconcurrency FlutterImplicitEngineDelegate {
  private let transcriber = SpeechFileTranscriber()
  var relay: RelayFlutterAdapter?
  private var channel: FlutterMethodChannel?
  override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    #if DEBUG
    Self.recordSceneProbe("launch")
    if ProcessInfo.processInfo.environment["INDEX_RELAY_SCENE_PROBE"] == "1" {
      for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
                   UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                   UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification,
                   UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
        NotificationCenter.default.addObserver(self, selector: #selector(recordLifecycleNotification(_:)), name: name, object: nil)
      }
    }
    #endif
    NotificationCenter.default.addObserver(self, selector: #selector(reconnectRestoredScene(_:)),
                                           name: UIScene.didActivateNotification, object: nil)
    // Register BG tasks and restore BLE before the Flutter engine/UI exists.
    DeliveryController.shared.launch(transcriptions: AutomaticRelayService.shared.store.transcriptions)
    AutomaticRelayService.shared.launch(restoredBluetooth: launchOptions?[.bluetoothCentrals] != nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  override func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                            options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    // Native SwiftUI releases can leave a differently named scene session behind.
    // Always connect the current Flutter scene and its storyboard on an in-place update.
    let configuration = UISceneConfiguration(name: "flutter", sessionRole: session.role)
    configuration.delegateClass = SceneDelegate.self
    configuration.storyboard = UIStoryboard(name: "Main", bundle: nil)
    return configuration
  }
  @objc private func reconnectRestoredScene(_ notification: Notification) {
    guard let scene = notification.object as? UIWindowScene,
          scene.session.role == .windowApplication, !(scene.delegate is SceneDelegate),
          scene.session.configuration.name != "flutter" else { return }
    // UIKit restores the old session's SwiftUI delegate without requesting a new configuration.
    // Replace only this app's obsolete UI delegate through the public scene API; keep all data.
    #if DEBUG
    Self.recordSceneProbe("adopted", scene: scene)
    #endif
    let delegate = SceneDelegate()
    scene.delegate = delegate
    delegate.adoptRestoredScene(scene)
  }
  override func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
    // UIApplicationDelegate makes this optional; FlutterAppDelegate has no implementation.
    // Calling super raises an Objective-C unrecognized-selector exception on device unlock.
    DeliveryController.shared.launch(transcriptions: AutomaticRelayService.shared.store.transcriptions)
    AutomaticRelayService.shared.launch()
  }
  override func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
    guard identifier == DeliveryController.backgroundIdentifier else {
      super.application(application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler)
      return
    }
    DeliveryController.shared.handleBackgroundEvents(completion: completionHandler)
  }
  #if DEBUG
  @objc private func recordLifecycleNotification(_ notification: Notification) {
    let names: [Notification.Name: String] = [
      UIApplication.didEnterBackgroundNotification: "app-background", UIApplication.willEnterForegroundNotification: "app-foreground",
      UIApplication.didBecomeActiveNotification: "app-active", UIApplication.willResignActiveNotification: "app-inactive",
      UIScene.didEnterBackgroundNotification: "scene-background", UIScene.willEnterForegroundNotification: "scene-foreground",
      UIScene.didActivateNotification: "scene-active", UIScene.willDeactivateNotification: "scene-inactive"]
    if let event = names[notification.name] { Self.recordSceneProbe(event, scene: notification.object as? UIScene) }
  }
  static func recordSceneProbe(_ event: String, scene: UIScene? = nil) {
    guard ProcessInfo.processInfo.environment["INDEX_RELAY_SCENE_PROBE"] == "1" else { return }
    let file = URL.applicationSupportDirectory.appendingPathComponent("scene-probe.json")
    var rows = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []
    let launch = (rows.last?["launch"] as? Int ?? 0) + (event == "launch" ? 1 : 0)
    rows.append(["launch": launch, "event": event,
                 "configuration": scene.map { $0.session.configuration.name.map { $0 == "flutter" ? "flutter" : "legacy" } ?? "unnamed" } ?? "none"])
    if let data = try? JSONSerialization.data(withJSONObject: Array(rows.suffix(100))) {
      try? data.write(to: file, options: .atomic)
    }
  }
  #endif
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IndexRelayProbe") else { return }
    relay = RelayFlutterAdapter(messenger: registrar.messenger(), presenter: registrar.viewController)
    #if DEBUG
    channel = FlutterMethodChannel(name: "index_relay/probe", binaryMessenger: registrar.messenger())
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "receiverLifecycleProbe":
        #if targetEnvironment(simulator)
        Task { @MainActor in
          var cleanupFailures = 0
          var managersCreated = 0
          var resumed = 0
          do {
            for _ in 0..<3 {
              let receiver = RingReceiver(ringId: "00000000-0000-0000-0000-000000000001",
                onEvent: {
                  if $0 == "受信停止時の後片付けに失敗しました" { cleanupFailures += 1 }
                  if $0 == "Haversineマネージャーを生成します。" { managersCreated += 1 }
                  if $0 == "同じ受信マネージャーで再開します" { resumed += 1 }
                },
                onRaw: { _, _ in }, onAudio: { _, _, _, _, _, _ in })
              try receiver.enableContinuousMode()
              try receiver.setDurableCursor(index: -1)
              try receiver.start()
              try await Task.sleep(for: .milliseconds(100))
              for _ in 0..<3 {
                try receiver.pause()
                try receiver.pause() // Idempotent OFF.
                try await Task.sleep(for: .milliseconds(30))
                try receiver.resume()
                try receiver.resume() // Idempotent ON.
                try await Task.sleep(for: .milliseconds(30))
              }
              try receiver.stop()
              try receiver.stop() // Repeated stops must also be harmless.
            }
            result(["cycles": 3, "cleanupFailures": cleanupFailures, "managersCreated": managersCreated, "resumed": resumed])
          } catch {
            result(FlutterError(code: "RECEIVER_LIFECYCLE_TEST_FAILED", message: "受信器の停止試験に失敗", details: nil))
          }
        }
        #else
        result(FlutterMethodNotImplemented)
        #endif
      case "protectedDataAvailableProbe":
        #if targetEnvironment(simulator)
        self.applicationProtectedDataDidBecomeAvailable(UIApplication.shared)
        result(true)
        #else
        result(FlutterMethodNotImplemented)
        #endif
      case "lifecycleProbeEvent":
        if let event = (call.arguments as? [String: String])?["state"],
           ["uiReady", "resumed", "inactive", "hidden", "paused", "detached"].contains(event) {
          Self.recordSceneProbe("dart-" + event)
        }
        result(true)
      case "capabilities":
        result(["platform": "ios", "speechAvailable": SpeechTranscriber.isAvailable,
                "backend": "existing SpeechFileTranscriber", "bleVerified": false])
      case "transcribeFixture":
        guard let args = call.arguments as? [String: Any], let wav = args["wav"] as? FlutterStandardTypedData, wav.data.count <= 2_000_000 else {
          result(FlutterError(code: "INVALID_WAV", message: "試験WAVを確認してください", details: nil)); return
        }
        Task { @MainActor in
          let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
          defer { try? FileManager.default.removeItem(at: file) }
          do {
            try wav.data.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
            let text = try await self.transcriber.transcribe(file: file, allowModelDownload: true, status: { _ in })
            result(["text": text, "offline": true, "engine": "existing Apple SpeechAnalyzer"])
          } catch {
            result(FlutterError(code: "TRANSCRIPTION_UNAVAILABLE", message: "端末内日本語認識またはモデルを利用できません", details: nil))
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
    #endif
  }
}
