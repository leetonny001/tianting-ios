import Foundation
import TiantingIM

public let maxApplyMessage = 50
public let maxRemark = 32
public let maxNickname = 32

/// Code points after trimming (PRD-core 3.1).
public func textLength(_ s: String) -> Int {
    countCodePoints(trimText(s))
}

/// userId format (PRD-core 3.1).
public func isValidUserId(_ s: String) -> Bool {
    let n = s.utf8.count
    guard n >= 1, n <= 64 else { return false }
    return s.utf8.allSatisfy { b in
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b == 0x2D
    }
}

public func badgeText(_ n: Int) -> String {
    n > 99 ? "99+" : String(n)
}

/// Whether the user card shows "发消息" (F-UI-14 rule 3).
public func canChat(relation: Relation, isFriend: Bool, mode: SocialMode, official: Bool) -> Bool {
    let open = mode == .open
    switch relation {
    case .friend: return true
    case .blocked: return open || isFriend
    case .pendingIn, .pendingOut: return open
    case .none: return open || official
    default: return false
    }
}

/// The second line of a friend request (F-UI-25 rule 1).
public func requestSecondLine(_ r: FriendRequest) -> String {
    if r.direction == .incoming { return r.message.isEmpty ? "请求添加你为朋友" : r.message }
    return r.message.isEmpty ? "等待对方验证" : "我：\(r.message)"
}

/// The right-hand state of a friend request; nil means the "同意" button (F-UI-25 rule 2).
public func requestStateText(_ r: FriendRequest) -> String? {
    if r.status == .expired { return "已过期" }
    if r.status == .accepted { return "已添加" }
    if r.direction == .outgoing { return "等待验证" }
    if r.status == .rejected { return "已拒绝" }
    return nil
}

public func applySourceText(_ source: ApplySource) -> String? {
    switch source {
    case .search: return "通过搜索添加"
    case .group: return "通过群聊添加"
    case .card: return "通过名片添加"
    case .conv: return "通过聊天添加"
    default: return nil
    }
}

/// F-UI-05 rule 4: in friends mode, starting a chat with a non-friend warns first; myself never warns.
public func startChatNeedsWarning(target: String, me: String, mode: SocialMode, relation: Relation) -> Bool {
    mode == .friends && target != me && relation != .friend
}

/// Local filter of the friend picker (F-UI-35 rule 2): display name or userId, case-insensitive.
public func filterFriends(_ friends: [Friend], query: String) -> [Friend] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if q.isEmpty { return friends }
    return friends.filter { $0.displayName.lowercased().contains(q) || $0.userId.lowercased().contains(q) }
}
