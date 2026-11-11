import Foundation
import TiantingIM

// Reporting and blocked content (PRD-chat section 10, F-MOD-02, F-MOD-03; C6, FE-695): copy and pure rules. The same
// words and rules as tianting-web FE-693 and tianting-android FE-694. The sheet is UI/Pages/ReportSheet.swift.

/// 4510 on `send` (P-48 ⑥): the SDK's "send:4510". Kept here for the tests and the failed icon's name.
public let contentBlockedSendText = "消息包含不当内容，无法发送"

/// 4510 anywhere else (P-48 ⑥): nickname, username, group name and notice, friend request note. The form keeps its content.
public let contentBlockedFormText = "内容包含不当信息，请修改后重试"

/// Shown above the button (F-MOD-03 rule 8).
public let reportHintText = "所选内容将提交给平台审核"

/// The toast after a report went through (AC-MOD-03-9).
public let reportDoneText = "已提交，感谢你的反馈"

/// After a c2c message or a user was reported (frontend-chat 79); the block dialog's explanation follows, as on H5.
public let reportAskBlockText = "要把对方加入黑名单吗？"

/// The block dialog's explanation (PRD-ui F-UI-14); the user card's own dialog uses the same words.
public let blockExplainText = "加入黑名单后，你将不再收到对方的私聊消息和好友申请；在共同的群聊里仍能看到对方的发言"

/// A pasted note longer than 200 code points was cut (frontend-chat 84; the words of H5 and Android).
public let reportNoteClippedText = "补充说明最多 \(reportNoteMax) 个字，超出的部分已去掉"

/// The six reasons and their words (frontend-chat 78, the same on three apps and the console), in UI order; none is
/// preselected.
public let reportReasons: [(reason: ReportReason, title: String)] = [
    (.spam, "垃圾广告"),
    (.abuse, "辱骂骚扰"),
    (.porn, "色情低俗"),
    (.fraud, "诈骗"),
    (.illegal, "违法违规"),
    (.other, "其他"),
]

/// What is reported, and whom to offer blocking afterwards: the sender of a c2c message, the reported user; never for a
/// group message or a group (frontend-chat 79). The first apps report one message (frontend-chat 85).
public struct ReportRequest: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case message(convId: String, msgId: String)
        case user(String)
        case group(String)
    }

    public let target: Target
    public let askBlock: String?

    public init(target: Target, askBlock: String? = nil) {
        self.target = target
        self.askBlock = askBlock
    }

    /// A message from the chat page: a c2c one offers blocking its sender.
    public static func message(_ m: Message) -> ReportRequest? {
        guard let id = m.msgId else { return nil }
        let c2c = m.convId.hasPrefix("c2c:")
        return ReportRequest(target: .message(convId: m.convId, msgId: id), askBlock: c2c ? m.from : nil)
    }

    public func input(reason: ReportReason, note: String?) -> ReportInput {
        switch target {
        case .message(let convId, let msgId): return .message(convId: convId, msgIds: [msgId], reason: reason, note: note)
        case .user(let id): return .user(id, reason: reason, note: note)
        case .group(let id): return .group(id, reason: reason, note: note)
        }
    }
}

/// Cuts to `max` code points (never inside one).
public func clampCodePoints(_ s: String, max: Int = reportNoteMax) -> String {
    let scalars = s.unicodeScalars
    guard scalars.count > max else { return s }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars.prefix(max))
    return String(out)
}

/// The note field after an edit (frontend-chat 84): counted in code points, at most 200. Going over by one code point (a
/// key) keeps the old text: typing stops. Going over by more (a paste) cuts to 200 and says so.
public func reportNoteInput(old: String, new: String) -> (value: String, clipped: Bool) {
    let n = countCodePoints(new)
    if n <= reportNoteMax { return (new, false) }
    if n - countCodePoints(old) <= 1 { return (old, false) }
    return (clampCodePoints(new), true)
}

/// The note sent: trimmed, none when empty.
public func reportNote(_ note: String) -> String? {
    let t = trimText(note)
    return t.isEmpty ? nil : t
}

/// A failed report (frontend-chat 83): 4040 "无法举报该内容", 4030 "举报功能暂不可用", 4292 "今天的举报次数已用完", other codes by
/// the "command + code" table; no server code (a timeout, a lost connection) is a network problem. Never the note.
public func reportErrorText(_ error: Error) -> String {
    guard let e = error as? IMError else { return networkErrorText }
    return errorText(e.code, cmd: "report")
}

/// These close the sheet after the toast (as H5 and Android): submitting again cannot help. Others (5000, 4290, a timeout,
/// a lost connection) keep the sheet and what was filled in for a manual retry; nothing retries by itself.
public func reportErrorFinal(_ error: Error) -> Bool {
    guard let e = error as? IMError else { return false }
    return [4040, 4030, 4292].contains(e.code)
}
