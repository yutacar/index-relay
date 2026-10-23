import SwiftUI
import UIKit

struct AutomaticRelayView: View {
    @ObservedObject var service: AutomaticRelayService
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsPresented = false
    @State private var isEditing = false
    var body: some View {
        NavigationStack {
            HistoryHomeList(service: service, store: service.store,
                            transcriptions: service.store.transcriptions, deliveries: DeliveryController.shared, isEditing: $isEditing)
                .navigationTitle("Index Relay")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(isEditing ? "完了" : "編集") { isEditing.toggle() }
                            .accessibilityLabel(isEditing ? "履歴の編集を完了" : "履歴を編集")
                            .accessibilityIdentifier("history.edit")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isEditing = false; settingsPresented = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("設定").accessibilityIdentifier("settings.open")
                    }
                }
        }
        .background { PrivacyShieldAnchor() }
        .sheet(isPresented: $settingsPresented, onDismiss: { service.maintainHistory() }) {
            RelaySettingsView(service: service)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.enterForeground(); DeliveryController.shared.enterForeground() }
            else if phase == .background { service.enterBackground(); DeliveryController.shared.enterBackground() }
        }
        .task { if scenePhase == .active { service.enterForeground(); DeliveryController.shared.enterForeground() } }
    }
}
struct RelaySettingsView: View {
    @ObservedObject var service: AutomaticRelayService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { AutomaticProcessingSettingsView(service: service) } label: { Label("リング・自動文字起こし", systemImage: "waveform") }
                NavigationLink { DeliverySettingsView(controller: DeliveryController.shared) } label: { Label("送り先・送信方法", systemImage: "paperplane") }
                NavigationLink { DeliveryOutboxView(controller: DeliveryController.shared) } label: { Label("送信一覧", systemImage: "tray") }
                NavigationLink { RelayDiagnosticsView(service: service) } label: { Label("診断・ログ", systemImage: "stethoscope") }
                Section {
                    Picker("表示・保存件数", selection: Binding(get: { service.historyLimit }, set: service.setHistoryLimit)) {
                        ForEach(Array(Set(HistoryPolicy.selectableLimits + [service.historyLimit])).sorted(), id: \.self) { limit in Text("\(limit)件").tag(limit) }
                    }
                    Text("初期値は30件です。件数を減らすと、超過した古い音声・文章をその場で削除します。手動削除も確認なしで実行します。")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("アプリ", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") / \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                    Text("アプリが非アクティブな間は表示を隠し、復帰すると戻します。受信・文字起こしは継続します。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
private struct AutomaticProcessingSettingsView: View {
    @ObservedObject var service: AutomaticRelayService
    var body: some View {
        List {
            Section("自動受信・文字起こし") {
                if let name = service.ringName {
                    LabeledContent("リング", value: name)
                    Toggle("自動で受信・文字起こし", isOn: Binding(get: { service.enabled }, set: service.setEnabled))
                }
                Text(service.status)
                NavigationLink(service.ringName == nil ? "最初にリングを選択" : "リングを選び直す") { AutomaticRingSetupView(service: service) }
                Text("一度リングを選んでオンにすると、リングで録音するだけで蓄積します。アプリを強制終了した場合は一度開いてください。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("処理状況") {
                LabeledContent("文字起こし待ち", value: "\(service.pendingCount)件")
                LabeledContent("要対応", value: "\(service.attentionCount)件")
                Text(service.backgroundStatus).font(.caption)
                LabeledContent("バックグラウンド更新", value: service.backgroundPermissionDescription)
                Text("ロック中も受信・保存します。処理が中断した分はバックグラウンド処理や次回起動で再開します。初回の日本語モデル準備はこの画面を開いたまま行ってください。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("未処理・要対応を再試行", action: service.retryPending).disabled(!service.enabled)
            }
        }.navigationTitle("リング・文字起こし")
    }
}
private struct RelayDiagnosticsView: View {
    @ObservedObject var service: AutomaticRelayService
    var body: some View {
        List {
            Section("自動処理のログ") {
                ShareLink(item: service.report) { Label("診断結果を共有", systemImage: "square.and.arrow.up") }
                Button("ログをクリア", action: service.clearEvents)
                ForEach(Array(service.events.suffix(25).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).textSelection(.enabled)
                }
            }
            Section("接続の詳細確認") {
                NavigationLink("Bluetooth・受信の診断画面") { BluetoothInspectorView() }.disabled(service.enabled)
                Text("診断画面を使う場合は、自動受信をオフにしてください。公式アプリのBluetooth許可は引き続きオフにします。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("診断・ログ")
    }
}

private struct AutomaticRingSetupView: View {
    @ObservedObject var service: AutomaticRelayService
    @StateObject private var inspector = BluetoothInspector()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                Text("初回だけ登録するリングを選びます。近くでリングのボタンを押すと検出しやすくなります。")
                Text(inspector.status).font(.caption)
                if inspector.authorizationDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("iPhoneの設定を開く", destination: settings)
                }
                Button("リングを探索", action: inspector.startScan).disabled(!inspector.canScan)
            }
            Section("見つかったリング") {
                ForEach(inspector.rings) { ring in
                    Button(ring.name) {
                        inspector.stopForBackground()
                        service.configure(ringID: ring.id.uuidString, name: ring.name)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("リングを選択")
        .task { if service.enabled { service.setEnabled(false) }; inspector.startScan() }
        .onDisappear { inspector.stopForBackground() }
    }
}
