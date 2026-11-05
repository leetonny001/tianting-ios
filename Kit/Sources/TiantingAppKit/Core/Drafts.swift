import Foundation
import Observation

/// Drafts (PRD-ui F-UI-24): memory only, one instance per login, by conversation.
@MainActor
@Observable
public final class DraftStore {
    public private(set) var drafts: [String: String] = [:]

    public init() {}

    public func draft(_ convId: String) -> String? { drafts[convId] }

    /// Whitespace-only text removes the draft.
    public func put(_ convId: String, _ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[convId] = nil
        } else {
            drafts[convId] = text
        }
    }

    public func remove(_ convId: String) {
        drafts[convId] = nil
    }
}
