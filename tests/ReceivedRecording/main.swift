import Foundation

var checks = 0
@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    precondition(condition(), label)
}
let legacy = Data("""
{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","receivedAt":0,"sampleRate":9997,"sampleCount":19994,"collectionIndex":47,"contiguous":true}
""".utf8)
let old = try JSONDecoder().decode(ReceivedRecording.self, from: legacy)
expect(old.transfer == nil, "Existing recordings without context remain readable")
expect(old.duration == 2, "Original duration unchanged")
let contextData = Data("""
{"start":43,"releasedMs":1792382400000,"completedMs":1792382401000,"buttonSequencePresent":true}
""".utf8)
let context = try JSONDecoder().decode(TransferContext.self, from: contextData)
expect(context.start == 43, "Collection range start decoded")
expect(context.releaseDate?.timeIntervalSince1970 == 1792382400, "Milliseconds interpreted correctly")
let updated = ReceivedRecording(id: old.id, receivedAt: old.receivedAt, sampleRate: old.sampleRate,
    sampleCount: old.sampleCount, collectionIndex: old.collectionIndex, contiguous: old.contiguous, transfer: context)
let reloaded = try JSONDecoder().decode(ReceivedRecording.self, from: JSONEncoder().encode(updated))
expect(reloaded.id == old.id && reloaded.receivedAt == old.receivedAt, "Enrichment keeps identity and received date")
expect(reloaded.transfer?.start == 43 && reloaded.transfer?.buttonSequencePresent == true, "New context round trip")
let missing = try JSONDecoder().decode(TransferContext.self, from: Data("{\"start\":0,\"releasedMs\":null,\"completedMs\":0,\"buttonSequencePresent\":false}".utf8))
expect(missing.releaseDate == nil, "Missing release timestamp stays unknown")
let invalidDate = TransferContext(start: 0, releasedMs: -1, completedMs: 0, buttonSequencePresent: false)
expect(invalidDate.releaseDate == nil, "Invalid ring clock not displayed as real date")
do {
    _ = try JSONDecoder().decode(TransferContext.self, from: Data("{\"start\":47}".utf8))
    fatalError("Malformed bridge context accepted")
} catch { checks += 1 }
expect(old.batteryVoltageText == "不明", "Legacy recording without transfer has no invented voltage")
expect(context.batteryVoltageMilliV == nil, "Legacy transfer without voltage remains readable")
let measured = TransferContext(start: 43, releasedMs: 1792382400000, completedMs: 1792382401000,
    buttonSequencePresent: true, batteryVoltageMilliV: 3012)
let measuredClip = ReceivedRecording(id: old.id, receivedAt: old.receivedAt, sampleRate: old.sampleRate,
    sampleCount: old.sampleCount, collectionIndex: old.collectionIndex, contiguous: old.contiguous, transfer: measured)
let voltageReloaded = try JSONDecoder().decode(ReceivedRecording.self, from: JSONEncoder().encode(measuredClip))
expect(voltageReloaded.transfer?.batteryVoltageMilliV == 3012, "Voltage persists per recording")
expect(voltageReloaded.batteryVoltageText == "3.012 V（3012 mV）", "Voltage rendered without percentage estimation")
expect(voltageReloaded.recordedAt == updated.recordedAt && voltageReloaded.id == updated.id, "Voltage does not alter identity or time")
for invalid in [0, -1, 65535, 65536] {
    let invalidContext = TransferContext(start: 0, releasedMs: nil, completedMs: 0, buttonSequencePresent: false, batteryVoltageMilliV: invalid)
    expect(invalidContext.validBatteryVoltageMilliV == nil, "Invalid voltage remains unknown")
}
let backfilled = context.addingBatteryVoltage(from: measured)
expect(backfilled.batteryVoltageMilliV == 3012, "Re-receipt can enrich missing voltage")
expect(backfilled.start == context.start && backfilled.releasedMs == context.releasedMs && backfilled.completedMs == context.completedMs,
       "Enrichment preserves original recording context")
expect(measured.addingBatteryVoltage(from: context) == measured, "Missing new metadata cannot erase known voltage")
let changedVoltage = TransferContext(start: 1, releasedMs: nil, completedMs: 0, buttonSequencePresent: false, batteryVoltageMilliV: 2800)
expect(measured.addingBatteryVoltage(from: changedVoltage) == measured, "Re-receipt does not replace an existing measurement")
print("ReceivedRecording: \(checks) checks passed")
