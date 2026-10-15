import Foundation
import Security
import Synchronization

protocol PasswordStore: Sendable {
    func hasPassword(for targetID: Target.ID) -> Bool
    func password(for targetID: Target.ID) -> String?
    func setPassword(_ password: String, for targetID: Target.ID) throws
    func removePassword(for targetID: Target.ID) throws
}

extension PasswordStore {
    func hasPassword(for targetID: Target.ID) -> Bool {
        password(for: targetID) != nil
    }
}

struct KeychainError: Error, Hashable, Sendable {
    var status: OSStatus
}

/// Uses the login keychain: the data protection keychain needs entitlements the ad-hoc signed app lacks.
struct KeychainPasswordStore: PasswordStore {
    var service = "de.rocu.BackupSquirrel.repository"

    /// Asks without the data, so a rebuilt app gets no access prompt at launch.
    func hasPassword(for targetID: Target.ID) -> Bool {
        var query = self.query(for: targetID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func password(for targetID: Target.ID) -> String? {
        var query = self.query(for: targetID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String, for targetID: Target.ID) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(
            query(for: targetID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(for: targetID)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Backup-Squirrel Repository"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func removePassword(for targetID: Target.ID) throws {
        let status = SecItemDelete(query(for: targetID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func query(for targetID: Target.ID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: targetID.uuidString.lowercased(),
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

final class InMemoryPasswordStore: PasswordStore {
    private let passwords: Mutex<[Target.ID: String]>

    init(_ passwords: [Target.ID: String] = [:]) {
        self.passwords = Mutex(passwords)
    }

    func password(for targetID: Target.ID) -> String? {
        passwords.withLock { $0[targetID] }
    }

    func setPassword(_ password: String, for targetID: Target.ID) {
        passwords.withLock { $0[targetID] = password }
    }

    func removePassword(for targetID: Target.ID) {
        passwords.withLock { $0[targetID] = nil }
    }
}
