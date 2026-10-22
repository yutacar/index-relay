import Foundation

struct TransferContext: Codable, Equatable {
    let start: Int64
    let releasedMs: Int64?
    let completedMs: Int64
    let buttonSequencePresent: Bool
    let batteryVoltageMilliV: Int?

    init(start: Int64, releasedMs: Int64?, completedMs: Int64, buttonSequencePresent: Bool,
         batteryVoltageMilliV: Int? = nil) {
        self.start = start
        self.releasedMs = releasedMs
        self.completedMs = completedMs
        self.buttonSequencePresent = buttonSequencePresent
        self.batteryVoltageMilliV = batteryVoltageMilliV
    }

    var validBatteryVoltageMilliV: Int? {
        guard let batteryVoltageMilliV, (1...65534).contains(batteryVoltageMilliV) else { return nil }
        return batteryVoltageMilliV
    }

    func addingBatteryVoltage(from newer: TransferContext) -> TransferContext {
        guard validBatteryVoltageMilliV == nil, let voltage = newer.validBatteryVoltageMilliV else { return self }
        return TransferContext(start: start, releasedMs: releasedMs, completedMs: completedMs,
                               buttonSequencePresent: buttonSequencePresent, batteryVoltageMilliV: voltage)
    }

    var releaseDate: Date? {
        guard let releasedMs, (1_577_836_800_000...4_102_444_800_000).contains(releasedMs) else { return nil }
        return Date(timeIntervalSince1970: Double(releasedMs) / 1000)
    }
}

struct ReceivedRecording: Codable, Identifiable {
    let id: String
    let receivedAt: Date
    let sampleRate: Int
    let sampleCount: Int
    let collectionIndex: Int
    let contiguous: Bool
    let transfer: TransferContext?

    var batteryVoltageText: String {
        guard let voltage = transfer?.validBatteryVoltageMilliV else { return "不明" }
        return String(format: "%.3f V（%d mV）", Double(voltage) / 1000, voltage)
    }

    var recordedAt: Date { transfer?.releaseDate ?? receivedAt }
    var duration: Double { Double(sampleCount) / Double(sampleRate) }
}
