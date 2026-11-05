import Foundation
import Security

/// A logged-in session. The token never goes into UserDefaults, a URL or a log (NF-UI-13, PRD-ui 3.4).
public struct Session: Sendable, Equatable, Codable {
    public var userId: String
    public var token: String

    public init(userId: String, token: String) {
        self.userId = userId
        self.token = token
    }
}

public protocol SessionStore: Sendable {
    func load() -> Session?
    func save(_ session: Session)
    func clear()
}

/// Keychain storage, this device only (PRD-ui 3.4, AC-UI-16-3).
public struct KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "session"

    public init(service: String = "com.tianting.im.session") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> Session? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { TTLog.requestError("keychain.save", code: Int(status)) }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }

    /// Whether anything is stored, for AC-UI-16-3.
    public var isEmpty: Bool {
        var q = query
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecItemNotFound
    }
}

/// For tests.
public final class MemorySessionStore: SessionStore, @unchecked Sendable {
    public var session: Session?

    public init(_ session: Session? = nil) {
        self.session = session
    }

    public func load() -> Session? { session }
    public func save(_ session: Session) { self.session = session }
    public func clear() { session = nil }
}
