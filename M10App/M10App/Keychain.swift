import Foundation
import Security

/// Minimal Keychain wrapper — WiFi passwords don't belong in UserDefaults.
enum Keychain {
    private static let service = "com.glmfunk.m10.wifi"

    static func savePassword(_ password: String, forSSID ssid: String) {
        let account = ssid.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = password.data(using: .utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadPassword(forSSID ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid.data(using: .utf8)!,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
