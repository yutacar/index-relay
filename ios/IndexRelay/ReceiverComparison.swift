import Foundation
import CryptoKit

/// Local diagnostic capture; no device identifiers and no network operations.
/// Raw collections may contain audio and other collection metadata.
final class ReceiverComparison {
    struct Asset: Codable {
        let name: String
        let kind: String
        let collection: Int
        let bytes: Int
        let sha256: String
    }
    struct Result: Codable {
        let collectionStart: Int
        let collectionEnd: Int
        let sampleRate: Int
        let nativeSampleCount: Int
        let nativeHash: String?
        let swiftHash: String
        let bridgeMatches: Bool?
        let replayStatus: String
        let replayMatches: Bool?
        let replayFirstDifferentByte: Int?
        let savedWAVValid: Bool
        let savedWAVMatches: Bool
        let savedFirstDifferentByte: Int?
        let rawCollections: [Int]
        let rawCoverageComplete: Bool
    }
    struct Manifest: Encodable {
        let schema = 1
        let createdAt: Date
        let engine = "Haversine 2541a33 / PPCollection + MultipartCollection"
        let limitation = "Replay uses the same decoder; equality proves reproducibility, not decoder correctness. Raw data is complete collection payload, not BLE packets."
        let assets: [Asset]
        let results: [Result]
        let issues: [String]
    }
    private let folder: URL
    private let createdAt = Date()
    private let byteLimit: Int
    private var totalBytes = 0
    private var assets: [Asset] = []
    private var results: [Result] = []
    private var issues: [String] = []
    private var rawIndices: Set<Int> = []
    enum CaptureError: Error { case limit, invalidWAV }

    init(root: URL, byteLimit: Int = 24 * 1024 * 1024) throws {
        self.byteLimit = byteLimit
        folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        #endif
        var excluded = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    func captureRaw(_ data: Data, index: Int) throws {
        guard (0...65535).contains(index) else { throw CaptureError.limit }
        try saveAsset(data, kind: "compressed-collection", index: index, suffix: "bin")
        rawIndices.insert(index)
        try writeManifest()
    }

    @discardableResult
    func compare(pcm: Data, replay: Data?, context: Data, index: Int, rate: Int, savedWAV: Data) throws -> Result {
        let object = try JSONSerialization.jsonObject(with: context) as? [String: Any] ?? [:]
        let start = (object["start"] as? NSNumber)?.intValue ?? index
        let nativeHash = object["nativePCMHash"] as? String
        let status = object["replayStatus"] as? String ?? "unavailable"
        let savedPCM = try? Self.wavPCM(savedWAV, sampleRate: rate)
        if savedPCM == nil { noteIssue("invalid_saved_wav") }
        let swiftHash = Self.fnv64(pcm)
        let expected = Self.collectionRange(start: start, end: index)
        let available = expected.filter { rawIndices.contains($0) }
        let result = Result(collectionStart: start, collectionEnd: index, sampleRate: rate,
            nativeSampleCount: pcm.count / 2, nativeHash: nativeHash, swiftHash: swiftHash,
            bridgeMatches: nativeHash.map { $0 == swiftHash }, replayStatus: status,
            replayMatches: replay.map { $0 == pcm }, replayFirstDifferentByte: replay.flatMap { Self.firstDifference(pcm, $0) },
            savedWAVValid: savedPCM != nil, savedWAVMatches: savedPCM == pcm,
            savedFirstDifferentByte: savedPCM.flatMap { Self.firstDifference(pcm, $0) },
            rawCollections: available, rawCoverageComplete: !expected.isEmpty && available.count == expected.count)
        results.append(result)
        do {
            try saveAsset(pcm, kind: "callback-pcm16le", index: index, suffix: "pcm")
            if let replay { try saveAsset(replay, kind: "replay-pcm16le", index: index, suffix: "pcm") }
            try saveAsset(savedWAV, kind: "saved-original-wav", index: index, suffix: "wav")
        } catch {
            noteIssue("comparison_assets_incomplete")
            try? writeManifest()
            throw error
        }
        try writeManifest()
        return result
    }

    func noteIssue(_ code: String) {
        if !issues.contains(code) { issues.append(code) }
    }

    /// Export only this session. The user explicitly invokes this from the UI.
    func export() throws -> URL {
        try writeManifest()
        let manifest = Manifest(createdAt: createdAt, assets: assets, results: results, issues: issues)
        struct File: Encodable { let asset: Asset; let data: Data }
        struct Bundle: Encodable { let manifest: Manifest; let files: [File] }
        let files = try assets.map { File(asset: $0, data: try Data(contentsOf: folder.appendingPathComponent($0.name))) }
        let destination = folder.appendingPathComponent("IndexRelay-comparison.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try Self.persist(encoder.encode(Bundle(manifest: manifest, files: files)), to: destination)
        return destination
    }

    private func saveAsset(_ data: Data, kind: String, index: Int, suffix: String) throws {
        guard data.count <= byteLimit - totalBytes else { noteIssue("capture_limit"); throw CaptureError.limit }
        let name = "\(assets.count)-\(index)-\(kind).\(suffix)"
        try Self.persist(data, to: folder.appendingPathComponent(name))
        totalBytes += data.count
        assets.append(Asset(name: name, kind: kind, collection: index, bytes: data.count,
                            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }
    private func writeManifest() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try Self.persist(encoder.encode(Manifest(createdAt: createdAt, assets: assets, results: results, issues: issues)),
                         to: folder.appendingPathComponent("manifest.json"))
    }
    private static func persist(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
    }
    static func fnv64(_ bytes: Data) -> String {
        var value: UInt64 = 14695981039346656037
        for byte in bytes { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%016llx", value)
    }
    static func firstDifference(_ lhs: Data, _ rhs: Data) -> Int? {
        for (i, pair) in zip(lhs, rhs).enumerated() where pair.0 != pair.1 { return i }
        return lhs.count == rhs.count ? nil : min(lhs.count, rhs.count)
    }
    static func collectionRange(start: Int, end: Int) -> [Int] {
        guard (0...65535).contains(start), (0...65535).contains(end) else { return [] }
        let count = ((end - start) & 65535) + 1
        return (0..<count).map { (start + $0) & 65535 }
    }
    static func wavPCM(_ data: Data, sampleRate: Int) throws -> Data {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        guard bytes.count >= 12, Data(bytes[0..<4]) == Data("RIFF".utf8),
              Data(bytes[8..<12]) == Data("WAVE".utf8), u32(4) == bytes.count - 8 else { throw CaptureError.invalidWAV }
        var offset = 12; var formatOK = false; var pcm: Data?
        while offset + 8 <= bytes.count {
            let size = u32(offset+4); let body = offset + 8
            guard size <= bytes.count - body else { throw CaptureError.invalidWAV }
            let tag = Data(bytes[offset..<offset+4])
            if tag == Data("fmt ".utf8) {
                guard size >= 16, u16(body) == 1, u16(body+2) == 1,
                      u32(body+4) == sampleRate, u16(body+12) == 2, u16(body+14) == 16 else { throw CaptureError.invalidWAV }
                formatOK = true
            } else if tag == Data("data".utf8) {
                guard pcm == nil, size.isMultiple(of: 2) else { throw CaptureError.invalidWAV }
                pcm = Data(bytes[body..<body+size])
            }
            offset = body + size + size % 2
        }
        guard formatOK, let pcm, offset == bytes.count else { throw CaptureError.invalidWAV }
        return pcm
    }
}
