import Foundation

/// Tracks one explicitly requested write; acknowledgement is not proof of a stored bond.
struct PairingProbe {
    enum State: Equatable {
        case notRun
        case pending
        case acknowledged
        case failed
        case interrupted
        case timedOut
    }

    private(set) var state: State = .notRun
    private(set) var connectionID: UUID?
    private(set) var detail = "未実施"

    @discardableResult
    mutating func begin(connectionID: UUID) -> Bool {
        guard state == .notRun else { return false }
        self.connectionID = connectionID
        state = .pending
        detail = "書き込み応答待ち。iPhoneのペアリング確認が出たら操作してください。"
        return true
    }

    @discardableResult
    mutating func finish(connectionID: UUID, outcome: State, detail: String) -> Bool {
        guard self.connectionID == connectionID, state == .pending,
              outcome != .notRun, outcome != .pending else { return false }
        state = outcome
        self.detail = detail
        return true
    }
}
