import Foundation
import Security

struct GatewayCredentials: Codable, Equatable, Sendable {
    let baseURL: String
    let apiKey: String

    private static var keychainItem: [String: Any] {
        let bundleID = Bundle.main.bundleIdentifier ?? "local.codex.thirdparty.launcher"
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(bundleID).gateway-credentials",
            kSecAttrAccount as String: "last-gateway",
        ]
    }

    static func load() throws -> Self? {
        var query = keychainItem
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let query = Self.keychainItem
        let attributes = [kSecValueData as String: try JSONEncoder().encode(self)]
        let item = query.merging(attributes) { _, value in value }
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }
}
