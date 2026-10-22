import Foundation
var checks = 0
@MainActor
func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("IndexRelayHistory-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
func key(_ n: Int) -> String { String(format: "%064x", n) }
func clip(_ n: Int, frames: Int = 16000, released: Int64? = nil) -> ReceivedRecording {
    ReceivedRecording(id: key(n), receivedAt: Date(timeIntervalSince1970: Double(n)), sampleRate: 16000,
        sampleCount: frames, collectionIndex: n & 65535, contiguous: true,
        transfer: released.map { TransferContext(start: Int64(n), releasedMs: $0, completedMs: $0, buttonSequencePresent: true) })
}
let all = (1...55).map { clip($0) }
let ordered = HistoryPolicy.newestFirst(all.shuffled())
check(ordered.first?.id == key(55) && ordered.last?.id == key(1), "Newest first regardless of file enumeration order")
check(HistoryPolicy.defaultLimit == 30, "Default history limit is 30")
check(HistoryPolicy.deletions(all) == Set((1...25).map(key)), "Default retention keeps newest 30")
check(HistoryPolicy.deletions(all, limit: 10) == Set((1...45).map(key)), "Configured smaller limit trims the oldest entries")
check(HistoryPolicy.deletions(all, limit: 100).isEmpty, "Increasing limit does not delete existing entries")
let old = HistoryPolicy.deletions(all, limit: 50)
check(old == Set((1...5).map(key)), "Keep exactly newest 50 recordings")
check(HistoryPolicy.deletions(Array(all.prefix(50)), limit: 50).isEmpty, "Never delete normal entries under the limit")
let tiny = clip(90, frames: 16)
check(HistoryPolicy.deletions(Array(all.prefix(50)) + [tiny], limit: 50) == [tiny.id], "Tiny protocol tails do not consume the 50 history slots")
let a = clip(1, released: 1_800_000_000_000)
let b = clip(99, released: 1_700_000_000_000)
check(HistoryPolicy.newestFirst([a,b]).first?.id == a.id, "Use recording time rather than delayed BLE arrival when available")
let tied = [ReceivedRecording(id: key(2), receivedAt: .distantPast, sampleRate: 16000, sampleCount: 16000, collectionIndex: 1, contiguous: true, transfer: nil), ReceivedRecording(id: key(1), receivedAt: .distantPast, sampleRate: 16000, sampleCount: 16000, collectionIndex: 2, contiguous: true, transfer: nil)]
check(HistoryPolicy.newestFirst(tied).first?.id == key(1), "Equal timestamps sort deterministically")
let ledger = try HistoryArchive(root: root)
check(ledger.state.deletedIDs.isEmpty && ledger.state.pendingIDs.isEmpty, "New history requires no migration or deletion")
try ledger.markDeleted(old)
check(ledger.state.deletedIDs == old && ledger.state.pendingIDs == old, "Tombstone and cleanup journal committed together")
let interrupted = try HistoryArchive(root: root)
check(interrupted.state.pendingIDs == old, "Interrupted cleanup resumes after process restart")
try interrupted.finishDeletion(old)
let restored = try HistoryArchive(root: root)
check(restored.state.pendingIDs.isEmpty && restored.state.deletedIDs == old, "Finished cleanup retains only suppression IDs")
check(restored.retentionLimit == 30, "Settings saved before this version adopt the new default")
try restored.setRetentionLimit(50)
check(try HistoryArchive(root: root).retentionLimit == 50, "Configured limit survives restart")
check(restored.state.deletedIDs == old, "Changing limit preserves deletion suppression")
check(rejects { try restored.setRetentionLimit(0) } && rejects { try restored.setRetentionLimit(501) }, "Invalid configured limits rejected")
check(restored.retentionLimit == 50, "Invalid change cannot publish a destructive limit")
try restored.markDeleted([key(2)])
check(restored.state.pendingIDs == [key(2)] && restored.state.deletedIDs == old, "Repeated deletion is idempotent and recoverable")
check(rejects { try restored.markDeleted(["../path"]) }, "Invalid path-like ID rejected")
let keptID = key(50)
for id in [key(2), keptID] {
    for relative in ["ReceivedRecordings/" + id + ".json", "ReceivedRecordings/" + id + ".wav", "Transcripts/" + id + ".json"] {
        let url = root.appendingPathComponent(relative)
        try TranscriptArchive.makeProtectedDirectory(url.deletingLastPathComponent())
        try Data("content".utf8).write(to: url)
    }
}
try restored.removeContentFiles([key(2)])
check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ReceivedRecordings/" + key(2) + ".wav").path), "Audio file physically removed")
check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Transcripts/" + key(2) + ".json").path), "Transcript file physically removed")
check(FileManager.default.fileExists(atPath: root.appendingPathComponent("ReceivedRecordings/" + keptID + ".wav").path), "Deleting an old entry preserves newer audio")
try restored.removeContentFiles([key(2)])
check(rejects { try restored.removeContentFiles([keptID]) }, "Never remove content before durable tombstone")
let file = restored.file
try FileManager.default.removeItem(at: file)
try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
let before = restored.state.deletedIDs
check(rejects { try restored.markDeleted([key(77)]) }, "Failed tombstone write surfaces to caller")
check(restored.state.deletedIDs == before, "Failed write cannot publish authorization to discard data")
check(rejects { try restored.setRetentionLimit(10) } && restored.retentionLimit == 50, "Failed setting write preserves previous limit")
let badRoot = root.appendingPathComponent("bad")
try TranscriptArchive.makeProtectedDirectory(badRoot.appendingPathComponent("History"))
try Data("broken".utf8).write(to: badRoot.appendingPathComponent("History/deletions.json"))
check(rejects { _ = try HistoryArchive(root: badRoot) }, "Corrupt deletion journal is never silently replaced")
let destination = DeliveryDestination(id: UUID(), name: "D", provider: .discord, targetID: "1", targetKind: "channel", identity: "D:1", enabled: true)
func job(_ phase: DeliveryPhase) -> DeliveryJob {
    DeliveryJob(recordingID: key(1), destinationID: destination.id, destinationName: "D", provider: .discord,
                targetIdentity: "D:1", text: "本文", createdAt: .now, confirmationRequired: true, phase: phase)
}
check(HistoryDeliverySummary(jobs: []).title == "未連携", "No route is not falsely shown as delivered")
check(HistoryDeliverySummary(jobs: [job(.sent)]).complete, "A confirmed delivery is green / complete")
check(HistoryDeliverySummary(jobs: [job(.sent),job(.queued)]).title == "送信待ち 1/2件", "Multiple destination progress is visible")
check(HistoryDeliverySummary(jobs: [job(.sent),job(.sent)]).title == "連携済み 2/2件", "All destinations must succeed before complete")
check(HistoryDeliverySummary(jobs: [job(.unknown)]).requiresAttention, "Uncertain result is not mistaken for completion")
check(HistoryDeliverySummary(jobs: [job(.needsAttention)]).title == "要対応", "Failure is visible on home")
check(HistoryDeliverySummary(jobs: [job(.confirmation)]).title == "確認待ち", "Approval state visible without settings")
check(HistoryDeliverySummary(jobs: [job(.cancelled)]).title == "送信しない", "Cancelled state visible")
check(!HistoryDeliverySummary(jobs: [job(.sent),job(.cancelled)]).complete, "Partial success remains distinct")
// Deletion must remove both ASR work and delivery text without rewinding BLE resume state.
let queue = try AutomaticQueue(file: root.appendingPathComponent("auto.json"))
try queue.configure(ringID: UUID().uuidString, name: "Ring")
try queue.observe(first: 1, reset: false)
try queue.received(clip(1), start: 1); try queue.received(clip(2), start: 2)
let frontier = queue.state.frontier.committed
try queue.start(id: key(1)); try queue.removeRecordings([key(1)])
check(queue.state.jobs[key(1)] == nil && queue.state.jobs[key(2)] != nil, "Deleting active ASR work leaves other recordings queued")
check(queue.state.frontier.committed == frontier, "Deleting history never rewinds reception frontier")
try queue.discardReceived(id: key(1), start: 1, end: 1)
check(queue.state.jobs[key(1)] == nil && queue.state.frontier.committed == frontier, "A tombstoned replay never requeues recognition")
let deliveries = try DeliveryArchive(file: root.appendingPathComponent("delivery.json"))
try deliveries.upsertDestination(destination); try deliveries.ingest([:])
let transcript = try TranscriptRecord(recordingID: key(1), text: "削除される本文")
try deliveries.ingest([key(1): transcript]); let id = deliveries.state.jobs[0].id
try deliveries.approve(id: id, text: transcript.text); let attempt = UUID(); try deliveries.begin(id: id, attempt: attempt)
try deliveries.removeRecordings([key(1)])
check(deliveries.state.jobs.isEmpty, "Deleting in-flight history purges local delivery text / routing")
check(deliveries.state.seenRecordings.contains(key(1)), "Deleted transcript cannot be routed again")
try deliveries.ingest([key(1): transcript])
check(deliveries.state.jobs.isEmpty, "Reconciliation of a stale transcript cannot recreate removed delivery")
print("History: \(checks) checks passed")
