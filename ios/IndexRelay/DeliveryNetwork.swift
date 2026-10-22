import Foundation
import CoreFoundation

enum DeliveryCredentialError: Error { case required }
struct DeliveryCredential: Codable, Sendable {
    var secret: String
    /// Read an existing credential only when saving an edit with a blank replacement.
    static func resolve(_ input: String, existingID: UUID?, load: (UUID) throws -> DeliveryCredential) throws -> String {
        let replacement = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !replacement.isEmpty { return replacement }
        guard let existingID else { throw DeliveryCredentialError.required }
        let stored = try load(existingID).secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { throw DeliveryCredentialError.required }
        return stored
    }
}
enum DeliveryNetworkError: Error, LocalizedError {
    case invalidWebhook, invalidToken, invalidChat, groupChatRequired, rejected(Int), invalidResponse, network(Int)
    var errorDescription: String? {
        switch self {
        case .invalidWebhook: "DiscordのWebhook URLを確認してください（通常のテキストチャンネル用）。"
        case .invalidToken: "TelegramのBotトークンを確認してください。"
        case .invalidChat: "TelegramのチャットIDを入力してください。"
        case .groupChatRequired: "Telegramはグループとスーパーグループへの投稿のみ対応しています。DM・チャンネルは登録できません。"
        case .rejected(let code): "送り先の確認に失敗しました（HTTP \(code)）。権限・URL・トークン・チャットIDを確認してください。"
        case .invalidResponse: "送り先情報を確認できませんでした。"
        case .network(let code): "通信に失敗しました（コード \(code)）。通信環境を確認してください。"
        }
    }
}
// No redirects: credentials must never be forwarded to another origin.
final class DeliveryValidationDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct DeliveryAPI {
    static func discordURL(_ secret: String, posting: Bool = false) throws -> URL {
        guard let parts = URLComponents(string: secret.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", ["discord.com", "discordapp.com"].contains(parts.host ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.query == nil,
              parts.percentEncodedPath.range(of: #"^/api/(?:v[0-9]+/)?webhooks/[0-9]+/[A-Za-z0-9._-]+/?$"#, options: .regularExpression) != nil else {
            throw DeliveryNetworkError.invalidWebhook
        }
        // Use one official API host even when an older URL was pasted.
        var result = parts; result.host = "discord.com"
        result.path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        if posting { result.queryItems = [URLQueryItem(name: "wait", value: "true")] }
        guard let url = result.url else { throw DeliveryNetworkError.invalidWebhook }; return url
    }
    static func telegramURL(_ token: String, method: String) throws -> URL {
        guard token.range(of: #"^[0-9]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              ["getMe", "getChat", "sendMessage"].contains(method),
              let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw DeliveryNetworkError.invalidToken }
        return url
    }
    static func request(destination: DeliveryDestination, credential: DeliveryCredential, text: String, discordMentions: DiscordMentionPolicy? = nil) throws -> (URLRequest, Data) {
        guard destination.isSupported else { throw DeliveryStoreError.unsupportedTarget }
        guard DeliveryArchive.validText(text, for: destination.provider) else { throw DeliveryStoreError.invalidText }
        let url: URL; let object: [String: Any]
        switch destination.provider {
        case .discord:
            url = try discordURL(credential.secret, posting: true)
            let policy = discordMentions ?? DiscordMentionPolicy()
            object = ["content": text, "allowed_mentions": ["parse": [String](), "users": policy.users, "roles": policy.roles]]
        case .telegram:
            url = try telegramURL(credential.secret, method: "sendMessage")
            object = ["chat_id": destination.targetID, "text": text, "link_preview_options": ["is_disabled": true]]
            // Deliberately omit parse_mode: recognized symbols are plain text.
        }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        return (request, try JSONSerialization.data(withJSONObject: object))
    }
    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: DeliveryValidationDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data; let response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch { throw DeliveryNetworkError.network((error as NSError).code) }
        guard let http = response as? HTTPURLResponse else { throw DeliveryNetworkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw DeliveryNetworkError.rejected(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeliveryNetworkError.invalidResponse }
        return json
    }
    static func telegramGroup(from json: [String: Any], botID: String) throws -> DeliveryDestination {
        guard json["ok"] as? Bool == true, let target = json["result"] as? [String: Any],
              let kind = target["type"] as? String else { throw DeliveryNetworkError.invalidResponse }
        guard ["group", "supergroup"].contains(kind) else { throw DeliveryNetworkError.groupChatRequired }
        guard let id = numericID(target["id"], negative: true),
              numericIDString(botID, negative: false) else { throw DeliveryNetworkError.invalidResponse }
        let title = (target["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DeliveryDestination(id: UUID(), name: title.isEmpty ? "Telegramグループ" : String(title.prefix(80)),
            provider: .telegram, targetID: id, targetKind: kind,
            identity: "telegram:\(botID):\(id):\(kind)", enabled: true)
    }
    static func numericIDString(_ value: String, negative: Bool) -> Bool {
        guard let number = Int64(value), String(number) == value else { return false }
        return negative ? number < 0 : number > 0
    }
    static func numericID(_ value: Any?, negative: Bool) -> String? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              numericIDString(number.stringValue, negative: negative) else { return nil }
        return number.stringValue
    }
    static func validate(provider: DeliveryProvider, secret: String, chat: String) async throws -> DeliveryDestination {
        switch provider {
        case .discord:
            let result = try await getJSON(discordURL(secret))
            guard (result["type"] as? Int) == 1, let channel = result["channel_id"] as? String,
                  let guild = result["guild_id"] as? String else { throw DeliveryNetworkError.invalidResponse }
            return DeliveryDestination(id: UUID(), name: "Discord", provider: provider, targetID: channel,
                                       targetKind: "channel", identity: "discord:\(guild):\(channel)", enabled: true)
        case .telegram:
            guard chat.range(of: #"^(?:-[1-9][0-9]*|@[A-Za-z0-9_]+)$"#, options: .regularExpression) != nil else { throw DeliveryNetworkError.invalidChat }
            let me = try await getJSON(telegramURL(secret, method: "getMe"))
            guard (me["ok"] as? Bool) == true, let bot = me["result"] as? [String: Any],
                  let botID = numericID(bot["id"], negative: false) else { throw DeliveryNetworkError.invalidResponse }
            var parts = URLComponents(url: try telegramURL(secret, method: "getChat"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "chat_id", value: chat)]
            let result = try await getJSON(parts.url!)
            return try telegramGroup(from: result, botID: botID)
        }
    }
    static func classify(provider: DeliveryProvider, status: Int?, data: Data, errorCode: Int?, bytesSent: Int64) -> DeliveryResult {
        // A zero counter alone is insufficient proof of non-delivery across retries / OS recovery.
        if let errorCode {
            let definitePreconnection = [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost]
            return status == nil && bytesSent == 0 && definitePreconnection.contains(errorCode) ? .retry(30) : .unknown
        }
        guard let status else { return .unknown }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 429 {
            let seconds = (json?["retry_after"] as? NSNumber)?.doubleValue ??
                ((json?["parameters"] as? [String: Any])?["retry_after"] as? NSNumber)?.doubleValue ?? 30
            return .retry(max(1, seconds))
        }
        // 5xx may follow a successful server-side write; never blindly replay it.
        if status >= 500 { return .unknown }
        // Only a definitive Telegram rejection may suggest a replacement target.
        // Keep the current destination and routing snapshot unchanged.
        if provider == .telegram, status == 400 || (200..<300).contains(status),
           (json?["ok"] as? Bool) == false, (json?["error_code"] as? Int) == 400,
           let parameters = json?["parameters"] as? [String: Any],
           let newID = numericID(parameters["migrate_to_chat_id"], negative: true) {
            return .attention("グループが移行しました。新しいID（\(newID)）で送り先を追加し直してください。自動では付け替えません。")
        }
        guard (200..<300).contains(status) else {
            return .attention("投稿が拒否されました（HTTP \(status)）。送り先の設定・権限を確認してください。")
        }
        switch provider {
        case .discord:
            guard let id = json?["id"] as? String else { return .unknown }; return .sent(id)
        case .telegram:
            if (json?["ok"] as? Bool) == false {
                let code = (json?["error_code"] as? Int) ?? 0
                return .attention("Telegramが投稿を拒否しました（\(code)）。設定・権限を確認してください。")
            }
            guard (json?["ok"] as? Bool) == true, let result = json?["result"] as? [String: Any],
                  let id = result["message_id"] as? NSNumber else { return .unknown }
            return .sent(id.stringValue)
        }
    }
}
