import SwiftUI
import UIKit

@MainActor
final class RelayAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Register tasks and recreate the native BLE central before any diagnostic view opens.
        DeliveryController.shared.launch(transcriptions: AutomaticRelayService.shared.store.transcriptions)
        AutomaticRelayService.shared.launch(restoredBluetooth: launchOptions?[.bluetoothCentrals] != nil)
        return true
    }
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        DeliveryController.shared.launch(transcriptions: AutomaticRelayService.shared.store.transcriptions)
        AutomaticRelayService.shared.launch()
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DeliveryController.backgroundIdentifier else { completionHandler(); return }
        DeliveryController.shared.handleBackgroundEvents(completion: completionHandler)
    }
}

@main
struct IndexRelayApp: App {
    @UIApplicationDelegateAdaptor(RelayAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { AutomaticRelayView(service: AutomaticRelayService.shared) }
    }
}
