import Foundation
import TiantingIM

// Routes (PRD-ui 3.2) and deep links (AC-UI-01-3, AC-UI-01-7 through the 3.6 table).

public enum MemberMode: String, Hashable, Sendable {
    case view, kick, admin, transfer
}

/// What a page passes to the user card and the apply page (PRD-ui 3.2 "route state"): not in any URL.
public struct UserContext: Hashable, Sendable {
    public var source: ApplySource?
    public var sourceRef: String?
    public var profile: Profile?

    public init(source: ApplySource? = nil, sourceRef: String? = nil, profile: Profile? = nil) {
        self.source = source
        self.sourceRef = sourceRef
        self.profile = profile
    }
}

public enum Route: Hashable, Sendable {
    case chat(String)
    case chatInfo(String)
    case notice(String)
    case members(String, MemberMode)
    case invite(String)
    case groupNew
    case requests
    case addFriend
    case groups
    case apply(String, UserContext)
    case user(String, UserContext)
    case remark(String)
    case settings
    case blocks
    case privacy
    case appearance
    case notices
}

public enum AppTab: String, Hashable, Sendable, CaseIterable {
    case chats, contacts, me
}

public struct Destination: Equatable, Sendable {
    public var tab: AppTab
    public var path: [Route]

    public init(tab: AppTab = .chats, path: [Route] = []) {
        self.tab = tab
        self.path = path
    }

    public static let home = Destination()
}

public func isGroupConv(_ convId: String) -> Bool { convId.hasPrefix("group:") }
public func groupId(ofConv convId: String) -> String { String(convId.dropFirst("group:".count)) }

/// `tianting://` deep links: known routes only, everything else goes to /chats. The chat page validates the conversation
/// id itself (F-UI-33 rule 1), group sub-pages need a group id.
public func parseDeepLink(_ url: URL) -> Destination {
    guard url.scheme?.lowercased() == "tianting",
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.port == nil, c.user == nil
    else { return .home }
    var raw: [String] = []
    if let host = c.percentEncodedHost, !host.isEmpty { raw.append(host) }
    raw += c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init).dropFirst()
    if raw.isEmpty { return .home }
    var segments: [String] = []
    for s in raw {
        guard !s.isEmpty, let decoded = s.removingPercentEncoding, !decoded.isEmpty else { return .home }
        segments.append(decoded)
    }
    return destination(segments)
}

private func destination(_ s: [String]) -> Destination {
    switch s.count {
    case 1:
        switch s[0] {
        case "chats": return .home
        case "contacts": return Destination(tab: .contacts)
        case "me": return Destination(tab: .me)
        default: return .home
        }
    case 2:
        switch (s[0], s[1]) {
        case ("chat", let id): return Destination(path: [.chat(id)])
        case ("groups", "new"): return Destination(path: [.groupNew])
        case ("contacts", "requests"): return Destination(tab: .contacts, path: [.requests])
        case ("contacts", "groups"): return Destination(tab: .contacts, path: [.groups])
        case ("contacts", "add"): return Destination(tab: .contacts, path: [.addFriend])
        case ("user", let id): return Destination(tab: .contacts, path: [.user(id, UserContext())])
        case ("me", "settings"): return Destination(tab: .me, path: [.settings])
        case ("me", "notices"): return Destination(tab: .me, path: [.notices])
        default: return .home
        }
    case 3:
        switch (s[0], s[1], s[2]) {
        case ("chat", let id, "info"): return Destination(path: [.chat(id), .chatInfo(id)])
        case ("chat", let id, "notice") where isGroupConv(id):
            return Destination(path: [.chat(id), .chatInfo(id), .notice(id)])
        case ("chat", let id, "members") where isGroupConv(id):
            return Destination(path: [.chat(id), .chatInfo(id), .members(id, .view)])
        case ("chat", let id, "invite") where isGroupConv(id):
            return Destination(path: [.chat(id), .chatInfo(id), .invite(id)])
        case ("contacts", "apply", let id):
            return Destination(tab: .contacts, path: [.apply(id, UserContext(source: .other))])
        case ("user", let id, "remark"):
            return Destination(tab: .contacts, path: [.user(id, UserContext()), .remark(id)])
        case ("me", "settings", "blocks"): return Destination(tab: .me, path: [.settings, .blocks])
        case ("me", "settings", "privacy"): return Destination(tab: .me, path: [.settings, .privacy])
        case ("me", "settings", "appearance"): return Destination(tab: .me, path: [.settings, .appearance])
        default: return .home
        }
    default:
        return .home
    }
}
