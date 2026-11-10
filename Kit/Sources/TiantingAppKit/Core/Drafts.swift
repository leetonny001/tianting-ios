import Foundation
import Observation

/// Drafts (PRD-ui F-UI-24): memory only, one instance per login, by conversation. Structured since C4: text, @ ranges and
/// the quoted msgId (PRD-chat F-MEN-01 rule 5, AC-MEN-01-10; still memory only, issue 15).
@MainActor
@Observable
public final class DraftStore {
    public private(set) var drafts: [String: Draft] = [:]

    public init() {}

    public func draft(_ convId: String) -> Draft? { drafts[convId] }

    /// The list's "[草稿]" text: nil when there is no draft or only a quote without text.
    public func text(_ convId: String) -> String? {
        guard let d = drafts[convId], !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return d.text
    }

    /// Whitespace-only text without a quote removes the draft.
    public func put(_ convId: String, _ draft: Draft) {
        drafts[convId] = draft.isEmpty ? nil : draft
    }

    public func put(_ convId: String, _ text: String) {
        put(convId, Draft(text: text))
    }

    public func remove(_ convId: String) {
        drafts[convId] = nil
    }
}
