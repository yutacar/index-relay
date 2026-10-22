import SwiftUI
import UniformTypeIdentifiers

private enum HistorySheet: Identifiable {
    case audio(ReceivedRecording), delivery(String)
    var id: String { switch self { case .audio(let clip): "audio-" + clip.id; case .delivery(let id): "delivery-" + id } }
}
struct HistoryHomeList: View {
    @ObservedObject var service: AutomaticRelayService
    @ObservedObject var store: RecordingStore
    @ObservedObject var transcriptions: TranscriptionController
    @ObservedObject var deliveries: DeliveryController
    @State private var sheet: HistorySheet?
    @State private var selection: Set<String> = []
    @Binding var isEditing: Bool
    private var clips: [ReceivedRecording] { Array(HistoryPolicy.newestFirst(store.recordings).prefix(service.historyLimit)) }
    var body: some View {
        let visible = clips
        List {
            if let error = service.historyError {
                Section { Text(error).foregroundStyle(.red); Button("履歴の整理を再試行", action: service.maintainHistory) }
            }
            if visible.isEmpty {
                ContentUnavailableView("文字起こしはまだありません", systemImage: "text.bubble", description: Text(service.ringName == nil ? "右上の歯車からリングを設定してください。" : "リングで録音すると、ここに新しい順で表示します。"))
            }
            Section {
                ForEach(visible) { clip in
                    if isEditing {
                        Button {
                            if selection.contains(clip.id) { selection.remove(clip.id) }
                            else { selection.insert(clip.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selection.contains(clip.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(selection.contains(clip.id) ? Color.accentColor : Color.secondary)
                                    .padding(.top, 4)
                                historyContent(clip, editing: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("history.select." + clip.id)
                        .accessibilityValue(selection.contains(clip.id) ? "選択済み" : "未選択")
                        .deleteDisabled(true)
                    } else {
                        historyContent(clip, editing: false)
                    }
                }
                .onDelete { offsets in
                    let ids = Set(offsets.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
                    service.deleteRecordings(ids)
                }
            } footer: {
                if !visible.isEmpty { Text("最新\(service.historyLimit)件を保存します。左へスワイプして削除、または「編集」で複数選択・全選択できます。削除は確認なしで実行します。") }
            }
        }
        .sheet(item: $sheet) { item in
            NavigationStack {
                switch item {
                case .audio(let recording):
                    RecordingAudioInfoView(store: store, transcriptions: transcriptions, recording: recording)
                case .delivery(let id):
                    RecordingDeliveryView(controller: deliveries, recordingID: id)
                }
            }
        }
        .toolbar {
            if isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(selection == Set(visible.map(\.id)) ? "全選択を解除" : "すべて選択") {
                        let ids = Set(visible.map(\.id))
                        selection = selection == ids ? [] : ids
                    }.disabled(visible.isEmpty).accessibilityIdentifier("history.selectAll")
                    Spacer()
                    Button("選択した\(selection.count)件を削除", role: .destructive) {
                        let ids = selection.intersection(Set(visible.map(\.id)))
                        service.deleteRecordings(ids)
                        selection = []
                    }.disabled(selection.isEmpty).accessibilityIdentifier("history.bulkDelete")
                }
            }
        }
        .onChange(of: isEditing) { _, editing in if !editing { selection = [] } }
        .onChange(of: store.recordings.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
    }
    @ViewBuilder
    private func historyContent(_ clip: ReceivedRecording, editing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(clip.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !editing {
                    Button { sheet = .audio(clip) } label: { Image(systemName: "info.circle").font(.title3) }
                        .buttonStyle(.borderless).accessibilityLabel("音声と録音情報")
                }
            }
            if let text = transcriptions.records[clip.id]?.text {
                if editing { Text(text).frame(maxWidth: .infinity, alignment: .leading) }
                else { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                HStack(spacing: 6) {
                    if transcriptions.activeRecordingID == clip.id { ProgressView().controlSize(.small) }
                    Text(transcriptions.statuses[clip.id] ?? "文字起こし待ち").font(.callout).foregroundStyle(.secondary)
                }
            }
            let jobs = deliveries.state.jobs.filter { $0.recordingID == clip.id }
            let summary = HistoryDeliverySummary(jobs: jobs)
            if editing {
                Label(summary.title, systemImage: summary.symbol).font(.caption.weight(.medium))
                    .foregroundStyle(summary.complete ? Color.green : summary.requiresAttention ? Color.orange : Color.secondary)
            } else {
                Button { sheet = .delivery(clip.id) } label: {
                    Label(summary.title, systemImage: summary.symbol).font(.caption.weight(.medium))
                        .foregroundStyle(summary.complete ? Color.green : summary.requiresAttention ? Color.orange : Color.secondary)
                }.buttonStyle(.borderless).disabled(jobs.isEmpty)
            }
        }.padding(.vertical, 6)
    }

}
private struct RecordingDeliveryView: View {
    @ObservedObject var controller: DeliveryController
    let recordingID: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(controller.state.jobs.filter { $0.recordingID == recordingID }) { job in
                NavigationLink { DeliveryJobDetail(controller: controller, id: job.id, initialText: job.text) } label: {
                    LabeledContent(job.destinationName, value: job.phase.title)
                }
            }
        }
        .navigationTitle("連携状況")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
    }
}
private struct WAVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
private struct RecordingAudioInfoView: View {
    @ObservedObject var store: RecordingStore
    @ObservedObject var transcriptions: TranscriptionController
    let recording: ReceivedRecording
    @Environment(\.dismiss) private var dismiss
    @State private var preparing = false
    @State private var document: WAVExportDocument?
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportStatus: String?
    private var available: Bool { store.recordings.contains { $0.id == recording.id } }
    var body: some View {
        Form {
            if available {
                Section("録音情報") {
                    LabeledContent("日時", value: recording.recordedAt.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("長さ", value: String(format: "%.1f秒", recording.duration))
                    LabeledContent("電池電圧", value: recording.batteryVoltageText)
                    Text("録音データに含まれる値です。現在の電圧や電池残量％を示すものではありません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("音声") {
                    Button("標準補正で再生", systemImage: "play.fill") { store.play(recording, mode: .adaptive) }
                    if let status = store.playbackStatus {
                        Text(status).font(.caption)
                        Button("再生を停止", action: store.stopPlayback)
                    }
                    Button {
                        preparing = true; exportStatus = nil
                        exportTask = Task {
                            defer { preparing = false }
                            do {
                                let data = try await store.correctedAudio(recording)
                                try Task.checkCancellation()
                                document = WAVExportDocument(data: data); exporting = true
                            } catch is CancellationError { }
                            catch { exportStatus = "音声の準備に失敗しました。履歴と空き容量を確認してください。" }
                        }
                    } label: {
                        if preparing { ProgressView("標準補正音声を準備中…") }
                        else { Label("標準補正音声をダウンロード", systemImage: "square.and.arrow.down") }
                    }.disabled(preparing)
                    Text("WAV形式で「ファイル」などの保存先を選べます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let exportStatus { Text(exportStatus).font(.caption) }
                    if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
                if let text = transcriptions.records[recording.id]?.text {
                    Section("文字起こし") { Text(text).textSelection(.enabled) }
                }
            } else {
                Text("この履歴は削除されました。")
            }
        }
        .navigationTitle("音声・録音情報")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .wav,
                      defaultFilename: "IndexRelay-\(recording.id.prefix(8)).wav") { result in
            switch result {
            case .success: exportStatus = "音声を保存しました。"
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { exportStatus = "音声を保存できませんでした。保存先を確認してください。" }
            }
            document = nil
        }
        .onDisappear { exportTask?.cancel(); store.stopPlayback() }
    }
}
