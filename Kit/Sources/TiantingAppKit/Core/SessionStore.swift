import Foundation
import Security
import TiantingIM

/// A Keychain call failed. Holds the status only.
public struct KeychainError: Error, Equatable {
    public let status: Int32
}

/// The session and the "pending logout" records in the Keychain, this device only (F-ACC-03 rule 8, PRD-ui 3.4, AC-UI-16-3).
/// The SDK decides when to write; this is only where. The token never goes into UserDefaults, a URL or a log (NF-UI-13).
///
/// The two are separate items: `clear()` removes the session and leaves the pending logouts (F-ACC-04 rule 1), which hold
/// only `sid` and refresh token. A save overwrites in place, so a process killed halfway still has the old value, and
/// returning means the value is written (R-CF-09). A failure throws, which keeps the SDK on the old token.
@MainActor
public final class KeychainSessionStore: AccountSessionStore {
    private let service: String
    private let sessionAccount = "session"
    private let pendingAccount = "pendingLogouts"

    public init(service: String = "com.tianting.im.session") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return out as? Data
    }

    private func write(_ account: String, _ data: Data) throws {
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let q = query(account).merging(attrs) { _, new in new }
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            TTLog.requestError("keychain.save", code: Int(status))
            throw KeychainError(status: status)
        }
    }

    private func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            TTLog.requestError("keychain.clear", code: Int(status))
            throw KeychainError(status: status)
        }
    }

    /// Unreadable data is no session. A locked Keychain throws: nothing gets cleared because of it.
    public func load() async throws -> AccountSession? {
        guard let data = try read(sessionAccount) else { return nil }
        return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    public func save(_ session: AccountSession) async throws {
        try write(sessionAccount, try JSONEncoder().encode(session))
        TestHooks.savedSession()
    }

    public func clear() async throws {
        try remove(sessionAccount)
    }

    public func loadPendingLogouts() async throws -> [PendingLogout] {
        guard let data = try read(pendingAccount) else { return [] }
        return (try? JSONDecoder().decode([PendingLogout].self, from: data)) ?? []
    }

    public func savePendingLogouts(_ pending: [PendingLogout]) async throws {
        if pending.isEmpty {
            try remove(pendingAccount)
        } else {
            try write(pendingAccount, try JSONEncoder().encode(pending))
        }
    }

    /// Whether a session is stored (AC-UI-16-3, AC-ACC-05-7).
    public var isEmpty: Bool {
        var q = query(sessionAccount)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecItemNotFound
    }

    /// How many pending logouts are stored; a count, nothing else.
    public var pendingCount: Int {
        guard let data = try? read(pendingAccount) else { return 0 }
        return ((try? JSONDecoder().decode([PendingLogout].self, from: data)) ?? []).count
    }

    #if DEBUG
        /// UI tests only: `{userId, token}` as the previous version wrote it (AC-ACC-03-18), and a clean device.
        func seedLegacySession(userId: String, token: String) {
            let data = try? JSONEncoder().encode(["userId": userId, "token": token])
            if let data { try? write(sessionAccount, data) }
        }

        /// `kSecAttrAccessible` of the stored session, for the UI tests (AfterFirstUnlockThisDeviceOnly is "cku").
        var accessibleClass: String {
            var q = query(sessionAccount)
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let attrs = out as? [String: Any] else { return "-" }
            return attrs[kSecAttrAccessible as String] as? String ?? "-"
        }

        func wipe() {
            try? remove(sessionAccount)
            try? remove(pendingAccount)
        }
    #endif
}
