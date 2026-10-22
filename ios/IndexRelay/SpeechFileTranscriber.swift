import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreMedia
import UIKit

/// On-device SpeechAnalyzer only: no microphone capture or server recognition fallback.
actor SpeechFileTranscriber: FileTranscriptionBackend {
    private var activeID: UUID?
    private var activeAnalyzer: SpeechAnalyzer?
    private var installation: AssetInstallationRequest?

    func transcribe(file: URL, allowModelDownload: Bool, status: @escaping @Sendable (TranscriptionStep) -> Void) async throws -> String {
        guard activeID == nil else { throw TranscriptError.unavailable }
        let id = UUID(); activeID = id
        defer { if activeID == id { activeID = nil; activeAnalyzer = nil; installation = nil } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard SpeechTranscriber.isAvailable else { throw TranscriptError.unavailable }
            status(.modelCheck)
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
                throw TranscriptError.unsupportedJapanese
            }
            try Task.checkCancellation()
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let modelStatus = await AssetInventory.status(forModules: [transcriber])
            let activeForModelDownload = await MainActor.run { UIApplication.shared.applicationState == .active }
            if modelStatus != .installed && (!allowModelDownload || !activeForModelDownload) {
                throw TranscriptError.modelNotPrepared
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try Task.checkCancellation()
                guard allowModelDownload, await MainActor.run(body: { UIApplication.shared.applicationState == .active }) else {
                    throw TranscriptError.modelNotPrepared
                }
                installation = request
                status(.modelDownload)
                try await request.downloadAndInstall()
                installation = nil
            }
            try Task.checkCancellation()
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw TranscriptError.modelUnavailable }
            try Task.checkCancellation()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            activeAnalyzer = analyzer
            status(.recognizing)
            // Consume results while feeding/finalizing the file to avoid backpressure deadlocks.
            let results = Task { () throws -> String in
                var segments = TranscriptSegments()
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    let seconds = CMTimeGetSeconds(result.range.start)
                    guard seconds.isFinite else { continue }
                    segments.add(startMicroseconds: Int64((seconds * 1_000_000).rounded()), text: String(result.text.characters))
                }
                return segments.text
            }
            do {
                let audioFile = try AVAudioFile(forReading: file)
                let last = try await analyzer.analyzeSequence(from: audioFile)
                try Task.checkCancellation()
                guard let last else { throw TranscriptError.noSpeech }
                try await analyzer.finalizeAndFinish(through: last)
                let text = try await results.value
                try Task.checkCancellation()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptError.noSpeech }
                return text
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await results.value
                throw error
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }
    private func cancel(id: UUID) async {
        guard activeID == id else { return }
        installation?.progress.cancel()
        await activeAnalyzer?.cancelAndFinishNow()
    }
}
