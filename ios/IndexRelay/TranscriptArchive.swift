import Foundation

struct TranscriptRecord: Codable, Sendable {
    let recordingID: String
    let text: String
    let createdAt: Date
    let locale: String
    let engine: String
    let audioProcessing: String

    init(recordingID: String, text: String, createdAt: Date = .now) throws {
        guard Self.validID(recordingID) else { throw TranscriptError.invalidRecording }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TranscriptError.noSpeech }
        self.recordingID = recordingID; self.text = cleaned; self.createdAt = createdAt
        locale = "ja-JP"; engine = "Apple SpeechAnalyzer / SpeechTranscriber"
        audioProcessing = "adaptive-30hz-v1"
    }
    static func validID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

enum TranscriptError: Error, LocalizedError {
    case invalidRecording, noSpeech, unavailable, unsupportedJapanese, modelUnavailable, modelNotPrepared
    var errorDescription: String? {
        switch self {
        case .invalidRecording: "録音データを確認できません。"
        case .noSpeech: "発話を認識できませんでした。原音と標準補正の再生を確認し、再度試してください。"
        case .unavailable: "この端末ではSpeechTranscriberを利用できません。"
        case .unsupportedJapanese: "この端末の音声認識では日本語を利用できません。"
        case .modelNotPrepared: "日本語モデルの準備待ちです。アプリを開くと準備を再開します。"
        case .modelUnavailable: "日本語モデルを利用できません。通信環境と端末の空き容量を確認してください。"
        }
    }
}

struct TranscriptArchive: Sendable {
    let folder: URL
    func loadAll() throws -> [String: TranscriptRecord] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [:] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var result: [String: TranscriptRecord] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(TranscriptRecord.self, from: data),
                  TranscriptRecord.validID(record.recordingID), url.deletingPathExtension().lastPathComponent == record.recordingID,
                  !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result[record.recordingID] = record
        }
        return result
    }
    func save(_ record: TranscriptRecord) throws {
        guard TranscriptRecord.validID(record.recordingID), !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptError.invalidRecording }
        try Self.makeProtectedDirectory(folder)
        try Self.writeProtected(JSONEncoder().encode(record), to: folder.appendingPathComponent(record.recordingID + ".json"))
    }
    static func makeProtectedDirectory(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        #endif
        var url = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    static func writeProtected(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
    }
}

/// Final segments are keyed by audio start time so repeated reports do not duplicate text.
struct TranscriptSegments: Sendable {
    private var segments: [Int64: String] = [:]
    mutating func add(startMicroseconds: Int64, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        segments[startMicroseconds] = text
    }
    var text: String { segments.keys.sorted().compactMap { segments[$0] }.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum TranscriptionStep: Sendable { case modelCheck, modelDownload, recognizing }
protocol FileTranscriptionBackend: Sendable {
    func transcribe(file: URL, allowModelDownload: Bool, status: @escaping @Sendable (TranscriptionStep) -> Void) async throws -> String
}


enum TranscriptionOutcome: Sendable, Equatable { case saved, cancelled, needsAttention, retryableFailure, modelDeferred }
