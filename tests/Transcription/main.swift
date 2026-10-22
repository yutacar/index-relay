import Foundation

actor FakeTranscriber: FileTranscriptionBackend {
    private var text: String
    private var failure: TranscriptError?
    private let hold: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var allowsModelDownload = true
    private(set) var calls = 0
    private(set) var input = Data()
    init(text: String = "認識結果", hold: Bool = false, failure: TranscriptError? = nil) {
        self.text = text; self.hold = hold; self.failure = failure
    }
    func transcribe(file: URL, allowModelDownload: Bool, status: @escaping @Sendable (TranscriptionStep) -> Void) async throws -> String {
        allowsModelDownload = allowModelDownload
        calls += 1; input = try Data(contentsOf: file)
        status(.modelCheck); status(.modelDownload); status(.recognizing)
        entered = true; waiters.forEach { $0.resume() }; waiters = []
        if hold { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
        return text // Deliberately ignores cancellation to test stale-result protection.
    }
    func waitForCall() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
}
var checks = 0
@MainActor
func expect(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IndexRelayTranscriptTests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let id = String(repeating: "a", count: 64)
let otherID = String(repeating: "b", count: 64)
let audio = folder.appendingPathComponent("input.wav")
var pcm = Data()
for i in 0..<1000 {
    let sample = Int16(sin(Double(i) * 0.15) * 3000 + 5000)
    let bits = UInt16(bitPattern: sample)
    pcm.append(UInt8(truncatingIfNeeded: bits)); pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
}
let raw = try PCM16WAV.encode(pcm: pcm, sampleRate: 9997)
try raw.write(to: audio)
let expected = try AudioSignal.prepare(wav: raw, mode: .adaptive).wav
let archive = TranscriptArchive(folder: folder.appendingPathComponent("archive"))
expect(try archive.loadAll().isEmpty, "New archive is empty")
expect(rejects { _ = try TranscriptRecord(recordingID: "../bad", text: "text") }, "Path traversal ID refused")
expect(rejects { _ = try TranscriptRecord(recordingID: id, text: " \n ") }, "Empty recognition rejected")
let saved = try TranscriptRecord(recordingID: id, text: "  日本語の結果\n")
expect(saved.text == "日本語の結果", "Trim only outer whitespace")
try archive.save(saved)
expect(try archive.loadAll()[id]?.text == saved.text, "Transcript survives archive reload")
let bad = archive.folder.appendingPathComponent("broken.json")
try Data("not json".utf8).write(to: bad)
expect(try archive.loadAll().count == 1, "Malformed sidecar does not hide valid results")
let unrelated = archive.folder.appendingPathComponent(otherID + ".json")
try JSONEncoder().encode(saved).write(to: unrelated)
expect(try archive.loadAll().count == 1, "Mismatched filename and recording ID ignored")
var segments = TranscriptSegments()
segments.add(startMicroseconds: 100, text: "後半。")
segments.add(startMicroseconds: 0, text: "前半。")
segments.add(startMicroseconds: 100, text: "修正版。")
segments.add(startMicroseconds: 200, text: " \n ")
expect(segments.text == "前半。修正版。", "Sort final segments, replace duplicate, exclude blank")
let root = folder.appendingPathComponent("session")
let successBackend = FakeTranscriber(text: "  実機確認の文章。\n")
let success = TranscriptionController(backend: successBackend, root: root)
success.start(recordingID: id, audioURL: audio)
await success.waitUntilFinished()
expect(success.records[id]?.text == "実機確認の文章。", "Recognized text exposed")
expect(success.statuses[id] == "文字起こしを保存しました" && !success.isBusy, "Success state after cleanup")
expect(await successBackend.input == expected, "Recognition gets exact standard-corrected WAV")
expect(try Data(contentsOf: audio) == raw, "Source WAV preserved")
let work = root.appendingPathComponent("TranscriptionWork")
expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty, "Temporary audio removed on success")
let restored = TranscriptionController(backend: FakeTranscriber(), root: root)
expect(restored.records[id]?.text == success.records[id]?.text, "Result restored after reopening screen")
expect(restored.records[id]?.locale == "ja-JP" && restored.records[id]?.audioProcessing == "adaptive-30hz-v1", "Result provenance saved")
let empty = TranscriptionController(backend: FakeTranscriber(text: " \n "), root: root)
empty.start(recordingID: id, audioURL: audio)
await empty.waitUntilFinished()
expect(empty.records[id]?.text == "実機確認の文章。", "Blank retry preserves previous result")
expect(empty.statuses[id]?.contains("発話を認識できません") == true, "Blank result requires attention")
let heldBackend = FakeTranscriber(text: "キャンセル後に届いた結果", hold: true)
let held = TranscriptionController(backend: heldBackend, root: root)
held.start(recordingID: id, audioURL: audio)
await heldBackend.waitForCall()
held.start(recordingID: otherID, audioURL: audio)
expect(await heldBackend.calls == 1 && held.activeRecordingID == id, "Only one recognition at a time")
held.cancel()
expect(held.isBusy, "Cancel waits for backend cleanup before reuse")
await heldBackend.release()
await held.waitUntilFinished()
expect(held.records[id]?.text == "実機確認の文章。", "Late cancelled result cannot overwrite saved text")
expect(held.statuses[id] == "文字起こしを中止しました" && !held.isBusy, "Cancellation settles status")
expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty, "Cancelled temporary audio removed")
let earlyBackend = FakeTranscriber()
let early = TranscriptionController(backend: earlyBackend, root: root)
early.start(recordingID: otherID, audioURL: audio); early.cancel()
await early.waitUntilFinished()
expect(await earlyBackend.calls == 0 && early.records[otherID] == nil, "Cancel before preparation does not start engine")
let failed = TranscriptionController(backend: FakeTranscriber(failure: .modelUnavailable), root: root)
failed.start(recordingID: otherID, audioURL: audio)
await failed.waitUntilFinished()
expect(failed.records[otherID] == nil && failed.statuses[otherID]?.contains("日本語モデル") == true, "Model failure surfaced without empty success")
let missing = TranscriptionController(backend: FakeTranscriber(), root: root)
missing.start(recordingID: otherID, audioURL: folder.appendingPathComponent("missing.wav"))
await missing.waitUntilFinished()
expect(!missing.isBusy && missing.records[otherID] == nil, "Missing audio fails without hanging")
let blockedRoot = folder.appendingPathComponent("blocked")
try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
try Data([1]).write(to: blockedRoot.appendingPathComponent("Transcripts"))
let blocked = TranscriptionController(backend: FakeTranscriber(text: "保存に失敗しても残す文章"), root: blockedRoot)
blocked.start(recordingID: id, audioURL: audio)
await blocked.waitUntilFinished()
expect(blocked.records[id]?.text == "保存に失敗しても残す文章", "Disk failure keeps recognized text for sharing")
expect(blocked.statuses[id]?.contains("保存できません") == true, "Disk failure is not reported as saved")
expect(!success.diagnosticSummary.joined().contains("実機確認の文章"), "Diagnostic report excludes recognized text")
expect(success.diagnosticSummary.joined().contains("保存しました"), "Diagnostic report includes outcome")
let backgroundBackend = FakeTranscriber(failure: .modelNotPrepared)
let background = TranscriptionController(backend: backgroundBackend, root: root)
background.start(recordingID: otherID, audioURL: audio, allowModelDownload: false)
await background.waitUntilFinished()
expect(await backgroundBackend.allowsModelDownload == false, "Background policy forbids a new model download")
expect(background.outcomes[otherID] == .modelDeferred, "Missing model is deferred rather than permanently failed")
expect(success.outcomes[id] == .saved && held.outcomes[id] == .cancelled && empty.outcomes[id] == .needsAttention, "Typed outcomes distinguish queue actions")
let deletionRoot = folder.appendingPathComponent("deletion-session")
let deletionBackend = FakeTranscriber(text: "削除後に届く結果", hold: true)
let deletion = TranscriptionController(backend: deletionBackend, root: deletionRoot)
deletion.start(recordingID: otherID, audioURL: audio)
await deletionBackend.waitForCall()
deletion.forget([otherID])
await deletionBackend.release(); await deletion.waitUntilFinished()
expect(deletion.records[otherID] == nil && deletion.outcomes[otherID] == nil && deletion.statuses[otherID] == nil, "Deleted recognition cannot resurrect through a late backend result")
expect(try TranscriptArchive(folder: deletionRoot.appendingPathComponent("Transcripts")).loadAll().isEmpty, "Late deleted result never written to disk")
deletion.start(recordingID: otherID, audioURL: audio)
let deletedCalls = await deletionBackend.calls
expect(!deletion.isBusy && deletedCalls == 1, "Removed IDs cannot be recognized again in this process")
success.forget([id]); success.reloadSavedResults()
expect(success.records[id] == nil && success.statuses[id] == nil, "Cleanup-in-progress transcript cannot reappear from remaining sidecar")
print("Transcription: \(checks) checks passed")
