import Foundation

enum HistorySettingsError: Error { case invalidLimit }

struct HistoryDeletionState: Codable {
    var deletedIDs: Set<String> = []
    var pendingIDs: Set<String> = []
    var retentionLimit: Int? = nil
}
/// Tombstone first, cleanup second. A crash cannot resurrect removed audio or deliveries.
final class HistoryArchive {
    let file: URL
    private let root: URL
    private(set) var state: HistoryDeletionState
    init(root: URL) throws {
        self.root = root
        file = root.appendingPathComponent("History/deletions.json")
        state = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(HistoryDeletionState.self, from: Data(contentsOf: file)) : HistoryDeletionState()
        if let limit = state.retentionLimit, !HistoryPolicy.allowedRange.contains(limit) { throw CocoaError(.fileReadCorruptFile) }
    }
    var retentionLimit: Int { state.retentionLimit ?? HistoryPolicy.defaultLimit }
    func setRetentionLimit(_ limit: Int) throws {
        guard HistoryPolicy.allowedRange.contains(limit) else { throw HistorySettingsError.invalidLimit }
        var copy = state; copy.retentionLimit = limit; try persist(copy)
    }
    func markDeleted(_ ids: Set<String>) throws {
        guard ids.allSatisfy(TranscriptRecord.validID) else { throw TranscriptError.invalidRecording }
        guard !ids.isEmpty else { return }
        var copy = state; copy.deletedIDs.formUnion(ids); copy.pendingIDs.formUnion(ids)
        try persist(copy)
    }
    func removeContentFiles(_ ids: Set<String>) throws {
        guard ids.allSatisfy(TranscriptRecord.validID), ids.isSubset(of: state.deletedIDs) else { throw TranscriptError.invalidRecording }
        for id in ids {
            for relative in ["ReceivedRecordings/" + id + ".json", "ReceivedRecordings/" + id + ".wav", "Transcripts/" + id + ".json"] {
                let url = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }
    func finishDeletion(_ ids: Set<String>) throws {
        var copy = state; copy.pendingIDs.subtract(ids); try persist(copy)
    }
    private func persist(_ copy: HistoryDeletionState) throws {
        try TranscriptArchive.makeProtectedDirectory(file.deletingLastPathComponent())
        try TranscriptArchive.writeProtected(JSONEncoder().encode(copy), to: file)
        state = copy
    }
}
enum HistoryPolicy {
    static let defaultLimit = 30
    static let allowedRange = 1...500
    static let selectableLimits = [10, 20, 30, 50, 100, 200, 500]
    static func newestFirst(_ recordings: [ReceivedRecording]) -> [ReceivedRecording] {
        recordings.sorted { $0.recordedAt == $1.recordedAt ? $0.id < $1.id : $0.recordedAt > $1.recordedAt }
    }
    static func deletions(_ recordings: [ReceivedRecording], limit: Int = defaultLimit) -> Set<String> {
        let visible = newestFirst(recordings.filter { $0.duration >= 0.1 })
        return Set(visible.dropFirst(allowedRange.contains(limit) ? limit : defaultLimit).map(\.id)).union(recordings.filter { $0.duration < 0.1 }.map(\.id))
    }
}
struct HistoryDeliverySummary: Equatable {
    let title: String
    let symbol: String
    let complete: Bool
    let requiresAttention: Bool
    init(jobs: [DeliveryJob]) {
        let total = jobs.count, sent = jobs.filter { $0.phase == .sent }.count
        complete = total > 0 && sent == total
        requiresAttention = jobs.contains { [.unknown, .needsAttention].contains($0.phase) }
        let count = total > 1 ? " \(sent)/\(total)件" : ""
        if total == 0 { title = "未連携"; symbol = "circle" }
        else if complete { title = "連携済み" + count; symbol = "checkmark.circle.fill" }
        else if jobs.contains(where: { $0.phase == .unknown }) { title = "結果不明" + count; symbol = "exclamationmark.triangle" }
        else if jobs.contains(where: { $0.phase == .needsAttention }) { title = "要対応" + count; symbol = "exclamationmark.circle" }
        else if jobs.contains(where: { $0.phase == .confirmation }) { title = "確認待ち" + count; symbol = "person.crop.circle.badge.questionmark" }
        else if jobs.contains(where: { $0.phase == .sending }) { title = "送信中" + count; symbol = "arrow.up.circle" }
        else if jobs.contains(where: { $0.phase == .queued }) { title = "送信待ち" + count; symbol = "clock" }
        else if jobs.contains(where: { $0.phase == .retryWaiting }) { title = "再試行待ち" + count; symbol = "clock.arrow.circlepath" }
        else if sent > 0 { title = "一部連携済み" + count; symbol = "checkmark.circle" }
        else { title = "送信しない"; symbol = "minus.circle" }
    }
}
