import Foundation
import TiantingIM

// Pin, notifications off and delete in the conversation list (PRD-chat C5: F-CVS-01..04, 13.3; PRD-ui v1.5 F-UI-04 rules 4,
// 5, 7, 9; FE-685). Same rules as tianting-web FE-683 (78c2b2f) and tianting-android FE-684.

/// "[N 条]" before the summary of a conversation with notifications off: N as it is, no "99+" (that is only for badges,
/// frontend-chat 61).
public func unreadPrefixText(_ n: Int64) -> String { "[\(n) 条]" }

/// The mark at the avatar (F-UI-04 rule 4): a number, or with notifications off only a dot, mentions of me included
/// (frontend-chat 61).
public enum ConvBadge: Equatable, Sendable {
    case none, dot
    case count(String)
}

public func convBadge(_ conv: Conversation) -> ConvBadge {
    guard conv.unread > 0 else { return .none }
    return conv.isNotifyOff ? .dot : .count(badgeText(Int(conv.unread)))
}

public enum ConvMenuAction: String, Sendable {
    case pin, notify, delete
}

public struct ConvMenuItem: Equatable, Sendable {
    public let action: ConvMenuAction
    public let title: String
}

/// The conversation menu (AC-CVS-01-6): the words follow the current state. None with `features.convSettings` off or
/// from an older server; pins and notifications off it already has still show (P-46 ②).
public func convMenuItems(_ conv: Conversation, enabled: Bool) -> [ConvMenuItem] {
    guard enabled else { return [] }
    return [
        ConvMenuItem(action: .pin, title: conv.isPinned ? "取消置顶" : "置顶"),
        ConvMenuItem(action: .notify, title: conv.isNotifyOff ? "取消免打扰" : "免打扰"),
        ConvMenuItem(action: .delete, title: "删除"),
    ]
}

/// F-CVS-03 rule 7.
public let convDeleteConfirmText = "删除后聊天记录不再显示，确定删除？"

/// A failed `convSet` / `convDelete`, after the SDK rolled it back (never retried, frontend-chat 56): 4220 "最多置顶 20 个
/// 会话", 4290 "操作过于频繁"; a timeout or a lost connection reads as a server error.
public func convActionErrorText(_ error: Error, cmd: String) -> String {
    errorText(errorCode(error), cmd: cmd)
}

/// A tab's accessible name carries the number its badge shows (frontend-chat 67: the visible count is part of the name).
public func tabAccessibilityLabel(_ label: String, _ tab: AppTab, badge: Int) -> String {
    guard badge > 0 else { return label }
    switch tab {
    case .chats: return "\(label)，\(badgeText(badge)) 条未读"
    case .contacts: return "\(label)，\(badgeText(badge)) 个新的朋友"
    case .me: return label
    }
}

/// What VoiceOver reads for a list row (one element): name, pinned, the summary line as shown, notifications off, unread.
/// With notifications off the number is in "[N 条]"; behind "[有人@我]" or "[草稿]" the dot reads "有新消息".
public func convRowAccessibilityText(
    name: String, conv: Conversation, prefix: SummaryPrefix, summary: String, draft: String?
) -> String {
    var parts = [name]
    if conv.isPinned { parts.append("已置顶") }
    switch prefix {
    case .mention: parts.append("[有人@我] \(summary)")
    case .draft: parts.append("[草稿] \(draft ?? "")")
    case .unread(let n): parts.append(conv.lastMsg != nil ? "\(unreadPrefixText(n)) \(summary)" : unreadPrefixText(n))
    case .none: if conv.lastMsg != nil { parts.append(summary) }
    }
    if conv.isNotifyOff { parts.append("免打扰") }
    switch convBadge(conv) {
    case .count(let text): parts.append("未读 \(text)")
    case .dot: if case .unread = prefix {} else { parts.append("有新消息") }
    case .none: break
    }
    return parts.joined(separator: "，")
}
