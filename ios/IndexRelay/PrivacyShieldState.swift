/// Lifecycle policy shared by the UIKit cover and deterministic tests.
/// Reattaching the same scene must not undo a willDeactivate cover before UIKit updates activationState.
struct PrivacyShieldState {
    enum Event { case willDeactivate, didEnterBackground, willEnterForeground, didActivate, didDisconnect }
    private(set) var sceneID: ObjectIdentifier?
    private(set) var isCovered = false

    mutating func attach(to sceneID: ObjectIdentifier, isActive: Bool) {
        guard self.sceneID != sceneID else { return }
        self.sceneID = sceneID
        isCovered = !isActive
    }
    @discardableResult
    mutating func receive(_ event: Event, from sceneID: ObjectIdentifier) -> Bool {
        guard self.sceneID == sceneID else { return false }
        switch event {
        case .willDeactivate, .didEnterBackground, .willEnterForeground: isCovered = true
        case .didActivate: isCovered = false
        case .didDisconnect: detach()
        }
        return true
    }
    mutating func detach() { sceneID = nil; isCovered = false }
}
