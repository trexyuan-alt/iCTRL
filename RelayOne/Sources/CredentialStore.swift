import Foundation
import Security

struct CompanionCredentials: Codable {
    let identity: String
    let secret: String
}

enum CredentialStore {
    private static let service = "com.temporary.relayone.credentials"
    private static let account = "install"

    static func loadOrCreate() throws -> CompanionCredentials {
        if let existing = try load() {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "RelayOne.Credentials", code: 1)
        }
        let value = CompanionCredentials(
            identity: "relayone-" + UUID().uuidString.lowercased(),
            secret: Data(bytes).base64EncodedString()
        )
        try save(value)
        return value
    }

    private static func load() throws -> CompanionCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw NSError(domain: "RelayOne.Credentials", code: Int(status))
        }
        return try JSONDecoder().decode(CompanionCredentials.self, from: data)
    }

    private static func save(_ value: CompanionCredentials) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "RelayOne.Credentials", code: Int(status))
        }
    }
}
