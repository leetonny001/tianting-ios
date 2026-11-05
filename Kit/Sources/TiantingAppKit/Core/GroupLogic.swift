import Foundation
import TiantingIM

public let maxGroupName = 50
public let maxNotice = 1000
public let maxGroupBatch = 50
public let minGroupPick = 2
public let memberGridSize = 20

/// What the group settings page shows (F-UI-36 rule 2). Hiding is only for experience; the server decides.
public struct GroupPermissions: Equatable, Sendable {
    public let canManage: Bool  // name editable, "−", notice editing
    public let canInvite: Bool  // "+"
    public let isOwner: Bool  // set admin, transfer
    public let canDissolve: Bool
    /// The leave dialog's text.
    public let leaveText: String

    public init(role: GroupRole, managed: Bool, owner: String) {
        canManage = role == .owner || role == .admin
        canInvite = !managed || !owner.isEmpty
        isOwner = role == .owner
        canDissolve = !managed && role == .owner
        leaveText = canDissolve ? "你是群主，退出后群主将自动转让给其他成员" : "退出后，将不再接收此群聊消息"
    }
}

/// The management modes my role may enter (F-UI-36 rule 2); otherwise back to viewing.
public func allowedMemberMode(_ wanted: MemberMode, role: GroupRole?) -> MemberMode {
    switch wanted {
    case .kick: return role == .owner || role == .admin ? .kick : .view
    case .admin, .transfer: return role == .owner ? wanted : .view
    case .view: return .view
    }
}

/// F-UI-38 rule 3: the owner picks admins and members, an admin only members.
public func memberSelectable(member: GroupRole, mode: MemberMode, myRole: GroupRole?) -> Bool {
    if member == .owner { return false }
    switch mode {
    case .kick: return myRole == .owner || member == .member
    case .admin, .transfer: return true
    case .view: return false
    }
}

public func roleLabel(_ role: GroupRole) -> String? {
    switch role {
    case .owner: return "群主"
    case .admin: return "管理员"
    default: return nil
    }
}

public func memberErrorText(code: Int, userId: String?, cmd: String, me: String, name: (String) -> String) -> String {
    if code == 4135, userId == me { return "你加入的群聊已达上限" }
    guard let userId else { return errorText(code, cmd: code == 4035 || code == 4135 ? nil : cmd) }
    return errorText(code, cmd: cmd, name: name(userId))
}

/// The ack's result text (F-UI-39 rule 3): at most 3 failures, the rest merged.
public func inviteResultText(_ result: GroupInviteResult, me: String, name: (String) -> String) -> String {
    var parts: [String] = result.added.isEmpty ? [] : ["已邀请 \(result.added.count) 人"]
    for f in result.failed.prefix(3) {
        parts.append(memberErrorText(code: f.code, userId: f.userId, cmd: "groupInvite", me: me, name: name))
    }
    if result.failed.count > 3 { parts.append("另有 \(result.failed.count - 3) 人邀请失败") }
    return parts.joined(separator: "；")
}
