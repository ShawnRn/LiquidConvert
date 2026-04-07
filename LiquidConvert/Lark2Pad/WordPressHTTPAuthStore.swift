import Foundation
import Security

struct WordPressHTTPAuthCredential: Codable {
    let username: String
    let password: String

    var urlCredential: URLCredential {
        URLCredential(user: username, password: password, persistence: .forSession)
    }
}

enum WordPressHTTPAuthStore {
    private static let service = "com.shawnrain.LiquidConvert.wordpress-http-auth"
    private static let account = "www.ifanr.com"
    private static let fallbackDefaultsKey = "wordpress_http_auth_fallback"
    private static let fallbackXORKey: UInt8 = 0x3D

    static func save(username: String, password: String) {
        let credential = WordPressHTTPAuthCredential(username: username, password: password)
        guard let data = try? JSONEncoder().encode(credential) else { return }

        saveFallback(data)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }

    static func load() -> WordPressHTTPAuthCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let credential = try? JSONDecoder().decode(WordPressHTTPAuthCredential.self, from: data) else {
            guard let fallbackData = loadFallback(),
                  let credential = try? JSONDecoder().decode(WordPressHTTPAuthCredential.self, from: fallbackData) else {
                return nil
            }
            return credential
        }

        return credential
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackDefaultsKey)
    }

    static func defaultCredential(for protectionSpace: URLProtectionSpace) -> URLCredential? {
        if let credential = URLCredentialStorage.shared.defaultCredential(for: protectionSpace) {
            return credential
        }

        guard let savedCredential = load()?.urlCredential else {
            return nil
        }

        URLCredentialStorage.shared.setDefaultCredential(savedCredential, for: protectionSpace)
        return savedCredential
    }

    private static func saveFallback(_ data: Data) {
        let obfuscated = Data(data.map { $0 ^ fallbackXORKey }).base64EncodedString()
        UserDefaults.standard.set(obfuscated, forKey: fallbackDefaultsKey)
    }

    private static func loadFallback() -> Data? {
        guard let encoded = UserDefaults.standard.string(forKey: fallbackDefaultsKey),
              let data = Data(base64Encoded: encoded) else {
            return nil
        }

        return Data(data.map { $0 ^ fallbackXORKey })
    }
}
