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

public enum ChatProbe: Equatable, Sendable {
    case idle, loading, notMember, notFound
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
    if m.deleted == true { return messageDeletedText }
    let body = m.type == "text" || m.type == "tip" ? (m.text ?? "") : "[暂不支持的消息]"
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
