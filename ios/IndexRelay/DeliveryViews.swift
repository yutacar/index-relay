import SwiftUI
import UIKit

struct DeliveryHomeSection: View {
    @ObservedObject var controller: DeliveryController
    var body: some View {
        Section("Discord・Telegram・hi.newへの送信") {
            NavigationLink("送り先・送信方法の設定") { DeliverySettingsView(controller: controller) }
            NavigationLink {
                DeliveryOutboxView(controller: controller)
            } label: {
                LabeledContent("送信一覧", value: "確認待ち \(controller.state.jobs.filter { $0.phase == .confirmation }.count)件")
            }
            Text(controller.state.requiresConfirmation ? "文字起こし後、本文を確認してから送信します。" : "新しい文字起こしを、選択した送り先へ自動送信します。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
struct DeliverySettingsView: View {
    @ObservedObject var controller: DeliveryController
    var body: some View {
        List {
            Section("送信方法") {
                Toggle("送信前に確認する", isOn: Binding(get: { controller.state.requiresConfirmation }, set: controller.setConfirmation))
                    .disabled(!controller.ready)
                Text("オン：送信一覧で本文を確認・編集して送信。オフ：新しい文字起こしを自動送信。変更は次の文字起こしから適用し、既存の送信待ち・確認待ちは変更しません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("送り先（複数選択可）") {
                ForEach(controller.state.destinations) { destination in
                    VStack(alignment: .leading) {
                        Toggle(isOn: Binding(get: { controller.state.destinations.first(where: { $0.id == destination.id })?.enabled ?? false },
                                             set: { controller.setDestinationEnabled(destination.id, enabled: $0) })) {
                            Text(destination.name)
                            Text("\(destination.provider.title) · \(destination.isSupported ? "" : "対象外・停止 · ")\(destination.targetID)").font(.caption).foregroundStyle(.secondary)
                        }.disabled(!controller.ready || !destination.isSupported)
                        if destination.provider == .hiNew {
                            Button("テスト文を確認待ちに追加") { controller.enqueueHiNewTest(destination.id) }
                                .disabled(!destination.enabled || !controller.ready)
                                .font(.caption)
                        }
                        NavigationLink("設定・資格情報を変更") { DeliveryDestinationEditor(controller: controller, existing: destination) }
                            .font(.caption)
                    }
                }
                NavigationLink("送り先を追加") { DeliveryDestinationEditor(controller: controller, existing: nil) }
                    .disabled(!controller.ready)
                Text("オンの送り先すべてに送ります。オフにすると、その送り先の未送信分も一時停止します。送信開始済みの分は継続します。送り先・確認方法は文字起こし保存時に確定します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("確認待ち・要対応の通知") {
                LabeledContent("通知", value: controller.notificationStatus)
                Button("通知を有効にする") { Task { await controller.enableNotifications() } }
                if let url = URL(string: UIApplication.openSettingsURLString) { Link("iPhoneの設定を開く", destination: url) }
                Text("ロック画面の通知には文字起こし本文や送り先名を表示しません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text(controller.status).font(.callout).textSelection(.enabled)
                Text("Webhook URL・各サービスのトークンはこの端末のKeychainに保存します。送信するのは文章のみです。自動送信はiOSの通信制約で遅れる場合があります。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("送り先設定")
    }
}
struct DeliveryOutboxView: View {
    @ObservedObject var controller: DeliveryController
    @State private var showCompleted = false
    @State private var showHistory = false
    var body: some View {
        List {
            Section {
                Toggle("送信済み・送信しない項目も表示", isOn: $showCompleted)
                Button("保存済みの文章を追加") { showHistory = true }
                    .disabled(!controller.state.destinations.contains(where: \.enabled))
                Text("文字起こしごと・送り先ごとに確認できます。複数の送り先は個別に送信状況を保存します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(controller.state.jobs.reversed().filter { showCompleted || ![.sent, .cancelled].contains($0.phase) }) { job in
                NavigationLink {
                    DeliveryJobDetail(controller: controller, id: job.id, initialText: job.text)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(job.destinationName); Spacer(); Text(job.provider == .hiNew && job.phase == .sent ? "hi.new受付済み" : job.phase.title).foregroundStyle(job.phase == .unknown ? .orange : .secondary) }
                        Text(job.text).lineLimit(2).font(.caption)
                        Text(job.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if job.canDeleteTest {
                        Button("テスト履歴を削除", role: .destructive) { controller.deleteCompletedTest(job.id) }
                    }
                }
            }
            if controller.state.jobs.isEmpty { Text("新しい文字起こしを待っています。過去の文章は上のボタンから追加できます。") }
            Section {
                Text(controller.status).font(.caption)
                Text(controller.backgroundStatus).font(.caption).foregroundStyle(.secondary)
                ShareLink(item: controller.report) { Label("送信診断を共有", systemImage: "square.and.arrow.up") }
            }
        }
        .navigationTitle("送信一覧")
        .sheet(isPresented: $showHistory) { DeliveryHistoryPicker(controller: controller) }
    }
}
struct DeliveryJobDetail: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: DeliveryController
    let id: UUID
    let initialText: String
    @State private var text = ""
    @State private var unknownPrompt = false
    private var job: DeliveryJob? { controller.state.jobs.first { $0.id == id } }
    var body: some View {
        Form {
            if let job {
                Section {
                    LabeledContent("送り先", value: job.destinationName)
                    LabeledContent("状態", value: job.phase.title)
                    if job.provider == .discord {
                        let policy = job.discordMentions ?? DiscordMentionPolicy()
                        Text("メンション許可：ユーザー・Bot \(policy.users.count)件／ロール \(policy.roles.count)件")
                            .font(.caption)
                        if !policy.users.isEmpty { Text("ユーザー・Bot ID：" + policy.users.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
                        if !policy.roles.isEmpty { Text("ロール ID：" + policy.roles.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
                    }
                    if !controller.state.destinations.contains(where: { $0.id == job.destinationID && $0.enabled }) {
                        Text("送り先がオフのため送信を一時停止しています。設定でオンにすると再開します。")
                    }
                    if let detail = job.detail { Text(detail).font(.callout) }
                    if let date = job.retryAfter { Text("再試行予定：\(date.formatted())").font(.caption) }
                    if let messageID = job.messageID { Text("メッセージID：\(messageID)").font(.caption).textSelection(.enabled) }
                }
                if job.provider == .hiNew {
                    Section("hi.newの受付") {
                        Text("送信済みはhi.newへの受付です。受信側の保存・要約・通知完了は追跡しません。")
                        if let date = job.hiNewExpiresAt { Text("未ACK本文の期限：\(date.formatted())").font(.caption) }
                        if job.textIsFrozen { Text("送信開始後は本文と送信キーを固定します。初回送信から24時間以内だけ、同じ内容を再送できます。") }
                    }
                }
                Section("送信する文章") {
                    if [.confirmation, .needsAttention].contains(job.phase) && !job.textIsFrozen {
                        TextEditor(text: $text).frame(minHeight: 180)
                        Text("\(job.provider.textSize(text)) / \(job.provider.limit)\(job.provider.sizeUnit)").font(.caption)
                    } else { Text(job.text).textSelection(.enabled) }
                    if [.confirmation, .needsAttention].contains(job.phase) {
                        Button(job.textIsFrozen ? "同じ内容で再送する" : "この内容で送信") { controller.approve(id, text: job.textIsFrozen ? job.text : text) }
                            .disabled(!DeliveryArchive.validText(text, for: job.provider))
                    }
                    if job.phase == .retryWaiting { Button("再試行を予約") { controller.retry(id) } }
                    if job.phase == .unknown {
                        Button("送り先で投稿を確認済み") { controller.markSent(id) }
                        Button("再送せず終了する") { controller.dismissUnknown(id) }
                        Button("送り先を確認して再送…", role: .destructive) { unknownPrompt = true }
                    }
                    if ![.sending, .sent, .unknown, .cancelled].contains(job.phase) {
                        Button("送信しない", role: .destructive) { controller.cancel(id) }
                    }
                }
                if job.canDeleteTest {
                    Section {
                        Button("このテスト履歴を削除", role: .destructive) {
                            controller.deleteCompletedTest(id)
                            if !controller.state.jobs.contains(where: { $0.id == id }) { dismiss() }
                        }
                    }
                }
                Section { Text(controller.status).font(.caption) }
            }
        }
        .disabled(!controller.ready)
        .navigationTitle("送信の確認")
        .task { text = initialText }
        .confirmationDialog("重複投稿になる可能性があります", isPresented: $unknownPrompt, titleVisibility: .visible) {
            Button("確認済み・再送する", role: .destructive) { controller.retry(id, allowUnknown: true) }
        } message: { Text(job?.provider == .hiNew ? "hi.newは初回送信から24時間以内、同じ本文・同じ送信キーで再照合します。受付済みでも受信側の処理完了は確認できません。" : "Discord／Telegramで前回の投稿が存在しないことを確認してから再送してください。") }
    }
}
private struct DeliveryHistoryPicker: View {
    @ObservedObject var controller: DeliveryController
    @Environment(\.dismiss) private var dismiss
    @State private var records: [TranscriptRecord] = []
    var body: some View {
        NavigationStack {
            List {
                Text("選んだ文章をオンの送り先へ追加します。自動送信設定でも、過去の文章は確認待ちになります。同じ送り先へ追加済みの文章は重複追加しません。")
                    .font(.footnote)
                ForEach(records, id: \.recordingID) { record in
                    Button {
                        controller.enqueueExisting(record); dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(record.createdAt.formatted()).font(.caption)
                            Text(record.text).lineLimit(3)
                        }
                    }
                }
            }
            .navigationTitle("保存済みの文章")
            .toolbar { Button("閉じる") { dismiss() } }
        }.task {
            let deleted = (try? HistoryArchive(root: .applicationSupportDirectory).state.deletedIDs) ?? []
            records = ((try? TranscriptArchive(folder: URL.applicationSupportDirectory.appendingPathComponent("Transcripts")).loadAll()) ?? [:]).values.filter { !deleted.contains($0.recordingID) }.sorted { $0.createdAt > $1.createdAt }
        }
    }
}
