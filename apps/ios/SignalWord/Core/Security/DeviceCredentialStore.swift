import Foundation
import Security

enum DeviceCredentialStore {
    private static let service = "SignalWord.AlertAPI"
    private static let account = "device-session-v1"

    struct Session: Codable, Equatable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userID: String?
        let reauthenticationUserID: String?
        init(accessToken: String, refreshToken: String, expiresAt: Date, userID: String? = nil, reauthenticationUserID: String? = nil) {
            self.accessToken = accessToken; self.refreshToken = refreshToken
            self.expiresAt = expiresAt; self.userID = userID
            self.reauthenticationUserID = reauthenticationUserID
        }
    }

    static func loadBearerToken() throws -> String? {
        try loadSession()?.accessToken
    }

    static func loadSession() throws -> Session? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // A locked/unavailable Keychain is not a new installation. Never replace
        // an existing identity just because its credentials cannot be read now.
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainError.invalidSession }
        do { return try JSONDecoder().decode(Session.self, from: data) }
        catch { throw KeychainError.invalidSession }
    }

    static func saveSession(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            // This is intentionally available to the locked App Intent only
            // after the device has been unlocked once since boot.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    static func clear() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

enum KeychainError: Error {
    case invalidSession
    case unexpectedStatus(OSStatus)
}
