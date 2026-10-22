import Foundation
import Combine

@MainActor
final class TranscriptionController: ObservableObject {
    @Published private(set) var records: [String: TranscriptRecord] = [:]
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var activeRecordingID: String?
    @Published private(set) var outcomes: [String: TranscriptionOutcome] = [:]
    @Published private(set) var loadError: String?
    var isBusy: Bool { activeRecordingID != nil }
    private let backend: any FileTranscriptionBackend
    private let archive: TranscriptArchive
    private let workRoot: URL
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var cancelRequested = false
    private var removedIDs: Set<String> = []

    init(backend: any FileTranscriptionBackend, root: URL) {
        self.backend = backend
        archive = TranscriptArchive(folder: root.appendingPathComponent("Transcripts", isDirectory: true))
        workRoot = root.appendingPathComponent("TranscriptionWork", isDirectory: true)
        do { records = try archive.loadAll() }
        catch { loadError = "保存済みの文字起こし結果を読み込めませんでした。" }
    }
    func start(recordingID: String, audioURL: URL, allowModelDownload: Bool = true) {
        guard !isBusy, !removedIDs.contains(recordingID), TranscriptRecord.validID(recordingID) else { return }
        let id = UUID(); token = id; cancelRequested = false
        outcomes[recordingID] = nil
        activeRecordingID = recordingID
        statuses[recordingID] = "標準補正の音声を準備しています…"
        let folder = workRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        task = Task { [self] in
            defer {
                try? FileManager.default.removeItem(at: folder)
                if token == id { activeRecordingID = nil; task = nil; token = nil }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let source = try Data(contentsOf: audioURL)
                    let prepared = try AudioSignal.prepare(wav: source, mode: .adaptive)
                    try Task.checkCancellation()
                    try TranscriptArchive.makeProtectedDirectory(folder)
                    let file = folder.appendingPathComponent("prepared.wav")
                    try TranscriptArchive.writeProtected(prepared.wav, to: file)
                    return file
                }
                let file = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                let text = try await backend.transcribe(file: file, allowModelDownload: allowModelDownload) { [weak self] step in
                    Task { @MainActor in
                        guard let self, self.token == id, !self.cancelRequested else { return }
                        switch step {
                        case .modelCheck: self.statuses[recordingID] = "日本語モデルを確認しています…"
                        case .modelDownload: self.statuses[recordingID] = "日本語モデルをダウンロードしています…"
                        case .recognizing: self.statuses[recordingID] = "日本語で文字起こししています…"
                        }
                    }
                }
                try Task.checkCancellation()
                guard token == id, !cancelRequested else { return }
                let record = try TranscriptRecord(recordingID: recordingID, text: text)
                // Keep recognized text available for manual sharing even on a disk failure.
                records[recordingID] = record
                do {
                    try archive.save(record)
                    statuses[recordingID] = "文字起こしを保存しました"
                    outcomes[recordingID] = .saved
                } catch {
                    outcomes[recordingID] = .retryableFailure
                    statuses[recordingID] = "認識結果を保存できませんでした。画面の文章を共有して退避してください。"
                }
            } catch {
                guard token == id, !removedIDs.contains(recordingID) else { return }
                if Task.isCancelled || cancelRequested || error is CancellationError {
                    statuses[recordingID] = "文字起こしを中止しました"
                    outcomes[recordingID] = .cancelled
                } else if let error = error as? TranscriptError {
                    statuses[recordingID] = error.localizedDescription
                    switch error {
                    case .modelNotPrepared: outcomes[recordingID] = .modelDeferred
                    case .noSpeech, .invalidRecording, .unavailable, .unsupportedJapanese: outcomes[recordingID] = .needsAttention
                    case .modelUnavailable: outcomes[recordingID] = .retryableFailure
                    }
                } else {
                    outcomes[recordingID] = .retryableFailure
                    let code = (error as NSError).code
                    statuses[recordingID] = "文字起こしに失敗しました（コード \(code)）。通信・空き容量を確認して再度試してください。"
                }
            }
        }
    }
    func reloadSavedResults() {
        guard !isBusy else { return }
        do { records = try archive.loadAll().filter { !removedIDs.contains($0.key) }; loadError = nil }
        catch { loadError = "保存済みの文字起こし結果を読み込めませんでした。" }
    }
    func forget(_ ids: Set<String>) {
        removedIDs.formUnion(ids)
        if let activeRecordingID, ids.contains(activeRecordingID) { cancel() }
        for id in ids { records[id] = nil; statuses[id] = nil; outcomes[id] = nil }
    }
    func cancel() {
        guard let activeRecordingID else { return }
        cancelRequested = true
        statuses[activeRecordingID] = "文字起こしを中止しています…"
        task?.cancel()
    }
    var diagnosticSummary: [String] {
        ["文字起こし: SpeechAnalyzer・ja-JP・標準補正・端末内認識", "文字起こし実行中: \(isBusy)"] +
        statuses.keys.sorted().map { "文字起こし \($0.prefix(8)): \(statuses[$0] ?? "不明")" }
    }
    // Used to await cleanup in lifecycle tests; production UI observes isBusy.
    func waitUntilFinished() async { await task?.value }
}
