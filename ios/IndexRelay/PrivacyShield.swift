import SwiftUI
import UIKit

/// Lives in the root view's background, even while sheets cover the root content.
/// Each anchor owns a cover for its actual window scene; it never chooses a process-wide "first" scene.
struct PrivacyShieldAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> PrivacyShieldAnchorView { PrivacyShieldAnchorView() }
    func updateUIView(_ uiView: PrivacyShieldAnchorView, context: Context) { uiView.updateScene() }
    static func dismantleUIView(_ uiView: PrivacyShieldAnchorView, coordinator: ()) { uiView.detach() }
}

@MainActor
final class PrivacyShieldAnchorView: UIView {
    private let shield = ScenePrivacyShield()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateScene()
    }
    func updateScene() { shield.attach(to: window?.windowScene) }
    func detach() { shield.detach() }
}

@MainActor
private final class ScenePrivacyShield: NSObject {
    private var state = PrivacyShieldState()
    private var cover: PrivacyShieldWindow?

    func attach(to scene: UIWindowScene?) {
        guard let scene else { detach(); return }
        let identifier = ObjectIdentifier(scene)
        guard state.sceneID != identifier else { return }
        detach()
        state.attach(to: identifier, isActive: scene.activationState == .foregroundActive)
        let window = PrivacyShieldWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .systemBackground
        window.isOpaque = true
        window.isUserInteractionEnabled = false
        window.accessibilityElementsHidden = true
        window.rootViewController = PrivacyShieldViewController()
        cover = window
        // UIKit posts these scene lifecycle notifications on the main thread. Selector delivery is
        // synchronous: do not defer covering until a Task or the next main-queue turn.
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.willEnterForegroundNotification, UIScene.didActivateNotification,
                     UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: scene)
        }
        applyVisibility()
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        let event: PrivacyShieldState.Event
        switch notification.name {
        case UIScene.willDeactivateNotification: event = .willDeactivate
        case UIScene.didEnterBackgroundNotification: event = .didEnterBackground
        case UIScene.willEnterForegroundNotification: event = .willEnterForeground
        case UIScene.didActivateNotification: event = .didActivate
        case UIScene.didDisconnectNotification: event = .didDisconnect
        default: return
        }
        guard state.receive(event, from: ObjectIdentifier(scene)) else { return }
        if event == .didDisconnect { detach() } else { applyVisibility() }
    }

    private func applyVisibility() {
        guard let cover else { return }
        UIView.performWithoutAnimation {
            if let scene = cover.windowScene { cover.frame = scene.coordinateSpace.bounds }
            cover.isHidden = !state.isCovered // Never make this window key.
            if state.isCovered {
                cover.rootViewController?.view.setNeedsLayout()
                cover.layoutIfNeeded()
            }
        }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        cover?.isHidden = true
        cover?.rootViewController = nil
        cover = nil
        state.detach()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor
private final class PrivacyShieldWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

@MainActor
private final class PrivacyShieldViewController: UIViewController {
    override func loadView() {
        let background = UIView()
        background.backgroundColor = .systemBackground
        background.isOpaque = true
        background.accessibilityElementsHidden = true
        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.text = "Index Relay"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .secondaryLabel
        title.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, title])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 36),
            icon.widthAnchor.constraint(equalToConstant: 36),
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        view = background
    }
}
