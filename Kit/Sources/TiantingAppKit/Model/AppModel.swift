import Foundation
import Network
import Observation
import SwiftUI
import TiantingIM

/// The running app: session, SDK client, navigation. One `IMClient` per login; logging out replaces it.
@MainActor
@Observable
public final class AppModel {
    public private(set) var session: Session?
    public private(set) var store: IMStore?
    public private(set) var drafts = DraftStore()
    /// Kicked or the login ended: the dialog that cannot be dismissed (F-UI-18).
    public private(set) var fatal: FatalReason?
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
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let makeClient: (AppConfig) -> IMClient
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Each login gets its own navigation state and page state.
    public private(set) var loginId = 0

    public init(
        config: AppConfig,
        sessions: SessionStore,
        theme: ThemeController = ThemeController(),
        makeClient: ((AppConfig) -> IMClient)? = nil
    ) {
        self.config = config
        self.sessions = sessions
        self.theme = theme
        self.makeClient = makeClient ?? AppModel.liveClient
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.online = online } }
        }
        monitor.start(queue: DispatchQueue(label: "tianting.app.network"))
    }

    deinit {
        monitor.cancel()
    }

    private static func liveClient(_ config: AppConfig) -> IMClient {
        var options = IMClientOptions(url: config.webSocketURL ?? "wss://invalid.invalid/ws")
        options.platform = .ios
        options.databaseDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tianting", isDirectory: true)
        return IMClient(options: options)
    }

    /// Cold start: picks up a stored session and reconnects (PRD-ui 3.4).
    public func restore() {
        guard session == nil, let saved = sessions.load() else { return }
        begin(saved)
    }

    public func login(_ newSession: Session) {
        sessions.save(newSession)
        fatal = nil
        begin(newSession)
        if let next = pendingDestination {
            pendingDestination = nil
            go(next)
        }
    }

    private func begin(_ newSession: Session) {
        let client = makeClient(config)
        let store = IMStore(client: client, me: newSession.userId)
        store.onFatal = { [weak self] reason in self?.fatal = reason }
        store.onSendFailed = { [weak self] _, _, error in
            // 4035 / 4036 / 4137 insert a tip in the chat page (F-UI-31), 4031 has the bar (F-UI-41 rule 5);
            // timeouts and kicks show nothing (F-UI-08 rule 3).
            guard case .code(let code) = error, ![4031, 4035, 4036, 4137].contains(code) else { return }
            self?.hub.show(errorText(code, cmd: "send"))
        }
        self.store = store
        session = newSession
        drafts = DraftStore()
        tab = .chats
        path = []
        loginId += 1
        client.restoreCache(userId: newSession.userId)
        client.connect(token: newSession.token)
        TTLog.event("session.started")
    }

    /// F-AUTH-05: closes with 1000, clears memory, the local database and the token; `ui.*` stays (F-UI-16 rule 3).
    public func logout() {
        store?.client.destroy()
        store = nil
        sessions.clear()
        session = nil
        fatal = nil
        drafts = DraftStore()
        path = []
        tab = .chats
        pendingDestination = nil
        hub.dismissDialog()
        TTLog.event("session.ended")
    }

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
