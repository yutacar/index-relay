import Foundation

struct TransferContext: Codable {
    let start: Int64
    let releasedMs: Int64?
    let completedMs: Int64
    let buttonSequencePresent: Bool

    var releaseDate: Date? {
        guard let releasedMs, (1_577_836_800_000...4_102_444_800_000).contains(releasedMs) else { return nil }
        return Date(timeIntervalSince1970: Double(releasedMs) / 1000)
    }
}

struct ReceivedRecording: Codable, Identifiable {
    let id: String
    let receivedAt: Date
    let sampleRate: Int
    let sampleCount: Int
    let collectionIndex: Int
    let contiguous: Bool
    let transfer: TransferContext?

    var recordedAt: Date { transfer?.releaseDate ?? receivedAt }
    var duration: Double { Double(sampleCount) / Double(sampleRate) }
}
