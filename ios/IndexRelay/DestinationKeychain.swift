import Foundation
import Security

enum DestinationKeychain {
    static var service: String { (Bundle.main.bundleIdentifier ?? "IndexRelay") + ".destinations" }
    static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    static func save(_ credential: DeliveryCredential, id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: "IndexRelayKeychain", code: Int(status)) }
    }
    static func load(_ id: UUID) throws -> DeliveryCredential {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: "IndexRelayKeychain", code: Int(status)) }
        return try JSONDecoder().decode(DeliveryCredential.self, from: data)
    }
    static func remove(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }
}
