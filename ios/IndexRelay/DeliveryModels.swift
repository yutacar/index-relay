import Foundation

enum DeliveryProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case discord, telegram
    var id: String { rawValue }
    var title: String { self == .discord ? "Discord" : "Telegram" }
    var limit: Int { self == .discord ? 2_000 : 4_096 }
}
struct DeliveryDestination: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var provider: DeliveryProvider
    var targetID: String
    var targetKind: String
    var identity: String
    var enabled: Bool
    // Optional for decoding settings saved before prefixes were introduced.
    var prefix: String? = nil
    var isSupported: Bool {
        guard provider == .telegram else { return true }
        guard ["group", "supergroup"].contains(targetKind), let number = Int64(targetID) else { return false }
        return number < 0 && String(number) == targetID
    }
    func messageText(_ transcript: String) -> String {
        let leading = (prefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return leading.isEmpty ? transcript : leading + " " + transcript
    }
}
/// Explicit IDs from the configured prefix, frozen with each delivery.
/// No automatic parsing of transcript text, @everyone or @here.
struct DiscordMentionPolicy: Codable, Equatable, Sendable {
    var users: [String] = []
    var roles: [String] = []
    static func fromPrefix(_ prefix: String?) -> Self {
        let source = prefix ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"<@([!&]?)([0-9]{1,20})>"#) else { return Self() }
        var policy = Self()
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let kindRange = Range(match.range(at: 1), in: source), let idRange = Range(match.range(at: 2), in: source) else { continue }
            let id = String(source[idRange])
            guard let number = UInt64(id), number > 0, String(number) == id else { continue }
            if source[kindRange] == "&" {
                if policy.roles.count < 100, !policy.roles.contains(id) { policy.roles.append(id) }
            } else {
                if policy.users.count < 100, !policy.users.contains(id) { policy.users.append(id) }
            }
        }
        return policy
    }
}
enum DeliveryPhase: String, Codable, Sendable {
    case confirmation, queued, sending, sent, retryWaiting, needsAttention, unknown, cancelled
    var title: String {
        switch self {
        case .confirmation: "確認待ち"
        case .queued: "送信待ち"
        case .sending: "送信中"
        case .sent: "送信済み"
        case .retryWaiting: "再試行待ち"
        case .needsAttention: "要対応"
        case .unknown: "結果不明"
        case .cancelled: "送信しない"
        }
    }
}
struct DeliveryJob: Codable, Identifiable, Sendable {
    var id = UUID()
    var recordingID: String
    var destinationID: UUID
    var destinationName: String
    var provider: DeliveryProvider
    var targetIdentity: String
    var text: String
    var createdAt: Date
    var confirmationRequired: Bool
    var phase: DeliveryPhase
    var attempt: UUID?
    var attempts = 0
    var retryAfter: Date?
    var messageID: String?
    var detail: String?
    // Missing in older jobs: keep all mentions suppressed, including on retry.
    var discordMentions: DiscordMentionPolicy? = nil
}
struct DeliveryState: Codable, Sendable {
    var requiresConfirmation = true
    var destinations: [DeliveryDestination] = []
    var jobs: [DeliveryJob] = []
    var seenRecordings: Set<String> = []
    // On first installation, existing transcripts form a baseline and are never posted automatically.
    var baselineEstablished = false
}
enum DeliveryStoreError: Error, LocalizedError {
    case invalidText, targetChanged, duplicateDestination, invalidTransition, pendingJobs, missingDestination, unsupportedTarget
    var errorDescription: String? {
        switch self {
        case .invalidText: "本文が空か、送り先の文字数上限を超えています。短く編集してください。"
        case .targetChanged: "登録済みと異なる送り先です。新しい送り先として追加してください。"
        case .duplicateDestination: "同じ送り先が登録済みです。既存の設定を変更してください。"
        case .invalidTransition: "送信状況が変わりました。画面を開き直してください。"
        case .pendingJobs: "未完了の送信があります。確認・取消を済ませてから削除してください。"
        case .unsupportedTarget: "Telegramはグループのみ対応しています。対象外の送り先は停止しました。グループを新しく追加してください。"
        case .missingDestination: "送り先を確認できません。設定を確認してください。"
        }
    }
}
final class DeliveryArchive {
    let file: URL
    private(set) var state: DeliveryState
    init(file: URL) throws {
        self.file = file
        state = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(DeliveryState.self, from: Data(contentsOf: file)) : DeliveryState()
        try restrictTelegramTargets()
    }
    /// Retain historical receipts. Stop legacy DM/channel routing without redirecting its jobs.
    private func restrictTelegramTargets() throws {
        var copy = state
        var changed = false
        for i in copy.destinations.indices where !copy.destinations[i].isSupported && copy.destinations[i].enabled {
            copy.destinations[i].enabled = false; changed = true
        }
        for i in copy.jobs.indices where copy.jobs[i].provider == .telegram && ![.sent, .cancelled].contains(copy.jobs[i].phase) {
            let job = copy.jobs[i]
            guard !copy.destinations.contains(where: { $0.id == job.destinationID && $0.isSupported && $0.identity == job.targetIdentity && $0.provider == job.provider }) else { continue }
            let phase: DeliveryPhase = [.sending, .unknown].contains(job.phase) ? .unknown : .cancelled
            let detail = phase == .unknown ? "グループ以外への送信は停止しました。送信開始済みのため、旧送り先で結果を確認してください。"
                : "グループ以外への投稿は対象外になったため、未送信分を取り消しました。"
            if copy.jobs[i].phase != phase || copy.jobs[i].detail != detail {
                copy.jobs[i].phase = phase; copy.jobs[i].detail = detail; changed = true
            }
        }
        if changed { let migrated = copy; try transaction { $0 = migrated } }
    }
    private func requireSupportedTarget(for id: UUID) throws {
        guard let job = state.jobs.first(where: { $0.id == id }) else { throw DeliveryStoreError.invalidTransition }
        if job.provider == .telegram {
            guard state.destinations.contains(where: { $0.id == job.destinationID && $0.provider == .telegram && $0.isSupported && $0.identity == job.targetIdentity }) else {
                throw DeliveryStoreError.unsupportedTarget
            }
        }
    }
    func transaction(_ body: (inout DeliveryState) throws -> Void) throws {
        var copy = state; try body(&copy)
        try TranscriptArchive.makeProtectedDirectory(file.deletingLastPathComponent())
        try TranscriptArchive.writeProtected(JSONEncoder().encode(copy), to: file)
        state = copy
    }
    static func validText(_ text: String, for provider: DeliveryProvider) -> Bool {
        // UTF-16 counting is conservative for supplementary Unicode characters.
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= provider.limit
    }
    func ingest(_ records: [String: TranscriptRecord]) throws {
        try transaction { state in
            if !state.baselineEstablished {
                state.seenRecordings.formUnion(records.keys); state.baselineEstablished = true; return
            }
            for record in records.values.sorted(by: { $0.createdAt < $1.createdAt }) where !state.seenRecordings.contains(record.recordingID) {
                for destination in state.destinations where destination.enabled && destination.isSupported {
                    let message = destination.messageText(record.text)
                    let valid = Self.validText(message, for: destination.provider)
                    state.jobs.append(DeliveryJob(recordingID: record.recordingID, destinationID: destination.id,
                        destinationName: destination.name, provider: destination.provider, targetIdentity: destination.identity,
                        text: message, createdAt: record.createdAt, confirmationRequired: state.requiresConfirmation,
                        phase: valid ? (state.requiresConfirmation ? .confirmation : .queued) : .needsAttention,
                        detail: valid ? nil : "文字数上限を超えています。本文を短く編集してください。",
                        discordMentions: destination.provider == .discord ? .fromPrefix(destination.prefix) : nil))
                }
                state.seenRecordings.insert(record.recordingID)
            }
        }
    }
    func validateDestination(_ destination: DeliveryDestination) throws {
        guard destination.isSupported else { throw DeliveryStoreError.unsupportedTarget }
        if let old = state.destinations.first(where: { $0.id == destination.id }) {
            guard old.identity == destination.identity && old.provider == destination.provider else { throw DeliveryStoreError.targetChanged }
        }
        guard !state.destinations.contains(where: { $0.id != destination.id && $0.identity == destination.identity }) else { throw DeliveryStoreError.duplicateDestination }
    }
    func upsertDestination(_ destination: DeliveryDestination) throws {
        try validateDestination(destination)
        try transaction { state in
            if let index = state.destinations.firstIndex(where: { $0.id == destination.id }) { state.destinations[index] = destination }
            else { state.destinations.append(destination) }
        }
    }
    func removeRecordings(_ ids: Set<String>) throws {
        guard !ids.isEmpty, state.jobs.contains(where: { ids.contains($0.recordingID) }) || !ids.isSubset(of: state.seenRecordings) else { return }
        try transaction { state in
            state.jobs.removeAll { ids.contains($0.recordingID) }
            state.seenRecordings.formUnion(ids)
        }
    }
    func approve(id: UUID, text: String) throws {
        try requireSupportedTarget(for: id)
        try update(id) { job in
            guard [.confirmation, .needsAttention].contains(job.phase) else { throw DeliveryStoreError.invalidTransition }
            guard Self.validText(text, for: job.provider) else { throw DeliveryStoreError.invalidText }
            // Explicit approval starts a fresh automatic-retry budget.
            job.text = text; job.phase = .queued; job.retryAfter = nil; job.detail = nil; job.attempts = 0
        }
    }
    func cancel(id: UUID) throws {
        try update(id) { job in
            guard ![.sending, .sent, .unknown].contains(job.phase) else { throw DeliveryStoreError.invalidTransition }
            job.phase = .cancelled; job.detail = nil
        }
    }
    func retry(id: UUID, allowUnknown: Bool = false) throws {
        try requireSupportedTarget(for: id)
        try update(id) { job in
            guard [.retryWaiting, .needsAttention].contains(job.phase) || (allowUnknown && job.phase == .unknown) else { throw DeliveryStoreError.invalidTransition }
            guard Self.validText(job.text, for: job.provider) else { throw DeliveryStoreError.invalidText }
            // A retry in the UI is explicit approval; toggling the global setting never approves jobs.
            if job.phase == .retryWaiting, let date = job.retryAfter, date > .now { return }
            job.phase = .queued; job.retryAfter = nil; job.detail = nil; job.attempts = 0
        }
    }
    func dismissUnknown(id: UUID) throws {
        try update(id) { job in
            guard job.phase == .unknown else { throw DeliveryStoreError.invalidTransition }
            job.phase = .cancelled; job.detail = "結果不明のまま、再送せず終了しました。"
        }
    }
    func markSent(id: UUID) throws {
        try update(id) { job in
            guard job.phase == .unknown else { throw DeliveryStoreError.invalidTransition }
            job.phase = .sent; job.detail = "送り先で確認済み（手動）"
        }
    }
    func begin(id: UUID, attempt: UUID) throws {
        try requireSupportedTarget(for: id)
        try update(id) { job in
            guard job.phase == .queued || job.phase == .retryWaiting else { throw DeliveryStoreError.invalidTransition }
            job.phase = .sending; job.attempt = attempt; job.attempts += 1; job.detail = nil
        }
    }
    func finish(id: UUID, attempt: UUID, result: DeliveryResult) throws {
        let targetSupported = (try? requireSupportedTarget(for: id)) != nil
        try update(id) { job in
            // Launch recovery may quarantine an attempt before the OS delivers its final result.
            // URLSession completes a task once, so a matching result for an unknown attempt is that late result.
            guard job.attempt == attempt, job.phase == .sending || job.phase == .unknown else { return }
            if !targetSupported {
                switch result {
                case .sent(let messageID): job.phase = .sent; job.messageID = messageID; job.detail = "旧送り先への送信完了を受信しました。今後の送信は停止しています。"
                case .unknown: job.phase = .unknown
                case .retry, .attention: job.phase = .cancelled; job.detail = "対象外の送り先への送信は取り消しました。再送しません。"
                }
                return
            }
            switch result {
            case .sent(let messageID): job.phase = .sent; job.messageID = messageID; job.detail = nil
            case .retry(let seconds):
                if job.attempts >= 5 { job.phase = .needsAttention; job.detail = "再試行が続いています。設定・通信状態を確認してください。" }
                else { job.phase = .retryWaiting; job.retryAfter = Date.now.addingTimeInterval(max(1, seconds)); job.detail = "未投稿の応答。時間を置いて再試行します。" }
            case .attention(let detail): job.phase = .needsAttention; job.detail = detail
            case .unknown:
                job.phase = .unknown; job.detail = "投稿が成立した可能性があります。送り先を確認してから操作してください。自動再送は行いません。"
            }
        }
    }
    func update(_ id: UUID, _ body: (inout DeliveryJob) throws -> Void) throws {
        try transaction { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { throw DeliveryStoreError.invalidTransition }
            try body(&state.jobs[index])
        }
    }
    func recover(activeAttempts: Set<UUID>) throws {
        try transaction { state in
            for i in state.jobs.indices where state.jobs[i].phase == .sending && !activeAttempts.contains(state.jobs[i].attempt ?? UUID()) {
                state.jobs[i].phase = .unknown
                state.jobs[i].detail = "前回の送信結果を回収できません。送り先で確認してください。"
            }
        }
    }
    private func eligibleDate(_ job: DeliveryJob, now: Date) -> Date? {
        guard [.queued, .retryWaiting].contains(job.phase),
              state.destinations.contains(where: { $0.id == job.destinationID && $0.enabled && $0.isSupported }) else { return nil }
        // Apply the most conservative provider cooldown, including a recently paused target.
        let cooldown = state.jobs.filter { $0.provider == job.provider && $0.phase == .retryWaiting }.compactMap(\.retryAfter).max() ?? now
        let own = job.phase == .retryWaiting ? (job.retryAfter ?? now) : now
        return max(now, own, cooldown)
    }
    func next(now: Date = .now) -> DeliveryJob? {
        state.jobs.first { eligibleDate($0, now: now).map { $0 <= now } ?? false }
    }
    func nextEligibleDate(now: Date = .now) -> Date? {
        state.jobs.compactMap { eligibleDate($0, now: now) }.min()
    }
}
enum DeliveryResult: Equatable, Sendable {
    case sent(String), retry(TimeInterval), attention(String), unknown
}
