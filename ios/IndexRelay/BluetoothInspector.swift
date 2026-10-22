import Foundation
import Combine
@preconcurrency import CoreBluetooth

struct DiscoveredRing: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
}

struct GATTCharacteristic: Identifiable {
    let id = UUID()
    let uuid: String
    let properties: String
}

struct GATTService: Identifiable {
    let id: UUID
    let uuid: String
    let primary: Bool
    var characteristics: [GATTCharacteristic] = []
    var result = "確認中"
}

/// All CoreBluetooth callbacks are delivered on the main queue.
/// The only write is a manually requested 00 / withResponse pairing probe.
/// No characteristic values are read and no notifications are subscribed to.
@MainActor
final class BluetoothInspector: NSObject, ObservableObject {
    static let serviceUUID = "607B5C9B-3700-4E94-F44A-2DF900BCB0C3"
    static let channelUUID = "DAAD3D52-237C-90A7-B54B-8854A134D801"

    enum Phase: String {
        case idle, scanning, connecting, discovering, connected, pairing, disconnecting
    }

    @Published private(set) var bluetoothStatus = "未確認（探索開始で確認します）"
    @Published private(set) var status = "Index01を近くに置き、探索開始を押してください。"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rings: [DiscoveredRing] = []
    @Published private(set) var services: [GATTService] = []
    @Published private(set) var events: [String] = []
    @Published private(set) var selectedName: String?
    @Published private(set) var selectedID: UUID?
    @Published private(set) var expectedServiceFound = false
    @Published private(set) var expectedChannelFound = false
    @Published private(set) var probe = PairingProbe()
    @Published private(set) var connectionCount = 0
    @Published private(set) var connectionDuration = "未接続"
    @Published var showPairingConfirmation = false
    @Published var clearLogOnConnect = true

    private var connectionCounts: [UUID: Int] = [:]
    private var connectionID: UUID?
    private var connectedAt: TimeInterval?
    private var pairingCharacteristic: CBCharacteristic?
    private var pendingWriteCharacteristic: CBCharacteristic?
    private var requestedDisconnectReason: String?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var pendingScan = false
    private var timeout: Task<Void, Never>?
    private var serviceIDs: [ObjectIdentifier: UUID] = [:]
    private var pendingServices: Set<ObjectIdentifier> = []

    var canScan: Bool { phase == .idle }
    var canConnect: Bool { phase == .idle || phase == .scanning }
    var canDisconnect: Bool {
        phase == .connecting || phase == .discovering || phase == .connected || phase == .pairing
    }
    var canRefresh: Bool { phase == .connected }
    var canProbe: Bool {
        phase == .connected && pairingCharacteristic != nil && probe.state == .notRun
    }
    var canReconnect: Bool {
        guard phase == .idle, central?.state == .poweredOn, let selectedID else { return false }
        return peripherals[selectedID] != nil
    }
    var authorizationDenied: Bool { CBCentralManager.authorization == .denied }

    func reconnect() {
        guard canReconnect, let selectedID else { return }
        connect(to: selectedID)
    }

    func startPairingProbe() {
        guard canProbe, let peripheral = activePeripheral, peripheral.state == .connected,
              let characteristic = pairingCharacteristic, let connectionID,
              characteristic.uuid == CBUUID(string: Self.channelUUID),
              characteristic.service?.uuid == CBUUID(string: Self.serviceUUID),
              characteristic.properties.contains(.write),
              probe.begin(connectionID: connectionID) else { return }
        phase = .pairing
        pendingWriteCharacteristic = characteristic
        status = "ペアリング確認中です。iPhoneの確認ダイアログが出たら操作してください。"
        record("明示操作によるペアリング確認開始: 対象チャネルへ00を1回、withResponseで送信")
        peripheral.writeValue(Data([0x00]), for: characteristic, type: .withResponse)
        scheduleTimeout(seconds: 25) { inspector in
            guard inspector.probe.finish(connectionID: connectionID, outcome: .timedOut,
                                          detail: "25秒以内に応答を確認できませんでした。書き込み未実行とは断定できません。") else { return }
            inspector.pendingWriteCharacteristic = nil
            inspector.record(inspector.probe.detail)
            inspector.disconnect(reason: "ペアリング確認が時間切れになったため切断します。自動再試行はしません。")
        }
    }

    func startScan() {
        guard canScan else { return }
        pendingScan = true
        if central == nil {
            status = "Bluetoothの状態を確認しています。許可ダイアログが出たら許可してください。"
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScanIfReady()
        }
    }

    private func beginScanIfReady() {
        guard pendingScan, let central else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting { pendingScan = false }
            status = "Bluetoothを利用できません。表示された状態と設定を確認してください。"
            return
        }
        pendingScan = false
        rings = []
        peripherals = [:]
        phase = .scanning
        status = "30秒間探索します。Index01のボタンを押して起こしてください。"
        central.scanForPeripherals(withServices: [CBUUID(string: Self.serviceUUID)], options: nil)
        record("探索開始（対象サービスのみ）")
        scheduleTimeout(seconds: 30) { inspector in
            inspector.stopScan()
        }
    }

    func stopScan() {
        pendingScan = false
        guard phase == .scanning else { return }
        timeout?.cancel()
        central?.stopScan()
        phase = .idle
        status = rings.isEmpty
            ? "見つかりませんでした。リングのボタンを押し、もう一度探索してください。"
            : "探索を停止しました。接続する機器を選んでください。"
        record("探索停止・発見数 \(rings.count)")
    }

    func connect(to id: UUID) {
        guard canConnect, central?.state == .poweredOn, let peripheral = peripherals[id] else { return }
        stopScan()
        timeout?.cancel()
        activePeripheral = peripheral
        peripheral.delegate = self
        selectedID = id
        selectedName = rings.first(where: { $0.id == id })?.name ?? "Index01候補"
        connectionID = UUID()
        connectedAt = nil
        requestedDisconnectReason = nil
        connectionDuration = "接続待ち"
        connectionCount = connectionCounts[id, default: 0]
        probe = PairingProbe()
        resetServices()
        phase = .connecting
        status = "接続中です。必要ならリングのボタンを押してください。"
        if clearLogOnConnect { clearEvents() }
        record("接続要求")
        central?.connect(peripheral, options: nil)
        scheduleTimeout(seconds: 20) { inspector in
            inspector.disconnect(reason: "接続が20秒以内に完了しませんでした。")
        }
    }

    func disconnect() {
        disconnect(reason: "切断を要求しました。")
    }

    private func disconnect(reason: String) {
        guard canDisconnect, let peripheral = activePeripheral else { return }
        timeout?.cancel()
        interruptProbe(reason: "アプリの切断要求で確認を中断しました。未送信とは断定できません。")
        requestedDisconnectReason = reason
        phase = .disconnecting
        status = reason
        record(reason)
        central?.cancelPeripheralConnection(peripheral)
    }

    func refreshServices() {
        guard canRefresh, let peripheral = activePeripheral else { return }
        discoverServices(on: peripheral)
    }

    func stopForBackground() {
        pendingScan = false
        stopScan()
        if canDisconnect {
            disconnect(reason: "前面での確認を終了するため切断します。")
        }
    }

    private func resetServices() {
        services = []
        serviceIDs = [:]
        pendingServices = []
        expectedServiceFound = false
        expectedChannelFound = false
        pairingCharacteristic = nil
        pendingWriteCharacteristic = nil
    }

    private func interruptProbe(reason: String) {
        if let connectionID,
           probe.finish(connectionID: connectionID, outcome: .interrupted, detail: reason) {
            record(reason)
        }
        pendingWriteCharacteristic = nil
    }

    private func discoverServices(on peripheral: CBPeripheral) {
        resetServices()
        phase = .discovering
        status = "サービスとCharacteristicの情報を確認しています。"
        record("サービス探索開始")
        peripheral.discoverServices(nil)
        scheduleTimeout(seconds: 15) { inspector in
            inspector.disconnect(reason: "情報取得が15秒以内に完了しませんでした。取得済み情報を残して切断します。")
        }
    }

    func clearEvents() { events = [] }

    private func record(_ message: String) {
        events.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(message)")
        if events.count > 150 { events.removeFirst(events.count - 150) }
    }

    private func scheduleTimeout(seconds: Int, action: @escaping @MainActor (BluetoothInspector) -> Void) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private func finishDiscoveryIfReady() {
        guard pendingServices.isEmpty else { return }
        timeout?.cancel()
        phase = .connected
        status = "情報取得が終了しました。ペアリング確認は専用ボタンから実行できます。録音取得は未確認です。"
        record("サービス情報取得終了・対象サービス \(expectedServiceFound)・対象チャネル \(expectedChannelFound)")
    }

    private func errorCode(_ error: Error) -> String {
        let value = error as NSError
        // Do not include userInfo / localizedDescription, which can contain device information.
        var label: String?
        if value.domain == CBErrorDomain {
            switch CBError.Code(rawValue: value.code) {
            case .peripheralDisconnected: label = "周辺機器の切断"
            case .connectionTimeout: label = "接続タイムアウト"
            case .connectionFailed: label = "接続失敗"
            case .operationCancelled: label = "操作取消"
            case .peerRemovedPairingInformation: label = "相手機器のペアリング情報が失われた"
            default: break
            }
        } else if value.domain == CBATTErrorDomain {
            switch CBATTError.Code(rawValue: value.code) {
            case .insufficientAuthentication: label = "認証不足"
            case .insufficientEncryption: label = "暗号化不足"
            case .writeNotPermitted: label = "書き込み不可"
            default: break
            }
        }
        return "\(value.domain) / \(value.code)" + (label.map { "（\($0)）" } ?? "")
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        let pairs: [(CBCharacteristicProperties, String)] = [
            (.read, "Read"), (.write, "Write"), (.writeWithoutResponse, "Write without response"),
            (.notify, "Notify"), (.indicate, "Indicate"), (.broadcast, "Broadcast"),
            (.authenticatedSignedWrites, "Signed writes"), (.extendedProperties, "Extended"),
            (.notifyEncryptionRequired, "Encrypted notify"), (.indicateEncryptionRequired, "Encrypted indicate")
        ]
        let names = pairs.compactMap { properties.contains($0.0) ? $0.1 : nil }
        return names.isEmpty ? "なし" : names.joined(separator: ", ")
    }

    var diagnosticReport: String {
        var lines = [
            "Index Relay Bluetooth確認", "日時: \(Date.now.ISO8601Format())",
            "アプリ版: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "不明") / \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "不明")",
            "Bluetooth: \(bluetoothStatus)", "状態: \(phase.rawValue)", status,
            "発見数: \(rings.count)",
            "対象サービス確認: \(expectedServiceFound)", "対象チャネル確認: \(expectedChannelFound)",
            "選択機器の接続成功回数（この画面中）: \(connectionCount)",
            "接続時間: \(connectionDuration)",
            "ペアリング確認: \(probe.state) / \(probe.detail)",
            "書き込みは明示操作による対象チャネルへの00 / withResponseのみ。",
            "ボンディング保存の直接確認・値の読み出し・通知購読・録音削除・DFUなし。"
        ]
        for service in services {
            lines.append("Service \(service.uuid) / \(service.result)")
            for characteristic in service.characteristics {
                lines.append("  \(characteristic.uuid) : \(characteristic.properties)")
            }
        }
        lines.append("イベント（この起動中・最大150件）")
        lines.append(contentsOf: events)
        return lines.joined(separator: "\n")
    }
}

extension BluetoothInspector: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothStatus = "利用可能"
        case .poweredOff: bluetoothStatus = "Bluetoothがオフ"
        case .unauthorized: bluetoothStatus = "利用許可なし（設定を確認）"
        case .unsupported: bluetoothStatus = "この環境では利用不可"
        case .resetting: bluetoothStatus = "再初期化中"
        case .unknown: bluetoothStatus = "確認中"
        @unknown default: bluetoothStatus = "未対応の状態"
        }
        record("Bluetooth状態: \(bluetoothStatus)")
        if central.state == .poweredOn {
            beginScanIfReady()
        } else {
            timeout?.cancel()
            interruptProbe(reason: "Bluetooth状態の変化により確認を中断しました。")
            if let connectedAt {
                connectionDuration = String(format: "%.1f秒（Bluetooth状態変化で終了）", ProcessInfo.processInfo.systemUptime - connectedAt)
                record("接続時間: \(connectionDuration)")
            }
            activePeripheral?.delegate = nil
            activePeripheral = nil
            pairingCharacteristic = nil
            connectionID = nil
            connectedAt = nil
            phase = .idle
            status = "\(bluetoothStatus)。利用可能になったら探索開始を押してください。"
            if central.state != .unknown && central.state != .resetting { pendingScan = false }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning else { return }
        peripherals[peripheral.identifier] = peripheral
        let ring = DiscoveredRing(
            id: peripheral.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Index01候補",
            rssi: RSSI.intValue
        )
        if let index = rings.firstIndex(where: { $0.id == ring.id }) {
            rings[index] = ring
        } else {
            rings.append(ring)
            record("対象サービスを広告する機器を発見")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === activePeripheral else { return }
        guard phase == .connecting else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        record("接続成功（ボンディングの成立とは別）")
        connectedAt = ProcessInfo.processInfo.systemUptime
        connectionDuration = "接続中（切断時に確定）"
        connectionCounts[peripheral.identifier, default: 0] += 1
        connectionCount = connectionCounts[peripheral.identifier, default: 0]
        record("選択機器の接続成功回数: \(connectionCount)")
        discoverServices(on: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnection(peripheral, message: "接続に失敗しました。", error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finishConnection(peripheral, message: "切断しました。取得済み情報は確認できます。", error: error)
    }

    private func finishConnection(_ peripheral: CBPeripheral, message: String, error: Error?) {
        guard peripheral === activePeripheral else { return }
        timeout?.cancel()
        interruptProbe(reason: "応答確認前に接続が終了しました。書き込み結果は未確認です。")
        if let connectedAt {
            connectionDuration = String(format: "%.1f秒", ProcessInfo.processInfo.systemUptime - connectedAt)
        } else {
            connectionDuration = "接続未成立"
        }
        record("接続時間: \(connectionDuration)")
        record(requestedDisconnectReason.map { "アプリ切断要求あり: \($0)" } ?? "アプリ切断要求なし（原因はエラーだけでは特定不可）")
        peripheral.delegate = nil
        activePeripheral = nil
        pairingCharacteristic = nil
        connectionID = nil
        connectedAt = nil
        pendingServices = []
        phase = .idle
        status = message + (error.map { " エラー: \(errorCode($0))" } ?? "")
        record(status)
    }
}

extension BluetoothInspector: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === activePeripheral, phase == .discovering else { return }
        if let error {
            record("サービス取得失敗: \(errorCode(error))")
            disconnect(reason: "サービス情報を取得できませんでした。イベントを確認してください。")
            return
        }
        let found = peripheral.services ?? []
        for service in found {
            let key = ObjectIdentifier(service)
            let id = UUID()
            serviceIDs[key] = id
            pendingServices.insert(key)
            services.append(GATTService(id: id, uuid: service.uuid.uuidString, primary: service.isPrimary))
            if service.uuid == CBUUID(string: Self.serviceUUID) { expectedServiceFound = true }
        }
        record("サービス数: \(found.count)")
        for service in found { peripheral.discoverCharacteristics(nil, for: service) }
        finishDiscoveryIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === activePeripheral, phase == .discovering else { return }
        let key = ObjectIdentifier(service)
        guard pendingServices.remove(key) != nil,
              let id = serviceIDs[key], let index = services.firstIndex(where: { $0.id == id }) else { return }
        if let error {
            services[index].result = "取得失敗: \(errorCode(error))"
            record("Characteristic取得失敗: \(errorCode(error))")
        } else {
            let found = service.characteristics ?? []
            services[index].characteristics = found.map {
                GATTCharacteristic(uuid: $0.uuid.uuidString, properties: describe($0.properties))
            }
            services[index].result = "\(found.count)件"
            if service.uuid == CBUUID(string: Self.serviceUUID),
               let channel = found.first(where: { $0.uuid == CBUUID(string: Self.channelUUID) }) {
                expectedChannelFound = true
                if channel.properties.contains(.write) { pairingCharacteristic = channel }
            }
        }
        finishDiscoveryIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === activePeripheral, phase == .pairing,
              characteristic === pendingWriteCharacteristic, let connectionID else { return }
        let detail = error.map { "書き込み失敗: \(errorCode($0))" }
            ?? "対象チャネルへの書き込み応答成功。暗号化状態・ボンディング保存は直接確認していません。"
        guard probe.finish(connectionID: connectionID,
                           outcome: error == nil ? .acknowledged : .failed, detail: detail) else { return }
        timeout?.cancel()
        pendingWriteCharacteristic = nil
        phase = .connected
        status = detail
        record(detail)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === activePeripheral else { return }
        record("サービス情報が変更されました。再接続して取得し直してください。")
        if canDisconnect { disconnect(reason: "サービス変更を検出したため切断します。再接続してください。") }
    }
}
