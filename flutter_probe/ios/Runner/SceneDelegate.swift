import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    private var shield: PrivacyShieldAnchorView?
    override func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        // Flutter uses the persisted configuration name as an NSUserActivity type.
        // SwiftUI sessions can have no name; that activity construction raises an exception.
        // Skip only legacy UI restoration. Recordings, queue state and credentials stay in their stores.
        guard scene.session.configuration.name == "flutter" else {
            #if DEBUG
            AppDelegate.recordSceneProbe("legacy-restoration-skipped", scene: scene)
            #endif
            return nil
        }
        return super.stateRestorationActivity(for: scene)
    }
    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        #if DEBUG
        AppDelegate.recordSceneProbe("connected", scene: scene)
        #endif
        let anchor = PrivacyShieldAnchorView(frame: .zero)
        window?.addSubview(anchor)
        shield = anchor
    }
    func adoptRestoredScene(_ scene: UIWindowScene) {
        for oldWindow in scene.windows { oldWindow.isHidden = true }
        let restoredWindow = UIWindow(windowScene: scene)
        window = restoredWindow
        restoredWindow.rootViewController = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()
        let anchor = PrivacyShieldAnchorView(frame: .zero)
        restoredWindow.addSubview(anchor); shield = anchor
        restoredWindow.makeKeyAndVisible()
        if scene.activationState == .foregroundActive { sceneDidBecomeActive(scene) }
    }
    override func sceneDidBecomeActive(_ scene: UIScene) {
        super.sceneDidBecomeActive(scene)
        shield?.sceneBecameActive(scene)
        #if DEBUG
        AppDelegate.recordSceneProbe("native-active", scene: scene)
        #endif
        (UIApplication.shared.delegate as? AppDelegate)?.relay?.attachPresenter(window?.rootViewController)
        AutomaticRelayService.shared.enterForeground()
        DeliveryController.shared.enterForeground()
    }
    override func sceneDidEnterBackground(_ scene: UIScene) {
        AutomaticRelayService.shared.enterBackground()
        DeliveryController.shared.enterBackground()
        super.sceneDidEnterBackground(scene)
        #if DEBUG
        AppDelegate.recordSceneProbe("native-background", scene: scene)
        #endif
    }
    override func sceneDidDisconnect(_ scene: UIScene) {
        shield?.detach(); shield?.removeFromSuperview(); shield = nil
        super.sceneDidDisconnect(scene)
    }
}
