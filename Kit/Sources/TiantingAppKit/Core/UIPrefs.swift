import Foundation

/// The app's only use of UserDefaults: device preferences under `ui.` (AC-UI-90-2, NF-UI-13). They stay after logout
/// (F-UI-16 rule 3), except `ui.noticeSeen.{userId}`: one number, no content, deleted on logout (L-18, F-PUSH-12 rule 5).
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
}
