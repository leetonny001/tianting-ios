import Foundation
import Observation
import TiantingIM

/// The report sheet's state (PRD-chat F-MOD-03 rule 8, FE-695): one of six reasons (none at first), an optional note of
/// at most 200 code points, and the submit. While it runs the sheet is locked. No automatic retry; the note is never
/// logged (the SDK keeps it out of logs and errors too).
@MainActor
@Observable
public final class ReportForm {
    public enum Outcome: Equatable, Sendable {
        /// Sent: toast "已提交，感谢你的反馈", then ask about blocking this user, or close.
        case done(askBlock: String?)
        /// Failed: toast `text`; `close` for 4040 / 4030 / 4292, otherwise the sheet stays as filled in.
        case failed(text: String, close: Bool)
        /// Nothing happened: no reason yet, or already submitting.
        case ignored
    }

    public let request: ReportRequest
    public var reason: ReportReason?
    public private(set) var note = ""
    /// The last edit was a paste that went over 200 and was cut (frontend-chat 84).
    public private(set) var clipped = false
    public private(set) var busy = false

    public init(_ request: ReportRequest) {
        self.request = request
    }

    public var canSubmit: Bool { reason != nil && !busy }
    public var noteCount: Int { countCodePoints(note) }

    /// The field's new text, by the rule of `reportNoteInput`.
    public func editNote(_ new: String) {
        let r = reportNoteInput(old: note, new: new)
        note = r.value
        clipped = r.clipped
    }

    /// Sends the report once. `isBlocked` is asked after success: a user already on my blacklist is not asked about.
    public func submit(_ client: IMClient, isBlocked: (String) -> Bool) async -> Outcome {
        guard let reason, !busy else { return .ignored }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.report(request.input(reason: reason, note: reportNote(note)))
            let ask = request.askBlock.flatMap { isBlocked($0) ? nil : $0 }
            return .done(askBlock: ask)
        } catch {
            return .failed(text: reportErrorText(error), close: reportErrorFinal(error))
        }
    }
}
