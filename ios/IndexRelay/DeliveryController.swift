import Foundation
import Combine
import UIKit
import UserNotifications
@preconcurrency import BackgroundTasks

@MainActor
final class DeliveryController: ObservableObject {
    static let shared = DeliveryController()
    static var backgroundIdentifier: String { (Bundle.main.bundleIdentifier ?? "IndexRelay") + ".delivery" }
    @Published private(set) var state = DeliveryState()
    @Published private(set) var status = "送り先を登録してください"
    @Published private(set) var ready = false
    @Published private(set) var notificationStatus = "未確認"
    @Published private(set) var backgroundStatus = "未予約"
    private let root: URL
    private var archive: DeliveryArchive?
    private var normalSession: URLSession?
    private var backgroundSession: URLSession?
    private var observer: AnyCancellable?
    private var active: [UUID: URLSessionTask] = [:]
    private var normalIDs: Set<UUID> = []
    private var recovering = false
    private var registered = false
    private var processingWindows: Set<UUID> = []
    private var retryTask: Task<Void, Never>?
    private var hiNewPreparation: Task<Void, Never>?
    private var lease: UIBackgroundTaskIdentifier = .invalid
    private var leaseToken: UUID?
    private var immediateWindow = false
    private var backgroundCompletion: (() -> Void)?
    private var savedOutcomes: Set<String> = []
    init(root: URL = .applicationSupportDirectory) { self.root = root }
    func launch(transcriptions: TranscriptionController) {
        if !registered {
            registered = true
            let success = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundIdentifier + ".work", using: .main) { task in
                guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in DeliveryController.shared.handle(task) }
            }
            backgroundStatus = success ? "バックグラウンド送信を登録済み" : "バックグラウンド送信の登録に失敗"
        }
        if observer == nil {
            observer = transcriptions.$outcomes.dropFirst().sink { [weak self] outcomes in
                guard let self else { return }
                // React only when a recording newly reaches .saved; other outcome changes need no rescan.
                let saved = Set(outcomes.compactMap { $0.value == .saved ? $0.key : nil })
                let isNew = !saved.isSubset(of: self.savedOutcomes)
                self.savedOutcomes = saved
                guard isNew else { return }
                // The transcript is already durable here. Snapshot routing before the next UI setting change.
                self.ingest(immediate: true)
            }
        }
        guard archive == nil else { return }
        do {
            let archive = try DeliveryArchive(file: root.appendingPathComponent("Delivery/state.json"))
            let deleted = try HistoryArchive(root: root).state.deletedIDs
            try archive.removeRecordings(deleted)
            try archive.ingest(TranscriptArchive(folder: root.appendingPathComponent("Transcripts")).loadAll().filter { !deleted.contains($0.key) })
            self.archive = archive
            try cleanupUnreferencedBodies()
            refresh(); ready = true
            setupSessions(); restoreTasks()
            Task { await refreshNotificationStatus() }
        } catch { archive = nil; status = "送信情報を読み込めません。ロック解除後に再度開いてください。"; ready = false }
    }
    private func setupSessions() {
        func delegate() -> DeliverySessionDelegate {
            DeliverySessionDelegate(complete: { [weak self] result in
                DispatchQueue.main.async { self?.completed(result) }
            }, finishedEvents: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }; let completion = self.backgroundCompletion
                    self.backgroundCompletion = nil; completion?()
                }
            })
        }
        func serialQueue() -> OperationQueue { let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue }
        let normal = URLSessionConfiguration.default
        normal.timeoutIntervalForRequest = 20; normal.timeoutIntervalForResource = 25
        normal.httpCookieStorage = nil; normal.urlCredentialStorage = nil; normal.urlCache = nil
        normalSession = URLSession(configuration: normal, delegate: delegate(), delegateQueue: serialQueue())
        let background = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        background.isDiscretionary = false; background.sessionSendsLaunchEvents = true
        background.timeoutIntervalForRequest = 30; background.timeoutIntervalForResource = 3_600
        background.httpCookieStorage = nil; background.urlCredentialStorage = nil; background.urlCache = nil
        backgroundSession = URLSession(configuration: background, delegate: delegate(), delegateQueue: serialQueue())
    }
    private func restoreTasks() {
        recovering = true
        backgroundSession?.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self, let archive = self.archive else { return }
                var attempts: Set<UUID> = []
                for task in tasks where task.state == .running || task.state == .suspended {
                    let parts = (task.taskDescription ?? "").split(separator: "|").map(String.init)
                    guard parts.count == 2, let id = UUID(uuidString: parts[0]), let attempt = UUID(uuidString: parts[1]),
                          let job = archive.state.jobs.first(where: { $0.id == id }), job.phase == .sending, job.attempt == attempt else { task.cancel(); continue }
                    if job.provider == .hiNew && !job.canReplayHiNew() { task.cancel(); continue }
                    attempts.insert(attempt); self.active[id] = task
                    if task.state == .suspended { task.resume() }
                }
                let previousUnknown = Set(archive.state.jobs.filter { $0.phase == .unknown }.map(\.id))
                do {
                    try archive.recover(activeAttempts: attempts); self.refresh()
                    for job in self.state.jobs where job.phase == .unknown && !previousUnknown.contains(job.id) { self.notify(job) }
                }
                catch { self.status = "送信状態の復旧を保存できません。自動送信を停止しました。"; self.ready = false }
                self.recovering = false
                self.pump()
            }
        }
    }
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        // launch() has already recreated the session in didFinishLaunching.
        if backgroundSession == nil { backgroundCompletion = nil; completion() }
    }
    func enterForeground() {
        ingest(immediate: true)
        Task { await refreshNotificationStatus() }
    }
    func ingest(immediate: Bool = false) {
        guard let archive, ready else { return }
        do {
            let deleted = try HistoryArchive(root: root).state.deletedIDs
            try removeRecordings(deleted)
            let previous = Set(archive.state.jobs.map(\.id))
            try archive.ingest(TranscriptArchive(folder: root.appendingPathComponent("Transcripts")).loadAll().filter { !deleted.contains($0.key) })
            refresh()
            for job in state.jobs where !previous.contains(job.id) { notify(job) }
            if immediate { openWindow() }
            pump()
        } catch { status = "文字起こしの送信待ち列を保存できませんでした。次回起動時に再開します。" }
    }
    func removeRecordings(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        guard let archive else { throw DeliveryStoreError.invalidTransition }
        let removed = archive.state.jobs.filter { ids.contains($0.recordingID) }
        do { try archive.removeRecordings(ids) }
        catch {
            ready = false
            for job in removed { active[job.id]?.cancel() }
            throw error
        }
        for job in removed {
            active.removeValue(forKey: job.id)?.cancel(); normalIDs.remove(job.id)
            clearNotification(job.id)
            if let attempt = job.attempt {
                let file = root.appendingPathComponent("Delivery/\(attempt.uuidString).json")
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        }
        try cleanupUnreferencedBodies()
        if !removed.isEmpty { refresh() }
    }
    private func cleanupUnreferencedBodies() throws {
        guard let archive else { return }
        let folder = root.appendingPathComponent("Delivery")
        let retained = Set(archive.state.jobs.filter { $0.phase == .sending }.compactMap(\.attempt).map { $0.uuidString })
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && !retained.contains(file.deletingPathExtension().lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }
    func enqueueExisting(_ record: TranscriptRecord) {
        change {
            guard !(try HistoryArchive(root: root).state.deletedIDs.contains(record.recordingID)) else { return }
            try archive?.transaction { state in
                for destination in state.destinations where destination.enabled && destination.isSupported && !state.jobs.contains(where: { $0.recordingID == record.recordingID && $0.destinationID == destination.id }) {
                    state.jobs.append(DeliveryJob(recordingID: record.recordingID, destinationID: destination.id,
                        destinationName: destination.name, provider: destination.provider, targetIdentity: destination.identity,
                        text: destination.messageText(record.text), createdAt: .now, confirmationRequired: true, phase: .confirmation,
                        discordMentions: destination.provider == .discord ? .fromPrefix(destination.prefix) : nil))
                }
            }
        }
    }
    func setConfirmation(_ value: Bool) { change { try archive?.transaction { $0.requiresConfirmation = value } } }
    func setDestinationEnabled(_ id: UUID, enabled: Bool) {
        change { try archive?.transaction { state in if let index = state.destinations.firstIndex(where: { $0.id == id }) { guard !enabled || state.destinations[index].isSupported else { throw DeliveryStoreError.unsupportedTarget }; state.destinations[index].enabled = enabled } } }
    }
    func saveDestination(existingID: UUID?, name: String, provider: DeliveryProvider, secret: String, chat: String, prefix: String, hiNewPlaintextConfirmed: Bool = false) async -> Bool {
        guard ready, let archive else { return false }
        do {
            if provider == .hiNew && !hiNewPlaintextConfirmed { throw HiNewError.plaintextConsent }
            let secretValue = try DeliveryCredential.resolve(secret, existingID: existingID, load: DestinationKeychain.load)
            var destination = try await DeliveryAPI.validate(provider: provider, secret: secretValue, chat: chat.trimmingCharacters(in: .whitespacesAndNewlines))
            if let existingID {
                guard let old = archive.state.destinations.first(where: { $0.id == existingID }), old.identity == destination.identity,
                      old.provider == provider else { throw DeliveryStoreError.targetChanged }
                destination.id = existingID; destination.enabled = old.enabled
            }
            destination.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? destination.name : String(name.prefix(80))
            destination.prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            try archive.validateDestination(destination)
            try DestinationKeychain.save(DeliveryCredential(secret: secretValue), id: destination.id)
            try archive.upsertDestination(destination)
            refresh(); status = "送り先を確認して保存しました（テスト投稿はしていません）"; pump(); return true
        } catch {
            if error is DeliveryCredentialError { status = "Webhook URLまたは送信者トークンを入力してください。" }
            else if let known = error as? HiNewError { status = known.localizedDescription }
            else if let known = error as? DeliveryNetworkError { status = known.localizedDescription }
            else if let known = error as? DeliveryStoreError { status = known.localizedDescription }
            else { status = "送り先を安全に保存できませんでした（コード \((error as NSError).code)）。" }
            return false
        }
    }
    func redeemHiNewInvite(existingID: UUID?, secret: String, peer: String, invite: String, plaintextConfirmed: Bool) async -> Bool {
        guard ready, let archive else { return false }
        do {
            guard plaintextConfirmed else { throw HiNewError.plaintextConsent }
            let old = existingID.flatMap { id in archive.state.destinations.first { $0.id == id && $0.provider == .hiNew } }
            if existingID != nil && old == nil { throw HiNewError.wrongPeer }
            let token = try DeliveryCredential.resolve(secret, existingID: existingID, load: DestinationKeychain.load)
            let result = try await HiNewAPI.redeem(token: token, peer: peer.trimmingCharacters(in: .whitespacesAndNewlines), invite: invite, expectedSender: old?.hiNewSender)
            guard old == nil || result.identity == old?.identity else { throw HiNewError.wrongPeer }
            status = "相手との接続を確認しました。送り先を確認して保存してください（投稿はしていません）。"
            return true
        } catch let error as HiNewError { status = error.localizedDescription }
        catch { status = "接続を確認できません。招待を繰り返し使用せず、送り先の確認で再照合してください。" }
        return false
    }
    func enqueueHiNewTest(_ id: UUID) {
        change {
            guard let archive, let destination = archive.state.destinations.first(where: { $0.id == id && $0.provider == .hiNew && $0.enabled && $0.isSupported }) else { throw DeliveryStoreError.missingDestination }
            try archive.transaction { state in
                state.jobs.append(DeliveryJob(recordingID: "hi-new-test-" + UUID().uuidString, destinationID: destination.id,
                    destinationName: destination.name, provider: .hiNew, targetIdentity: destination.identity,
                    text: destination.messageText("Index Relayの接続テストです。"), createdAt: .now, confirmationRequired: true, phase: .confirmation))
            }
            status = "テスト文を確認待ちに追加しました。送信一覧で内容を確認して送ってください。"
        }
    }
    func removeDestination(_ id: UUID) {
        change {
            guard let archive else { return }
            guard !archive.state.jobs.contains(where: { $0.destinationID == id && ![.sent, .cancelled].contains($0.phase) }) else { throw DeliveryStoreError.pendingJobs }
            try archive.transaction { $0.destinations.removeAll { $0.id == id } }
            DestinationKeychain.remove(id)
        }
    }
    func approve(_ id: UUID, text: String) { change { try archive?.approve(id: id, text: text) }; clearNotification(id); openWindow(); pump() }
    func cancel(_ id: UUID) { change { try archive?.cancel(id: id) }; clearNotification(id) }
    func retry(_ id: UUID, allowUnknown: Bool = false) { change { try archive?.retry(id: id, allowUnknown: allowUnknown) }; openWindow(); pump() }
    func deleteCompletedTest(_ id: UUID) {
        change { try archive?.deleteCompletedTest(id: id) }
        if !state.jobs.contains(where: { $0.id == id }) { clearNotification(id) }
    }
    func dismissUnknown(_ id: UUID) { change { try archive?.dismissUnknown(id: id) }; clearNotification(id) }
    func markSent(_ id: UUID) { change { try archive?.markSent(id: id) }; clearNotification(id) }
    private func change(_ action: () throws -> Void) {
        guard ready else { return }
        do { try action(); refresh(); pump() }
        catch let error as DeliveryStoreError { status = error.localizedDescription }
        catch { ready = false; status = "送信情報の保存に失敗したため自動送信を停止しました（コード \((error as NSError).code)）。再起動後に確認してください。" }
    }
    private func refresh() {
        if let archive { state = archive.state }
        scheduleBackground()
    }
    private func scheduleBackground() {
        guard ready else { return }
        guard let earliest = archive?.nextEligibleDate() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundIdentifier + ".work")
            backgroundStatus = "再試行の予約はありません（OS転送中の分は継続）"; return
        }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundIdentifier + ".work")
        request.requiresNetworkConnectivity = true; request.requiresExternalPower = false
        request.earliestBeginDate = .now.addingTimeInterval(max(30, earliest.timeIntervalSinceNow))
        do { try BGTaskScheduler.shared.submit(request); backgroundStatus = "再試行を予約済み（開始時刻はiOSが決定）" }
        catch { backgroundStatus = "再試行を予約できませんでした（コード \((error as NSError).code)）。次回起動でも再開します。" }
    }
    private func handle(_ task: BGProcessingTask) {
        let completion = BackgroundCompletionGate()
        let windowID = UUID(); processingWindows.insert(windowID)
        var expired = false
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                expired = true; self?.processingWindows.remove(windowID); self?.expireImmediateWork()
                completion.finish(false) { task.setTaskCompleted(success: $0) }
            }
        }
        Task {
            guard !expired else { return }
            resumeBackgroundWork()
            await waitForImmediateWork()
            processingWindows.remove(windowID)
            completion.finish(!expired) { task.setTaskCompleted(success: $0) }
            scheduleBackground()
        }
    }
    private func openWindow() {
        if lease != .invalid { immediateWindow = true; return }
        guard UIApplication.shared.applicationState == .active || UIApplication.shared.backgroundTimeRemaining > 8 else { return }
        let token = UUID(); leaseToken = token
        lease = UIApplication.shared.beginBackgroundTask(withName: "IndexRelayDelivery") { [weak self] in
            Task { @MainActor in
                guard let self, self.leaseToken == token else { return }
                self.immediateWindow = false
                self.hiNewPreparation?.cancel()
                // Cancel only ordinary transfers; uncertain attempts are never registered a second time.
                for (id, task) in self.active where self.normalIDs.contains(id) { task.cancel() }
                self.endWindow()
                self.pump()
            }
        }
        immediateWindow = lease != .invalid
    }
    func enterBackground() {
        immediateWindow = lease != .invalid
        if !normalIDs.isEmpty { openWindow() }
        pump()
    }
    private func endWindow() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) }
        lease = .invalid; leaseToken = nil; immediateWindow = false
    }
    private var canPrepareHiNew: Bool {
        UIApplication.shared.applicationState == .active || !processingWindows.isEmpty || UIApplication.shared.backgroundTimeRemaining > 8
    }
    private var excludedProviders: Set<DeliveryProvider> {
        DeliveryScheduling.excludedProviders(canPrepareHiNew: canPrepareHiNew, hiNewPreparing: hiNewPreparation != nil)
    }
    private func pump() {
        retryTask?.cancel(); retryTask = nil
        guard ready, !recovering, active.isEmpty, let archive else { return }
        let excluded = excludedProviders
        let job = archive.next(excluding: excluded)
        guard let job else {
            // Keep the execution lease while the read-only hi.new preflight is running.
            if hiNewPreparation == nil { endWindow() }
            scheduleRetry(excluding: excluded); return
        }
        guard let destination = state.destinations.first(where: { $0.id == job.destinationID }), destination.identity == job.targetIdentity else {
            change { try archive.update(job.id) { $0.phase = .needsAttention; $0.detail = "送り先が変更されています。確認してください。" } }; return
        }
        if job.provider == .hiNew {
            hiNewPreparation = Task { [weak self] in
                guard let self else { return }
                defer { self.hiNewPreparation = nil; self.pump() }
                do {
                    let credential = try DestinationKeychain.load(destination.id)
                    let verified = try await HiNewAPI.validate(token: credential.secret, peer: destination.targetID, expectedSender: destination.hiNewSender)
                    try Task.checkCancellation()
                    guard self.ready, self.canPrepareHiNew, let current = archive.state.jobs.first(where: { $0.id == job.id && [.queued, .retryWaiting].contains($0.phase) }),
                          let target = archive.state.destinations.first(where: { $0.id == destination.id && $0.enabled && $0.identity == current.targetIdentity }) else { return }
                    guard verified.identity == current.targetIdentity else { throw HiNewError.wrongPeer }
                    self.submit(current, to: target, credential: credential)
                } catch is CancellationError { /* No POST was registered. Resume on the next execution window. */ }
                catch {
                    guard !Task.isCancelled, archive.state.jobs.contains(where: { $0.id == job.id && [.queued, .retryWaiting].contains($0.phase) }) else { return }
                    do {
                        let known = error as? HiNewError
                        try archive.hiNewValidationFailed(id: job.id, detail: known?.localizedDescription ?? "hi.newの資格情報・送信設定を確認してください。", retryDelay: known?.retryDelay)
                        self.refresh(); if let updated = archive.state.jobs.first(where: { $0.id == job.id }) { self.notify(updated) }
                    } catch { self.ready = false; self.status = "送信前確認の結果を保存できません。自動送信を停止しました。" }
                }
            }
            // Preflight suspends on GET requests. Register another provider without waiting for it.
            pump()
        } else { submit(job, to: destination) }
    }
    private func submit(_ job: DeliveryJob, to destination: DeliveryDestination, credential suppliedCredential: DeliveryCredential? = nil) {
        guard let archive else { return }
        let attempt = UUID()
        do {
            let credential = try suppliedCredential ?? DestinationKeychain.load(destination.id)
            let (request, body) = try job.provider == .hiNew
                ? HiNewAPI.post(destination: destination, token: credential.secret, job: job)
                : DeliveryAPI.request(destination: destination, credential: credential, text: job.text, discordMentions: job.discordMentions)
            let file = root.appendingPathComponent("Delivery/\(attempt.uuidString).json")
            try TranscriptArchive.writeProtected(body, to: file)
            let useNormal = UIApplication.shared.applicationState == .active || !processingWindows.isEmpty || (immediateWindow && UIApplication.shared.backgroundTimeRemaining > 8)
            guard let session = useNormal ? normalSession : backgroundSession else { return }
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = "\(job.id.uuidString)|\(attempt.uuidString)"
            do { try archive.begin(id: job.id, attempt: attempt) }
            catch { task.cancel(); try? FileManager.default.removeItem(at: file); throw error }
            if useNormal { normalIDs.insert(job.id) }
            active[job.id] = task; refresh(); task.resume()
        } catch {
            do {
                try archive.update(job.id) {
                    $0.phase = $0.provider == .hiNew && $0.hiNewPossiblyAccepted == true ? .unknown : .needsAttention
                    $0.detail = (error as? DeliveryStoreError)?.localizedDescription ?? "送信準備に失敗しました。資格情報・空き容量・本文サイズを確認してください。"
                }
                refresh(); if let job = state.jobs.first(where: { $0.id == job.id }) { notify(job) }
            } catch { ready = false; status = "送信状態を保存できないため、自動送信を停止しました。" }
            pump()
        }
    }
    private func completed(_ result: DeliveryCompletion) {
        let parts = result.tag.split(separator: "|").map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[0]), let attempt = UUID(uuidString: parts[1]), let archive else { return }
        if active[id]?.taskDescription == result.tag { active[id] = nil; normalIDs.remove(id) }
        guard let job = archive.state.jobs.first(where: { $0.id == id }), job.attempt == attempt,
              job.phase == .sending || job.phase == .unknown else {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("Delivery/\(attempt.uuidString).json"))
            pump(); return
        }
        do {
            let outcome = DeliveryAPI.classify(provider: job.provider, status: result.status, data: result.data, errorCode: result.errorCode, bytesSent: result.bytesSent, expectedPeer: job.provider == .hiNew ? state.destinations.first(where: { $0.id == job.destinationID && $0.identity == job.targetIdentity })?.targetID : nil, retryAfter: result.retryAfter)
            try archive.finish(id: id, attempt: attempt, result: outcome)
            try? FileManager.default.removeItem(at: root.appendingPathComponent("Delivery/\(attempt.uuidString).json"))
            refresh()
            if let updated = state.jobs.first(where: { $0.id == id }) { notify(updated) }
            pump()
        } catch {
            ready = false; status = "送信結果を保存できません。重複防止のため自動送信を停止しました。再起動後に送り先を確認してください。"
            endWindow()
        }
    }
    private func scheduleRetry(excluding providers: Set<DeliveryProvider> = []) {
        guard let date = archive?.nextEligibleDate(excluding: providers), date > .now else { return }
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow))) } catch { return }
            self?.pump()
        }
        // Suspension may delay this timer; a dedicated BGProcessingTask also wakes the outbox.
    }
    func resumeBackgroundWork() { ingest(immediate: true); pump() }
    var hasPendingDelivery: Bool { state.jobs.contains { [.queued, .retryWaiting, .sending].contains($0.phase) } }
    func waitForImmediateWork() async {
        while !Task.isCancelled && (!normalIDs.isEmpty || hiNewPreparation != nil) {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
    func expireImmediateWork() {
        if UIApplication.shared.applicationState == .active { endWindow(); return }
        immediateWindow = false
        hiNewPreparation?.cancel()
        for (id, task) in active where normalIDs.contains(id) { task.cancel() }
        endWindow()
    }
    func enableNotifications() async {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { notificationStatus = "通知の許可を確認できませんでした" }
        await refreshNotificationStatus()
        notifyWaiting()
    }
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) ? "許可済み" : "未許可（設定から変更できます）"
    }
    var report: String {
        (["Index Relay 送信診断", Date.now.ISO8601Format(), "確認あり: \(state.requiresConfirmation)",
          "送り先: \(state.destinations.count)件・送信履歴: \(state.jobs.count)件", "状態: \(status)", "BG: \(backgroundStatus)"] +
         state.jobs.map { "\($0.id.uuidString.prefix(8)) / \($0.provider.rawValue) / \($0.phase.rawValue) / 試行\($0.attempts)回" }).joined(separator: "\n")
    }
    private func notifyWaiting() { for job in state.jobs where [.confirmation, .needsAttention, .unknown].contains(job.phase) { notify(job) } }
    private func notify(_ job: DeliveryJob) {
        guard [.confirmation, .needsAttention, .unknown].contains(job.phase) else { clearNotification(job.id); return }
        let content = UNMutableNotificationContent()
        content.title = "Index Relay：\(job.phase.title)"
        content.body = "アプリの「送信一覧」で確認してください。"
        content.sound = .default
        // Do not reveal transcript text, channel names, URLs, or tokens on the lock screen.
        let request = UNNotificationRequest(identifier: "delivery.\(job.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    private func clearNotification(_ id: UUID) {
        let ids = ["delivery.\(id.uuidString)"]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}
