final class SceneToken {}
let first = SceneToken(), second = SceneToken()
let a = ObjectIdentifier(first), b = ObjectIdentifier(second)
var count = 0
@MainActor
func expect(_ condition: @autoclosure () -> Bool) {
    count += 1
    precondition(condition(), "PrivacyShield check \(count) failed")
}
var state = PrivacyShieldState()
expect(state.sceneID == nil && !state.isCovered)
expect(!state.receive(.didActivate, from: a))
state.attach(to: a, isActive: true)
expect(state.sceneID == a && !state.isCovered)
expect(state.receive(.willDeactivate, from: a))
expect(state.isCovered)
// UIKit's activationState can still report active while willDeactivate is delivered.
state.attach(to: a, isActive: true)
expect(state.isCovered)
expect(!state.receive(.didActivate, from: b))
expect(state.isCovered && state.sceneID == a)
expect(state.receive(.didEnterBackground, from: a))
expect(state.isCovered)
expect(state.receive(.willEnterForeground, from: a))
expect(state.isCovered)
expect(state.receive(.didActivate, from: a))
expect(!state.isCovered)
// Permission/control-center style inactive -> active without entering background.
expect(state.receive(.willDeactivate, from: a) && state.isCovered)
expect(state.receive(.willDeactivate, from: a) && state.isCovered)
expect(state.receive(.didActivate, from: a) && !state.isCovered)
// Attaching while background/inactive must be private from its first frame.
state.attach(to: b, isActive: false)
expect(state.sceneID == b && state.isCovered)
expect(!state.receive(.didActivate, from: a))
expect(!state.receive(.didDisconnect, from: a))
expect(state.sceneID == b && state.isCovered)
expect(state.receive(.didActivate, from: b) && !state.isCovered)
expect(state.receive(.didDisconnect, from: b))
expect(state.sceneID == nil && !state.isCovered)
expect(!state.receive(.willEnterForeground, from: b))
state.attach(to: a, isActive: false)
expect(state.isCovered)
state.detach()
expect(state.sceneID == nil && !state.isCovered)
expect(!state.receive(.willDeactivate, from: a))
print("PrivacyShield: \(count) checks passed")
