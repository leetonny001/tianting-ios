import Foundation
import TiantingIM

/// The app's only use of UserDefaults: device preferences under `ui.` (AC-UI-90-2, NF-UI-13). They stay after logout
/// (F-UI-16 rule 3), except `ui.noticeSeen.{userId}`: one number, no content, deleted on logout (L-18, F-PUSH-12 rule 5).
/// `ui.privacyAck.{hash of the user id}` (F-ACC-10 rule 2, the same key as H5 and Android) stays, so its name has no user id.
/// scripts/py/check_sources.py rejects UserDefaults anywhere else.
public struct UIPrefs {
    public static let prefix = "ui."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func get(_ key: String) -> String? {
        precondition(key.hasPrefix(Self.prefix))
        return defaults.string(forKey: key)
    }

    public func set(_ key: String, _ value: String?) {
        precondition(key.hasPrefix(Self.prefix))
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func removeAll(prefix: String) {
        precondition(prefix.hasPrefix(Self.prefix))
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// UI tests start clean.
    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The privacy notice version this account confirmed on this device (F-ACC-10 rule 2).
public func privacyAckKey(_ userId: String) -> String { "ui.privacyAck.\(String(fnv1a32(userId), radix: 16))" }
