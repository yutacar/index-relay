import SwiftUI

struct BluetoothInspectorView: View {
    @StateObject private var inspector = BluetoothInspector()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section("Bluetooth確認") {
                LabeledContent("Bluetooth", value: inspector.bluetoothStatus)
                Text(inspector.status)
                    .accessibilityIdentifier("bluetooth.status")
                if inspector.authorizationDenied {
                    Button("アプリの設定を開く") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                }
                if inspector.phase == .scanning {
                    Button("探索を停止", action: inspector.stopScan)
                } else {
                    Button("探索開始", action: inspector.startScan)
                        .disabled(!inspector.canScan)
                }
                Text("Index01のボタンを押すと探索しやすくなります。探索は30秒で停止します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("見つかった機器（\(inspector.rings.count)）") {
                if inspector.rings.isEmpty {
                    Text("対象サービスを広告する機器がここに表示されます。")
                        .foregroundStyle(.secondary)
                }
                ForEach(inspector.rings) { ring in
                    Button {
                        inspector.connect(to: ring.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ring.name)
                                Text(ring.rssi == 127 ? "電波強度：不明" : "電波強度：\(ring.rssi) dBm")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(inspector.selectedID == ring.id && !inspector.canConnect ? "選択中" : "接続")
                        }
                    }
                    .disabled(!inspector.canConnect)
                }
            }

            if let name = inspector.selectedName {
                Section("選択した機器") {
                    Text(name)
                    LabeledContent("対象サービス", value: inspector.expectedServiceFound ? "確認済み" : "未確認")
                    LabeledContent("対象チャネル", value: inspector.expectedChannelFound ? "確認済み" : "未確認")
                    LabeledContent("接続成功回数", value: "\(inspector.connectionCount)")
                    LabeledContent("接続時間", value: inspector.connectionDuration)
                    Button("選択した機器に再接続", action: inspector.reconnect)
                        .disabled(!inspector.canReconnect)
                    Button("サービス情報を再取得", action: inspector.refreshServices)
                        .disabled(!inspector.canRefresh)
                    Button("切断", role: .destructive, action: inspector.disconnect)
                        .disabled(!inspector.canDisconnect)
                    if let id = inspector.selectedID {
                        NavigationLink("この機器の録音受信を確認") {
                            RecordingReceiverView(ringID: id.uuidString)
                        }
                        .disabled(!inspector.canReconnect)
                        Text("録音受信へ進む前に「切断」を押し、切断完了を待ってください。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("ペアリング確認") {
                    Text(inspector.probe.detail)
                    Button("ペアリング確認を開始") { inspector.showPairingConfirmation = true }
                        .disabled(!inspector.canProbe)
                    Text("接続後、1接続につき1回実行できます。iPhoneの確認が表示されたら操作してください。次の確認は切断・再接続してから行います。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("書き込み成功だけでボンディング情報の保存は断定しません。再接続時に確認ダイアログが出たかも記録してください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            ForEach(inspector.services) { service in
                Section {
                    Text(service.uuid).font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("種類", value: service.primary ? "Primary" : "Secondary")
                    Text(service.result).font(.caption).foregroundStyle(.secondary)
                    ForEach(service.characteristics) { characteristic in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(characteristic.uuid).font(.caption.monospaced()).textSelection(.enabled)
                            Text(characteristic.properties).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Service") }
            }

            Section("確認結果") {
                Toggle("接続時にログをクリア", isOn: $inspector.clearLogOnConnect)
                Button("ログをクリア", action: inspector.clearEvents)
                    .disabled(inspector.events.isEmpty)
                ShareLink(item: inspector.diagnosticReport) {
                    Label("確認結果を共有", systemImage: "square.and.arrow.up")
                }
                .disabled(inspector.events.isEmpty)
                Text("共有内容はGATTのUUID・属性とイベント時刻です。機器名・端末固有ID・音声は含めません。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(Array(inspector.events.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.caption.monospaced()).textSelection(.enabled)
                }
            }

            Section {
                Text("この版は前面での接続・ペアリング確認用です。専用ボタンで対象チャネルに1バイト（00）を書き込みます。値の読み出し・通知購読・録音消去・ファームウェア更新は行いません。録音取得・ロック中の動作は未実装です。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Index01 接続確認")
        .confirmationDialog("ペアリング確認を実行しますか？", isPresented: $inspector.showPairingConfirmation, titleVisibility: .visible) {
            Button("00を書き込んで確認") { inspector.startPairingProbe() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("公式iOSコードと同じ対象チャネルへ、応答ありで00を1回送ります。録音消去や更新コマンドは送りません。")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { inspector.stopForBackground() }
        }
        .onDisappear { inspector.stopForBackground() }
    }
}
