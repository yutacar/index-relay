import Foundation
import Combine
import UIKit
@preconcurrency import BackgroundTasks
@preconcurrency import IndexReceiverBridge

@MainActor
final class AutomaticRelayService: ObservableObject {
    static let shared = AutomaticRelayService()
    static var taskIdentifier: String { (Bundle.main.bundleIdentifier ?? "IndexRelay") + ".transcribe" }
    let store = RecordingStore()
    @Published private(set) var enabled = false
    @Published private(set) var ringName: String?
    @Published private(set) var status = "最初にリングを選択してください"
    @Published private(set) var backgroundStatus = "未登録"
    @Published private(set) var pendingCount = 0
    @Published private(set) var attentionCount = 0
    @Published private(set) var historyLimit = HistoryPolicy.defaultLimit
    @Published private(set) var historyError: String?
    private var maintainingHistory = false
    @Published private(set) var events: [String] = []
    private var queue: AutomaticQueue?
    private var receiver: RingReceiver?
    private var receiverID: UUID?
    private var launched = false
    private var foreground = false
    private var runner: Task<Void, Never>?
    private var runnerID: UUID?
    private var retry: Task<Void, Never>?
    private var receiverRetry: Task<Void, Never>?
    private var receiveLeaseToken: UUID?
    private var recognitionLeaseToken: UUID?
    private var launchKind = "通常起動"
    private var receiveLease: UIBackgroundTaskIdentifier = .invalid
    private var recognitionLease: UIBackgroundTaskIdentifier = .invalid
    private var recognitionDeadline: Date?
    private var processingTasks: Set<UUID> = []
    private var expiredTasks: Set<UUID> = []
    private var observation: AnyCancellable?
    private let root = URL.applicationSupportDirectory

    init() {
        observation = store.transcriptions.$activeRecordingID.dropFirst().sink { [weak self] id in
            guard id == nil else { return }
            DispatchQueue.main.async {
                guard let self, self.foreground || !self.processingTasks.isEmpty else { return }
                self.pump()
            }
        }
    }
    func launch(restoredBluetooth: Bool = false) {
        if !launched {
            launched = true
            launchKind = restoredBluetooth ? "Bluetooth状態復元で起動" : "通常起動"
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
                guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in AutomaticRelayService.shared.handle(task) }
            }
            backgroundStatus = registered ? "バックグラウンド処理を登録済み" : "バックグラウンド処理の登録に失敗"
        }
        do {
            if queue == nil {
                queue = try AutomaticQueue(file: root.appendingPathComponent("AutomaticRelay/state.json"))
                if let data = try? Data(contentsOf: root.appendingPathComponent("AutomaticRelay/events.json")),
                   let saved = try? JSONDecoder().decode([String].self, from: data) { events = Array(saved.suffix(150)) }
                try applyHistoryDeletion([])
                try reconcile()
            }
            refresh()
            if enabled {
                startReceiver(); scheduleBackground()
                if UIApplication.shared.applicationState == .background { pump() }
            }
        } catch {
            queue = nil; enabled = false
            status = "自動処理の保存情報を読み込めません。ロック解除後にアプリを開いてください。"
        }
    }
    func configure(ringID: String, name: String) {
        launch()
        stopReceiver()
        store.transcriptions.cancel(); runner?.cancel()
        do {
            guard let queue else { return }
            try queue.configure(ringID: ringID, name: name)
            try reconcile(); refresh(); startReceiver(); pumpAfterCurrentWork(); scheduleBackground()
            log("リングの選択を保存し、自動受信を開始しました")
        } catch { status = "自動受信の設定を保存できませんでした" }
    }
    func setEnabled(_ value: Bool) {
        guard queue?.state.ringID != nil else { return }
        do {
            try queue?.setEnabled(value); refresh()
            if value { try reconcile(); startReceiver(); pumpAfterCurrentWork(); scheduleBackground() }
            else {
                stopReceiver(); store.transcriptions.cancel(); runner?.cancel(); retry?.cancel()
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
                status = "自動受信を停止しました。保存済み音声と文章は保持しています。"
            }
        } catch { status = "自動処理の設定を保存できませんでした" }
    }
    func enterForeground() {
        foreground = true
        endRecognitionLease(); endReceiveLease()
        launch()
        log("前面へ移行しました")
        maintainHistory()
        do {
            if !store.transcriptions.isBusy { store.transcriptions.reloadSavedResults(); try reconcile() }
            try queue?.foregroundReady(); refresh()
        } catch { status = "未処理の録音情報を更新できませんでした" }
        if enabled { startReceiver(); pump(); scheduleBackground() }
    }
    func enterBackground() {
        foreground = false
        log("バックグラウンドへ移行しました")
        store.stopPlayback()
        if !enabled { store.transcriptions.cancel(); return }
        if enabled {
            scheduleBackground()
            if runner != nil { _ = beginRecognitionLease() }
            else { pump() }
        }
        // The BLE receiver deliberately remains alive across scene changes.
    }
    func setHistoryLimit(_ limit: Int) {
        do {
            let history = try HistoryArchive(root: root)
            try history.setRetentionLimit(limit)
            historyLimit = limit
            maintainHistory()
        } catch { historyError = "表示・保存件数を保存できませんでした。" }
    }
    func deleteRecordings(_ ids: Set<String>) {
        do { try applyHistoryDeletion(ids); historyError = nil }
        catch { historyError = "履歴の削除を完了できませんでした。次回起動時に再開します。" }
    }
    func maintainHistory() {
        do { try applyHistoryDeletion([]); historyError = nil }
        catch { historyError = "履歴の整理を完了できませんでした。次回起動時に再開します。" }
    }
    private func applyHistoryDeletion(_ requested: Set<String>) throws {
        guard !maintainingHistory else { return }
        guard let queue else { throw AutomaticQueueError.missingJob }
        maintainingHistory = true; defer { maintainingHistory = false }
        let history = try HistoryArchive(root: root)
        historyLimit = history.retentionLimit
        store.reload()
        guard store.errorMessage == nil else { throw CocoaError(.fileReadUnknown) }
        let ids = requested.union(history.state.pendingIDs).union(HistoryPolicy.deletions(store.recordings, limit: historyLimit))
        guard !ids.isEmpty else { return }
        try history.markDeleted(ids)
        // The durable tombstone is authoritative even if a later cleanup step fails.
        store.transcriptions.forget(ids)
        store.reload()
        try queue.removeRecordings(ids)
        try DeliveryController.shared.removeRecordings(ids)
        try store.removeFiles(ids: ids)
        try history.finishDeletion(ids)
        refresh()
        log("履歴整理: \(ids.count)件を削除（本文・音声はログに含みません）")
    }
    func retryPending() {
        guard !store.transcriptions.isBusy else { return }
        do { try queue?.retryWaiting(); refresh(); pump(); scheduleBackground() }
        catch { status = "再試行の設定を保存できませんでした" }
    }
    private func reconcile() throws {
        store.reload()
        if !store.transcriptions.isBusy { store.transcriptions.reloadSavedResults() }
        let completed = Set(try TranscriptArchive(folder: root.appendingPathComponent("Transcripts")).loadAll().keys)
        try queue?.reconcile(recordings: store.recordings, completed: completed)
    }
    private func refresh() {
        enabled = queue?.state.enabled ?? false
        ringName = queue?.state.ringName
        pendingCount = queue?.pendingCount ?? 0; attentionCount = queue?.attentionCount ?? 0
    }
    private nonisolated static func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { work() } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { work() } } }
    }
    private func startReceiver() {
        guard enabled, receiver == nil, let ringID = queue?.state.ringID else { return }
        receiverRetry?.cancel()
        let id = UUID(); receiverID = id
        let native = RingReceiver(ringId: ringID, onEvent: { [weak self] message in
            Self.deliver { [weak self] in
                guard let self, self.receiverID == id else { return }
                self.handleEvent(message)
            }
        }, onRaw: { _, _ in }, onAudio: { [weak self] pcm, _, rate, index, context, contiguous in
            let rate = rate.intValue; let index = index.intValue; let contiguous = contiguous.boolValue
            // Finish durable saving before returning from the native audio callback.
            Self.deliver { [weak self] in
                guard let self, self.receiverID == id else { return }
                self.receive(pcm: pcm, rate: rate, index: index, context: context, contiguous: contiguous, ringID: ringID)
            }
        })
        receiver = native
        do {
            try native.enableContinuousMode()
            try native.setDurableCursor(index: Int32(queue?.state.frontier.committed ?? -1))
            try native.start()
            if receiverID == id { status = "リングを自動探索・再接続しています" }
        } catch { status = "自動受信の開始に失敗しました"; restartReceiverLater() }
    }
    private func stopReceiver() {
        receiverRetry?.cancel(); receiverID = nil
        let current = receiver; receiver = nil
        try? current?.stop()
        endReceiveLease()
    }
    private func restartReceiverLater() {
        stopReceiver()
        guard enabled else { return }
        scheduleBackground()
        receiverRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.startReceiver()
        }
    }
    private func handleEvent(_ message: String) {
        if message.hasPrefix("自動受信範囲初期化:"), let first = Int(message.split(separator: ":").last ?? "") {
            do { try queue?.observe(first: first, reset: false) }
            catch { status = "受信位置の保存に失敗しました" }
            return
        }
        if message.hasPrefix("自動受信範囲再設定:"), let first = Int(message.split(separator: ":").last ?? "") {
            do { try queue?.observe(first: first, reset: true); log("リング内の保持範囲に合わせて受信位置を再設定しました") }
            catch { status = "受信位置の再設定を保存できませんでした" }
            return
        }
        if message.hasPrefix("録音転送開始:") {
            status = "録音を受信しています"; beginReceiveLease()
        } else if message == "Bluetooth準備完了。スキャンを開始します。" {
            status = "自動受信の待機中です。リングで録音してください。"
        } else if message == "受信失敗" || message == "受信停止" {
            status = "受信を再開するため再接続を待っています"; restartReceiverLater()
        } else if message.hasPrefix("転送失敗:") || message.hasPrefix("Bluetooth接続失敗:") {
            status = "接続・転送の再試行を待っています"; endReceiveLease()
        }
        if message.hasPrefix("録音転送開始:") || message.contains("失敗") || message.contains("準備完了") { log(message) }
    }
    private func receive(pcm: Data, rate: Int, index: Int, context: String, contiguous: Bool, ringID: String) {
        beginReceiveLease()
        do {
            let metadata = try JSONDecoder().decode(TransferContext.self, from: Data(context.utf8))
            let id = store.recordingID(pcm: pcm, sampleRate: rate, collectionIndex: index, ringID: ringID)
            if try store.isDeleted(id) {
                guard let queue else { throw AutomaticQueueError.missingJob }
                try queue.discardReceived(id: id, start: Int(metadata.start), end: index)
                try receiver?.setDurableCursor(index: Int32(queue.state.frontier.committed ?? -1))
                endReceiveLease(); return
            }
            let saved = try store.save(pcm: pcm, sampleRate: rate, collectionIndex: index, ringID: ringID,
                                       contiguous: contiguous, transfer: metadata)
            guard let recording = store.receivedRecording(pcm: pcm, sampleRate: rate, collectionIndex: index, ringID: ringID),
                  let queue else { throw TranscriptError.invalidRecording }
            try queue.received(recording, start: Int(metadata.start))
            // Only local resume state is advanced; no ring erase/programming command is sent.
            try receiver?.setDurableCursor(index: Int32(queue.state.frontier.committed ?? -1))
            refresh()
            status = "録音を保存しました。リングで次の録音ができます。"
            if saved { log("録音保存: Collection \(metadata.start)..\(index)・\(recording.sampleCount)サンプル・未処理 \(pendingCount)件") }
            maintainHistory()
            scheduleBackground(); pump()
        } catch {
            // Do not advance the resume position on any WAV/metadata/queue failure.
            status = "録音または待ち列を保存できません。空き容量を確認してください。"
            log("録音・待ち列の保存失敗（受信位置は未確定）")
            restartReceiverLater()
        }
        endReceiveLease()
    }
    private func beginReceiveLease() {
        guard !foreground, receiveLease == .invalid else { return }
        let token = UUID(); receiveLeaseToken = token
        receiveLease = UIApplication.shared.beginBackgroundTask(withName: "Index Relay 録音保存") { [weak self] in
            Task { @MainActor in
                guard self?.receiveLeaseToken == token else { return }
                self?.endReceiveLease()
            }
        }
    }
    private func endReceiveLease() {
        guard receiveLease != .invalid else { return }
        UIApplication.shared.endBackgroundTask(receiveLease); receiveLease = .invalid; receiveLeaseToken = nil
    }
    private func beginRecognitionLease() -> Bool {
        if !processingTasks.isEmpty || foreground { return true }
        if recognitionLease != .invalid { return true }
        let token = UUID(); recognitionLeaseToken = token
        recognitionLease = UIApplication.shared.beginBackgroundTask(withName: "Index Relay 文字起こし") { [weak self] in
            Task { @MainActor in
                guard self?.recognitionLeaseToken == token else { return }
                self?.expireRecognitionLease()
            }
        }
        guard recognitionLease != .invalid else { return false }
        // A short opportunity, not a promise of continuous background execution.
        recognitionDeadline = .now.addingTimeInterval(20)
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.recognitionLeaseToken == token, !self.foreground, self.processingTasks.isEmpty,
                  let deadline = self.recognitionDeadline, deadline <= .now else { return }
            self.expireRecognitionLease()
        }
        return true
    }
    private func expireRecognitionLease() {
        log("短時間の認識猶予が終了しました。未処理分は再開待ちです。")
        store.transcriptions.cancel(); runner?.cancel()
        endRecognitionLease(); scheduleBackground()
    }
    private func endRecognitionLease() {
        guard recognitionLease != .invalid else { return }
        UIApplication.shared.endBackgroundTask(recognitionLease); recognitionLease = .invalid; recognitionDeadline = nil; recognitionLeaseToken = nil
    }
    private func pumpAfterCurrentWork() {
        guard let current = runner else { pump(); return }
        Task { [weak self] in
            await current.value
            self?.pump()
        }
    }
    private func pump() {
        guard enabled, runner == nil, !store.transcriptions.isBusy, queue?.next() != nil else { return }
        guard foreground || !processingTasks.isEmpty || beginRecognitionLease() else { scheduleBackground(); return }
        let id = UUID(); runnerID = id
        runner = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.runnerID == id { self.runner = nil; self.runnerID = nil }
                self.endRecognitionLease(); self.refresh(); self.scheduleBackground(); self.scheduleForegroundRetry()
            }
            while self.enabled && !Task.isCancelled, let job = self.queue?.next() {
                if !self.foreground && self.processingTasks.isEmpty {
                    guard let deadline = self.recognitionDeadline, deadline.timeIntervalSinceNow > 2 else { break }
                }
                do {
                    guard let clip = self.store.recordings.first(where: { $0.id == job.id }),
                          let audio = self.store.audioURL(clip) else {
                        try self.queue?.finish(id: job.id, outcome: .needsAttention, detail: "録音ファイルが見つかりません")
                        continue
                    }
                    try self.queue?.start(id: job.id); self.refresh()
                    self.store.transcriptions.start(recordingID: job.id, audioURL: audio, allowModelDownload: self.foreground)
                    await self.store.transcriptions.waitUntilFinished()
                    if try self.store.isDeleted(job.id) { continue }
                    let outcome = self.store.transcriptions.outcomes[job.id] ?? .cancelled
                    let detail: String? = if case .modelDeferred = outcome { "model_deferred" }
                        else { self.store.transcriptions.statuses[job.id] }
                    try self.queue?.finish(id: job.id, outcome: outcome, detail: detail)
                    if self.foreground { try self.queue?.foregroundReady() }
                    self.refresh()
                                        switch outcome {
                    case .saved: self.log("文字起こし保存: \(job.id.prefix(8))・未処理 \(self.pendingCount)件")
                    case .cancelled: self.log("文字起こし中断: \(job.id.prefix(8))・待ち列に保持")
                    case .modelDeferred: self.log("モデル準備待ち: \(job.id.prefix(8))・前面で再開")
                    case .retryableFailure: self.log("文字起こし失敗: \(job.id.prefix(8))・再試行待ち")
                    case .needsAttention: self.log("文字起こし要対応: \(job.id.prefix(8))")
                    }
                    if Task.isCancelled { break }
                } catch {
                    self.status = "待ち列を保存できないため、自動文字起こしを中断しました"
                    self.log("文字起こし待ち列の更新失敗")
                    break
                }
            }
        }
    }
    private func scheduleForegroundRetry() {
        retry?.cancel()
        guard enabled, foreground, let next = queue?.state.jobs.values.filter({ $0.phase == .queued }).compactMap(\.retryAfter).min() else { return }
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) } catch { return }
            self?.pump()
        }
    }
    private func scheduleBackground() {
        guard enabled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = false; request.requiresNetworkConnectivity = false
        // Also provides a deferred recovery opportunity if the BLE receiver stopped unexpectedly.
        let deferred = queue?.state.jobs.values.filter { $0.phase == .queued }.compactMap(\.retryAfter).min()
        let delay = pendingCount > 0 ? (queue?.next() == nil ? max(30, deferred?.timeIntervalSinceNow ?? 30) : 30) : 900
        request.earliestBeginDate = .now.addingTimeInterval(delay)
        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundStatus = "実行を予約済み（開始時刻はiOSが決定）"
        } catch {
            backgroundStatus = "予約できませんでした（\((error as NSError).code)）。前面で未処理分を再開します。"
        }
    }
    private func handle(_ task: BGProcessingTask) {
        let id = UUID(); processingTasks.insert(id)
        log("BGProcessingTask 開始")
        let completion = BackgroundCompletionGate()
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                completion.finish(false) { task.setTaskCompleted(success: $0) }
                guard let self else { return }
                self.log("BGProcessingTask 期限切れ。認識を中断します。")
                self.processingTasks.remove(id)
                self.expiredTasks.insert(id); self.store.transcriptions.cancel(); self.runner?.cancel()
            }
        }
        Task { [weak self] in
            guard let self else { completion.finish(false) { task.setTaskCompleted(success: $0) }; return }
            self.launch()
            if !self.store.transcriptions.isBusy && self.runner == nil {
                do { try self.reconcile(); self.refresh() }
                catch { self.log("バックグラウンドで待ち列を復元できませんでした") }
            }
            if self.enabled { self.startReceiver(); self.pump() }
            await self.runner?.value
            let success = !self.expiredTasks.contains(id) && (!self.enabled || self.queue?.next() == nil)
            self.processingTasks.remove(id); self.expiredTasks.remove(id)
            completion.finish(success) { task.setTaskCompleted(success: $0) }
            self.log("BGProcessingTask 終了: \(success ? "完了" : "未処理あり")")
            self.scheduleBackground()
            if self.foreground { self.pump() }
        }
    }
    private func log(_ message: String) {
        events.append("\(Date.now.ISO8601Format()) \(message)")
        events = Array(events.suffix(150))
        if let data = try? JSONEncoder().encode(events) {
            try? TranscriptArchive.writeProtected(data, to: root.appendingPathComponent("AutomaticRelay/events.json"))
        }
    }
    func clearEvents() { events = []; log("自動処理のログをクリアしました") }
    var backgroundPermissionDescription: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: "利用可能"
        case .denied: "無効（iPhoneの設定を確認）"
        case .restricted: "端末の設定で制限中"
        @unknown default: "未確認"
        }
    }
    var report: String {
        (["Index Relay 自動処理", Date.now.ISO8601Format(), "起動: \(launchKind)",
          "アプリ版: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不明") / \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "不明")", "自動受信: \(enabled)", "状態: \(status)",
          "未処理: \(pendingCount)・要対応: \(attentionCount)", "BG: \(backgroundStatus)",
          "受信器: \(receiver != nil)・前面: \(foreground)", "省電力モード: \(ProcessInfo.processInfo.isLowPowerModeEnabled)",
          "バックグラウンド更新: \(backgroundPermissionDescription)"] + events + store.transcriptions.diagnosticSummary).joined(separator: "\n")
    }
}
