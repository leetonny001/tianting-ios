import Foundation
import TiantingIM

// Error copy (PRD-core section 5, PRD-ui F-UI-19): "command + code" first, then the code's default; the server's `msg`
// is never shown. A new ws code in errors.json must get copy here (ErrorCopyTests walks errors.json).

private let byCode: [Int: String] = [
    4000: "请求出错",
    4001: "当前版本过低，请刷新页面",
    4002: "请求出错",
    4003: "请求出错",
    4004: "账号格式不正确",
    4005: "不能发送空白消息",
    4006: "消息过长",
    4007: "请求出错",
    4008: "请求出错",
    4009: "请求出错",
    4010: "登录已失效，请重新登录",
    4011: "登录已过期，请重新登录",
    4012: "账号已被下线",
    4030: "无权限",
    4031: "你已被禁言",
    4032: "请求出错",
    4033: "你已不在该群",
    4035: "对方开启了好友验证，你还不是他的好友",
    4036: "消息已发出，但被对方拒收了",
    4040: "内容不存在",
    4041: "请求出错",
    4042: "用户不存在",
    4043: "群聊不存在或已解散",
    4045: "该申请已过期",
    4046: "对方已不在群里",
    4090: "请求出错",
    4091: "你们已经是朋友了",
    4130: "请求出错",
    4131: "请求出错",
    4132: "你的好友数量已达上限",
    4133: "对方好友数量已达上限",
    4134: "黑名单已满",
    4135: "加入的群聊已达上限",
    4136: "管理员最多 10 人",
    4137: "对方回复之前，发送的消息数量已达上限",
    4290: "发送太频繁，请稍后再试",
    4292: "今天的次数已用完，明天再试",
    5000: "服务异常，请稍后重试",
    5030: "服务异常，请稍后重试",
]

// Page-only copy, outside the SDK's "command + code" table (PRD-social 9.4).
private let byCommand: [String: [Int: String]] = [
    "friendApply": [4000: "请先将对方移出黑名单"],
    "friendRemark": [4040: "对方已不在你的通讯录中"],
    "groupCreate": [4130: "群成员已达上限"],
    "groupInvite": [4130: "群成员已达上限"],
]

/// Development-time defects: logged, and the UI only says "请求出错" (F-UI-19 rule 5).
private let logOnly: Set<Int> = [4000, 4002, 4003, 4007, 4008]

/// Copy for an error code; unknown 4xxx is "请求出错", 5xxx "服务异常，请稍后重试" (C-09).
public func errorText(_ code: Int, cmd: String? = nil, strangerMsgLimit: Int = 0, name: String = "") -> String {
    if logOnly.contains(code) { TTLog.requestError("request.defect", code: code) }
    if let cmd {
        if let s = byCommand[cmd]?[code] { return s }
        if let s = messageFor(cmd: cmd, code: code, strangerMsgLimit: strangerMsgLimit, name: name) { return s }
    }
    if let s = byCode[code] { return s }
    return code >= 5000 ? "服务异常，请稍后重试" : "请求出错"
}

/// The code of a failed command; timeouts and lost connections read as a server error.
public func errorCode(_ error: Error) -> Int {
    (error as? IMError)?.code ?? 5000
}

public let messageDeletedText = "该消息已被删除"

/// 4034 and `kicked.reason = suspended` (F-UI-18, F-UI-43): no end time when permanent or missing.
public func bannedText(until: Int64?) -> String {
    guard let until else { return "账号已被封禁" }
    return "账号已被封禁，解封时间：\(formatDateTime(until))"
}

/// The mute bar (F-UI-41 rule 3).
public func mutedText(_ until: Until) -> String {
    switch until {
    case .permanent: return errorText(4031)
    case .at(let t): return "你已被禁言，解除时间：\(formatMonthDayTime(t))"
    }
}

private let kickText: [String: String] = [
    "tokenInvalid": "登录已失效，请重新登录",
    "tokenExpired": "登录已过期，请重新登录",
    "banned": "账号已被下线",
    "tooManyConnections": "登录设备过多，当前设备已下线",
]

/// The kicked dialog's copy (F-UI-18): by `kicked.reason`, then by close code.
public func fatalText(_ reason: FatalReason) -> String {
    let code: Int
    switch reason {
    case .kicked(let r, let c, let until):
        if r == "suspended" {
            if case .at(let t)? = until { return bannedText(until: t) }
            return bannedText(until: nil)
        }
        if let s = kickText[r] { return s }
        code = c
    case .closed(let c, _):
        code = c
    }
    if code == 4429 { return "登录设备过多，当前设备已下线" }
    return errorText(code)
}
