import Foundation
import Network
import Observation
import SwiftUI
import TiantingIM
import UIKit

/// Who is logged in. Tokens stay with `AccountClient`.
public struct SessionInfo: Sendable, Equatable {
    public var userId: String
    public var mode: SessionMode
}

/// The save page's content (F-ACC-05 rule 1). `code` nil: the newest generation has no code on this device, the user asks
/// for a new one with the password. Memory only.
public struct RecoveryPrompt: Equatable {
    public var code: String?
    public var gen: Int64?
}

/// `GET /v1/config` for the login page: a failure guesses nothing (F-ACC-07 rule 4).
public enum ConfigState: Equatable {
    case loading, failed
    case loaded(AccountConfig)
}

/// The running app: session, SDK clients, navigation. One `AccountClient` for the process (it keeps the pending logouts);
/// one `IMClient` per login, and logging out replaces it.
@MainActor
@Observable
public final class AppModel {
    public private(set) var session: SessionInfo?
    public private(set) var store: IMStore?
    /// This login's system notices (F-UI-44).
    public private(set) var notices: NoticeStore?
    /// This login's images and files (FE-637, FE-638).
    public private(set) var media: MediaOps?
    public private(set) var drafts = DraftStore()
    /// Kicked or the login ended: the dialog that cannot be dismissed (F-UI-18).
    public private(set) var fatal: FatalReason?
    /// Blocks everything until the code is confirmed (AC-ACC-01-12, F-ACC-05 rule 1).
    public private(set) var recovery: RecoveryPrompt?
    /// The stored session has not been read yet: neither the login page nor the list.
    public private(set) var booting = true
    public private(set) var loginConfig: ConfigState = .loading
    public private(set) var cachedConfig: CachedConfig?
    public var tab: AppTab = .chats
    public var path: [Route] = []
    /// Bumped to scroll the conversation list to the top (F-UI-01 rule 4).
    public private(set) var chatsScrollTick = 0
    /// Where to go after logging in (AC-UI-01-3).
    public private(set) var pendingDestination: Destination?
    /// Network reachability: "网络不可用" vs "连接中…" (F-CONN-02).
    public private(set) var online = true

    public let config: AppConfig
    public let hub = UIHub()
    public let theme: ThemeController
    public let account: AccountClient
    @ObservationIgnored private let sessions: AccountSessionStore
    @ObservationIgnored private let prefs: UIPrefs
    @ObservationIgnored private let makeClient: (AppConfig, FileClient?) -> IMClient
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var accountSubscription: IMSubscription?
    @ObservationIgnored private var logoutTask: Task<Void, Never>?
    /// Logged out but not destroyed yet. A new session destroys it first: it would connect with the new token, and its
    /// `destroy` removes the database the new session uses.
    @ObservationIgnored private var closingClient: IMClient?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var askNoticeOnEnter = false
    /// Each login gets its own navigation state and page state.
    public private(set) var loginId = 0

    public init(
        config: AppConfig,
        sessions: AccountSessionStore,
        theme: ThemeController = ThemeController(),
        prefs: UIPrefs = UIPrefs(),
        makeClient: ((AppConfig, FileClient?) -> IMClient)? = nil,
        makeAccount: ((AppConfig, AccountSessionStore) -> AccountClient)? = nil
    ) {
        self.config = config
        self.sessions = sessions
        self.theme = theme
        self.prefs = prefs
        self.makeClient = makeClient ?? AppModel.liveClient
        prefs.removeAll(prefix: "ui.noticeVersion.")  // Named with the plain user id and kept after logout (issue A2).
        MediaOps.clearTemp()  // Picked and processed copies an earlier run left (killed while processing).
        account = makeAccount?(config, sessions) ?? AppModel.liveAccount(config, sessions)
        cachedConfig = prefs.get(Self.configKey).flatMap { try? JSONDecoder().decode(CachedConfig.self, from: Data($0.utf8)) }
        accountSubscription = account.on { [weak self] in self?.handle($0) }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied && !TestHooks.forceOffline
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.online = online } }
        }
        monitor.start(queue: DispatchQueue(label: "tianting.app.network"))
    }

    deinit {
        monitor.cancel()
    }

    private static func databaseDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tianting", isDirectory: true)
    }

    private static func liveClient(_ config: AppConfig, _ files: FileClient?) -> IMClient {
        var options = IMClientOptions(url: config.webSocketURL ?? "wss://invalid.invalid/ws")
        options.platform = .ios
        options.databaseDirectory = databaseDirectory()
        // Sandbox copies under the database directory (Application Support, excluded from backup by the SDK), downloads in
        // Caches (F-FILE-07 rule 2, F-FILE-03 rule 3).
        options.files = files
        return IMClient(options: options)
    }

    /// The SDK's sandbox (the default under the database directory).
    static var attachmentRoot: URL? { databaseDirectory()?.appendingPathComponent("tianting-attachments", isDirectory: true) }

    /// Files in the SDK's sandbox, every user: what the UI tests read through the debug probe (AC-FILE-07-5, 07-9).
    nonisolated static func attachmentFileCount() -> Int {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tianting/tianting-attachments"),
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return 0 }
        var n = 0
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { n += 1 }
        return n
    }

    /// `features.files` (F-FILE, 13.3): the "+" and the avatar entry are hidden when off.
    public var filesEnabled: Bool {
        if case .loaded(let c) = loginConfig { return c.features.files }
        return cachedConfig?.files == true
    }

    /// `features.msgActions` (PRD-ui F-UI-09 rule 4, `IM_MSG_ACTIONS_ENABLED`): "引用", "撤回" and @ only when on; a server
    /// without the field reads as off (issue 36).
    public var msgActionsEnabled: Bool {
        if case .loaded(let c) = loginConfig { return c.features.msgActions == true }
        return cachedConfig?.msgActions == true
    }

    private static func liveAccount(_ config: AppConfig, _ sessions: AccountSessionStore) -> AccountClient {
        var options = AccountClientOptions(baseUrl: config.apiBase)
        options.platform = .ios
        options.deviceName = UIDevice.current.model
        options.store = sessions
        options.unregisterSystemPushToken = { UIApplication.shared.unregisterForRemoteNotifications() }
        return AccountClient(options: options)
    }

    // MARK: Session

    /// Cold start: picks up a stored session and connects (PRD-ui 3.4, F-ACC-03 rule 5). An expired access token refreshes
    /// first inside the SDK; the list shows from the cache meanwhile. No session: nothing to connect (K7).
    public func restore() async {
        guard !restored else { return }
        restored = true
        defer { booting = false }
        // A throw is a locked Keychain or the like: not logged in for now, and nothing gets cleared.
        _ = try? await account.start()
        guard account.session != nil else {
            // Killed during a logout, before the client cleaned up after itself.
            if let dir = Self.databaseDirectory() { try? FileManager.default.removeItem(at: dir) }
            return
        }
        enterSession()
        refreshCachedConfig()
    }

    /// Demo login: no refresh token, nothing for the SDK to refresh (F-ACC-07).
    public func login(_ demo: AccountSession) async {
        closeLoggedOutClient()
        account.restore(demo)  // Before the save: a logout in flight now knows of the new session and leaves the store alone.
        try? await sessions.save(demo)
        fatal = nil
        enterSession()
    }

    /// An account session was adopted: the IM connection starts, unless the recovery code still has to be saved.
    private func accept(_ result: AuthResult, askNotice: Bool) {
        askNoticeOnEnter = askNotice
        if let code = result.recoveryCode, let gen = result.recoveryCodeGen {
            recovery = RecoveryPrompt(code: code, gen: gen)
            return
        }
        if store == nil { enterSession() }
    }

    private func enterSession() {
        guard let s = account.session else { return }  // Ended meanwhile: connecting now would only say so again (K7).
        begin(s)
        if let next = pendingDestination {
            pendingDestination = nil
            go(next)
        }
        if askNoticeOnEnter {
            askNoticeOnEnter = false
            askNoticeIfUpdated(s.userId)
        }
    }

    private func begin(_ s: AccountSession) {
        // The file endpoints: account sessions through AccountClient (4011 per rule 7); demo sessions with their fixed token.
        let auth: FileAuth = s.mode == .account ? account : StaticTokenAuth(baseUrl: config.apiBase, token: s.accessToken)
        let files = FileClient(auth: auth)
        let client = makeClient(config, files)
        let store = IMStore(client: client, me: s.userId)
        let media = MediaOps(client: client, files: files)
        store.onFilesExpired = { [weak media] ids in media?.forget(ids) }
        // A file download stopped by a recall: "该消息已被撤回"; a deletion or expiry says nothing more, the bubble changes
        // itself (issue 46). The SDK removed the partial file.
        store.onDownloadAborted = { [weak self, weak media] fileId, recalled in
            if media?.downloadAborted(fileId) == true, recalled { self?.hub.show(messageRecalledText) }
        }
        self.media = media
        store.onFatal = { [weak self] reason in self?.stop(reason) }
        store.onSendFailed = { [weak self] _, _, error in
            // 4035 / 4036 / 4137 insert a tip in the chat page (F-UI-31), 4031 has the bar (F-UI-41 rule 5);
            // timeouts and kicks show nothing (F-UI-08 rule 3).
            guard case .code(let code) = error, ![4031, 4035, 4036, 4137].contains(code) else { return }
            self?.hub.show(errorText(code, cmd: "send"))
        }
        store.onSecurityNotice = { [weak self] notice in  // AC-ACC-02-13, AC-ACC-03-25, AC-ACC-03-45.
            if let text = securityNoticeText(notice.kind) { self?.hub.show(text) }
        }
        self.store = store
        let notices = NoticeStore(client: client, userId: s.userId, prefs: prefs)
        notices.attach()  // Before connecting: with a subscriber the SDK catches up as soon as auth succeeds.
        self.notices = notices
        session = SessionInfo(userId: s.userId, mode: s.mode)
        drafts = DraftStore()
        tab = .chats
        path = []
        loginId += 1
        client.restoreCache(userId: s.userId)
        switch s.mode {
        case .account: client.connect(tokenProvider: account.tokenProvider)
        case .demo: client.connect(token: s.accessToken)
        }
        TTLog.event("session.started")
    }

    private func handle(_ event: AccountEvent) {
        switch event {
        case .recoveryCodeUnacked:
            if recovery == nil, account.session?.mode == .account { recovery = RecoveryPrompt() }  // F-ACC-05 rule 1.
        case .ended(let end):
            // A logout started here. A kick came as the client's fatal. With a client bound its fatal came just before this:
            // the dialog is up, or there was nothing to say and the logout already ran. So only without a client: on the save
            // page, or between reading the session and connecting.
            if end.action == .logout || end.origin == .kick || fatal != nil || store != nil { return }
            if recovery != nil || fatalNeedsDialog(.session(end)) { stop(.session(end)) }
        case .tokens, .outcome:
            break
        }
    }

    /// The connection or the session stopped for good.
    private func stop(_ reason: FatalReason) {
        recovery = nil
        if fatalNeedsDialog(reason) {
            fatal = reason
        } else {
            logout(keepNoticeSeen: true)
        }
    }

    /// The dialog's "确定": back to login, local data cleared (AC-ACC-04-5). A notice baseline stays (F-PUSH-12 rule 5).
    public func acknowledgeFatal() {
        logout(keepNoticeSeen: true)
    }

    /// F-AUTH-05: clears memory, the local database and the token at once as far as the user can see; `ui.*` stays (F-UI-16
    /// rule 3), except the notice baseline. A kick or a dead credential keeps that too, so logging in again does not repeat
    /// reminders (F-PUSH-12 rule 5). The push cursor is not in the local database and stays in every case (PRD-live 4.9).
    ///
    /// The page does not wait: `AccountClient.logout()` can hang on the network for 30 seconds (K2). It writes the pending
    /// record and clears the stored token first, tells the server, and only then does the connection close with 1000; a new
    /// login before the answer closes it right then. The logout ends only its own session (issue A1).
    public func logout(keepNoticeSeen: Bool = false) {
        notices?.detach()
        notices = nil
        media?.clear()
        media = nil
        if !keepNoticeSeen, let userId = session?.userId { prefs.set(noticeSeenKey(userId), nil) }
        let client = store?.client
        if let client { closingClient = client }
        store = nil
        session = nil
        fatal = nil
        recovery = nil
        drafts = DraftStore()
        path = []
        tab = .chats
        pendingDestination = nil
        hub.dismissDialog()
        let previous = logoutTask
        logoutTask = Task { [weak self, account] in
            await account.logout()
            if let client, self?.closingClient === client { self?.closeLoggedOutClient() }
            await previous?.value
        }
        TTLog.event("session.ended")
    }

    private func closeLoggedOutClient() {
        closingClient?.destroy()
        closingClient = nil
    }

    /// Every logout so far got its answer or timed out. Nothing needs this to log in again.
    public func logoutFinished() async {
        await logoutTask?.value
    }

    // MARK: Account pages

    public func accountLogin(username: String, password: String) async throws {
        closeLoggedOutClient()
        accept(try await account.login(username: username, password: password), askNotice: true)
    }

    public func accountRegister(username: String, password: String, nickname: String?, inviteCode: String?) async throws {
        closeLoggedOutClient()
        let result = try await account.register(
            username: username, password: password, nickname: nickname, inviteCode: inviteCode)
        // Registering agrees to the version on show (F-ACC-10 rule 2).
        if case .loaded(let c) = loginConfig, let v = c.privacyNotice?.version { prefs.set(privacyAckKey(result.userId), v) }
        accept(result, askNotice: false)
    }

    public func accountRecover(username: String, recoveryCode: String, newPassword: String) async throws {
        closeLoggedOutClient()
        accept(try await account.recover(username: username, recoveryCode: recoveryCode, newPassword: newPassword), askNotice: true)
    }

    public func cancelDeletion(username: String, password: String) async throws {
        try await account.cancelDelete(username: username, password: password)
    }

    public func changePassword(old: String, new: String) async throws {
        accept(try await account.changePassword(oldPassword: old, newPassword: new), askNotice: false)
    }

    public func logoutOthers(password: String) async throws {
        accept(try await account.logoutOthers(password: password), askNotice: false)
    }

    /// The avatar (F-ACC-06 rules 3, 4): upload kind=avatar, then PATCH profile. Shown from the local file in this login
    /// (the SDK fetches the new address too, issue H13). A failure throws; the nickname is not touched here.
    public func changeAvatar(_ jpeg: URL) async throws {
        guard let media else { return }
        let fileId = try await media.uploadAvatar(jpeg)
        try await account.updateProfile(avatarFileId: fileId)
        media.setLocalAvatar(jpeg)
    }

    public func requestRecoveryCode(password: String) async throws {
        let r = try await account.regenerateRecoveryCode(password: password)
        recovery = RecoveryPrompt(code: r.recoveryCode, gen: r.recoveryCodeGen)
    }

    /// "我已保存": the token reaches the Keychain only inside this call, when it was memory only (RS5-13).
    public func confirmRecovery() async throws {
        guard let gen = recovery?.gen else { return }
        try await account.ackRecoveryCode(gen: gen)
        recovery = nil
        if store == nil { enterSession() }
    }

    // MARK: Configuration

    private static let configKey = "ui.config"

    /// The login page's entries. Each attempt starts from "loading", so a retry never shows a stale mode.
    public func loadLoginConfig() async {
        loginConfig = .loading
        do {
            let c = try await account.getConfig()
            remember(c)
            loginConfig = .loaded(c)
        } catch {
            loginConfig = .failed
        }
    }

    /// Logged in: a failure keeps the last value (F-ACC-07 rule 4).
    private func refreshCachedConfig() {
        Task { if let c = try? await account.getConfig() { remember(c) } }
    }

    private func remember(_ c: AccountConfig) {
        let cached = CachedConfig(c)
        cachedConfig = cached
        if let data = try? JSONEncoder().encode(cached) {
            prefs.set(Self.configKey, String(decoding: data, as: UTF8.self))
        }
    }

    /// The address behind "隐私说明" (F-ACC-10); nil hides the entries.
    public var noticeURL: URL? {
        if case .loaded(let c) = loginConfig, let url = privacyURL(c.privacyNotice?.url) { return url }
        return privacyURL(cachedConfig?.privacyURL)
    }

    /// F-ACC-10 rule 2: once per new version, and not agreeing blocks nothing. The server has no way to record it or to say
    /// which version an account agreed to, so this device remembers (see "实现时发现的问题").
    private func askNoticeIfUpdated(_ userId: String) {
        let version: String?
        if case .loaded(let c) = loginConfig { version = c.privacyNotice?.version } else { version = cachedConfig?.privacyVersion }
        guard let version, !version.isEmpty, prefs.get(privacyAckKey(userId)) != version else { return }
        let key = privacyAckKey(userId)
        hub.present(id: "privacy-update-dialog") {
            PrivacyUpdateDialog {
                self.prefs.set(key, version)
                self.hub.dismissDialog()
            } open: {
                self.prefs.set(key, version)
                self.hub.dismissDialog()
                self.push(.privacyNotice)
            }
        }
    }

    // MARK: Navigation

    public func push(_ route: Route) {
        path.append(route)
    }

    public func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    public func popToRoot() {
        path = []
    }

    /// Back to a page further down the stack; used after an action that ends the pages on top.
    public func replaceTop(with route: Route) {
        if !path.isEmpty { path.removeLast() }
        path.append(route)
    }

    public func selectTab(_ next: AppTab) {
        if next == .chats, tab == .chats { chatsScrollTick += 1 }
        tab = next
    }

    /// Tapping the notice banner.
    func openNotices() {
        notices?.dismissBanner()
        go(Destination(tab: .me, path: [.notices]))
    }

    func go(_ destination: Destination) {
        tab = destination.tab
        path = destination.path
    }

    /// `tianting://` (AC-UI-01-3, AC-UI-01-7): not logged in, the login page comes first.
    public func handle(url: URL) {
        let destination = parseDeepLink(url)
        if session == nil {
            pendingDestination = destination
        } else {
            go(destination)
        }
    }
}
