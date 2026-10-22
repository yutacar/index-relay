import SwiftUI

struct DeliveryDestinationEditor: View {
    @ObservedObject var controller: DeliveryController
    let existing: DeliveryDestination?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prefix = ""
    @State private var provider: DeliveryProvider = .discord
    @State private var secret = ""
    @State private var chat = ""
    @State private var saving = false
    @State private var deletePrompt = false
    var body: some View {
        Form {
            Section("送り先") {
                TextField("表示名（例：自分のメモ）", text: $name)
                Picker("サービス", selection: $provider) {
                    ForEach(DeliveryProvider.allCases) { Text($0.title).tag($0) }
                }.disabled(existing != nil)
                SecureField(existing == nil ? (provider == .discord ? "Webhook URL" : "Botトークン")
                                            : "変更する場合のみ入力（空欄なら現在の値）", text: $secret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if provider == .telegram {
                    TextField("グループID（-123…／-100…／@group_name）", text: $chat)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Botを追加したグループまたはスーパーグループを指定してください。公開スーパーグループは@ユーザー名も使えます。個別DM・チャンネルへの投稿は対象外です。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let existing, !existing.isSupported {
                        Text("この送り先は対象外のため停止しました。グループを新しく追加してください。未完了の項目は送信一覧で確認できます。")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("接頭語（任意）") {
                TextField("例：/memo", text: $prefix)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("設定すると「接頭語＋半角スペース＋文字起こし本文」で送信します。空欄なら本文のみです。変更後に追加する文章から適用します。")
                    .font(.footnote).foregroundStyle(.secondary)
                if provider == .discord {
                    Text("メンションはユーザー・Botなら <@ユーザーID>、ロールなら <@&ロールID> と入力します。@名前だけではメンションになりません。接頭語で指定した相手だけ許可し、@everyone・@hereは抑制します。")
                        .font(.footnote).foregroundStyle(.secondary)
                    let policy = DiscordMentionPolicy.fromPrefix(prefix)
                    Text("メンション許可：ユーザー・Bot \(policy.users.count)件／ロール \(policy.roles.count)件")
                        .font(.caption)
                }
                LabeledContent("送信例") {
                    let leading = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(leading.isEmpty ? "文字起こし本文" : leading + " " + "文字起こし本文")
                        .textSelection(.enabled)
                }
            }
            Section {
                if provider == .discord {
                    Text("Discordの通常テキストチャンネルで、チャンネル設定 → 連携サービス → ウェブフックから作成し、URLを貼り付けてください。フォーラム・スレッド指定は現在対象外です。")
                } else {
                    Text("@BotFatherで作成したBotをグループに追加し、メッセージ送信を許可してください。BotトークンとグループIDを入力して登録します。開始用リンクや個別メッセージの候補取得は行いません。トピック指定は現在対象外です。")
                }
                Text("登録時はAPIで送り先情報を確認します。投稿は行いません。資格情報の変更時は登録済みと同じ送り先であることを照合します。別の送り先は新規追加してください。")
            }.font(.footnote).foregroundStyle(.secondary)
            Section {
                Button {
                    saving = true
                    Task {
                        let saved = await controller.saveDestination(existingID: existing?.id, name: name, provider: provider, secret: secret, chat: chat, prefix: prefix)
                        saving = false
                        if saved { dismiss() }
                    }
                } label: {
                    if saving { ProgressView("送り先を確認しています…") }
                    else { Text("送り先を確認して保存") }
                }.disabled(saving || (existing == nil && secret.isEmpty) || (provider == .telegram && chat.isEmpty) || (existing.map { !$0.isSupported } ?? false))
                Text(controller.status).font(.caption)
                if let existing {
                    Button("この送り先を削除", role: .destructive) { deletePrompt = true }
                        .disabled(saving)
                        .confirmationDialog("送り先を削除しますか？", isPresented: $deletePrompt) {
                            Button("削除", role: .destructive) {
                                controller.removeDestination(existing.id)
                                if !controller.state.destinations.contains(where: { $0.id == existing.id }) { dismiss() }
                            }
                        } message: { Text("未完了の送信がある場合は削除できません。送り先のスイッチで一時停止できます。") }
                }
            }
        }
        .disabled(!controller.ready)
        .navigationTitle(existing == nil ? "送り先を追加" : "送り先を変更")
        .interactiveDismissDisabled(saving)
        .task {
            if let existing {
                name = existing.name; provider = existing.provider; chat = existing.targetID; prefix = existing.prefix ?? ""
                // The stored credential is not loaded into the editor; a blank field keeps it.
            }
        }
    }
}
