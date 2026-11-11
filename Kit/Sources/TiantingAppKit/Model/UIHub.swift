import Observation
import SwiftUI

/// Toasts and dialogs live at the root, above the navigation bar. One toast at a time, for 2 seconds; a new one replaces
/// the old (F-UI-19 rule 1).
@MainActor
@Observable
public final class UIHub {
    public struct Toast: Equatable {
        public let id: Int
        public let text: String
    }

    public struct Dialog: Identifiable {
        public let id: String
        let dismissible: Bool
        let sheet: Bool
        let content: AnyView
    }

    public private(set) var toast: Toast?
    public private(set) var dialog: Dialog?
    /// The open dialog cannot be dismissed by the scrim for now (the report sheet while it submits, FE-695).
    public private(set) var dialogLocked = false
    @ObservationIgnored private var counter = 0
    @ObservationIgnored private var hide: Task<Void, Never>?
    @ObservationIgnored public var toastDuration: Duration = .seconds(2)

    public init() {}

    public func show(_ text: String) {
        counter += 1
        toast = Toast(id: counter, text: text)
        hide?.cancel()
        let id = counter
        let duration = toastDuration
        hide = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }

    public func clearToast() {
        hide?.cancel()
        toast = nil
    }

    func present<V: View>(id: String, dismissible: Bool = true, sheet: Bool = false, @ViewBuilder _ content: () -> V) {
        dialogLocked = false
        dialog = Dialog(id: id, dismissible: dismissible, sheet: sheet, content: AnyView(content()))
    }

    public func dismissDialog() {
        dialogLocked = false
        dialog = nil
    }

    /// Locks or unlocks the open dialog against the scrim.
    public func lockDialog(_ locked: Bool) {
        dialogLocked = locked
    }

    /// A confirm dialog: text, "取消", and an action (F-UI-08, F-UI-14, F-UI-16...).
    func confirm(id: String, text: String, ok: String, danger: Bool = false, onOk: @escaping () -> Void) {
        present(id: id) {
            ConfirmDialog(text: text, ok: ok, danger: danger, onOk: onOk)
        }
    }
}
