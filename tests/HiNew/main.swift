import Foundation
var checks = 0
@MainActor func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
func response(_ value: [String: Any], status: Int = 200) -> HiNewHTTPResponse { HiNewHTTPResponse(status: status, data: json(value)) }
enum Step: Sendable { case value(HiNewHTTPResponse), failure(HiNewError) }
actor Script: HiNewTransport {
    var steps: [Step]; private var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> HiNewHTTPResponse {
        requests.append(request); precondition(!steps.isEmpty, "Unexpected network request")
        switch steps.removeFirst() { case .value(let value): return value; case .failure(let error): throw error }
    }
    func captured() -> [URLRequest] { requests }
}
let token = "hn_" + String(repeating: "x", count: 32)
let invite = "https://hi.new/i/" + "hni_" + String(repeating: "y", count: 32)
let peer = "reader-bot", sender = "relay-bot"
let me: [String: Any] = ["name": sender, "email_verified": true]
let grant: [String: Any] = ["name": peer, "key_changed": false, "public_key": NSNull(), "pinned_key": NSNull()]
let grants: [String: Any] = ["grants": [grant]]
let noGrants: [String: Any] = ["grants": [[String: Any]]()]
for name in ["abc", "reader-bot", String(repeating: "a", count: 32)] { check(DeliveryDestination.validHandle(name), "Valid handle") }
for name in ["ab", "-abc", "abc-", "a--b", "ABC", "a/b", "a?b", "日本語", String(repeating: "a", count: 33)] { check(!DeliveryDestination.validHandle(name), "Unsafe handle rejected") }
for bad in ["", "Bearer " + token, token + "\n", "hns_" + String(repeating: "a", count: 32), "https://elsewhere.test/"] { check(!HiNewAPI.tokenIsValid(bad), "Only sender bearer tokens accepted") }
check(HiNewAPI.tokenIsValid(token), "Owner token accepted")
check(HiNewAPI.tokenIsValid("hnt_" + String(repeating: "x", count: 32)), "Scoped token accepted")
check(try HiNewAPI.inviteToken(invite).hasPrefix("hni_"), "Extract invite capability")
for bad in [invite.replacingOccurrences(of: "https:", with: "http:"), invite.replacingOccurrences(of: "hi.new", with: "hi.new.evil.test"), invite + "?x=y", invite + "#fragment", invite.replacingOccurrences(of: "hi.new", with: "user@hi.new"), invite.replacingOccurrences(of: "hi.new", with: "hi.new:443"), invite.replacingOccurrences(of: "/i/", with: "/i/%68"), "hni_" + String(repeating: "a", count: 32)] {
    check(rejects { _ = try HiNewAPI.inviteToken(bad) }, "Reject modified origin/path/invite")
}
for path in ["//evil.test/api/grants", "/api/inbox", "/api/handles", "/api/dm/../evil", "/api/dm/reader-bot?next=https://evil.test", "/api/tokens"] {
    check(rejects { _ = try HiNewAPI.request(path: path, token: token, method: "POST") }, "Allowlisted paths only")
}
var destination = try HiNewAPI.destination(me: me, grants: grants, peer: peer)
check(destination.isSupported && !destination.enabled && destination.hiNewSender == sender, "Verified destination starts disabled")
check(destination.identity == "hi-new:relay-bot:reader-bot", "Sender and recipient bound in identity")
var unconfirmed = destination; unconfirmed.hiNewPlaintextConfirmed = false
check(!unconfirmed.isSupported, "Unconfirmed plaintext cannot send")
for update: [String: Any] in [["key_changed": true], ["public_key": "age1test"], ["pinned_key": "age1test"], ["key_changed": 0]] {
    let bad = grant.merging(update) { _, new in new }
    check(rejects { _ = try HiNewAPI.destination(me: me, grants: ["grants": [bad]], peer: peer) }, "Reject keys and malformed key status")
}
check(rejects { _ = try HiNewAPI.destination(me: ["name": sender, "email_verified": false], grants: grants, peer: peer) }, "Owner email verification required")
check(rejects { _ = try HiNewAPI.destination(me: me, grants: noGrants, peer: peer) }, "Grant required")
check(rejects { _ = try HiNewAPI.destination(me: me, grants: grants, peer: peer, expectedSender: "other-bot") }, "Token replacement cannot change sender")
let root = FileManager.default.temporaryDirectory.appendingPathComponent("IndexRelayHiNew-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let file = root.appendingPathComponent("state.json")
let archive = try DeliveryArchive(file: file)
destination.enabled = true; destination.prefix = "memo"
var second = destination; second.id = UUID(); second.targetID = "backup-bot"; second.identity = "hi-new:relay-bot:backup-bot"
try archive.transaction { $0.destinations = [destination, second]; $0.baselineEstablished = true }
let transcript = try TranscriptRecord(recordingID: String(repeating: "a", count: 64), text: "日本語メモ")
try archive.ingest([transcript.recordingID: transcript])
check(archive.state.jobs.count == 2 && archive.state.jobs.allSatisfy { $0.phase == .confirmation }, "Confirmation default and per-destination jobs")
let job = archive.state.jobs[0], other = archive.state.jobs[1]
check(job.hiNewKey != other.hiNewKey && job.hiNewKey.count <= 128, "No key collision across recipients")
check(job.text == "memo 日本語メモ", "Existing prefix format retained")
let (post, payload) = try HiNewAPI.post(destination: destination, token: token, job: job)
let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
check(post.url?.absoluteString == "https://hi.new/api/dm/reader-bot" && post.httpMethod == "POST", "Fixed HTTPS DM endpoint")
check(post.value(forHTTPHeaderField: "Authorization") == "Bearer " + token, "Bearer header")
check(post.value(forHTTPHeaderField: "Idempotency-Key") == job.hiNewKey && post.httpBody == nil, "Stable header and separate upload file data")
check(object["enc"] as? String == "none" && object["recipient_public_key"] is NSNull && object["body"] as? String == job.text, "Explicit plaintext and nil recipient key")
check(rejects { _ = try HiNewAPI.post(destination: second, token: token, job: job) }, "Routing snapshot cannot redirect to another peer")
for count in [64_000, 64_001] { check(DeliveryArchive.validText(String(repeating: "a", count: count), for: .hiNew) == (count == 64_000), "UTF8 ASCII boundary") }
check(DeliveryArchive.validText(String(repeating: "あ", count: 21_333), for: .hiNew), "UTF8 Japanese within limit")
check(!DeliveryArchive.validText(String(repeating: "あ", count: 21_334), for: .hiNew), "UTF8 Japanese overflow")
check(!DeliveryArchive.validText(String(repeating: "😀", count: 16_001), for: .hiNew), "UTF8 supplementary overflow")
try archive.approve(id: job.id, text: "edited")
let attempt = UUID(); try archive.begin(id: job.id, attempt: attempt)
let started = archive.state.jobs[0]
check(started.firstSubmissionAt != nil && started.textIsFrozen, "Persist first attempt before dispatch")
try archive.finish(id: job.id, attempt: attempt, result: .unknown)
check(archive.state.jobs[0].hiNewPossiblyAccepted == true, "Uncertain acceptance preserved")
try archive.retry(id: job.id, allowUnknown: true)
let attempt2 = UUID(); try archive.begin(id: job.id, attempt: attempt2)
check(archive.state.jobs[0].hiNewKey == started.hiNewKey, "Manual unknown retry keeps original key")
try archive.finish(id: job.id, attempt: attempt2, result: .retry(3600))
check(archive.state.jobs[0].phase == .unknown && archive.state.jobs[0].hiNewPossiblyAccepted == true, "Later rejection cannot disprove earlier acceptance")
do {
    try archive.retry(id: job.id, allowUnknown: true)
    preconditionFailure("Cooldown must explain the wait")
} catch DeliveryStoreError.waitingUntil(let date) {
    check(date > .now && DeliveryStoreError.waitingUntil(date).localizedDescription.contains("待機中"), "Unknown replay explains cooldown")
}
check(archive.state.jobs[0].phase == .unknown, "Unknown replay honors rate cooldown")
check(archive.next() == nil, "Quota shared across same sender's recipients")
try archive.update(job.id) { $0.retryAfter = nil; $0.phase = .needsAttention }
check(rejects { try archive.approve(id: job.id, text: "different") }, "Frozen body cannot be edited after any attempt")
try archive.approve(id: job.id, text: "edited")
let reload = try DeliveryArchive(file: file)
check(reload.state.jobs[0].hiNewKey == started.hiNewKey && reload.state.jobs[0].text == "edited", "Reboot retains immutable send identity and body")
check(!started.canReplayHiNew(now: started.firstSubmissionAt!.addingTimeInterval(86_400)), "Bounded replay window")
try archive.update(job.id) { $0.firstSubmissionAt = .now.addingTimeInterval(-86_401) }
check(rejects { try archive.begin(id: job.id, attempt: UUID()) }, "Cannot dispatch after replay window")
check(rejects { try archive.retry(id: job.id, allowUnknown: true) }, "Expired key is never automatically replaced")
let expiry = "2026-11-01T00:00:00.000Z"
let receipt: [String: Any] = ["id": 42, "to": peer, "enc": "none", "expires_at": expiry, "replayed": false]
func classify(_ status: Int?, _ body: [String: Any] = [:], error: Int? = nil, sent: Int64 = 1, retry: TimeInterval? = nil) -> DeliveryResult {
    HiNewAPI.classify(status: status, data: json(body), errorCode: error, bytesSent: sent, expectedPeer: peer, retryAfter: retry)
}
check(classify(201, receipt) == .hiNewSent("42", HiNewAPI.parseDate(expiry)!, false), "Receipt stores message ID, expiry and replay")
var replayReceipt = receipt; replayReceipt["replayed"] = true
check(classify(201, replayReceipt) == .hiNewSent("42", HiNewAPI.parseDate(expiry)!, true), "ACKed message replay resolves original send")
for update: [String: Any] in [["id": true], ["id": -1], ["to": "other-bot"], ["enc": "age"], ["replayed": 1], ["expires_at": "bad"]] {
    check(classify(201, receipt.merging(update) { _, new in new }) == .unknown, "Malformed receipt remains uncertain")
}
check(classify(200, receipt) != .hiNewSent("42", HiNewAPI.parseDate(expiry)!, false), "200 without replay confirmation remains unknown")
check(classify(500) == .unknown, "No blind 5xx retry")
check(classify(nil, error: NSURLErrorTimedOut, sent: 0) == .unknown, "Zero-byte counter cannot prove timeout was unsent")
check(classify(nil, error: NSURLErrorCannotConnectToHost, sent: 0) == .retry(30), "Definite preconnection failure retry")
check(classify(429) == .retry(3600), "Hourly fallback, no rapid 429 retry")
check(classify(429, retry: 7200) == .retry(7200), "Respect longer Retry-After")
check(classify(429, retry: .nan) == .retry(3600), "Malformed delay bounded")
for (status, code) in [(400, "encryption_required"), (409, "recipient_key_changed"), (409, "idempotency_key_reused"), (403, "no_grant"), (401, "invalid_token"), (402, "payment_required")] {
    if case .hiNewBlocked(let detail) = classify(status, ["error": code, "hint": token]) { check(!detail.contains(token), "Pause credential/key failures without leaking provider text") }
    else { check(false, "Should pause destination") }
}
check(DeliveryAPI.classify(provider: .discord, status: 500, data: Data(), errorCode: nil, bytesSent: 0) == .unknown, "Discord semantics unchanged")
check(DeliveryAPI.classify(provider: .telegram, status: 429, data: json(["retry_after": 3]), errorCode: nil, bytesSent: 0) == .retry(3), "Telegram semantics unchanged")
let readScript = Script([.value(response(me)), .value(response(grants))])
let validated = try await HiNewAPI.validate(token: token, peer: peer, transport: readScript)
check(validated.identity == destination.identity, "Mock setup validation")
let readRequests = await readScript.captured()
check(readRequests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "hi.new" }, "Saving never posts, claims, reads inbox, or sends")
let redeemScript = Script([.value(response(me)), .value(response(noGrants)), .failure(.network(NSURLErrorTimedOut)), .value(response(me)), .value(response(grants))])
let reconciled = try await HiNewAPI.redeem(token: token, peer: peer, invite: invite, transport: redeemScript)
let redeemRequests = await redeemScript.captured()
check(reconciled.identity == destination.identity && redeemRequests.filter { $0.httpMethod == "POST" }.count == 1, "Lost single-use response reconciles grant without second redeem")
let connectedScript = Script([.value(response(me)), .value(response(grants))])
_ = try await HiNewAPI.redeem(token: token, peer: peer, invite: invite, transport: connectedScript)
let connectedRequests = await connectedScript.captured()
check(connectedRequests.count == 2 && connectedRequests.allSatisfy { $0.httpMethod == "GET" }, "Already connected does not consume another invite")
let wrongSenderScript = Script([.value(response(me))])
do { _ = try await HiNewAPI.redeem(token: token, peer: peer, invite: invite, expectedSender: "other-bot", transport: wrongSenderScript); check(false, "Wrong sender rejected") } catch HiNewError.wrongPeer { check(true, "Wrong sender rejected before mutation") }
let wrongSenderRequests = await wrongSenderScript.captured(); check(wrongSenderRequests.count == 1, "No redeem with replacement account")
let unverifiedScript = Script([.value(response(["name": sender, "email_verified": false]))])
do { _ = try await HiNewAPI.redeem(token: token, peer: peer, invite: invite, transport: unverifiedScript); check(false, "Unverified owner rejected") } catch HiNewError.unverifiedOwner { check(true, "Unverified owner rejected before grant mutation") }
let stale = UUID(); try archive.finish(id: job.id, attempt: stale, result: .hiNewBlocked("changed"))
check(archive.state.destinations[0].enabled, "Stale callback cannot disable current target")
try archive.update(job.id) { $0.firstSubmissionAt = .now; $0.phase = .queued; $0.hiNewPossiblyAccepted = false }
let a3 = UUID(); try archive.begin(id: job.id, attempt: a3)
try archive.finish(id: job.id, attempt: a3, result: .hiNewBlocked("changed"))
let paused = try DeliveryArchive(file: file)
check(paused.state.jobs[0].phase == .needsAttention && !paused.state.destinations[0].enabled, "Security failure atomically persists job and destination pause")
check(DeliverySessionDelegate.retryDelay("7200") == 7200 && DeliverySessionDelegate.retryDelay("nan") == nil, "Parse Retry-After safely")
let date = HiNewAPI.parseDate("2026-10-24T00:00:00Z")!
check(DeliverySessionDelegate.retryDelay("Sat, 24 Oct 2026 01:00:00 GMT", now: date) == 3600, "HTTP-date Retry-After")
// Replay receipts survive reboot; a successful replay must resolve earlier uncertainty.
try archive.transaction { $0.destinations[0].enabled = true }
try archive.approve(id: job.id, text: "edited")
let receiptAttempt = UUID(); try archive.begin(id: job.id, attempt: receiptAttempt)
try archive.finish(id: job.id, attempt: receiptAttempt, result: .hiNewSent("42", HiNewAPI.parseDate(expiry)!, true))
let receipted = try DeliveryArchive(file: file).state.jobs[0]
check(receipted.phase == .sent && receipted.messageID == "42" && receipted.hiNewReplayed == true && receipted.hiNewExpiresAt == HiNewAPI.parseDate(expiry)!, "Persist replay receipt, expiry and sent phase")
check(receipted.hiNewPossiblyAccepted == false && receipted.retryAfter == nil, "Resolved receipt clears previous uncertainty and cooldown")
let remaining = archive.state.jobs[1]
try archive.approve(id: remaining.id, text: remaining.text)
let lost = UUID(); try archive.begin(id: remaining.id, attempt: lost)
try archive.recover(activeAttempts: [])
check(archive.state.jobs[1].phase == .unknown && archive.state.jobs[1].hiNewPossiblyAccepted == true, "Lost OS task keeps original uncertainty and key")
var differentAccount = destination; differentAccount.id = UUID(); differentAccount.hiNewSender = "alternate-bot"; differentAccount.identity = "hi-new:alternate-bot:reader-bot"
try archive.transaction { state in
    state.jobs[1].retryAfter = .now.addingTimeInterval(3600)
    state.destinations.append(differentAccount)
    state.jobs.append(DeliveryJob(recordingID: "account-test", destinationID: differentAccount.id, destinationName: "Other account", provider: .hiNew,
                                 targetIdentity: differentAccount.identity, text: "body", createdAt: .now, confirmationRequired: false, phase: .queued))
}
check(archive.next()?.destinationID == differentAccount.id, "One sender's quota does not block another sender")
check(HiNewAPI.classify(status: 302, data: Data(), errorCode: nil, bytesSent: 1, expectedPeer: peer) == .unknown, "Redirect after POST does not prove rejection")
let preparationID = UUID()
try archive.transaction { state in
    var pending = DeliveryJob(id: preparationID, recordingID: "preparation-test", destinationID: destination.id, destinationName: "Preparation", provider: .hiNew,
                              targetIdentity: destination.identity, text: "body", createdAt: .now, confirmationRequired: false, phase: .queued)
    pending.firstSubmissionAt = .now; pending.hiNewPossiblyAccepted = true
    state.jobs.append(pending)
}
try archive.hiNewValidationFailed(id: preparationID, detail: "offline", retryDelay: 30)
check(archive.state.jobs.last?.phase == .unknown && archive.state.jobs.last?.hiNewPossiblyAccepted == true, "Read-only preflight failure preserves previous POST uncertainty")
try archive.update(preparationID) { $0.phase = .queued; $0.retryAfter = nil }
try archive.hiNewValidationFailed(id: preparationID, detail: "changed key", retryDelay: nil)
check(archive.state.jobs.last?.phase == .unknown && archive.state.destinations[0].enabled == false, "Permanent preflight failure pauses target without claiming prior POST was unsent")

check(classify(200, replayReceipt) == .hiNewSent("42", HiNewAPI.parseDate(expiry)!, true), "200 replay receipt resolves original send")
for update: [String: Any] in [["id": true], ["to": "other-bot"], ["enc": "age"], ["expires_at": "bad"], ["replayed": 1]] {
    check(classify(200, replayReceipt.merging(update) { _, new in new }) == .unknown, "200 replay still validates every receipt field")
}
check(HiNewAPI.isOwnerToken(token) && !HiNewAPI.isOwnerToken("hnt_" + String(repeating: "x", count: 32)), "Warn only for owner tokens")
// Exercise the same execution policy and persistent queue selection used by pump().
let routing = try DeliveryArchive(file: root.appendingPathComponent("routing.json"))
let discord = DeliveryDestination(id: UUID(), name: "Discord", provider: .discord, targetID: "42", targetKind: "channel", identity: "discord:42", enabled: true)
let telegram = DeliveryDestination(id: UUID(), name: "Telegram", provider: .telegram, targetID: "-42", targetKind: "group", identity: "telegram:-42", enabled: true)
try routing.transaction { state in
    state.destinations = [destination, discord, telegram]; state.baselineEstablished = true; state.requiresConfirmation = false
}
try routing.ingest([transcript.recordingID: transcript])
check(routing.next()?.provider == .hiNew, "hi.new starts at the head of a multi-provider recording")
for (hasWindow, preparing) in [(false, false), (true, true), (false, true)] {
    let excluded = DeliveryScheduling.excludedProviders(canPrepareHiNew: hasWindow, hiNewPreparing: preparing)
    let first = routing.next(excluding: excluded)!
    check(first.provider == .discord, "No window or ongoing preflight does not block Discord registration")
    let attempt = UUID(); try routing.begin(id: first.id, attempt: attempt)
    check(routing.state.jobs.first(where: { $0.id == first.id })?.phase == .sending, "Selected Discord job can register its attempt")
    check(routing.next(excluding: excluded)?.provider == .telegram, "Telegram also remains eligible behind hi.new")
    try routing.update(first.id) { $0.phase = .queued }
}
check(routing.next(excluding: DeliveryScheduling.excludedProviders(canPrepareHiNew: true, hiNewPreparing: false))?.provider == .hiNew, "hi.new resumes on the next execution window")
try routing.transaction { state in
    for i in state.jobs.indices where state.jobs[i].provider != .hiNew { state.jobs[i].phase = .retryWaiting; state.jobs[i].retryAfter = .now.addingTimeInterval(60) }
}
check(routing.nextEligibleDate(excluding: [.hiNew])! > .now, "hi.new at head does not hide other providers' retry timer")
let syntheticID = UUID()
try routing.transaction { state in
    var synthetic = job; synthetic.id = syntheticID; synthetic.recordingID = "hi-new-test-" + UUID().uuidString; synthetic.phase = .confirmation
    state.jobs.append(synthetic)
}
for phase: DeliveryPhase in [.confirmation, .queued, .sending, .retryWaiting, .needsAttention, .unknown] {
    try routing.update(syntheticID) { $0.phase = phase }
    check(rejects { try routing.deleteCompletedTest(id: syntheticID) }, "Cannot delete a pending or uncertain test")
}
for phase: DeliveryPhase in [.sent, .cancelled] {
    try routing.update(syntheticID) { $0.phase = phase }
    check(routing.state.jobs.last!.canDeleteTest, "Completed and cancelled tests expose delete action")
}
try routing.update(syntheticID) { $0.retryAfter = .now.addingTimeInterval(3600) }
check(rejects { try routing.deleteCompletedTest(id: syntheticID) }, "Deleting a cancelled test cannot bypass sender cooldown")
try routing.update(syntheticID) { $0.retryAfter = nil }
try routing.deleteCompletedTest(id: syntheticID)
check(!routing.state.jobs.contains { $0.id == syntheticID }, "Delete completed synthetic job")
check(!(try DeliveryArchive(file: root.appendingPathComponent("routing.json"))).state.jobs.contains { $0.id == syntheticID }, "Test deletion survives restart")
try routing.update(routing.state.jobs[0].id) { $0.phase = .sent }
check(rejects { try routing.deleteCompletedTest(id: routing.state.jobs[0].id) }, "Ordinary delivery receipts cannot be deleted as tests")

print("HiNew: \(checks) checks passed")
