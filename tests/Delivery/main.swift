import Foundation
var checks = 0
@MainActor
func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("IndexRelayDelivery-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let file = root.appendingPathComponent("state.json")
let archive = try DeliveryArchive(file: file)
let discord = DeliveryDestination(id: UUID(), name: "D", provider: .discord, targetID: "123", targetKind: "channel", identity: "discord:1:123", enabled: true)
let telegram = DeliveryDestination(id: UUID(), name: "T", provider: .telegram, targetID: "-100123", targetKind: "supergroup", identity: "telegram:2:-100123:supergroup", enabled: true)
func record(_ char: String, text: String = "こんにちは") throws -> TranscriptRecord { try TranscriptRecord(recordingID: String(repeating: char, count: 64), text: text) }
let old = try record("0")
try archive.transaction { $0.destinations = [discord, telegram] }
check(archive.state.requiresConfirmation, "Confirmation is the default")
try archive.ingest([old.recordingID: old])
check(archive.state.jobs.isEmpty && archive.state.baselineEstablished, "Existing transcripts never auto-post on upgrade")
let first = try record("a")
try archive.ingest([old.recordingID: old, first.recordingID: first])
check(archive.state.jobs.count == 2, "One durable delivery per destination")
check(archive.state.jobs.allSatisfy { $0.phase == .confirmation }, "No network-ready jobs until approval")
try archive.ingest([first.recordingID: first])
check(archive.state.jobs.count == 2, "Reconciliation never duplicates deliveries")
try archive.transaction { $0.requiresConfirmation = false }
check(archive.state.jobs.allSatisfy { $0.phase == .confirmation }, "Disabling confirmation cannot approve existing work")
let second = try record("b")
try archive.ingest([second.recordingID: second])
check(archive.state.jobs.filter { $0.recordingID == second.recordingID }.allSatisfy { $0.phase == .queued }, "New transcripts honor automatic mode")
check(archive.state.jobs[0].destinationID == discord.id && archive.state.jobs[0].targetIdentity == discord.identity, "Routing snapshot preserves target identity without credentials")
let firstID = archive.state.jobs[0].id
check(rejects { try archive.approve(id: firstID, text: " ") }, "Blank text rejected")
check(rejects { try archive.approve(id: firstID, text: String(repeating: "あ", count: 2001)) }, "Long Discord text requires editing")
try archive.approve(id: firstID, text: "編集した本文")
check(archive.state.jobs[0].text == "編集した本文" && archive.state.jobs[0].phase == .queued, "Approval freezes edited text")
let attempt = UUID()
try archive.begin(id: firstID, attempt: attempt)
check(archive.state.jobs[0].phase == .sending && archive.state.jobs[0].attempts == 1, "Persist attempt before dispatch")
check(rejects { try archive.cancel(id: firstID) }, "Cannot cancel an in-flight post as unsent")
try archive.finish(id: firstID, attempt: UUID(), result: .sent("stale"))
check(archive.state.jobs[0].phase == .sending, "A stale response cannot overwrite a newer attempt")
try archive.finish(id: firstID, attempt: attempt, result: .sent("message-1"))
check(archive.state.jobs[0].messageID == "message-1" && archive.state.jobs[0].phase == .sent, "Server message ID is durable")
check(archive.state.jobs[1].phase == .confirmation, "One destination success cannot approve another")
let id2 = archive.state.jobs[1].id
try archive.approve(id: id2, text: "送信")
let a2 = UUID(); try archive.begin(id: id2, attempt: a2)
try archive.finish(id: id2, attempt: a2, result: .unknown)
check(archive.state.jobs[1].phase == .unknown, "Uncertain result quarantined")
check(rejects { try archive.retry(id: id2) }, "Uncertain result cannot silently retry")
try archive.retry(id: id2, allowUnknown: true)
check(archive.state.jobs[1].phase == .queued, "Explicit duplicate-risk consent permits retry")
check(archive.state.jobs[1].attempts == 0, "Manual retry restores the automatic retry budget")
let a3 = UUID(); try archive.begin(id: id2, attempt: a3)
try archive.finish(id: id2, attempt: a3, result: .retry(65))
check(archive.state.jobs[1].phase == .retryWaiting && archive.state.jobs[1].retryAfter!.timeIntervalSinceNow > 60, "Rate limit retry_after retained")
try archive.retry(id: id2)
check(archive.state.jobs[1].phase == .retryWaiting && archive.state.jobs[1].retryAfter != nil, "Manual retry respects server cooldown")
let long = try record("c", text: String(repeating: "あ", count: 2100))
try archive.ingest([long.recordingID: long])
check(archive.state.jobs.first { $0.recordingID == long.recordingID && $0.provider == .discord }?.phase == .needsAttention, "Long text stops automatic Discord posting")
check(archive.state.jobs.first { $0.recordingID == long.recordingID && $0.provider == .telegram }?.phase == .queued, "Provider limits handled independently")
let queued = archive.state.jobs.first { $0.recordingID == second.recordingID }!
let a4 = UUID(); try archive.begin(id: queued.id, attempt: a4)
try archive.recover(activeAttempts: [a4])
check(archive.state.jobs.first { $0.id == queued.id }?.phase == .sending, "Live OS task is restored without duplicate dispatch")
try archive.recover(activeAttempts: [])
check(archive.state.jobs.first { $0.id == queued.id }?.phase == .unknown, "Lost task becomes unknown rather than replayed")
try archive.finish(id: queued.id, attempt: UUID(), result: .sent("late-stale"))
check(archive.state.jobs.first { $0.id == queued.id }?.phase == .unknown, "A late result for another attempt cannot resolve an unknown job")
try archive.markSent(id: queued.id)
check(archive.state.jobs.first { $0.id == queued.id }?.phase == .sent, "User can resolve uncertain result after checking target")
var renamed = discord; renamed.name = "新しい表示名"
try archive.upsertDestination(renamed)
check(archive.state.destinations[0].name == "新しい表示名", "Rename retains destination ID for pending jobs")
var duplicate = discord; duplicate.id = UUID()
check(rejects { try archive.upsertDestination(duplicate) }, "Same physical target cannot be selected twice")
var changed = discord; changed.identity = "discord:other:channel"; changed.targetID = "other"
check(rejects { try archive.upsertDestination(changed) }, "Credential edit cannot redirect pending jobs to another channel")
check(archive.state.jobs.first { $0.destinationID == discord.id }?.targetIdentity == discord.identity, "Destination rename never mutates routing snapshot")
let reloaded = try DeliveryArchive(file: file)
check(reloaded.state.jobs.count == archive.state.jobs.count && reloaded.state.jobs[0].messageID == "message-1", "Relaunch preserves outbox and receipts")
try archive.transaction { $0.destinations[0].enabled = false }
let third = try record("d"); try archive.ingest([third.recordingID: third])
check(archive.state.jobs.filter { $0.recordingID == third.recordingID }.count == 1, "Disabled destinations excluded from new snapshots")
check(DeliveryArchive.validText(String(repeating: "a", count: 2000), for: .discord), "Discord limit inclusive")
check(!DeliveryArchive.validText(String(repeating: "😀", count: 1001), for: .discord), "Supplementary Unicode counted conservatively")
check(DeliveryArchive.validText(String(repeating: "あ", count: 4096), for: .telegram), "Telegram limit inclusive")
let webhook = "https://discord.com/api/webhooks/123/token_ABC"
let (dr, db) = try DeliveryAPI.request(destination: discord, credential: DeliveryCredential(secret: webhook), text: "@everyone メモ")
check(dr.httpMethod == "POST" && dr.url!.query == "wait=true", "Discord obtains a server receipt")
let dj = try JSONSerialization.jsonObject(with: db) as! [String: Any]
check(((dj["allowed_mentions"] as? [String: Any])?["parse"] as? [String])?.isEmpty == true, "No Discord mentions from recognized content")
let (tr, tb) = try DeliveryAPI.request(destination: telegram, credential: DeliveryCredential(secret: "123:abc_DEF"), text: "*記号* [日本語]")
let tj = try JSONSerialization.jsonObject(with: tb) as! [String: Any]
check(tr.url!.host == "api.telegram.org" && tj["parse_mode"] == nil, "Telegram plaintext avoids markdown errors")
check((tj["chat_id"] as? String) == "-100123", "Use verified canonical chat ID")
for url in ["http://discord.com/api/webhooks/1/a", "https://evil.test/api/webhooks/1/a", "https://discord.com.evil.test/api/webhooks/1/a", webhook + "?thread_id=1", "https://user:pass@discord.com/api/webhooks/1/a", "https://discord.com:444/api/webhooks/1/a", "https://discord.com/api/webhooks/1/a%2Fb"] {
    check(rejects { _ = try DeliveryAPI.discordURL(url) }, "Reject credential leakage / unsupported route")
}
check(try DeliveryAPI.discordURL("https://discordapp.com/api/webhooks/1/abc").host == "discord.com", "Old webhook host canonicalized")
check(rejects { _ = try DeliveryAPI.telegramURL("123:bad/token", method: "sendMessage") }, "Telegram token cannot alter request path")
func classify(_ provider: DeliveryProvider = .discord, _ status: Int? = 200, _ body: String = "{}", _ error: Int? = nil, _ bytes: Int64 = 100) -> DeliveryResult {
    DeliveryAPI.classify(provider: provider, status: status, data: Data(body.utf8), errorCode: error, bytesSent: bytes)
}
check(classify(.discord, 200, "{\"id\":\"456\"}") == .sent("456"), "Discord receipt parsed")
check(classify(.telegram, 200, "{\"ok\":true,\"result\":{\"message_id\":42}}") == .sent("42"), "Telegram receipt parsed")
check(classify(.discord, 204) == .unknown, "Missing receipt never marked sent")
check(classify(.discord, 200, "broken json") == .unknown, "Malformed response is uncertain")
check(classify(.discord, 503) == .unknown, "5xx may follow server write")
check(classify(.discord, nil, "", NSURLErrorTimedOut, 0) == .unknown, "Zero byte timeout is not assumed proof of non-delivery")
check(classify(.discord, nil, "", NSURLErrorCancelled, 0) == .unknown, "Cancellation is not automatically retried")
check(classify(.discord, nil, "", NSURLErrorNetworkConnectionLost, 42) == .unknown, "Connection loss after upload quarantined")
check(classify(.discord, nil, "", NSURLErrorNotConnectedToInternet, 0) == .retry(30), "Definite preconnection failure can retry")
check(classify(.discord, 429, "{\"retry_after\":2.5}") == .retry(2.5), "Discord fractional retry_after")
check(classify(.telegram, 429, "{\"parameters\":{\"retry_after\":12}}") == .retry(12), "Telegram retry_after")
if case .attention = classify(.discord, 403) { check(true, "403 requires settings action") } else { check(false, "403 misclassified") }
if case .attention = classify(.telegram, 200, "{\"ok\":false,\"error_code\":400}") { check(true, "Telegram application errors not successful posts") } else { check(false, "Telegram rejection misclassified") }
check(classify(.discord, 200, "", NSURLErrorCannotConnectToHost, 0) == .unknown, "An existing HTTP response prevents preconnection inference")
let movedBody = """
{"ok":false,"error_code":400,"parameters":{"migrate_to_chat_id":-1001234567890}}
"""
let moveNotice = DeliveryResult.attention("グループが移行しました。新しいID（-1001234567890）で送り先を追加し直してください。自動では付け替えません。")
check(classify(.telegram, 400, movedBody) == moveNotice, "Migration preserves the full 64-bit ID in actionable notice")
check(classify(.telegram, 200, movedBody) == moveNotice, "Application rejection also explains migration")
for invalid in ["true", "123", "0", "-100.5", "\"-100123\"", "-9223372036854775809", "null"] {
    let body = "{\"ok\":false,\"error_code\":400,\"parameters\":{\"migrate_to_chat_id\":\(invalid)}}"
    check(classify(.telegram, 400, body) != moveNotice, "Invalid migration ID cannot become suggested target")
    if case .attention(let message) = classify(.telegram, 400, body) {
        check(!message.contains("グループが移行"), "Invalid migration ID uses generic rejection")
    } else { check(false, "Invalid migration rejection requires attention") }
}
check(classify(.discord, 400, movedBody) != moveNotice, "Discord never interprets Telegram migration")
check(classify(.telegram, 403, movedBody) != moveNotice, "Unrelated HTTP rejection does not suggest migration")
check(classify(.telegram, 503, movedBody) == .unknown, "5xx retains uncertainty even with migration fields")
check(classify(.telegram, 400, movedBody, NSURLErrorTimedOut) == .unknown, "Transport error retains uncertainty")
check(classify(.telegram, 429, movedBody) == .retry(30), "Rate limit retains retry classification")
check(classify(.telegram, 200, "{\"ok\":true,\"result\":{\"message_id\":42},\"parameters\":{\"migrate_to_chat_id\":-1001234567890}}") == .sent("42"), "Success receipt takes precedence over stray migration fields")
let groupMove = try DeliveryArchive(file: root.appendingPathComponent("group-move.json"))
try groupMove.transaction { $0.destinations = [telegram]; $0.requiresConfirmation = false }
try groupMove.ingest([:]); try groupMove.ingest([first.recordingID: first])
let groupMoveJob = groupMove.state.jobs[0], groupMoveAttempt = UUID()
try groupMove.begin(id: groupMoveJob.id, attempt: groupMoveAttempt)
try groupMove.finish(id: groupMoveJob.id, attempt: groupMoveAttempt, result: classify(.telegram, 400, movedBody))
let groupMoveReload = try DeliveryArchive(file: root.appendingPathComponent("group-move.json"))
check(groupMoveReload.state.jobs[0].phase == .needsAttention && groupMoveReload.state.jobs[0].detail?.contains("-1001234567890") == true, "Migration notice and needsAttention survive restart")
check(groupMoveReload.next() == nil, "Migration is never automatically retried")
check(groupMoveReload.state.destinations[0].identity == telegram.identity && groupMoveReload.state.destinations[0].targetID == telegram.targetID, "Migration does not alter destination")
check(groupMoveReload.state.jobs[0].targetIdentity == groupMoveJob.targetIdentity && groupMoveReload.state.jobs[0].text == groupMoveJob.text, "Migration preserves routing snapshot and text")
let cancelledJob = archive.state.jobs.first { $0.recordingID == third.recordingID }!
try archive.cancel(id: cancelledJob.id)
check(archive.state.jobs.first { $0.id == cancelledJob.id }?.phase == .cancelled, "Declining a pending post persists cancellation")
try archive.ingest([third.recordingID: third])
check(archive.state.jobs.filter { $0.recordingID == third.recordingID }.count == 1, "A cancelled transcript is not re-created on restart")
let noTargets = try DeliveryArchive(file: root.appendingPathComponent("no-targets.json"))
try noTargets.ingest([:]); try noTargets.ingest([first.recordingID: first])
try noTargets.upsertDestination(discord); try noTargets.ingest([first.recordingID: first])
check(noTargets.state.jobs.isEmpty, "Adding a destination never retroactively posts transcripts")
let schedule = try DeliveryArchive(file: root.appendingPathComponent("schedule.json"))
try schedule.transaction { $0.destinations = [discord, telegram]; $0.requiresConfirmation = false }
try schedule.ingest([:]); try schedule.ingest([first.recordingID: first, second.recordingID: second])
let scheduledID = schedule.state.jobs.first { $0.provider == .discord }!.id
let scheduleAttempt = UUID(); try schedule.begin(id: scheduledID, attempt: scheduleAttempt)
try schedule.finish(id: scheduledID, attempt: scheduleAttempt, result: .retry(120))
check(schedule.next()?.provider == .telegram, "Discord rate limit does not block Telegram")
try schedule.transaction { $0.destinations[1].enabled = false }
check(schedule.next() == nil, "All Discord jobs honor provider cooldown")
check(schedule.nextEligibleDate()!.timeIntervalSinceNow > 115, "Wake-up scheduler avoids rapid retries against active cooldown")
check(schedule.next(now: .now.addingTimeInterval(130))?.provider == .discord, "Eligible jobs resume when cooldown elapses")
try schedule.recover(activeAttempts: [])
let ambiguous = schedule.state.jobs.first { $0.provider == .discord && $0.phase == .queued }!
let unknownAttempt = UUID(); try schedule.begin(id: ambiguous.id, attempt: unknownAttempt)
try schedule.finish(id: ambiguous.id, attempt: unknownAttempt, result: .unknown)
try schedule.dismissUnknown(id: ambiguous.id)
check(schedule.state.jobs.first { $0.id == ambiguous.id }?.phase == .cancelled, "Unknown job may be abandoned without falsely claiming successful delivery")
let serial = String(data: try JSONEncoder().encode(archive.state), encoding: .utf8)!
check(!serial.contains("token_ABC") && !serial.contains(webhook), "Posting ledger excludes tokens and webhook URLs")
// Prefixes are assembled once, before confirmation and length checks.
let prefixed = try DeliveryArchive(file: root.appendingPathComponent("prefix.json"))
var withPrefix = discord; withPrefix.prefix = "  /memo  "
var otherPrefix = telegram; otherPrefix.prefix = "記録"
try prefixed.upsertDestination(withPrefix); try prefixed.upsertDestination(otherPrefix)
try prefixed.ingest([:]); try prefixed.ingest([first.recordingID: first])
check(prefixed.state.jobs[0].text == "/memo こんにちは", "Prefix followed by exactly one ASCII space")
check(prefixed.state.jobs[1].text == "記録 こんにちは", "Prefixes are independent per destination")
check(discord.messageText("本文") == "本文", "Missing prefix adds no space")
var blankPrefix = discord; blankPrefix.prefix = " \n "
check(blankPrefix.messageText("本文") == "本文", "Whitespace-only prefix treated as empty")
check(withPrefix.messageText("本文\n続き") == "/memo 本文\n続き", "Transcript line breaks preserved")
let legacy = try JSONEncoder().encode(discord)
check(try JSONDecoder().decode(DeliveryDestination.self, from: legacy).prefix == nil, "Older settings without prefix decode intact")
check(try JSONDecoder().decode(DeliveryDestination.self, from: JSONEncoder().encode(withPrefix)).prefix == "  /memo  ", "Configured prefix persists")
withPrefix.prefix = "NEW"; try prefixed.upsertDestination(withPrefix)
check(prefixed.state.jobs[0].text == "/memo こんにちは", "Changing prefix cannot mutate pending / approved messages")
let prefixJobID = prefixed.state.jobs[0].id
try prefixed.approve(id: prefixJobID, text: prefixed.state.jobs[0].text)
check(prefixed.state.jobs[0].text == "/memo こんにちは", "Approval does not add prefix twice")
let (_, prefixBody) = try DeliveryAPI.request(destination: withPrefix, credential: DeliveryCredential(secret: webhook), text: prefixed.state.jobs[0].text)
let prefixJSON = try JSONSerialization.jsonObject(with: prefixBody) as! [String: Any]
check(prefixJSON["content"] as? String == "/memo こんにちは", "HTTP content matches the reviewed snapshot")
try prefixed.transaction { $0.requiresConfirmation = false }
let nearlyFull = try record("e", text: String(repeating: "あ", count: 1998))
try prefixed.ingest([nearlyFull.recordingID: nearlyFull])
check(prefixed.state.jobs.first { $0.recordingID == nearlyFull.recordingID && $0.provider == .discord }?.phase == .needsAttention, "Length limit includes prefix and separator")
check(prefixed.state.jobs.first { $0.recordingID == nearlyFull.recordingID && $0.provider == .telegram }?.text.hasPrefix("記録 ") == true, "Automatic path includes the prefix")
// Only the prefix can grant mention permissions. Text edits / destination changes cannot expand them.
let mentionPolicy = DiscordMentionPolicy.fromPrefix("通知 <@123> <@!456> <@&789> <@123> @everyone @here")
check(mentionPolicy.users == ["123", "456"] && mentionPolicy.roles == ["789"], "Parse user, legacy nickname, bot and role IDs; deduplicate")
check(DiscordMentionPolicy.fromPrefix(nil) == DiscordMentionPolicy(), "Missing prefix grants no mentions")
check(DiscordMentionPolicy.fromPrefix("@someone ＠someone @everyone @here") == DiscordMentionPolicy(), "Plain names and broadcast mentions never grant permissions")
check(DiscordMentionPolicy.fromPrefix("<@0> <@001> <@-1> <@１２３> <@18446744073709551616> <@abc> <@&>") == DiscordMentionPolicy(), "Malformed / noncanonical / overflowing IDs ignored")
let many = (1...110).map { "<@\($0)> <@&\($0)>" }.joined(separator: " ")
let capped = DiscordMentionPolicy.fromPrefix(many)
check(capped.users.count == 100 && capped.roles.count == 100, "Discord maximum 100 allowed IDs per kind")
let mentionQueue = try DeliveryArchive(file: root.appendingPathComponent("mentions.json"))
var mentionDestination = discord; mentionDestination.prefix = "<@123> <@&789>"
try mentionQueue.upsertDestination(mentionDestination); try mentionQueue.upsertDestination(telegram)
try mentionQueue.ingest([:])
let mentionTranscript = try record("f", text: "本文 <@999> <@&888> @everyone @here")
try mentionQueue.ingest([mentionTranscript.recordingID: mentionTranscript])
let mentionJob = mentionQueue.state.jobs.first { $0.provider == .discord }!
check(mentionJob.discordMentions?.users == ["123"] && mentionJob.discordMentions?.roles == ["789"], "Snapshot prefix targets separately from transcript content")
check(mentionQueue.state.jobs.first { $0.provider == .telegram }?.discordMentions == nil, "Telegram jobs do not inherit Discord permissions")
let (_, mentionedBody) = try DeliveryAPI.request(destination: mentionDestination, credential: DeliveryCredential(secret: webhook), text: mentionJob.text, discordMentions: mentionJob.discordMentions)
let mentionedJSON = try JSONSerialization.jsonObject(with: mentionedBody) as! [String: Any]
let allowed = mentionedJSON["allowed_mentions"] as! [String: Any]
check(allowed["users"] as? [String] == ["123"] && allowed["roles"] as? [String] == ["789"], "POST explicitly allows only snapshotted targets")
check((allowed["parse"] as? [String]) == [], "Never enable broad users / roles / everyone parsing")
check(mentionedJSON["content"] as? String == "<@123> <@&789> 本文 <@999> <@&888> @everyone @here", "Keep prefix plus ASCII space plus original transcript")
mentionDestination.prefix = "<@999>"; try mentionQueue.upsertDestination(mentionDestination)
check(mentionQueue.state.jobs.first { $0.id == mentionJob.id }?.discordMentions == mentionJob.discordMentions, "Configuration changes cannot expand pending permissions")
try mentionQueue.approve(id: mentionJob.id, text: "編集 <@777> <@&666>")
let approvedMentionJob = mentionQueue.state.jobs.first { $0.id == mentionJob.id }!
check(approvedMentionJob.discordMentions == mentionJob.discordMentions, "Review edits cannot authorize new recipients")
let mentionAttempt = UUID(); try mentionQueue.begin(id: mentionJob.id, attempt: mentionAttempt)
try mentionQueue.finish(id: mentionJob.id, attempt: mentionAttempt, result: .unknown)
try mentionQueue.retry(id: mentionJob.id, allowUnknown: true)
check(mentionQueue.state.jobs.first { $0.id == mentionJob.id }?.discordMentions == mentionJob.discordMentions, "Retry retains the exact original allowlist")
let mentionReloaded = try DeliveryArchive(file: mentionQueue.file)
check(mentionReloaded.state.jobs.first { $0.id == mentionJob.id }?.discordMentions == mentionJob.discordMentions, "Restart preserves allowed recipients")
let (_, oldBody) = try DeliveryAPI.request(destination: mentionDestination, credential: DeliveryCredential(secret: webhook), text: "<@999> old job")
let oldAllowed = (try JSONSerialization.jsonObject(with: oldBody) as! [String: Any])["allowed_mentions"] as! [String: Any]
check(oldAllowed["users"] as? [String] == [] && oldAllowed["roles"] as? [String] == [], "A legacy job cannot inherit current destination permissions")
let legacyJob = archive.state.jobs[0]
var legacyJobObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyJob)) as! [String: Any]
legacyJobObject.removeValue(forKey: "discordMentions")
let legacyJobData = try JSONSerialization.data(withJSONObject: legacyJobObject)
check(try JSONDecoder().decode(DeliveryJob.self, from: legacyJobData).discordMentions == nil, "Old jobs without policy remain fully suppressed")
let (_, telegramMentionBody) = try DeliveryAPI.request(destination: telegram, credential: DeliveryCredential(secret: "123:abc_DEF"), text: "<@123> 本文", discordMentions: mentionPolicy)
let telegramMentionJSON = try JSONSerialization.jsonObject(with: telegramMentionBody) as! [String: Any]
check(telegramMentionJSON["allowed_mentions"] == nil && telegramMentionJSON["parse_mode"] == nil, "Telegram remains plain text even if policy is supplied")
try mentionQueue.transaction { $0.requiresConfirmation = false }
let automaticMention = try record("1")
try mentionQueue.ingest([automaticMention.recordingID: automaticMention])
check(mentionQueue.state.jobs.first { $0.recordingID == automaticMention.recordingID && $0.provider == .discord }?.discordMentions?.users == ["999"], "New automatic jobs capture the newly configured prefix")
// Recovery and OS completion can arrive in either order. Explicit user actions always win.
func recoveredDelivery() throws -> (DeliveryArchive, UUID, UUID) {
    let queue = try DeliveryArchive(file: root.appendingPathComponent("late-" + UUID().uuidString + ".json"))
    try queue.transaction { $0.destinations = [discord]; $0.requiresConfirmation = false }
    try queue.ingest([:]); try queue.ingest([first.recordingID: first])
    let id = queue.state.jobs[0].id, attempt = UUID()
    try queue.begin(id: id, attempt: attempt)
    try queue.recover(activeAttempts: [])
    return (queue, id, attempt)
}
let (lateSuccess, lateID, lateAttempt) = try recoveredDelivery()
try lateSuccess.finish(id: lateID, attempt: lateAttempt, result: .sent("late-message"))
check(lateSuccess.state.jobs[0].phase == .sent && lateSuccess.state.jobs[0].messageID == "late-message", "Matching delayed OS success resolves recovery quarantine")
check(try DeliveryArchive(file: lateSuccess.file).state.jobs[0].messageID == "late-message", "Delayed success persists across restart")
let (manuallySent, manualID, manualAttempt) = try recoveredDelivery()
try manuallySent.markSent(id: manualID)
try manuallySent.finish(id: manualID, attempt: manualAttempt, result: .retry(30))
check(manuallySent.state.jobs[0].phase == .sent, "Delayed retry cannot overwrite manual sent decision")
let (abandoned, abandonedID, abandonedAttempt) = try recoveredDelivery()
try abandoned.dismissUnknown(id: abandonedID)
try abandoned.finish(id: abandonedID, attempt: abandonedAttempt, result: .sent("ignored"))
check(abandoned.state.jobs[0].phase == .cancelled, "Delayed success cannot reverse explicit abandonment")
let (replayed, replayID, oldAttempt) = try recoveredDelivery()
try replayed.retry(id: replayID, allowUnknown: true)
try replayed.finish(id: replayID, attempt: oldAttempt, result: .sent("old-success"))
check(replayed.state.jobs[0].phase == .queued, "Queued manual replay rejects previous attempt before new dispatch")
let newAttempt = UUID(); try replayed.begin(id: replayID, attempt: newAttempt)
try replayed.recover(activeAttempts: [])
try replayed.finish(id: replayID, attempt: oldAttempt, result: .sent("old-success"))
check(replayed.state.jobs[0].phase == .unknown && replayed.state.jobs[0].attempt == newAttempt, "Previous attempt cannot resolve a newer quarantined attempt")
try replayed.finish(id: replayID, attempt: newAttempt, result: .sent("new-success"))
check(replayed.state.jobs[0].messageID == "new-success", "Current attempt still resolves after a stale callback")
let (lateRetry, retryID, retryAttempt) = try recoveredDelivery()
try lateRetry.finish(id: retryID, attempt: retryAttempt, result: .retry(30))
check(lateRetry.state.jobs[0].phase == .retryWaiting, "Definite non-delivery result may reenter retry after recovery")
check(lateRetry.state.jobs[0].retryAfter!.timeIntervalSinceNow > 25, "Delayed retry preserves server cooldown")
let countBeforeCooldown = lateRetry.state.jobs[0].attempts
try lateRetry.retry(id: retryID)
check(lateRetry.state.jobs[0].attempts == countBeforeCooldown, "Manual tap during server cooldown cannot reset budget")
let (lateUnknown, unknownID, uncertainAttempt) = try recoveredDelivery()
try lateUnknown.finish(id: unknownID, attempt: uncertainAttempt, result: .unknown)
check(lateUnknown.state.jobs[0].phase == .unknown, "Ambiguous delayed completion never auto-retries")
let (exhausted, exhaustedID, exhaustedAttempt) = try recoveredDelivery()
try exhausted.update(exhaustedID) { $0.attempts = 5 }
try exhausted.finish(id: exhaustedID, attempt: exhaustedAttempt, result: .retry(30))
check(exhausted.state.jobs[0].phase == .needsAttention, "Recovery does not bypass automatic retry limit")
try exhausted.approve(id: exhaustedID, text: "修正した本文")
check(exhausted.state.jobs[0].attempts == 0, "Explicit approval resets exhausted retry budget")
let approvedAttempt = UUID(); try exhausted.begin(id: exhaustedID, attempt: approvedAttempt)
try exhausted.finish(id: exhaustedID, attempt: approvedAttempt, result: .retry(30))
check(exhausted.state.jobs[0].phase == .retryWaiting && exhausted.state.jobs[0].attempts == 1, "Approved work receives a fresh bounded retry budget")
// Credential edits never need to preload secrets into the UI.
let credentialID = UUID()
var loads = 0
@MainActor
func storedCredential(_ id: UUID) throws -> DeliveryCredential {
    check(id == credentialID, "Only the edited destination credential is resolved")
    loads += 1; return DeliveryCredential(secret: "123:stored_fixture")
}
let keptSecret = try DeliveryCredential.resolve(" \n ", existingID: credentialID, load: storedCredential)
check(keptSecret == "123:stored_fixture" && loads == 1, "Blank edit resolves the existing credential at save time")
let replacedSecret = try DeliveryCredential.resolve(" 123:new_fixture ", existingID: credentialID, load: storedCredential)
check(replacedSecret == "123:new_fixture" && loads == 1, "Replacement credential does not read the stored secret")
check(rejects { _ = try DeliveryCredential.resolve("", existingID: nil, load: storedCredential) }, "New destinations cannot use blank credentials")
check(loads == 1, "Blank new destination never queries the keychain")
check(rejects { _ = try DeliveryCredential.resolve("", existingID: credentialID) { _ in throw NSError(domain: "Fixture", code: -1) } }, "Locked or unavailable keychain is surfaced instead of silently using an empty credential")
check(rejects { _ = try DeliveryCredential.resolve("", existingID: credentialID) { _ in DeliveryCredential(secret: " ") } }, "Empty stored credentials are rejected")
let before = archive.state.jobs.count
try FileManager.default.removeItem(at: file)
try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
check(rejects { try archive.transaction { $0.jobs.removeAll() } }, "Persistence failure surfaced")
check(archive.state.jobs.count == before, "Failed transaction cannot erase live outbox")
let corrupt = root.appendingPathComponent("corrupt.json"); try Data("bad".utf8).write(to: corrupt)
check(rejects { _ = try DeliveryArchive(file: corrupt) }, "Corrupt state never silently resets posting ledger")
// Group-only validation uses the same getChat result parser as registration.
func groupJSON(_ id: Any = NSNumber(value: -100123), kind: String = "supergroup") -> [String: Any] {
    ["ok": true, "result": ["id": id, "type": kind, "title": "Group Fixture"]]
}
let group = try DeliveryAPI.telegramGroup(from: groupJSON(), botID: "2")
check(group.isSupported && group.targetKind == "supergroup" && group.targetID == "-100123", "Supergroup is allowed")
check(group.identity == "telegram:2:-100123:supergroup" && group.name == "Group Fixture", "Canonical group identity and title are retained")
let basicGroup = try DeliveryAPI.telegramGroup(from: groupJSON(NSNumber(value: -123), kind: "group"), botID: "2")
check(basicGroup.isSupported && basicGroup.targetID == "-123", "Basic group is allowed")
for kind in ["private", "channel", "unknown", "", "Group"] {
    check(rejects { _ = try DeliveryAPI.telegramGroup(from: groupJSON(kind: kind), botID: "2") }, "Only exact group types are allowed")
}
for value: Any in [NSNumber(value: true), NSNumber(value: 123), NSNumber(value: 0), NSNumber(value: -1.5), "-123", "-100123", NSNull()] {
    check(rejects { _ = try DeliveryAPI.telegramGroup(from: groupJSON(value), botID: "2") }, "Malformed or nonnegative getChat ID rejected")
}
check(rejects { _ = try DeliveryAPI.telegramGroup(from: ["ok": false], botID: "2") }, "API failure cannot register a group")
for id in ["0", "-2", "true", "2.5", "02"] {
    check(rejects { _ = try DeliveryAPI.telegramGroup(from: groupJSON(), botID: id) }, "Invalid bot ID rejected")
}
check(rejects { _ = try DeliveryAPI.telegramURL("123:fake_token", method: "getUpdates") }, "Group-only app cannot fetch conversation updates")
check(rejects { _ = try DeliveryAPI.telegramURL("123:fake_token", method: "getWebhookInfo") }, "Removed discovery API is unavailable")
check(rejects { _ = try DeliveryAPI.telegramURL("123:fake_token", method: "deleteWebhook") }, "App cannot alter bot webhooks")
var privateTarget = telegram; privateTarget.id = UUID(); privateTarget.targetKind = "private"; privateTarget.targetID = "123"; privateTarget.identity = "telegram:2:123:private"
var channelTarget = telegram; channelTarget.id = UUID(); channelTarget.targetKind = "channel"; channelTarget.identity = "telegram:2:-100123:channel"
for target in [privateTarget, channelTarget] {
    check(!target.isSupported, "Legacy target is unsupported")
    check(rejects { _ = try DeliveryAPI.request(destination: target, credential: DeliveryCredential(secret: "123:fake_token"), text: "Body") }, "Request builder blocks legacy DM/channel posting")
    check(rejects { try archive.upsertDestination(target) }, "Archive rejects newly registered unsupported targets")
}
let (_, groupBody) = try DeliveryAPI.request(destination: group, credential: DeliveryCredential(secret: "123:fake_token"), text: "memo 本文")
let groupPayload = try JSONSerialization.jsonObject(with: groupBody) as! [String: Any]
check(groupPayload["chat_id"] as? String == "-100123" && groupPayload["text"] as? String == "memo 本文", "Group payload retains prefix and canonical ID")
check(groupPayload["parse_mode"] == nil, "Group text is plain text")
// Upgrade retains history and quarantines already-started work; it never redirects to the new group.
let legacyFile = root.appendingPathComponent("legacy.json")
var legacyState = DeliveryState()
legacyState.destinations = [privateTarget, channelTarget, telegram, discord]
legacyState.baselineEstablished = true
let legacyPhases: [DeliveryPhase] = [.confirmation, .queued, .retryWaiting, .needsAttention, .sending, .unknown, .sent, .cancelled]
for phase in legacyPhases {
    var job = DeliveryJob(recordingID: "old-" + phase.rawValue, destinationID: privateTarget.id, destinationName: "Old DM", provider: .telegram,
                          targetIdentity: privateTarget.identity, text: "Old Body", createdAt: .now, confirmationRequired: false, phase: phase)
    if [.sending, .unknown].contains(phase) { job.attempt = UUID() }
    legacyState.jobs.append(job)
}
legacyState.jobs.append(DeliveryJob(recordingID: "group", destinationID: telegram.id, destinationName: "Group", provider: .telegram,
                                    targetIdentity: telegram.identity, text: "Group Body", createdAt: .now, confirmationRequired: false, phase: .queued))
try JSONEncoder().encode(legacyState).write(to: legacyFile)
let migrated = try DeliveryArchive(file: legacyFile)
check(migrated.state.destinations.filter { !$0.isSupported }.allSatisfy { !$0.enabled }, "Legacy DM and channel destinations are disabled on load")
check(migrated.state.destinations.filter(\.isSupported).allSatisfy(\.enabled), "Group and Discord settings remain enabled")
for i in legacyPhases.indices {
    let expected: DeliveryPhase = [.sending, .unknown].contains(legacyPhases[i]) ? .unknown : (legacyPhases[i] == .sent ? .sent : .cancelled)
    check(migrated.state.jobs[i].phase == expected, "Legacy job upgrade preserves delivery uncertainty and completed history")
    check(migrated.state.jobs[i].destinationID == privateTarget.id, "Old jobs are never redirected to a group")
}
let oldSending = migrated.state.jobs[4]
check(oldSending.attempt == legacyState.jobs[4].attempt, "In-flight attempt identity retained for late final result")
check(migrated.next()?.recordingID == "group", "Only the group job is eligible after upgrade")
check(rejects { try migrated.retry(id: oldSending.id, allowUnknown: true) }, "Unknown DM cannot be manually retried")
check(rejects { try migrated.begin(id: oldSending.id, attempt: UUID()) }, "Legacy target cannot be started directly")
check(rejects { try migrated.approve(id: migrated.state.jobs[0].id, text: "Body") }, "Legacy approval cannot reenable posting")
let savedMigration = try Data(contentsOf: legacyFile)
_ = try DeliveryArchive(file: legacyFile)
let reloadedMigration = try Data(contentsOf: legacyFile)
check(reloadedMigration == savedMigration, "Migration is durable and idempotent")
try migrated.finish(id: oldSending.id, attempt: oldSending.attempt!, result: .retry(1))
check(migrated.state.jobs[4].phase == .cancelled, "Late pre-delivery rejection never schedules a DM retry")
let oldUnknown = migrated.state.jobs[5]
try migrated.finish(id: oldUnknown.id, attempt: oldUnknown.attempt!, result: .sent("old-receipt"))
check(migrated.state.jobs[5].phase == .sent && migrated.state.jobs[5].messageID == "old-receipt", "Late actual delivery receipt is retained as a fact")
try migrated.transaction { $0.destinations[0].enabled = true }
let newTranscript = try record("e")
try migrated.ingest([newTranscript.recordingID: newTranscript])
check(migrated.state.jobs.filter { $0.recordingID == newTranscript.recordingID }.allSatisfy { $0.destinationID != privateTarget.id && $0.destinationID != channelTarget.id }, "Unsupported enabled legacy entries cannot receive newly ingested transcripts")
// Success removes a stale retry time; another job's live provider cooldown is retained.
for target in [discord, telegram] {
    let queue = try DeliveryArchive(file: root.appendingPathComponent("success-cooldown-" + target.provider.rawValue + ".json"))
    try queue.transaction { $0.destinations = [target]; $0.requiresConfirmation = false }
    try queue.ingest([:]); try queue.ingest([first.recordingID: first, second.recordingID: second])
    let id = queue.state.jobs[0].id, pendingID = queue.state.jobs[1].id
    let initial = UUID(); try queue.begin(id: id, attempt: initial)
    try queue.finish(id: id, attempt: initial, result: .retry(30))
    check(queue.state.jobs[0].retryAfter != nil, "Retry time is retained while waiting")
    try queue.update(id) { $0.retryAfter = .now.addingTimeInterval(-1) }
    let attempt = UUID(); try queue.begin(id: id, attempt: attempt)
    try queue.update(pendingID) { $0.phase = .retryWaiting; $0.retryAfter = .now.addingTimeInterval(60) }
    try queue.finish(id: id, attempt: attempt, result: .sent("success"))
    check(queue.state.jobs[0].phase == .sent && queue.state.jobs[0].retryAfter == nil, "Successful Discord/Telegram retry clears its schedule")
    check(try DeliveryArchive(file: queue.file).state.jobs[0].retryAfter == nil, "Cleared schedule survives restart")
    check(queue.next() == nil && queue.nextEligibleDate()!.timeIntervalSinceNow > 55, "Other job's provider cooldown is unchanged")
}

print("Delivery: \(checks) checks passed")
