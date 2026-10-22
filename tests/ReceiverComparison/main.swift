import Foundation

var checks = 0
@MainActor
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label); checks += 1
}
func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("IndexRelayComparisonTests-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let pcm = Data([0,0,255,127,0,128,255,255])
let wav = try PCM16WAV.encode(pcm: pcm, sampleRate: 9997)
check(ReceiverComparison.fnv64(Data()) == "cbf29ce484222325", "FNV empty vector")
check(ReceiverComparison.fnv64(Data("hello".utf8)) == "a430d84680aabd0b", "FNV standard vector")
check(ReceiverComparison.firstDifference(pcm, pcm) == nil, "equality")
check(ReceiverComparison.firstDifference(Data([1,2,3]), Data([1,4,3])) == 1, "mismatch position")
check(ReceiverComparison.firstDifference(Data([1,2]), Data([1])) == 1, "length mismatch position")
check(ReceiverComparison.collectionRange(start: 65534, end: 1) == [65534,65535,0,1], "collection rollover")
check(ReceiverComparison.collectionRange(start: -1, end: 1).isEmpty, "invalid collection")
let extracted = try ReceiverComparison.wavPCM(wav, sampleRate: 9997)
check(extracted == pcm, "extract original WAV")
check(rejects { _ = try ReceiverComparison.wavPCM(wav, sampleRate: 16000) }, "reject wrong rate")
check(rejects { _ = try ReceiverComparison.wavPCM(Data(wav.dropLast()), sampleRate: 9997) }, "reject truncated file")
var malformed = wav; malformed[40] = 255
check(rejects { _ = try ReceiverComparison.wavPCM(malformed, sampleRate: 9997) }, "reject invalid chunk size")
let capture = try ReceiverComparison(root: root)
try capture.captureRaw(Data([3,4]), index: 65535)
try capture.captureRaw(Data([5,6]), index: 0)
let context = try JSONSerialization.data(withJSONObject: ["start":65535,"nativePCMHash":ReceiverComparison.fnv64(pcm),"replayStatus":"equal"])
let result = try capture.compare(pcm: pcm, replay: pcm, context: context, index: 0, rate: 9997, savedWAV: wav)
check(result.bridgeMatches == true && result.replayMatches == true && result.savedWAVMatches, "all paths equal")
check(result.rawCoverageComplete && result.rawCollections == [65535,0], "rollover raw coverage")
let export = try capture.export()
if let output = ProcessInfo.processInfo.environment["INDEX_RELAY_TEST_EXPORT"] {
    try Data(contentsOf: export).write(to: URL(fileURLWithPath: output), options: .atomic)
}
let bundle = try JSONSerialization.jsonObject(with: Data(contentsOf: export)) as! [String:Any]
let files = bundle["files"] as! [[String:Any]]
check(files.count == 5, "export has raw, callback, replay and saved assets")
let first = Data(base64Encoded: files[0]["data"] as! String)
check(first == Data([3,4]), "compressed bytes survive export")
let manifest = bundle["manifest"] as! [String:Any]
check((manifest["results"] as! [Any]).count == 1, "comparison exported")
var changed = pcm; changed[3] = 1
let mismatch = try capture.compare(pcm: pcm, replay: changed, context: Data("{\"start\":10,\"nativePCMHash\":\"bad\",\"replayStatus\":\"different\"}".utf8), index: 10, rate: 9997,
    savedWAV: PCM16WAV.encode(pcm: changed, sampleRate: 9997))
check(mismatch.bridgeMatches == false && mismatch.replayMatches == false && !mismatch.savedWAVMatches, "detect changed paths")
check(mismatch.replayFirstDifferentByte == 3 && mismatch.savedFirstDifferentByte == 3, "record changed byte")
check(!mismatch.rawCoverageComplete, "missing input never complete")
let unavailable = try capture.compare(pcm: pcm, replay: nil, context: Data("{}".utf8), index: 9, rate: 9997, savedWAV: wav)
check(unavailable.bridgeMatches == nil && unavailable.replayMatches == nil, "unavailable is not equality")
let invalid = try capture.compare(pcm: pcm, replay: nil, context: Data("{}".utf8), index: 11, rate: 9997, savedWAV: Data([1,2,3]))
check(!invalid.savedWAVValid && !invalid.savedWAVMatches, "invalid saved header retained as failure")
let invalidExport = try capture.export()
let invalidBundle = try JSONSerialization.jsonObject(with: Data(contentsOf: invalidExport)) as! [String:Any]
let invalidManifest = invalidBundle["manifest"] as! [String:Any]
check((invalidManifest["issues"] as! [String]).contains("invalid_saved_wav"), "invalid saved format explicitly marked")
let limited = try ReceiverComparison(root: root, byteLimit: 1)
check(rejects { try limited.captureRaw(Data([1,2]), index: 0) }, "capture bounded")
let limitURL = try limited.export()
let limitBundle = try JSONSerialization.jsonObject(with: Data(contentsOf: limitURL)) as! [String:Any]
check(((limitBundle["manifest"] as! [String:Any])["issues"] as! [String]).contains("capture_limit"), "limit visible in export")
print("ReceiverComparison: \(checks) checks passed")
