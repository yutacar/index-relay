@preconcurrency import Flutter
import UIKit
import SwiftUI
import Combine

/// Swift remains the sole owner of recordings, credentials, cursors and delivery attempts.
/// The channel exports display data only; it never serializes Keychain contents.
@MainActor
final class RelayFlutterAdapter: NSObject, UIDocumentPickerDelegate {
    private let channel: FlutterMethodChannel
    private let service = AutomaticRelayService.shared
    private let delivery = DeliveryController.shared
    private var observers: Set<AnyCancellable> = []
    private var changeScheduled = false
    private var exportResult: FlutterResult?
    private var exportURL: URL?
    private weak var presenter: UIViewController?

    init(messenger: FlutterBinaryMessenger, presenter: UIViewController?) {
        self.channel = FlutterMethodChannel(name: "index_relay/relay", binaryMessenger: messenger)
        self.presenter = presenter
        super.init()
        for publisher in [service.objectWillChange.eraseToAnyPublisher(), service.store.objectWillChange.eraseToAnyPublisher(),
                          service.store.transcriptions.objectWillChange.eraseToAnyPublisher(), delivery.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.changed() }.store(in: &observers)
        }
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            Task { @MainActor in await self.handle(call, result: result) }
        }
    }
    func attachPresenter(_ presenter: UIViewController?) { self.presenter = presenter }
    private func changed() {
        guard !changeScheduled else { return }
        changeScheduled = true
        // @Published emits before mutation. Send an invalidation on the next main turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeScheduled = false
            self.channel.invokeMethod("stateChanged", arguments: nil)
        }
    }
    func snapshot() -> [String: Any] {
        let transcripts = service.store.transcriptions
        let recordings: [[String: Any]] = HistoryPolicy.newestFirst(service.store.recordings).map { record in
            let text = transcripts.records[record.id]
            let phase = text != nil ? "done" : transcripts.activeRecordingID == record.id ? "processing" : service.job(for: record.id)?.phase.rawValue ?? "queued"
            let summary = HistoryDeliverySummary(jobs: delivery.state.jobs.filter { $0.recordingID == record.id })
            return ["id": record.id, "createdAt": Int64(record.recordedAt.timeIntervalSince1970 * 1000),
                    "phase": phase, "text": text?.text ?? "", "samples": record.sampleCount, "sampleRate": record.sampleRate,
                    "engine": text?.engine ?? "", "elapsedMs": 0, "simulation": false,
                    "deliveryTitle": summary.title, "deliveryComplete": summary.complete,
                    "detail": transcripts.statuses[record.id] ?? service.job(for: record.id)?.detail ?? ""]
        }
        return ["historyLimit": service.historyLimit, "requiresConfirmation": delivery.state.requiresConfirmation,
                "recordings": recordings, "destinations": delivery.state.destinations.map {
                    ["id": $0.id.uuidString, "name": $0.name, "provider": $0.provider.rawValue,
                     "prefix": $0.prefix ?? "", "targetHint": ""]
                }, "busy": transcripts.isBusy, "nativeIOS": true, "simulation": false,
                "receiverEnabled": service.enabled, "receiverStatus": service.status]
    }
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let args = call.arguments as? [String: Any] ?? [:]
        do {
            if call.method == "stopAudio" { service.store.stopPlayback(); result(true); return }
            guard service.isReady, delivery.ready else { throw CocoaError(.fileReadUnknown) }
            switch call.method {
            case "applicationInfo": result(["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""])
            case "snapshot": result(snapshot())
            case "deleteRecordings":
                guard let ids = args["ids"] as? [String], ids.allSatisfy(TranscriptRecord.validID) else { throw TranscriptError.invalidRecording }
                service.deleteRecordings(Set(ids))
                guard service.historyError == nil else { throw CocoaError(.fileWriteUnknown) }
                result(snapshot())
            case "saveSettings":
                guard let limit = args["historyLimit"] as? Int, HistoryPolicy.allowedRange.contains(limit), let confirmation = args["requiresConfirmation"] as? Bool else { throw HistorySettingsError.invalidLimit }
                service.setHistoryLimit(limit)
                guard service.historyError == nil else { throw CocoaError(.fileWriteUnknown) }
                delivery.setConfirmation(confirmation)
                guard delivery.state.requiresConfirmation == confirmation else { throw CocoaError(.fileWriteUnknown) }
                result(snapshot())
            case "openNativeSettings":
                guard let host = presenter, host.presentedViewController == nil else { throw CocoaError(.userCancelled) }
                host.present(UIHostingController(rootView: RelaySettingsView(service: service)), animated: true)
                result(snapshot())
            case "retryTranscription":
                guard let id = args["id"] as? String else { throw TranscriptError.invalidRecording }
                try service.retryTranscription(id: id)
                result(snapshot())
            case "playAudio", "exportAudio", "audioBytes":
                guard let id = args["id"] as? String, let record = service.store.recordings.first(where: { $0.id == id }) else { throw TranscriptError.invalidRecording }
                if call.method == "playAudio" { service.store.play(record, mode: .adaptive); result(true); return }
                let data = try await service.store.correctedAudio(record)
                if call.method == "audioBytes" { result(FlutterStandardTypedData(bytes: data)); return }
                guard exportResult == nil, let host = presenter, host.presentedViewController == nil else { throw CocoaError(.userCancelled) }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RelayExport-" + UUID().uuidString, isDirectory: true)
                try TranscriptArchive.makeProtectedDirectory(folder)
                let file = folder.appendingPathComponent("IndexRelay-corrected.wav")
                do { try TranscriptArchive.writeProtected(data, to: file) }
                catch { try? FileManager.default.removeItem(at: folder); throw error }
                let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
                exportResult = result; exportURL = folder; picker.delegate = self
                host.present(picker, animated: true)
            default: result(FlutterMethodNotImplemented)
            }
        } catch { result(FlutterError(code: "NATIVE_RELAY_ERROR", message: "保存情報・操作対象を確認してください。", details: nil)) }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finishExport(!urls.isEmpty) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finishExport(false) }
    private func finishExport(_ success: Bool) {
        let completion = exportResult; exportResult = nil
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil; completion?(success)
    }
}
