import Foundation

// Runs without a Bluetooth device: swiftc ios/IndexRelay/PairingProbe.swift
// tests/PairingProbe/main.swift -o <temporary binary>; then execute that binary.
var checks = 0
@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
    checks += 1
    guard condition() else {
        fatalError("FAIL: \(description)")
    }
}

let first = UUID()
let second = UUID()
var probe = PairingProbe()
expect(probe.state == .notRun, "Starts without a pending write")
expect(!probe.finish(connectionID: first, outcome: .acknowledged, detail: "late"), "Rejects unsolicited acknowledgement")
expect(probe.begin(connectionID: first), "Starts explicit check")
expect(!probe.begin(connectionID: first), "Does not duplicate pending write")
expect(!probe.begin(connectionID: second), "Does not replace pending connection")
expect(!probe.finish(connectionID: second, outcome: .acknowledged, detail: "wrong"), "Rejects stale connection callback")
expect(!probe.finish(connectionID: first, outcome: .notRun, detail: "invalid"), "Rejects invalid terminal state")
expect(probe.finish(connectionID: first, outcome: .timedOut, detail: "timeout"), "Timeout ends request")
expect(!probe.finish(connectionID: first, outcome: .acknowledged, detail: "late"), "Late acknowledgement cannot overwrite timeout")
expect(!probe.begin(connectionID: first), "No retry on same connection after timeout")
expect(probe.state == .timedOut && probe.detail == "timeout", "Keeps uncertain outcome")

for outcome in [PairingProbe.State.acknowledged, .failed, .interrupted] {
    var next = PairingProbe()
    expect(next.begin(connectionID: second), "New connection can be checked")
    expect(next.finish(connectionID: second, outcome: outcome, detail: "result"), "Accepts terminal outcome")
    expect(!next.finish(connectionID: second, outcome: .acknowledged, detail: "duplicate"), "Ignores duplicate callback")
    expect(!next.begin(connectionID: second), "Exactly one explicit write per connection")
    expect(next.state == outcome, "Preserves terminal result")
}

print("PairingProbe: \(checks) checks passed")
