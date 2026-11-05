import Observation
import SwiftUI
import UIKit

public enum ThemePref: String, CaseIterable, Sendable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Appearance (PRD-ui F-UI-22): follows the system unless set by hand. Stored as `ui.theme`, kept after logout. Applied on
/// the windows, which also covers the keyboard and system menus.
@MainActor
@Observable
public final class ThemeController {
    public static let key = "ui.theme"
    public private(set) var pref: ThemePref
    private let prefs: UIPrefs

    public init(prefs: UIPrefs = UIPrefs()) {
        self.prefs = prefs
        pref = prefs.get(Self.key).flatMap(ThemePref.init(rawValue:)) ?? .system
    }

    public func set(_ value: ThemePref) {
        pref = value
        prefs.set(Self.key, value.rawValue)
        apply()
    }

    public func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows { window.overrideUserInterfaceStyle = pref.style }
        }
    }
}
