import Foundation
import TiantingIM

// The @ input model (PRD-chat F-MEN-01 rule 5, R-CF-16): text + [{start, len, userId}]. Pure functions shared by the
// composer and the unit tests; same semantics as tianting-web's src/lib/mentions.ts and tianting-android's core/Mentions.kt
// (FE-666, FE-668). Positions are UTF-16 offsets, as UITextView's selectedRange.

/// One @ in the input: [start, start + len) of the text stands for userId; `all` is "@所有人" (F-MEN-02), userId empty.
public struct MentionRange: Equatable, Hashable, Sendable {
    public var start: Int
    public var len: Int
    public var userId: String
    public var all: Bool

    public init(start: Int, len: Int, userId: String, all: Bool = false) {
        self.start = start
        self.len = len
        self.userId = userId
        self.all = all
    }

    public var end: Int { start + len }
}

/// A draft (PRD-ui F-UI-24; PRD-chat F-MEN-01 rule 5 "草稿改为结构化"): text, @ ranges, the quote (only its msgId: the bar
/// shows the loaded message, so a recall leaves no copy here, issue 41). Memory only (issue 15).
public struct Draft: Equatable, Sendable {
    public var text: String
    public var mentions: [MentionRange]
    public var quote: String?

    public init(text: String, mentions: [MentionRange] = [], quote: String? = nil) {
        self.text = text
        self.mentions = mentions
        self.quote = quote
    }

    /// Blank text and no quote: not a draft.
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quote == nil }
}

private func isAt(_ u: UInt16?) -> Bool { u == 0x40 || u == 0xFF20 }  // "@", "＠"

private func isSpace(_ u: UInt16) -> Bool {
    guard let s = Unicode.Scalar(u) else { return false }
    return Character(s).isWhitespace
}

private func units(_ s: String) -> [UInt16] { Array(s.utf16) }

private func string(_ u: ArraySlice<UInt16>) -> String { String(decoding: u, as: UTF16.self) }

/// The ranges after the text went from `prev` to `next`: ranges before the edit stay, those after it move by the length
/// difference, and any that overlap the edit go (deleting any character of "@小王 " drops that @, AC-MEN-01-5).
public func reconcileMentions(_ prev: String, _ next: String, _ ranges: [MentionRange]) -> [MentionRange] {
    if prev == next { return ranges }
    let p = units(prev)
    let n = units(next)
    let maxCommon = min(p.count, n.count)
    var head = 0
    while head < maxCommon, p[head] == n[head] { head += 1 }
    var tail = 0
    while tail < maxCommon - head, p[p.count - 1 - tail] == n[n.count - 1 - tail] { tail += 1 }
    let oldEnd = p.count - tail  // [head, oldEnd) of prev was replaced
    let delta = n.count - p.count
    var out: [MentionRange] = []
    for r in ranges {
        if r.end <= head {
            out.append(r)
        } else if r.start >= oldEnd {
            var moved = r
            moved.start += delta
            out.append(moved)
        }
    }
    return out
}

/// Whether this edit typed one "@" or "＠" at a line start or after whitespace (AC-MEN-01-8): its position, else nil. A
/// multi-character insert (pasting "@u2") does not count; the @ of a@b.com follows a letter and does not count.
public func mentionTrigger(_ prev: String, _ next: String) -> Int? {
    let p = units(prev)
    let n = units(next)
    guard n.count == p.count + 1 else { return nil }
    var i = 0
    while i < p.count, p[i] == n[i] { i += 1 }
    guard Array(n[0..<i]) + Array(n[(i + 1)...]) == p, isAt(n[i]) else { return nil }
    return i == 0 || isSpace(n[i - 1]) ? i : nil
}

/// A caret inside a mention (not at its ends) moves to an end (rule 5: the caret cannot land inside): coming from behind
/// (moving left into it) to its start, otherwise (tapping in, moving right) to its end. `prev` is the caret before.
public func clampCaret(_ pos: Int, _ ranges: [MentionRange], prev: Int? = nil) -> Int {
    for r in ranges where pos > r.start && pos < r.end {
        if let prev, prev >= r.end { return r.start }
        return r.end
    }
    return pos
}

/// The result of an edit: text, ranges, caret.
public struct MentionEdit: Equatable, Sendable {
    public var text: String
    public var ranges: [MentionRange]
    public var caret: Int
}

/// Backspace: the caret (no selection) is right after a mention and the edit only removed text just before it (the soft or
/// hardware keyboard's delete): the whole mention goes (AC-MEN-01-12). nil when it is not that case.
public func backspaceMention(_ prev: String, prevCaret: Int, _ next: String, _ ranges: [MentionRange]) -> MentionEdit? {
    let p = units(prev)
    let n = units(next)
    guard n.count < p.count, prevCaret <= p.count else { return nil }
    let removed = p.count - n.count
    let from = prevCaret - removed
    guard from >= 0, Array(p[0..<from]) + Array(p[prevCaret...]) == n else { return nil }
    guard let hit = ranges.first(where: { $0.end == prevCaret && from >= $0.start }) else { return nil }
    let text = string(p[0..<hit.start]) + string(p[prevCaret...])
    return MentionEdit(text: text, ranges: reconcileMentions(prev, text, ranges), caret: hit.start)
}

/// Replaces the "@" at `at` with "@{name} " and records the range (R-CF-03: the public nickname, else the userId, never a
/// remark). A nil userId is "@所有人".
public func insertMention(_ text: String, _ ranges: [MentionRange], at: Int, name: String, userId: String?) -> MentionEdit {
    let t = units(text)
    let at = max(0, min(at, t.count))
    let replaced = at < t.count && isAt(t[at]) ? 1 : 0
    let piece = "@\(name) "
    let pieceLen = piece.utf16.count
    let without = string(t[0..<at]) + string(t[(at + replaced)...])
    let next = string(t[0..<at]) + piece + string(t[(at + replaced)...])
    let moved = reconcileMentions(text, without, ranges).map { r -> MentionRange in
        var r = r
        if r.start >= at { r.start += pieceLen }
        return r
    }
    let range = userId.map { MentionRange(start: at, len: pieceLen, userId: $0) }
        ?? MentionRange(start: at, len: pieceLen, userId: "", all: true)
    return MentionEdit(text: next, ranges: (moved + [range]).sorted { $0.start < $1.start }, caret: at + pieceLen)
}

/// The mentions to send: only ranges whose text still starts with an @; userIds deduplicated; nil when none (not sent).
public func mentionsToSend(_ text: String, _ ranges: [MentionRange]) -> Mentions? {
    let t = units(text)
    var ids: [String] = []
    var all = false
    for r in ranges {
        guard r.start >= 0, r.end <= t.count, isAt(t[r.start]) else { continue }
        if r.all {
            all = true
        } else if !ids.contains(r.userId) {
            ids.append(r.userId)
        }
    }
    if !all && ids.isEmpty { return nil }
    return Mentions(userIds: ids, all: all)
}

/// The composer's state (no UIKit, the unit tests use it directly): text, selection, @ ranges. `composeBase` is the text
/// before the IME composition started (non-nil while composing).
public struct EditState: Equatable, Sendable {
    public var text: String
    public var selStart: Int
    public var selEnd: Int
    public var ranges: [MentionRange]
    public var composeBase: String?

    public init(text: String, selStart: Int? = nil, selEnd: Int? = nil, ranges: [MentionRange] = [], composeBase: String? = nil) {
        self.text = text
        let end = text.utf16.count
        self.selStart = selStart ?? end
        self.selEnd = selEnd ?? self.selStart
        self.ranges = ranges
        self.composeBase = composeBase
    }

    public static let empty = EditState(text: "")
}

/// One input step: the new state; a non-nil `trigger` opens the member picker for the @ at that position.
public struct EditResult: Equatable, Sendable {
    public var state: EditState
    public var trigger: Int?
}

/// One change of the input (UITextView's textViewDidChange). `composing` means the IME has marked text (markedTextRange).
/// - While composing the model does not change and the picker does not open (AC-MEN-01-9, rule 5): only the text before
///   the composition is kept; when it ends (committed) the edit is computed once from it.
/// - Backspace with no selection right after a mention removes all of it and its range (AC-MEN-01-12).
/// - Otherwise ranges move or go with the edit (AC-MEN-01-5); a caret-only move does not land inside a mention.
/// - With `canMention` (a group, and features.msgActions on) an @ / ＠ typed at a line start or after whitespace opens the
///   picker (AC-MEN-01-6, 01-8).
public func applyEdit(
    _ old: EditState, text: String, selStart: Int, selEnd: Int, composing: Bool, canMention: Bool
) -> EditResult {
    if composing {
        var s = old
        s.text = text
        s.selStart = selStart
        s.selEnd = selEnd
        s.composeBase = old.composeBase ?? old.text
        return EditResult(state: s, trigger: nil)
    }
    let fromComposition = old.composeBase != nil
    let prev = old.composeBase ?? old.text
    if !fromComposition, selStart == selEnd, old.selStart == old.selEnd,
        let r = backspaceMention(old.text, prevCaret: old.selStart, text, old.ranges)
    {
        return EditResult(state: EditState(text: r.text, selStart: r.caret, selEnd: r.caret, ranges: r.ranges), trigger: nil)
    }
    let ranges = reconcileMentions(prev, text, old.ranges)
    var s = selStart
    var e = selEnd
    if s == e, prev == text {
        let c = clampCaret(s, ranges, prev: old.selStart)
        s = c
        e = c
    }
    let trigger = canMention ? mentionTrigger(prev, text) : nil
    return EditResult(state: EditState(text: text, selStart: s, selEnd: e, ranges: ranges), trigger: trigger)
}
