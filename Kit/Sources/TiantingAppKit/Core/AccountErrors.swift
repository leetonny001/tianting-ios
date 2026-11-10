import Foundation
import TiantingIM

// The account pages' states and copy (PRD-chat 13.4, AC-ACC-01-13, AC-ACC-01-18, AC-ACC-02-8, AC-ACC-02-9). The server's
// `msg` is never shown. Pure, so every code is a unit test.

public enum AccountPageKind: Sendable {
    case login, register, recover, password, nickname
}

public struct AccountFailure: Equatable, Sendable {
    public var text: String
    /// Shown under the username, not above the button (AC-ACC-01-13).
    public var onUsername = false
    /// Empties the password field (AC-ACC-02-8).
    public var clearPassword = false
    /// A deletion is pending: the date, for the dialog that offers to cancel it (F-ACC-08 rule 2).
    public var deleteAt: Int64?
}

public let networkErrorText = "网络异常，请稍后重试"
public let serviceDownText = "服务暂不可用"
public let tooFrequentText = "操作太频繁，请稍后再试"
public let recoveryLostText = "恢复码丢失后账号无法找回"

public func accountFailure(_ error: Error, page: AccountPageKind) -> AccountFailure {
    if let e = error as? AccountError { return accountFailure(e, page: page) }
    if error is SessionEndedError { return AccountFailure(text: errorText(4010)) }
    if case .status(let status)? = error as? AccountNetworkError, status >= 500 { return AccountFailure(text: serviceDownText) }
    return AccountFailure(text: networkErrorText)
}

private func accountFailure(_ e: AccountError, page: AccountPageKind) -> AccountFailure {
    switch e.code {
    case 4004:
        return AccountFailure(text: "用户名格式不正确")
    case 4095:
        return AccountFailure(text: "这个用户名不能使用", onUsername: true)
    case 4018:
        switch page {
        case .login: return AccountFailure(text: "用户名或密码错误", clearPassword: true)
        case .recover: return AccountFailure(text: "用户名或恢复码错误")
        default: return AccountFailure(text: "密码错误", clearPassword: true)
        }
    case 4000:
        if e.reason == "passwordWeak" { return AccountFailure(text: "密码太简单") }
        if page == .nickname { return AccountFailure(text: "昵称不能使用") }
        return AccountFailure(text: errorText(4000))
    case 4030:
        switch e.reason {
        case "inviteInvalid": return AccountFailure(text: "邀请码无效")
        case "registerClosed": return AccountFailure(text: "暂未开放注册")
        case "accountDeletionPending":
            return AccountFailure(text: "账号正在注销", deleteAt: e.details?["deleteAt"]?.intValue)
        default: return AccountFailure(text: errorText(4030))
        }
    case 4034:
        return AccountFailure(text: bannedText(until: e.details?["bannedUntil"]?.intValue))
    case 4294:
        return AccountFailure(text: lockedText(retryAfterSeconds: e.details?["retryAfterSeconds"]?.intValue))
    case 4290:
        return AccountFailure(text: tooFrequentText)
    case 5030:
        return AccountFailure(text: serviceDownText)
    default:
        return AccountFailure(text: errorText(e.code))
    }
}

/// F-ACC-02 rule 3: rounds up, so waiting that long is enough.
public func lockedText(retryAfterSeconds: Int64?) -> String {
    guard let s = retryAfterSeconds, s > 0 else { return "尝试次数过多，请稍后再试" }
    return "尝试次数过多，请 \((s + 59) / 60) 分钟后再试"
}

public func deletionPendingText(deleteAt: Int64?) -> String {
    let date = deleteAt.map { sessionDate($0) } ?? "7 天"
    return "账号正在注销，\(date)后不可恢复，是否撤销？"
}

public let deletionWarningText = "7 天后不可恢复，用户名不能再使用，已发的消息会保留"

/// The date as in the SDK's dialogs.
public func sessionDate(_ ms: Int64) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "yyyy/M/d"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
}

/// The toast for a `securityNotice`. The new device line is the PRD's (AC-ACC-02-13); the others were added while
/// implementing and wait for confirmation (issue table A12). The SDK already drops unknown kinds; nil is a second guard.
public func securityNoticeText(_ kind: String) -> String? {
    switch kind {
    case "newDeviceLogin": return "你的账号在新设备登录"
    case "recoveryCodeRegenerated": return "你的恢复码已重新生成"
    case "refreshReplay": return "检测到你的账号登录凭证异常"
    case "refreshRateLimited": return "你的账号登录凭证刷新过于频繁"
    case "newIpPrefix": return "你的账号正在新的网络使用"
    case "passwordChanged": return "你的账号密码已被修改"
    case "passwordRecovered": return "你的账号已通过恢复码重设密码"
    default: return nil
    }
}

/// The lines of "最近登录记录" (F-ACC-02 rule 3b); an unknown kind still gets a line.
public func accountEventText(_ kind: String) -> String {
    switch kind {
    case "newDeviceLogin": return "新设备登录"
    case "passwordChanged": return "修改了密码"
    case "passwordRecovered": return "用恢复码找回了密码"
    case "loggedOutOthers": return "退出了其他设备"
    case "recoveryCodeRegenerated": return "重新生成了恢复码"
    case "deletionRequested": return "申请注销账号"
    case "deletionCanceled": return "撤销注销账号"
    case "refreshReplay": return "检测到登录凭证异常"
    case "refreshRateLimited": return "登录凭证刷新过于频繁"
    case "newIpPrefix": return "从新的网络登录"
    default: return "账号活动"
    }
}

public func platformText(_ platform: String?) -> String? {
    switch platform {
    case "ios": return "iOS"
    case "android": return "Android"
    case "web": return "网页"
    case "pc": return "电脑"
    default: return nil
    }
}

// MARK: - Login page entry

/// What the login page shows (F-ACC-07 rules 4, 5, F-ACC-10).
public struct LoginEntry: Equatable, Sendable {
    public var showDemo: Bool
    public var showRegister: Bool
    public var askInviteCode: Bool
    public var privacyURL: URL?
}

/// Both switches have to be on for the demo form; the build's is the upper limit (R-CF-11).
public func loginEntry(_ config: AccountConfig, buildDemoLogin: Bool) -> LoginEntry {
    LoginEntry(
        showDemo: buildDemoLogin && config.demoLogin,
        showRegister: config.registerMode != .closed,
        askInviteCode: config.registerMode == .invite,
        privacyURL: privacyURL(config.privacyNotice?.url))
}

/// Only http(s): the address comes from configuration and goes into a web view.
public func privacyURL(_ raw: String?) -> URL? {
    guard let raw, !raw.isEmpty, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
        scheme == "https" || scheme == "http", url.host != nil
    else { return nil }
    return url
}

/// What is kept of `GET /v1/config` for a logged-in user whose next request fails (F-ACC-07 rule 4). No secrets in it.
public struct CachedConfig: Codable, Equatable, Sendable {
    public var files: Bool
    /// `features.msgActions` (C4); nil from an older server or an older cache: off (issue 36).
    public var msgActions: Bool?
    public var privacyVersion: String?
    public var privacyURL: String?

    public init(_ c: AccountConfig) {
        files = c.features.files
        msgActions = c.features.msgActions
        privacyVersion = c.privacyNotice?.version
        privacyURL = c.privacyNotice?.url
    }
}
