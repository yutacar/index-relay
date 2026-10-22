import Foundation

/// A small synchronous checkpoint, usable before dispatching native callbacks to the UI.
/// Contains stages and numeric metadata only. Never pass PCM, device IDs, or credentials.
final class ReceiverCheckpoint: @unchecked Sendable {
    struct Entry: Codable {
        let date: Date
        let stage: String
        var description: String { "\(date.ISO8601Format())  \(stage)" }
    }
    static let shared = ReceiverCheckpoint()
    private let lock = NSLock()
    private let directory: URL?

    init(directory: URL? = nil) { self.directory = directory }

    private func file() throws -> URL {
        var folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ReceiverDiagnostics", isDirectory: true)
        #if os(iOS)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder.appendingPathComponent("checkpoint.json")
    }

    @discardableResult
    func write(_ stage: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            let url = try file()
            let data = try JSONEncoder().encode(Entry(date: .now, stage: String(stage.prefix(500))))
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
            return true
        } catch { return false }
    }

    func read() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? file(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    @discardableResult
    func clear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            let url = try file()
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return true
        } catch { return false }
    }
}
