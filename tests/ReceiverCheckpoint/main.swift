import Foundation

var checks = 0
@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    precondition(condition(), label)
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("index-relay-checkpoint-test-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let checkpoint = ReceiverCheckpoint(directory: folder)
expect(checkpoint.read() == nil, "No previous checkpoint")
expect(checkpoint.write("音声変換直前"), "Synchronous write succeeds")
expect(checkpoint.read()?.stage == "音声変換直前", "Read saved checkpoint")
let reopened = ReceiverCheckpoint(directory: folder)
expect(reopened.read()?.stage == "音声変換直前", "Fresh instance reads previous process file")
expect(checkpoint.write(String(repeating: "a", count: 1000)), "Bounded input write")
expect(checkpoint.read()?.stage.count == 500, "Bound message length")
DispatchQueue.concurrentPerform(iterations: 30) { i in
    _ = checkpoint.write("stage \(i)")
    _ = checkpoint.read()
}
expect(checkpoint.read() != nil, "Concurrent callbacks leave valid JSON")
expect(checkpoint.clear(), "Explicit clear succeeds")
expect(reopened.read() == nil, "Clear persists across instances")
expect(checkpoint.clear(), "Clear is idempotent")
print("ReceiverCheckpoint: \(checks) checks passed")
