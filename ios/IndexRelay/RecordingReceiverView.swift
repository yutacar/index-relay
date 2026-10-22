import SwiftUI
import Combine
@preconcurrency import IndexReceiverBridge

@MainActor
final class RecordingReceiverController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var receptionStatus = "未開始"
    @Published private(set) var events: [String] = []
    @Published var showStartConfirmation = false
    @Published var clearOnStart = true
    @Published var showHistory = false
    @Published private(set) var baselineIDs: Set<String> = []
    @Published private(set) var previousCheckpoint: String?
    let store = RecordingStore()
    private let ringID: String
    private var nativeReceiver: RingReceiver?
    private var comparison: ReceiverComparison?
    @Published private(set) var comparisonURL: URL?
    @Published private(set) var comparisonStatus = "未開始"
    private var timeout: Task<Void, Never>?
    private var sessionID: UUID?
    @Published private(set) var failureNotices = 0
    private var consecutiveFailures = 0
    private var newSegments = 0
    private var duplicateSegments = 0
    private var sessionStartedAt: Date?

    init(ringID: String) {
        self.ringID = ringID
        store.reload()
        baselineIDs = Set(store.recordings.map(\.id))
        previousCheckpoint = ReceiverCheckpoint.shared.read()?.description
        restoreEvents()
        append("録音受信画面を表示。以前のイベントも保持しています。")
    }

    func start() {
        guard !running else { return }
        guard !store.transcriptions.isBusy else {
            append("文字起こしの完了、または中止処理の終了を待ってから受信を開始してください。")
            return
        }
        timeout?.cancel()
        if clearOnStart { clearDiagnostics() }
        baselineIDs = Set(store.recordings.map(\.id))
        comparisonURL = nil
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("ReceiverComparisons", isDirectory: true)
            comparison = try ReceiverComparison(root: root)
            comparisonStatus = "圧縮入力とPCMの比較を準備しました"
        } catch {
            comparison = nil
            comparisonStatus = "比較用保存先を作成できません"
            append("比較用保存先の作成に失敗したため、試験を開始しません。")
            return
        }
        let sessionID = UUID()
        self.sessionID = sessionID
        failureNotices = 0
        consecutiveFailures = 0
        newSegments = 0
        duplicateSegments = 0
        sessionStartedAt = .now
        running = true
        receptionStatus = "リングを探索しています"
        append("受信確認開始（90秒で停止）。リングで短い音声を録音してください。")
        append("受信ブリッジを生成します。")
        ReceiverCheckpoint.shared.write("受信ブリッジの生成直前")
        let receiver = RingReceiver(ringId: ringID, onEvent: { @Sendable [weak self] message in
            // Persist before hopping queues; console output is limited to Debug builds.
            ReceiverCheckpoint.shared.write(message)
            #if DEBUG
            NSLog("IndexRelay receiver: %@", message)
            #endif
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionID, self.running else { return }
                self.append(message)
                if message == "選択したリングを検出" { self.receptionStatus = "リング検出・転送待ち" }
                if message.hasPrefix("録音転送開始:") { self.receptionStatus = "録音データを転送しています" }
                if message.hasPrefix("転送失敗:") { self.receptionStatus = "転送失敗の通知あり" }
                if message.hasPrefix("転送失敗:") {
                    self.failureNotices += 1
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures >= 3 {
                        self.append("失敗通知が3件連続したため停止します。通知数は再試行回数とは限りません。公式アプリを終了し、接続条件を確認してください。")
                        self.stop()
                        return
                    }
                }
                if message == "受信失敗" {
                    self.stop()
                } else if message == "受信停止" {
                    self.receptionStatus = "受信ライブラリが停止しました"
                    self.running = false
                    self.sessionID = nil
                    self.timeout?.cancel()
                    self.timeout = nil
                    self.nativeReceiver = nil
                }
            }
        }, onRaw: { @Sendable [weak self] data, index in
            let collectionIndex = index.intValue
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionID, self.running else { return }
                do {
                    try self.comparison?.captureRaw(data, index: collectionIndex)
                } catch {
                    self.comparison?.noteIssue("raw_capture_failed")
                    self.comparisonStatus = "比較用の圧縮データ保存に失敗（通常受信は継続）"
                    self.append("比較用圧縮データを保存できませんでした: Collection \(collectionIndex)")
                }
            }
        }, onAudio: { @Sendable [weak self] data, replay, rate, index, context, contiguous in
            // Convert Kotlin objects before crossing executors. Native callbacks may use any thread.
            let sampleRate = rate.intValue
            let collectionIndex = index.intValue
            let isContiguous = contiguous.boolValue
            ReceiverCheckpoint.shared.write("Swiftへ音声到着: \(data.count)バイト / \(sampleRate) Hz / Collection \(collectionIndex)")
            DispatchQueue.main.async {
                guard let self, self.sessionID == sessionID, self.running else { return }
                do {
                    ReceiverCheckpoint.shared.write("区間情報の解析直前: Collection \(collectionIndex)")
                    let metadata = try JSONDecoder().decode(TransferContext.self, from: Data(context.utf8))
                    self.consecutiveFailures = 0
                    ReceiverCheckpoint.shared.write("WAV保存直前: \(data.count)バイト / Collection \(collectionIndex)")
                    let saved = try self.store.save(pcm: data, sampleRate: sampleRate,
                        collectionIndex: collectionIndex, ringID: self.ringID, contiguous: isContiguous, transfer: metadata)
                    ReceiverCheckpoint.shared.write("WAV保存完了: Collection \(collectionIndex)")
                    do {
                        let savedWAV = try self.store.savedWAVForComparison(pcm: data, sampleRate: sampleRate,
                            collectionIndex: collectionIndex, ringID: self.ringID)
                        if let result = try self.comparison?.compare(pcm: data, replay: replay,
                            context: Data(context.utf8), index: collectionIndex, rate: sampleRate, savedWAV: savedWAV) {
                            func label(_ value: Bool?) -> String { value.map { $0 ? "一致" : "不一致" } ?? "未比較" }
                            self.comparisonStatus = "再復号 \(label(result.replayMatches))・保存 \(result.savedWAVMatches ? "一致" : "不一致")"
                            self.append("データ比較: Collection \(collectionIndex)・ブリッジ \(label(result.bridgeMatches))・再復号 \(label(result.replayMatches))（\(result.replayStatus)）・WAV \(result.savedWAVMatches ? "一致" : "不一致")・圧縮入力 \(result.rawCoverageComplete ? "全区間あり" : "不足あり")")
                        }
                    } catch {
                        self.comparison?.noteIssue("comparison_failed")
                        self.comparisonStatus = "比較処理に失敗（音声の保存結果は別途確認）"
                        self.append("データ比較に失敗: Collection \(collectionIndex)")
                    }
                    if saved { self.newSegments += 1 } else { self.duplicateSegments += 1 }
                    self.receptionStatus = "保存: 新規 \(self.newSegments)区間・既存 \(self.duplicateSegments)区間"
                    if saved {
                        self.append("区間情報: Collection \(metadata.start)..\(collectionIndex)・ボタン解放 \(metadata.releaseDate?.ISO8601Format() ?? "不明")・ボタン列あり \(metadata.buttonSequencePresent)")
                    }
                    if saved {
                        self.append("受信区間保存: \(data.count / 2)サンプル、\(sampleRate) Hz、Collection \(collectionIndex)、連続性 \(isContiguous)")
                    } else if self.duplicateSegments == 1 || self.duplicateSegments.isMultiple(of: 10) {
                        self.append("保存済み区間を再取得（今回累計 \(self.duplicateSegments)区間・新規保存なし）")
                    }
                } catch {
                    self.append("区間情報の解析・保存に失敗したため停止します（\(type(of: error))）。")
                    self.stop()
                }
            }
        })
        nativeReceiver = receiver
        append("受信ブリッジの開始を呼び出します。")
        ReceiverCheckpoint.shared.write("受信ブリッジstart呼び出し直前")
        do {
            try receiver.start()
            append("受信ブリッジの開始呼び出しが戻りました。")
        } catch {
            append("受信開始で同期例外を検出しました（\((error as NSError).code)）。")
            stop()
            return
        }
        guard running, self.sessionID == sessionID else { return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            guard !Task.isCancelled, self?.sessionID == sessionID else { return }
            self?.stop()
        }
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        let receiver = nativeReceiver
        nativeReceiver = nil
        sessionID = nil
        let wasRunning = running
        running = false
        receptionStatus = "停止: 新規 \(newSegments)・既存 \(duplicateSegments)・失敗通知 \(failureNotices)"
        if let receiver {
            ReceiverCheckpoint.shared.write("受信ブリッジstop呼び出し直前")
            do { try receiver.stop() }
            catch { append("受信停止で同期例外を検出しました（\((error as NSError).code)）。") }
        }
        if wasRunning {
            if newSegments == 0 && duplicateSegments == 0 {
                append("今回の試験で保存処理まで届いた音声区間は0件です。")
            }
            append("受信停止: 新規 \(newSegments)区間・保存済み \(duplicateSegments)区間・失敗通知 \(failureNotices)件")
        }
    }

    func leave() {
        stop()
        store.transcriptions.cancel()
        store.stopPlayback()
    }

    func exportComparison() {
        guard !running else { return }
        do {
            comparisonURL = try comparison?.export()
            if comparisonURL == nil { comparisonStatus = "比較する試験データがありません" }
        } catch {
            comparisonStatus = "比較データの書き出しに失敗しました"
        }
    }

    func clearDiagnostics() {
        guard !running else { return }
        events = []
        previousCheckpoint = nil
        comparisonURL = nil
        comparison = nil
        comparisonStatus = "未開始"
        showHistory = false
        failureNotices = 0
        consecutiveFailures = 0
        newSegments = 0
        duplicateSegments = 0
        sessionStartedAt = nil
        receptionStatus = "未開始"
        baselineIDs = Set(store.recordings.map(\.id))
        store.clearDiagnostics()
        let cleared = ReceiverCheckpoint.shared.clear()
        append(cleared ? "ログと今回の表示をクリアしました。保存済みデータは保持しています。"
                       : "ログをクリアしましたが、直前処理のファイルは消去できませんでした。")
    }

    private func append(_ text: String) {
        #if DEBUG
        NSLog("IndexRelay UI: %@", text)
        #endif
        events.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(text)")
        if events.count > 150 { events.removeFirst(events.count - 150) }
        do {
            let url = try eventFile()
            try JSONEncoder().encode(events).write(to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A diagnostics failure must not prevent audio reception.
            if events.last != "診断イベントを端末内に保存できません。" {
                events.append("診断イベントを端末内に保存できません。")
            }
        }
    }

    private func eventFile() throws -> URL {
        var folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("ReceiverDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder.appendingPathComponent("events.json")
    }

    private func restoreEvents() {
        guard let url = try? eventFile(), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String].self, from: data) else { return }
        events = Array(saved.suffix(150))
    }

    var report: String {
        (["Index Relay 録音受信確認", "日時: \(Date.now.ISO8601Format())",
          "アプリ版: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不明") / \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "不明")",
          "データ比較: \(comparisonStatus)",
          "受信中: \(running)", "受信状況: \(receptionStatus)", "保存済み受信区間数: \(store.recordings.count)",
          "直近の試験開始: \(sessionStartedAt?.ISO8601Format() ?? "未開始")",
          "直近の試験: 新規 \(newSegments)区間・保存済み \(duplicateSegments)区間・失敗通知 \(failureNotices)件",
          "前回の最終処理: \(previousCheckpoint ?? "未記録・クリア済み")",
          "現在の最終処理: \(ReceiverCheckpoint.shared.read()?.description ?? "未記録・クリア済み")",
          "保存全体で1秒以上の受信区間: \(store.recordings.filter { $0.duration >= 1 }.count)",
          "保存全体の最長区間: \(String(format: "%.4f秒", store.recordings.map(\.duration).max() ?? 0))",
          "今回新規で1秒以上の区間: \(store.recordings.filter { !baselineIDs.contains($0.id) && $0.duration >= 1 }.count)",
          "今回新規の最長区間: \(String(format: "%.4f秒", store.recordings.filter { !baselineIDs.contains($0.id) }.map(\.duration).max() ?? 0))",
          "0.1秒未満の受信区間: \(store.recordings.filter { $0.duration < 0.1 }.count)",
          "受信位置は永続化せず、削除・更新は要求しません。音声・端末固有IDは含めません。"] + events + store.audioDiagnostics.values.sorted() + store.transcriptions.diagnosticSummary)
            .joined(separator: "\n")
    }
}

struct RecordingReceiverView: View {
    @StateObject private var controller: RecordingReceiverController
    @Environment(\.scenePhase) private var scenePhase

    init(ringID: String) {
        _controller = StateObject(wrappedValue: RecordingReceiverController(ringID: ringID))
    }

    var body: some View {
        List {
            Section("録音受信の実機確認") {
                LabeledContent("受信状況", value: controller.receptionStatus)
                Text("試験前に公式アプリを終了してください。受信開始後にIndex01のボタンを押して3〜5秒話します。過去の保存データも取得対象です。区間数は録音回数とは限りません。")
                if controller.running {
                    Button("受信を停止", action: controller.stop)
                } else {
                    Button("録音受信の確認を開始") { controller.showStartConfirmation = true }
                }
                Text("前面で最大90秒間だけ確認します。失敗通知が3件連続した場合、戻る操作、背景への移行でも停止します。音声はこのiPhone内だけに保存します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("表示") {
                Toggle("受信開始時にログをクリア", isOn: $controller.clearOnStart)
                    .disabled(controller.running)
                Toggle("過去の受信データも表示", isOn: $controller.showHistory)
                Button("ログ・診断・今回の表示をクリア", action: controller.clearDiagnostics)
                    .disabled(controller.running)
                Text("通常は今回新しく保存した区間だけを表示します。クリアしても音声ファイルは削除しません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let checkpoint = controller.previousCheckpoint {
                Section("前回の最終処理（終了原因は未確定）") {
                    Text(checkpoint).font(.caption).textSelection(.enabled)
                }
            }

            ReceivedRecordingList(store: controller.store, baselineIDs: controller.baselineIDs,
                                  showHistory: controller.showHistory, canTranscribe: !controller.running)

            Section("データ比較") {
                Text(controller.comparisonStatus)
                Text("圧縮された受信データを再復号し、受信時のPCMと保存WAVを照合します。同じ復号エンジンでの再現確認であり、音質の正しさを保証するものではありません。")
                    .font(.footnote)
                Button("比較データを書き出す", action: controller.exportComparison)
                    .disabled(controller.running)
                if let url = controller.comparisonURL {
                    ShareLink(item: url) { Label("比較データを共有（音声を含む）", systemImage: "square.and.arrow.up") }
                }
                Text("受信停止後に書き出せます。今回の圧縮入力・復号PCM・保存WAVを含みます。端末内で保存し、共有先を選んだ場合だけ外部へ渡します。過去の比較データはアプリ内に残ります。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("受信イベント") {
                ShareLink(item: controller.report) {
                    Label("受信結果を共有", systemImage: "square.and.arrow.up")
                }
                ForEach(Array(controller.events.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.caption).textSelection(.enabled)
                }
            }

            Section {
                Text("HaversineのiOS配布版を利用します。更新情報を返さず、初回消去は拒否します。旧ファームウェアでユーザーIDが必要な場合の書き込みは行いません。受信できない場合は結果を共有してください。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("録音受信確認")
        .confirmationDialog("選択したIndex01から録音を受信しますか？",
            isPresented: $controller.showStartConfirmation, titleVisibility: .visible) {
                Button("90秒間の受信を開始") {
                    // Dismissal updates SwiftUI's presentation state synchronously.
                    // Begin publishing receiver/store changes on the next main-loop turn.
                    DispatchQueue.main.async { controller.start() }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("録音データを転送してiPhone内に保存します。音声の外部送信、録音消去、更新は要求しません。")
            }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.leave() }
        }
        .onDisappear { controller.leave() }
    }
}

struct ReceivedRecordingList: View {
    @ObservedObject var store: RecordingStore
    let baselineIDs: Set<String>
    let showHistory: Bool
    let canTranscribe: Bool
    var automatic = false

    private var visibleRecordings: [ReceivedRecording] {
        store.recordings.filter { showHistory || !baselineIDs.contains($0.id) }
    }

    var body: some View {
        Section("表示中の受信データ（\(visibleRecordings.count)区間）") {
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if visibleRecordings.isEmpty {
                Text(showHistory ? "まだ保存されていません。" : "今回新しく保存した区間はありません。過去分は上のスイッチで表示できます。")
            }
            if let status = store.playbackStatus { Text(status).font(.footnote) }
            Text("まず1秒以上の項目を「標準補正で再生」で確認してください。聞き取れると確認できた比較版と同じ処理で音量を調整します。120Hz版・通常補正・原音とも比較できます。共有操作をすると、音声内容を選択した共有先へ渡します。")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(visibleRecordings.filter { $0.duration >= 0.1 }) { clip in
                VStack(alignment: .leading, spacing: 6) {
                    Text("受信日時: \(clip.receivedAt.formatted(date: .abbreviated, time: .standard))")
                    if let release = clip.transfer?.releaseDate {
                        Text("リング報告のボタン解放: \(release.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption)
                    }
                    if let transfer = clip.transfer {
                        Text("Collection \(transfer.start)..\(clip.collectionIndex)・ボタン列 \(transfer.buttonSequencePresent ? "あり" : "なし")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(String(format: "%.1f秒・%d Hz・Collection %d", clip.duration, clip.sampleRate, clip.collectionIndex))
                        .font(.caption).foregroundStyle(.secondary)
                    if !clip.contiguous {
                        Text("連続性未確認の区間を含みます").font(.caption).foregroundStyle(.orange)
                    }
                    Button("標準補正で再生") { store.play(clip, mode: .adaptive) }
                    Button("比較用：120Hz補正で再生") { store.play(clip, mode: .enhanced) }
                    Button("通常補正で再生") { store.play(clip, mode: .corrected) }
                    Button("原音を再生") { store.play(clip, mode: .original) }
                    if let diagnostic = store.audioDiagnostics[clip.id] {
                        Text(diagnostic).font(.caption).textSelection(.enabled)
                    }
                    if let url = store.audioURL(clip) {
                        RecordingTranscriptionView(controller: store.transcriptions, recordingID: clip.id,
                                                   audioURL: url, canStart: canTranscribe, automatic: automatic)
                        ShareLink(item: url) { Label("原音WAVを共有", systemImage: "square.and.arrow.up") }
                    }
                }
                .buttonStyle(.borderless)
            }
            let tiny = visibleRecordings.filter { $0.duration < 0.1 }
            if !tiny.isEmpty {
                DisclosureGroup("極短区間（0.1秒未満・\(tiny.count)件）") {
                    Text("音声確認用の一覧から分けています。データは保持しています。")
                        .font(.caption)
                    ForEach(tiny) { clip in
                        VStack(alignment: .leading) {
                            Text("Collection \(clip.collectionIndex)・\(clip.sampleCount)サンプル")
                            if let url = store.audioURL(clip) {
                                ShareLink("原音WAVを共有", item: url)
                            }
                        }
                    }
                }
            }
            if !store.recordings.isEmpty { Button("再生を停止", action: store.stopPlayback) }
        }
    }
}


private struct RecordingTranscriptionView: View {
    @ObservedObject var controller: TranscriptionController
    let recordingID: String
    let audioURL: URL
    let canStart: Bool
    var automatic = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.activeRecordingID == recordingID {
                ProgressView()
                if automatic {
                    Text("自動文字起こし中（停止は上のスイッチ）").font(.caption)
                } else {
                    Button("文字起こしを中止", action: controller.cancel)
                }
            } else {
                Button(controller.records[recordingID] == nil ? "日本語で文字起こし" : "日本語で文字起こしをやり直す") {
                    controller.start(recordingID: recordingID, audioURL: audioURL)
                }
                .disabled(controller.isBusy || !canStart)
            }
            if !canStart {
                Text(automatic ? "自動で順番に文字起こしします。" : "文字起こしは受信停止後に実行できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(automatic ? "標準補正した音声を端末内で認識し、結果を保存します。" : "標準補正した音声を端末内で認識します。初回は日本語モデルのダウンロードが必要な場合があります。この画面を開いたまま実行してください。")
                .font(.caption).foregroundStyle(.secondary)
            if let loadError = controller.loadError { Text(loadError).font(.caption) }
            if let status = controller.statuses[recordingID] {
                Text(status).font(.caption).textSelection(.enabled)
            }
            if let record = controller.records[recordingID] {
                Text("認識結果: \(record.createdAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(record.text).textSelection(.enabled)
                ShareLink(item: record.text) { Label("文字起こしを共有", systemImage: "square.and.arrow.up") }
            }
        }
        .buttonStyle(.borderless)
    }
}
