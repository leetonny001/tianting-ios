import Foundation
import Observation
import TiantingIM

/// SDK state for SwiftUI (the iOS counterpart of tianting-web's `im/hooks.ts`): keeps the snapshots that SDK events carry,
/// so views read plain values and redraw only for what they read. Everything goes through `IMClient` (PRD-ui 2.1).
@MainActor
@Observable
public final class IMStore {
    public let client: IMClient
    public let me: String

    public private(set) var convs: [Conversation]
    /// `convs` has come from the server once (until then the list shows a skeleton, F-UI-20).
    public private(set) var convsLoaded = false
    public private(set) var truncated = false
    public private(set) var state: ConnState
    public private(set) var banner = false
    public private(set) var totalUnread: Int
    public private(set) var pendingCount: Int
    public private(set) var friends: [Friend]
    public private(set) var requests: FriendRequestList
    public private(set) var blocks: [BlockedUser]
    public private(set) var settings: SocialSettings
    public private(set) var socialLoaded: Bool
    public private(set) var official: Bool
    private var messageLists: [String: [Message]] = [:]
    /// Permission tips (F-UI-31): convId → clientMsgId → code. Memory only.
    public private(set) var sendTips: [String: [String: Int]] = [:]
    /// Bumped when `muteState` may have changed.
    public private(set) var muteVersion = 0
    /// Bumped when `conversationSnapshot` may have changed.
    public private(set) var snapshotVersion = 0
    /// Bumped when the profile cache learned something.
    public private(set) var profileVersion = 0
    /// Per group: bumped on `groupChanged`, with the info it brought.
    public private(set) var groupTicks: [String: Int] = [:]
    public private(set) var groupInfos: [String: GroupInfo] = [:]

    public var onFatal: ((FatalReason) -> Void)?
    public var onSendFailed: ((String, String, SendFailure) -> Void)?
    @ObservationIgnored private var subscription: IMSubscription?
    @ObservationIgnored private var activeConv: String?

    public init(client: IMClient, me: String) {
        self.client = client
        self.me = me
        convs = client.conversations()
        state = client.state
        totalUnread = Int(client.totalUnread())
        pendingCount = client.pendingCount()
        friends = client.friends()
        requests = client.friendRequests()
        blocks = client.blocks()
        settings = client.socialSettings()
        socialLoaded = client.socialLoaded()
        official = client.isOfficial()
        subscription = client.on { [weak self] event in self?.handle(event) }
    }

    private func handle(_ event: IMEvent) {
        switch event {
        case .state(let s):
            state = s
        case .banner(let b):
            banner = b
        case .conversations(let list):
            convs = list
            truncated = client.truncated()
            snapshotVersion += 1
            // Before the first `convs` the client emits empty resets; those do not count as loaded.
            if client.state == .connected { convsLoaded = true }
        case .messages(let convId, let list):
            messageLists[convId] = list
        case .totalUnread(let n):
            totalUnread = n
        case .pendingCount(let n):
            pendingCount = n
        case .sendFailed(let convId, let id, let error):
            if case .code(let code) = error, [4035, 4036, 4137].contains(code) {
                sendTips[convId, default: [:]][id] = code
            }
            onSendFailed?(convId, id, error)
        case .convRemoved:
            snapshotVersion += 1
        case .muteChanged:
            muteVersion += 1
        case .fatal(let reason):
            onFatal?(reason)
        case .friends(let list):
            friends = list
            socialLoaded = client.socialLoaded()
            official = client.isOfficial()
        case .friendRequests(let list):
            requests = list
        case .blocks(let list):
            blocks = list
        case .socialSettings(let s):
            settings = s
        case .groupChanged(let groupId, let info):
            groupInfos[groupId] = info
            groupTicks[groupId, default: 0] += 1
        }
    }

    public var connected: Bool { state == .connected }

    public func conversation(_ convId: String) -> Conversation? {
        convs.first { $0.convId == convId }
    }

    public func messages(_ convId: String) -> [Message] {
        if let list = messageLists[convId] { return list }
        return client.messages(convId)
    }

    public func snapshot(_ convId: String) -> ConversationSnapshot? {
        _ = snapshotVersion
        return client.conversationSnapshot(convId)
    }

    public func mute(_ convId: String) -> MuteInfo? {
        _ = muteVersion
        return client.muteState(convId)
    }

    public func relation(_ userId: String) -> Relation {
        _ = friends
        _ = requests
        _ = blocks
        return client.relationOf(userId)
    }

    /// Display name: remark, nickname, userId (PRD-ui 2.1).
    public func displayName(_ userId: String) -> String {
        _ = friends
        _ = profileVersion
        return client.displayName(userId)
    }

    public func profile(_ userId: String) -> UserProfile? {
        _ = profileVersion
        return client.profileOf(userId)
    }

    /// Loads profiles into the SDK's cache (invisible and absent users simply stay unknown, F-SOC-10).
    public func loadProfiles(_ ids: [String]) async {
        guard connected, !ids.isEmpty else { return }
        let missing = ids.filter { client.profileOf($0) == nil }
        let before = missing.count
        let got = await client.getUsers(ids)
        if before > 0, !got.isEmpty { profileVersion += 1 }
    }

    /// Only the visible chat page is the active conversation (F-UI-06 rule 8).
    public func setActive(_ convId: String) {
        activeConv = convId
        client.setActiveConversation(convId)
    }

    public func clearActive(_ convId: String) {
        guard activeConv == convId else { return }
        activeConv = nil
        client.setActiveConversation(nil)
    }
}
