import Foundation
import CoreFoundation

enum HiNewError: Error, LocalizedError, Sendable {
    case invalidHandle, invalidToken, invalidInvite, unverifiedOwner, missingGrant, changedKey, wrongPeer, plaintextConsent
    case rejected(Int), rateLimited, network(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidHandle: "hi.newの相手ハンドルを確認してください（小文字英数字・内側の単一ハイフン、3〜32文字）。"
        case .invalidToken: "送信者専用のhi.newトークン（hn_…／hnt_…）を入力してください。受信者のトークンは使用しません。"
        case .invalidInvite: "https://hi.new/i/hni_… 形式の招待リンクを入力してください。"
        case .unverifiedOwner: "送信者の所有者メール確認をhi.newで完了してください。"
        case .missingGrant: "相手への送信許可がありません。招待を明示的に使用するか、接続済みの送信者トークンを入力してください。"
        case .changedKey: "相手の鍵が変更されたか、暗号化が必要になりました。平文送信を停止しました。信頼できる別の経路で相手を確認してください。"
        case .wrongPeer: "登録済みの送信者・相手と一致しません。新しい送り先として確認してください。"
        case .plaintextConsent: "平文送信と、送信側・受信側双方のtranscript保持設定を確認してください。"
        case .rateLimited: "hi.newの通信制限です。時間を置いて確認してください。"
        case .rejected(let code): "hi.newが要求を拒否しました（HTTP \(code)）。権限・所有者メール・招待の有効性を確認してください。"
        case .network(let code): "hi.newと通信できませんでした（コード \(code)）。招待を使用した場合は、送り先の確認操作で接続状況を再照合してください。"
        case .invalidResponse: "hi.newの応答を確認できませんでした。接続状況を再照合してください。"
        }
    }
    var retryDelay: TimeInterval? {
        switch self { case .rateLimited: 3_600; case .network: 30; case .rejected(let code) where code >= 500: 60; default: nil }
    }
}
struct HiNewHTTPResponse: Sendable { var status: Int; var data: Data }
protocol HiNewTransport: Sendable { func send(_ request: URLRequest) async throws -> HiNewHTTPResponse }
struct HiNewURLTransport: HiNewTransport {
    func send(_ request: URLRequest) async throws -> HiNewHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: DeliveryValidationDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 262_144 else { throw HiNewError.invalidResponse }
            return HiNewHTTPResponse(status: response.statusCode, data: data)
        } catch let error as HiNewError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw HiNewError.network((error as NSError).code) }
    }
}
enum HiNewAPI {
    static func isOwnerToken(_ value: String) -> Bool { tokenIsValid(value) && value.hasPrefix("hn_") }
    static func tokenIsValid(_ value: String) -> Bool {
        value.range(of: #"^(?:hn|hnt)_[A-Za-z0-9_-]{16,128}$"#, options: .regularExpression) != nil
    }
    static func inviteToken(_ value: String) throws -> String {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", parts.host == "hi.new", parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.range(of: #"^/i/hni_[A-Za-z0-9_-]{16,128}$"#, options: .regularExpression) != nil else { throw HiNewError.invalidInvite }
        return String(parts.path.dropFirst(3))
    }
    static func request(path: String, token: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard tokenIsValid(token) else { throw HiNewError.invalidToken }
        let allowed = (method == "GET" && ["/api/handles/me", "/api/grants"].contains(path)) ||
            (method == "POST" && (path.range(of: #"^/api/invites/hni_[A-Za-z0-9_-]{16,128}/redeem$"#, options: .regularExpression) != nil ||
             (path.hasPrefix("/api/dm/") && DeliveryDestination.validHandle(String(path.dropFirst(8))))))
        guard allowed, let url = URL(string: "https://hi.new" + path) else { throw HiNewError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("IndexRelay/0.10", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue
    }
    private static func json(_ response: HiNewHTTPResponse) throws -> [String: Any] {
        if response.status == 429 { throw HiNewError.rateLimited }
        guard (200..<300).contains(response.status) else { throw HiNewError.rejected(response.status) }
        guard response.data.count <= 262_144, let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw HiNewError.invalidResponse }
        return object
    }
    static func destination(me: [String: Any], grants: [String: Any], peer: String, expectedSender: String? = nil) throws -> DeliveryDestination {
        guard DeliveryDestination.validHandle(peer), let sender = me["name"] as? String, DeliveryDestination.validHandle(sender), sender != peer else { throw HiNewError.invalidHandle }
        guard expectedSender == nil || expectedSender == sender else { throw HiNewError.wrongPeer }
        guard boolean(me["email_verified"]) == true else { throw HiNewError.unverifiedOwner }
        guard let rows = grants["grants"] as? [[String: Any]] else { throw HiNewError.invalidResponse }
        guard let grant = rows.first(where: { $0["name"] as? String == peer }) else { throw HiNewError.missingGrant }
        guard boolean(grant["key_changed"]) == false, grant["public_key"] is NSNull, grant["pinned_key"] is NSNull else { throw HiNewError.changedKey }
        return DeliveryDestination(id: UUID(), name: "hi.new", provider: .hiNew, targetID: peer, targetKind: "plaintext",
            identity: "hi-new:\(sender):\(peer)", enabled: false, hiNewSender: sender, hiNewPlaintextConfirmed: true)
    }
    static func validate(token: String, peer: String, expectedSender: String? = nil, transport: any HiNewTransport = HiNewURLTransport()) async throws -> DeliveryDestination {
        guard DeliveryDestination.validHandle(peer) else { throw HiNewError.invalidHandle }
        let me = try json(await transport.send(request(path: "/api/handles/me", token: token)))
        // Check account ownership before any invite mutation.
        guard let sender = me["name"] as? String, expectedSender == nil || sender == expectedSender else { throw HiNewError.wrongPeer }
        guard boolean(me["email_verified"]) == true else { throw HiNewError.unverifiedOwner }
        let grants = try json(await transport.send(request(path: "/api/grants", token: token)))
        return try destination(me: me, grants: grants, peer: peer, expectedSender: expectedSender)
    }
    static func redeem(token: String, peer: String, invite: String, expectedSender: String? = nil, transport: any HiNewTransport = HiNewURLTransport()) async throws -> DeliveryDestination {
        let invite = try inviteToken(invite)
        do { return try await validate(token: token, peer: peer, expectedSender: expectedSender, transport: transport) }
        catch HiNewError.missingGrant { /* Only an absent grant permits the explicitly requested redemption. */ }
        do {
            let result = try json(await transport.send(request(path: "/api/invites/" + invite + "/redeem", token: token, method: "POST", body: Data("{}".utf8))))
            guard boolean(result["granted"]) == true, let other = result["peer"] as? [String: Any], other["name"] as? String == peer else { throw HiNewError.wrongPeer }
        } catch {
            // Single-use redemption may have committed before its response was lost. Never POST twice.
            if let resolved = try? await validate(token: token, peer: peer, expectedSender: expectedSender, transport: transport) { return resolved }
            throw error
        }
        return try await validate(token: token, peer: peer, expectedSender: expectedSender, transport: transport)
    }
    static func post(destination: DeliveryDestination, token: String, job: DeliveryJob) throws -> (URLRequest, Data) {
        guard destination.provider == .hiNew, destination.isSupported, job.provider == .hiNew, job.destinationID == destination.id, job.targetIdentity == destination.identity else { throw HiNewError.wrongPeer }
        guard job.canReplayHiNew() else { throw DeliveryStoreError.replayExpired }
        guard DeliveryArchive.validText(job.text, for: .hiNew) else { throw DeliveryStoreError.invalidText }
        let body = try JSONSerialization.data(withJSONObject: ["body": job.text, "enc": "none", "recipient_public_key": NSNull()])
        var request = try request(path: "/api/dm/" + destination.targetID, token: token, method: "POST")
        request.setValue(job.hiNewKey, forHTTPHeaderField: "Idempotency-Key")
        return (request, body)
    }
    static func classify(status: Int?, data: Data, errorCode: Int?, bytesSent: Int64, expectedPeer: String?, retryAfter: TimeInterval? = nil) -> DeliveryResult {
        if let errorCode {
            let preconnect = [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost]
            return status == nil && bytesSent == 0 && preconnect.contains(errorCode) ? .retry(30) : .unknown
        }
        guard let status else { return .unknown }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? String
        if status == 429 {
            if let retryAfter, retryAfter.isFinite, retryAfter > 86_400 { return .hiNewBlocked("hi.newから長い待機時間が指定されたため、送り先を停止しました。時間を置いて設定を確認してください。") }
            return .retry(max(3_600, retryAfter.flatMap { $0.isFinite ? $0 : nil } ?? 3_600))
        }
        if status >= 500 || (200..<400).contains(status) && status != 201 && status != 200 { return .unknown }
        if ["recipient_key_changed", "encryption_required"].contains(error ?? "") { return .hiNewBlocked(HiNewError.changedKey.localizedDescription) }
        if status == 409 { return .hiNewBlocked("hi.newの送信キーまたは相手の状態が一致しません。新しいキーで自動再送せず、設定と送信結果を確認してください。") }
        if [401, 402, 403, 404].contains(status) { return .hiNewBlocked(HiNewError.rejected(status).localizedDescription) }
        guard status == 201 || status == 200 else { return .attention("hi.newが投稿を拒否しました（HTTP \(status)）。本文サイズ・設定を確認してください。") }
        guard let id = DeliveryAPI.numericID(object?["id"], negative: false), let expectedPeer, object?["to"] as? String == expectedPeer,
              object?["enc"] as? String == "none", let replayed = boolean(object?["replayed"]), let expiry = object?["expires_at"] as? String,
              let expiresAt = parseDate(expiry), status == 201 || replayed else { return .unknown }
        return .hiNewSent(id, expiresAt, replayed)
    }
    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
