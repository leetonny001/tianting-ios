import Foundation
import TiantingIM

// Pure rules of the chat page and the conversation list.

/// Why the composer is replaced (F-UI-33 rules 2-4): the tip at the list's end and the disabled bar.
public struct ChatBlock: Equatable, Sendable {
    public let tip: String
    public let bar: String

    public init(tip: String, bar: String) {
        self.tip = tip
        self.bar = bar
    }
}

public func removedBlock(reason: String?) -> ChatBlock {
    switch reason {
    case "dissolved": return ChatBlock(tip: "群聊已解散", bar: "群聊已解散")
    case "left": return ChatBlock(tip: "你已退出该群聊", bar: "你已退出该群聊")
    default: return ChatBlock(tip: "你已不在该群", bar: "你已不在该群，无法发送消息")
    }
}

/// `done`: the server let us in (still a member) but there is no message, e.g. a group whose conversation I deleted
/// (PRD-chat F-CVS-03 rule 4): an empty chat page, not "加载中…" for ever (frontend-chat 66).
public enum ChatProbe: Equatable, Sendable {
    case idle, loading, done, notMember, notFound
}

public func chatBlock(snapshot: ConversationSnapshot?, probe: ChatProbe) -> ChatBlock? {
    if let snapshot { return removedBlock(reason: snapshot.reason) }
    switch probe {
    case .notMember: return removedBlock(reason: nil)
    case .notFound: return ChatBlock(tip: "群聊不存在或已解散", bar: "群聊不存在或已解散")
    default: return nil
    }
}

public enum ChatRow: Identifiable, Equatable, Sendable {
    case divider(id: String, ts: Int64)
    case message(Message)

    public var id: String {
        switch self {
        case .divider(let id, _): return id
        case .message(let m): return m.clientMsgId
        }
    }
}

public func chatRows(_ messages: [Message]) -> [ChatRow] {
    var out: [ChatRow] = []
    out.reserveCapacity(messages.count + 8)
    var previous: Int64?
    for m in messages {
        if needsDivider(previous: previous, ts: m.ts) { out.append(.divider(id: "d-\(m.clientMsgId)", ts: m.ts)) }
        out.append(.message(m))
        previous = m.ts
    }
    return out
}

/// Permission tips (F-UI-31): after a failed message; adjacent equal tips keep only the last. A successful resend makes
/// the message stop being failed, and its tip goes away.
public func permissionTips(_ messages: [Message], tips: [String: Int]?) -> [String: Int] {
    guard let tips, !tips.isEmpty else { return [:] }
    var out: [String: Int] = [:]
    var lastId = ""
    var lastCode = 0
    for m in messages {
        guard m.status == .failed, let code = tips[m.clientMsgId] else { continue }
        if lastCode == code { out[lastId] = nil }
        out[m.clientMsgId] = code
        lastId = m.clientMsgId
        lastCode = code
    }
    return out
}

/// Conversation summary (F-UI-04 rule 5), without any draft. Group messages from others get the sender prefix.
public func conversationSummary(_ conv: Conversation, me: String, senderName: (String) -> String) -> String {
    guard let m = conv.lastMsg else { return "" }
    if m.deleted == true {
        // A recall: the same table as the chat line (F-RCL-02 rule 1a, F-RCL-03 rule 4); a console deletion keeps its copy.
        if let n = recallNotice(convId: conv.convId, lastMsg: m, me: me) { return recallText(n, nameOf: senderName) }
        return messageDeletedText
    }
    // Images and files show a fixed word, never a file name (F-FILE-02 rule 5, F-FILE-03 rule 5, AC-FILE-02-8, 03-8).
    let body = m.type == "text" || m.type == "tip" ? (m.text ?? "") : attachmentSummary(m.type) ?? "[暂不支持的消息]"
    if conv.type == .group, m.type != "tip", m.from != me, !m.from.isEmpty {
        return "\(senderName(m.from)): \(body)"
    }
    return body
}

/// The id whose color and initial stand for a conversation: the peer, or the group.
public func conversationAvatarId(_ conv: Conversation, me: String) -> String {
    if conv.type == .group { return groupId(ofConv: conv.convId) }
    return peerId(convId: conv.convId, type: conv.type, me: me) ?? conv.convId
}

/// Copy text of a message: "" unless it is plain text.
public func messageStatusValue(_ status: MessageStatus) -> String {
    switch status {
    case .processing: return "处理中"
    case .uploading: return "上传中"
    case .queued: return "排队中"
    case .sending: return "发送中"
    case .sent: return "已发送"
    case .failed: return "发送失败"
    }
}

/// How many code points are over the limit; 0 or less means sendable (C-28).
public func overLimitCount(_ text: String) -> Int {
    countCodePoints(text) - maxTextLength
}

// MARK: Recall, quote, mentions (C4)

/// The message menu's items (PRD-ui F-UI-09 rules 3-5, PRD-chat 13.3). "举报" comes with C6.
public enum MenuAction: String, Sendable, CaseIterable {
    case copy, quote, recall, retry, delete

    public var title: String {
        switch self {
        case .copy: return "复制"
        case .quote: return "引用"
        case .recall: return "撤回"
        case .retry: return "重发"
        case .delete: return "删除"
        }
    }
}

/// The menu (F-UI-09 rules 3-5): with features.msgActions off only "复制" (text) and a failed message's "重发" "删除"; on,
/// the SDK's messageActions (copy, quote, recall by `ts` and the corrected server time; none for recalled or deleted
/// messages and tips). Empty means a long press does nothing. `canRetry` is false when only deleting is left (F-FILE-07
/// rule 4).
public func menuItems(
    _ m: Message, actionsOn: Bool, canRetry: Bool = true, sdkActions: () -> [MessageAction]
) -> [MenuAction] {
    if m.deleted == true || m.type == .tip { return [] }
    var out: [MenuAction] = []
    if actionsOn {
        for a in sdkActions() {
            switch a {
            case .copy: out.append(.copy)
            case .quote: out.append(.quote)
            case .recall: out.append(.recall)
            }
        }
    } else if m.type == .text {
        out.append(.copy)
    }
    if m.status == .failed {
        if canRetry { out.append(.retry) }
        out.append(.delete)
    }
    return out
}

/// The message mentions me (or everyone), not my own (F-MEN-03 rule 6): the bubble is styled as a whole (F-MEN-01 rule 4).
public func mentionsMe(_ m: Message, me: String) -> Bool {
    guard let men = m.body.mentions, m.from != me, m.deleted != true else { return false }
    return men.all || men.userIds.contains(me)
}

/// Quote jumps (F-QUO-02 rule 5): within 200 of the loaded range only; at most 200 a page (sync's limit).
public let quoteJumpMax: Int64 = 200

/// What a jump to `seq` needs (F-QUO-02 rule 5, issue 40): loaded, go there; older within `limit`, page up (the loaded
/// range stays contiguous); further, "消息太早，请翻页查看"; no seq, or inside the loaded range but not there, "消息不存在".
public enum JumpPlan: Equatable, Sendable {
    case here, tooEarly, missing
    case load(Int)
}

public func jumpPlan(_ seq: Int64?, loaded: [Int64], limit: Int64) -> JumpPlan {
    guard let seq else { return .missing }
    if loaded.contains(seq) { return .here }
    guard let oldest = loaded.min() else { return .missing }
    if seq > oldest { return .missing }
    let gap = oldest - seq
    if gap > limit { return .tooEarly }
    return .load(Int(min(quoteJumpMax, gap)))
}

/// The list's summary prefix, one at most (F-MEN-03 rule 2, PRD-ui F-UI-04 rule 5, frontend-chat 61): "[有人@我]" over
/// "[草稿]" over "[N 条]". With a mention the last message's summary follows, not the draft (issue 38); "[N 条]" is a
/// conversation with notifications off that has unread messages (PRD-chat F-CVS-02 rule 5), the summary follows too.
public enum SummaryPrefix: Equatable, Sendable {
    case mention, draft, none
    case unread(Int64)
}

public func summaryPrefix(_ conv: Conversation, hasDraft: Bool) -> SummaryPrefix {
    if (conv.mentionUnread ?? 0) > 0 { return .mention }
    if hasDraft { return .draft }
    if conv.isNotifyOff, conv.unread > 0 { return .unread(conv.unread) }
    return .none
}

/// The quote bar above the input (F-QUO-01, F-QUO-02 rule 3, 13.4 "引用条"): the loaded message, following its recall or
/// deletion; only the msgId is kept, so not loaded is "引用内容不可用" (issue 41). Plain text (AC-QUO-02-5).
public func quoteBarText(_ m: Message?, senderName: (String) -> String) -> String {
    guard let m else { return "引用内容不可用" }
    if m.deleted == true { return m.recalled == true ? "引用内容已被撤回" : "引用内容已被删除" }
    return "\(senderName(m.from)): \(quoteSummary(m))"
}

/// The quote on a bubble (F-QUO-02 rule 3): the SDK's label; a normal one gets the original sender's name first.
public func quoteBlockText(_ q: QuoteView, senderName: (String) -> String) -> String {
    let label = quoteLabel(q)
    if q.state == .normal, let from = q.from, !from.isEmpty { return "\(senderName(from)): \(label)" }
    return label
}
