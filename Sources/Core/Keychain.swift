import Foundation
import Security

/// macOS Keychain 封装 — 安全存储敏感信息（密码、Token 等）
public enum Keychain {
    private static let service = "com.yiban.checkin"

    /// 检测是否在 .app bundle 中运行（裸二进制无 entitlements 访问 Keychain 会 crash）
    private static var isInAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// 存储字符串到 Keychain
    @discardableResult
    public static func set(_ value: String, forKey key: String) -> Bool {
        guard isInAppBundle else {
            // 裸二进制回退到 UserDefaults（仅开发调试用）
            UserDefaults.standard.set(value, forKey: "kc_\(key)")
            return true
        }
        delete(key)

        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// 从 Keychain 读取字符串
    public static func get(_ key: String) -> String? {
        guard isInAppBundle else {
            return UserDefaults.standard.string(forKey: "kc_\(key)")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 从 Keychain 删除
    @discardableResult
    public static func delete(_ key: String) -> Bool {
        guard isInAppBundle else {
            UserDefaults.standard.removeObject(forKey: "kc_\(key)")
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
