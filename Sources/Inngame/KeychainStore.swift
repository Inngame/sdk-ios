import Foundation
import Security

/// The device token lives in the Keychain: it survives reinstalls on iOS and is never in UserDefaults.
enum KeychainStore {
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "gg.inngame", kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "gg.inngame", kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        // Sans trousseau (tests en ligne de commande) : repli sur UserDefaults.
        if status != errSecSuccess { UserDefaults.standard.set(value, forKey: "gg.inngame.\(key)") }
    }

    static func fallback(_ key: String) -> String? { UserDefaults.standard.string(forKey: "gg.inngame.\(key)") }
}
