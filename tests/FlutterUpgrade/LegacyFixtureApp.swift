// Simulator-only legacy-format fixture writer. Never linked into either production app.
import UIKit

@main
@MainActor final class LegacyFixtureApp: UIResponder, UIApplicationDelegate {
    static let destination = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let root = URL.applicationSupportDirectory
        do {
            if ProcessInfo.processInfo.environment["INDEX_RELAY_VERIFY_KEYCHAIN"] == "1" {
                let credential = try DestinationKeychain.load(Self.destination)
                guard credential.secret == "synthetic-non-network-credential" else { throw CocoaError(.fileReadCorruptFile) }
                try Data("verified".utf8).write(to: root.appendingPathComponent("upgrade-keychain-result.txt"))
            } else {
                try seed(root)
            }
        } catch {
            try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("upgrade-fixture-error.txt"))
        }
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Fixture", sessionRole: session.role)
        configuration.delegateClass = LegacyFixtureSceneDelegate.self
        return configuration
    }
    private func seed(_ root: URL) throws {
        // All targets disabled. The synthetic credential is deliberately not a valid API credential.
        let destination = DeliveryDestination(id: Self.destination, name: "移行試験・停止中", provider: .discord,
            targetID: "1", targetKind: "channel", identity: "synthetic-destination", enabled: false, prefix: "試験")
        var state = DeliveryState(); state.destinations = [destination]; state.baselineEstablished = true
        let phases: [DeliveryPhase] = [.sent, .unknown, .sending, .confirmation, .queued, .retryWaiting, .needsAttention, .cancelled]
        let folder = root.appendingPathComponent("ReceivedRecordings")
        try TranscriptArchive.makeProtectedDirectory(folder)
        let transcripts = TranscriptArchive(folder: root.appendingPathComponent("Transcripts"))
        let queue = try AutomaticQueue(file: root.appendingPathComponent("AutomaticRelay/state.json"))
        try queue.observe(first: 65530, reset: false)
        for (i, phase) in phases.enumerated() {
            let id = String(repeating: String(i + 1), count: 64)
            let time = Date(timeIntervalSince1970: 1_790_000_000 + Double(i))
            let record = ReceivedRecording(id: id, receivedAt: time, sampleRate: 9997, sampleCount: 19994,
                collectionIndex: (65530 + i) & 65535, contiguous: true, transfer: nil)
            let wav = try PCM16WAV.encode(pcm: Data(repeating: 0, count: 39988), sampleRate: 9997)
            try TranscriptArchive.writeProtected(wav, to: folder.appendingPathComponent(id + ".wav"))
            try TranscriptArchive.writeProtected(JSONEncoder().encode(record), to: folder.appendingPathComponent(id + ".json"))
            try transcripts.save(TranscriptRecord(recordingID: id, text: "移行試験 \(phase.rawValue)", createdAt: time))
            try queue.received(record, start: record.collectionIndex)
            state.seenRecordings.insert(id)
            state.jobs.append(DeliveryJob(recordingID: id, destinationID: destination.id, destinationName: destination.name,
                provider: destination.provider, targetIdentity: destination.identity, text: "試験 移行試験 \(phase.rawValue)",
                createdAt: time, confirmationRequired: true, phase: phase,
                attempt: UUID(), attempts: 1, retryAfter: phase == .retryWaiting ? .distantFuture : nil,
                messageID: phase == .sent ? "synthetic-receipt-1" : nil))
        }
        let pendingID = String(repeating: "9", count: 64)
        let pending = ReceivedRecording(id: pendingID, receivedAt: Date(timeIntervalSince1970: 1_790_000_010),
            sampleRate: 9997, sampleCount: 19994, collectionIndex: 2, contiguous: true, transfer: nil)
        try TranscriptArchive.writeProtected(PCM16WAV.encode(pcm: Data(repeating: 0, count: 39988), sampleRate: 9997), to: folder.appendingPathComponent(pendingID + ".wav"))
        try TranscriptArchive.writeProtected(JSONEncoder().encode(pending), to: folder.appendingPathComponent(pendingID + ".json"))
        try queue.received(pending, start: 2)
        try queue.start(id: pendingID)
        // A durable, deleted ID must never reappear in Flutter.
        let history = try HistoryArchive(root: root)
        try history.setRetentionLimit(20)
        let deleted = Set([String(repeating: "f", count: 64)])
        try history.markDeleted(deleted); try history.finishDeletion(deleted)
        try TranscriptArchive.makeProtectedDirectory(root.appendingPathComponent("Delivery"))
        try TranscriptArchive.writeProtected(JSONEncoder().encode(state), to: root.appendingPathComponent("Delivery/state.json"))
        try DestinationKeychain.save(DeliveryCredential(secret: "synthetic-non-network-credential"), id: Self.destination)
        try Data("seeded".utf8).write(to: root.appendingPathComponent("upgrade-fixture-ready.txt"))
    }
}

// New runtimes require scene adoption even for this minimal synthetic fixture app.
@MainActor final class LegacyFixtureSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
