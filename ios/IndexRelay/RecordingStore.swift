import Foundation
import Combine
import CryptoKit

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [ReceivedRecording] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var playbackStatus: String?
    @Published private(set) var audioDiagnostics: [String: String] = [:]
    let transcriptions = TranscriptionController(backend: SpeechFileTranscriber(), root: URL.applicationSupportDirectory)
    private var preparation: Task<Void, Never>?
    private var processing: Task<AudioSignal.Prepared, Error>?
    private var playbackID: UUID?
    private let playback = PlaybackCoordinator(backend: SystemAudioPlayback())
    private var playbackRevision = 0

    private func directory() throws -> URL {
        var folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
            .appendingPathComponent("ReceivedRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    func reload() {
        do {
            let folder = try directory()
            let deleted = try HistoryArchive(root: .applicationSupportDirectory).state.deletedIDs
            recordings = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .compactMap { url in
                    guard let data = try? Data(contentsOf: url),
                          let clip = try? JSONDecoder().decode(ReceivedRecording.self, from: data),
                          !deleted.contains(clip.id), clip.id.count == 64, clip.id.allSatisfy({ $0.isHexDigit && $0.isASCII }),
                          (1_000...192_000).contains(clip.sampleRate), clip.sampleCount > 0,
                          FileManager.default.fileExists(atPath: folder.appendingPathComponent(clip.id + ".wav").path)
                    else { return nil }
                    return clip
                }
                .sorted { $0.receivedAt > $1.receivedAt }
            errorMessage = nil
        } catch { errorMessage = "保存済み録音を読み込めませんでした。" }
    }

    /// Saves audio before publishing the recording. Never sends audio to diagnostics.
    @discardableResult
    func save(pcm: Data, sampleRate: Int, collectionIndex: Int, ringID: String, contiguous: Bool, transfer: TransferContext? = nil) throws -> Bool {
        let wav = try PCM16WAV.encode(pcm: pcm, sampleRate: sampleRate)
        let id = recordingID(pcm: pcm, sampleRate: sampleRate, collectionIndex: collectionIndex, ringID: ringID)
        if try isDeleted(id) { return false }
        let folder = try directory()
        let audioURL = folder.appendingPathComponent(id + ".wav")
        let metadataURL = folder.appendingPathComponent(id + ".json")
        if let existingAudio = try? Data(contentsOf: audioURL), existingAudio == wav,
           let metadata = try? Data(contentsOf: metadataURL),
           let existing = try? JSONDecoder().decode(ReceivedRecording.self, from: metadata),
           existing.id == id, existing.sampleRate == sampleRate, existing.sampleCount == pcm.count / 2 {
            let updatedTransfer = transfer.map { incoming in
                existing.transfer?.addingBatteryVoltage(from: incoming) ?? incoming
            } ?? existing.transfer
            if existing.transfer != updatedTransfer {
                let enriched = ReceivedRecording(id: existing.id, receivedAt: existing.receivedAt,
                    sampleRate: existing.sampleRate, sampleCount: existing.sampleCount,
                    collectionIndex: existing.collectionIndex, contiguous: existing.contiguous, transfer: updatedTransfer)
                try persist(JSONEncoder().encode(enriched), to: metadataURL)
                reload()
            }
            return false
        }
        try persist(wav, to: audioURL)
        let clip = ReceivedRecording(id: id, receivedAt: .now, sampleRate: sampleRate,
            sampleCount: pcm.count / 2, collectionIndex: collectionIndex, contiguous: contiguous, transfer: transfer)
        try persist(JSONEncoder().encode(clip), to: metadataURL)
        reload()
        return true
    }

    func recordingID(pcm: Data, sampleRate: Int, collectionIndex: Int, ringID: String) -> String {
        var identity = Data("\(ringID)|\(sampleRate)|\(collectionIndex)|".utf8)
        identity.append(pcm)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    func isDeleted(_ id: String) throws -> Bool {
        try HistoryArchive(root: .applicationSupportDirectory).state.deletedIDs.contains(id)
    }
    func removeFiles(ids: Set<String>) throws {
        guard ids.allSatisfy(TranscriptRecord.validID) else { throw TranscriptError.invalidRecording }
        stopPlayback()
        try HistoryArchive(root: .applicationSupportDirectory).removeContentFiles(ids)
        for id in ids { audioDiagnostics[id] = nil }
        reload()
    }
    func correctedAudio(_ recording: ReceivedRecording) async throws -> Data {
        guard !(try isDeleted(recording.id)), let file = audioURL(recording) else { throw TranscriptError.invalidRecording }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try AudioSignal.prepare(wav: Data(contentsOf: file), mode: .adaptive).wav
        }
        let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard !(try isDeleted(recording.id)) else { throw TranscriptError.invalidRecording }
        return data
    }

    func receivedRecording(pcm: Data, sampleRate: Int, collectionIndex: Int, ringID: String) -> ReceivedRecording? {
        let id = recordingID(pcm: pcm, sampleRate: sampleRate, collectionIndex: collectionIndex, ringID: ringID)
        return recordings.first { $0.id == id }
    }

    func savedWAVForComparison(pcm: Data, sampleRate: Int, collectionIndex: Int, ringID: String) throws -> Data {
        let id = recordingID(pcm: pcm, sampleRate: sampleRate, collectionIndex: collectionIndex, ringID: ringID)
        return try Data(contentsOf: directory().appendingPathComponent(id + ".wav"))
    }

    private func persist(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func clearDiagnostics() {
        transcriptions.cancel()
        stopPlayback()
        audioDiagnostics = [:]
        errorMessage = nil
    }

    func audioURL(_ recording: ReceivedRecording) -> URL? {
        try? directory().appendingPathComponent(recording.id + ".wav")
    }

    func play(_ recording: ReceivedRecording, mode: AudioSignal.Mode = .adaptive) {
        stopPlayback()
        let token = UUID()
        let revision = playbackRevision
        playbackID = token
        playbackStatus = "\(mode.title)を準備しています…"
        guard let url = audioURL(recording) else {
            errorMessage = "音声ファイルを開けません。"
            playbackStatus = nil
            return
        }
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    try AudioSignal.prepare(wav: Data(contentsOf: url), mode: mode)
                }
                self.processing = worker
                let prepared = try await worker.value
                try Task.checkCancellation()
                guard self.playbackID == token else { return }
                self.processing = nil
                let gainDescription = prepared.appliedGain.map { String(format: "・適用増幅 %.3f倍", $0) } ?? ""
                self.audioDiagnostics[recording.id] = "Collection \(recording.collectionIndex): 再生 \(mode.title)（\(mode.details)\(gainDescription)） / \(prepared.analysis.summary)"
                guard try await self.playback.play(data: prepared.wav, revision: revision) else { return }
                guard !Task.isCancelled, self.playbackID == token else {
                    try? await self.playback.stop(revision: revision)
                    return
                }
                self.errorMessage = nil
                self.playbackStatus = "\(mode.title)で再生しています。"
            } catch is CancellationError {
                // A newer selection or stop action owns the UI state now.
            } catch {
                guard self.playbackID == token else { return }
                self.processing = nil
                self.playbackStatus = nil
                self.errorMessage = "音声の診断・再生に失敗しました（\(type(of: error))）。"
            }
        }
    }

    func stopPlayback() {
        let hadPlaybackRequest = playbackID != nil
        playbackRevision += 1
        let revision = playbackRevision
        playbackID = nil
        preparation?.cancel()
        preparation = nil
        processing?.cancel()
        processing = nil
        playbackStatus = nil
        guard hadPlaybackRequest else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await self.playback.stop(revision: revision) }
            catch {
                guard self.playbackRevision == revision else { return }
                self.errorMessage = "再生セッションの停止に失敗しました（\((error as NSError).code)）。"
            }
        }
    }
}
