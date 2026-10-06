import Foundation
import Security

/// A single secret string in the iOS Keychain (encrypted, only readable by this app, removed with it).
/// Used for API keys, which must never be stored in code, UserDefaults or git.
nonisolated struct KeychainStore: Sendable {
    let service: String
    let account: String

    static let openAIKey = KeychainStore(service: "tik.tian.com.WikiReader.openai", account: "apiKey")

    enum Failure: Error, Equatable {
        case status(OSStatus)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value`, replacing any previous one; an empty value deletes it.
    func save(_ value: String) throws(Failure) {
        guard !value.isEmpty else { return try delete() }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw .status(update) }

        var add = query
        add[kSecValueData as String] = data
        // Readable after the first unlock following a reboot, never synced to other devices.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw .status(status) }
    }

    func delete() throws(Failure) {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .status(status) }
    }
}
