import Foundation

/// A local resume position, never a request to erase or acknowledge data on the ring.
struct SavedCollectionFrontier: Codable, Sendable {
    private(set) var next: Int?
    private(set) var committed: Int?
    private var pending: Set<Int> = []

    mutating func observe(first: Int, reset: Bool) {
        guard (0...65535).contains(first) else { return }
        if next == nil || reset { next = first; committed = nil; pending = [] }
    }
    mutating func saved(start: Int, end: Int) throws {
        guard (0...65535).contains(start), (0...65535).contains(end) else { throw AutomaticQueueError.invalidRange }
        let count = ((end - start) & 65535) + 1
        guard count <= 8192 else { throw AutomaticQueueError.invalidRange }
        if next == nil { next = start }
        guard let expected = next else { return }
        for offset in 0..<count {
            let index = (start + offset) & 65535
            // Ignore replayed data behind the frontier, including across 16-bit rollover.
            if ((index - expected) & 65535) < 32768 { pending.insert(index) }
        }
        while let expected = next, pending.remove(expected) != nil {
            committed = expected; next = (expected + 1) & 65535
        }
    }
}

enum AutomaticQueueError: Error { case invalidRange, missingJob, invalidID }
enum AutomaticJobPhase: String, Codable, Sendable { case queued, processing, done, needsAttention }
struct AutomaticJob: Codable, Sendable, Identifiable {
    let id: String
    let createdAt: Date
    var phase: AutomaticJobPhase = .queued
    var failures = 0
    var retryAfter: Date?
    var detail: String?
}
struct AutomaticRelayState: Codable, Sendable {
    var enabled = false
    var ringID: String?
    var ringName: String?
    var frontier = SavedCollectionFrontier()
    var jobs: [String: AutomaticJob] = [:]
}

/// Atomic snapshot: a failed write never publishes an advanced cursor or job state.
final class AutomaticQueue {
    private(set) var state: AutomaticRelayState
    private let file: URL
    init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(AutomaticRelayState.self, from: Data(contentsOf: file))
        } else { state = AutomaticRelayState() }
    }
    private func transaction(_ edit: (inout AutomaticRelayState) throws -> Void) throws {
        var candidate = state; try edit(&candidate)
        try TranscriptArchive.makeProtectedDirectory(file.deletingLastPathComponent())
        try TranscriptArchive.writeProtected(JSONEncoder().encode(candidate), to: file)
        state = candidate
    }
    func configure(ringID: String, name: String) throws {
        guard UUID(uuidString: ringID) != nil else { throw AutomaticQueueError.invalidID }
        try transaction {
            if $0.ringID != ringID { $0.frontier = SavedCollectionFrontier() }
            $0.ringID = ringID; $0.ringName = name; $0.enabled = true
        }
    }
    func setEnabled(_ value: Bool) throws { try transaction { $0.enabled = value } }
    func observe(first: Int, reset: Bool) throws {
        try transaction { $0.frontier.observe(first: first, reset: reset) }
    }
    /// Called only after both WAV and recording metadata have been durably saved.
    func received(_ recording: ReceivedRecording, start: Int) throws {
        guard TranscriptRecord.validID(recording.id) else { throw AutomaticQueueError.invalidID }
        try transaction { state in
            if recording.duration >= 0.1, state.jobs[recording.id] == nil {
                state.jobs[recording.id] = AutomaticJob(id: recording.id, createdAt: recording.receivedAt)
            }
            try state.frontier.saved(start: start, end: recording.collectionIndex)
        }
    }
    /// Rebuild missing queue entries from committed audio and recover interrupted recognition.
    func reconcile(recordings: [ReceivedRecording], completed: Set<String>) throws {
        try transaction { state in
            for recording in recordings where recording.duration >= 0.1 && state.jobs[recording.id] == nil {
                state.jobs[recording.id] = AutomaticJob(id: recording.id, createdAt: recording.receivedAt)
            }
            for key in Array(state.jobs.keys) {
                if completed.contains(key) { state.jobs[key]?.phase = .done }
                else if state.jobs[key]?.phase == .processing || state.jobs[key]?.phase == .done { state.jobs[key]?.phase = .queued }
            }
        }
    }
    func removeRecordings(_ ids: Set<String>) throws {
        try transaction { state in for id in ids { state.jobs[id] = nil } }
    }
    /// Explicitly discarded by the user / retention, so local replay can be skipped without saving audio again.
    func discardReceived(id: String, start: Int, end: Int) throws {
        try transaction { state in
            state.jobs[id] = nil
            try state.frontier.saved(start: start, end: end)
        }
    }
    func next(now: Date = .now) -> AutomaticJob? {
        state.jobs.values.filter { $0.phase == .queued && ($0.retryAfter == nil || $0.retryAfter! <= now) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }.first
    }
    func start(id: String) throws {
        try transaction {
            guard $0.jobs[id]?.phase == .queued else { throw AutomaticQueueError.missingJob }
            $0.jobs[id]?.phase = .processing; $0.jobs[id]?.detail = nil
        }
    }
    func finish(id: String, outcome: TranscriptionOutcome, detail: String?, now: Date = .now) throws {
        try transaction { state in
            guard var job = state.jobs[id] else { throw AutomaticQueueError.missingJob }
            job.detail = detail
            switch outcome {
            case .saved: job.phase = .done; job.retryAfter = nil
            case .cancelled: job.phase = .queued
            case .needsAttention: job.phase = .needsAttention
            case .modelDeferred: job.phase = .queued; job.retryAfter = now.addingTimeInterval(300)
            case .retryableFailure:
                job.failures += 1
                job.phase = job.failures >= 3 ? .needsAttention : .queued
                job.retryAfter = now.addingTimeInterval(min(1800, 30 * pow(2, Double(job.failures - 1))))
            }
            state.jobs[id] = job
        }
    }
    func retryWaiting() throws {
        try transaction { state in
            for id in Array(state.jobs.keys) where state.jobs[id]?.phase != .done {
                state.jobs[id]?.phase = .queued; state.jobs[id]?.retryAfter = nil; state.jobs[id]?.failures = 0
            }
        }
    }
    func foregroundReady() throws {
        try transaction { state in
            for id in Array(state.jobs.keys) where state.jobs[id]?.phase == .queued {
                // Foreground may download missing models. Other failures retain their backoff.
                if state.jobs[id]?.detail == "model_deferred" { state.jobs[id]?.retryAfter = nil }
            }
        }
    }
    var pendingCount: Int { state.jobs.values.filter { $0.phase == .queued || $0.phase == .processing }.count }
    var attentionCount: Int { state.jobs.values.filter { $0.phase == .needsAttention }.count }
}

/// Expiration and normal completion may race; the OS task must be completed exactly once.
@MainActor
final class BackgroundCompletionGate {
    private var finished = false
    func finish(_ success: Bool, action: (Bool) -> Void) {
        guard !finished else { return }
        finished = true
        action(success)
    }
}
