import SwiftUI
import TiantingIM

/// The app's root. `@main` lives in the Xcode target (App/TiantingApp.swift).
public struct TiantingRootView: View {
    @State private var model: AppModel

    public init() {
        let sessions = KeychainSessionStore()
        Self.prepareForTestsIfAsked(sessions)
        _model = State(initialValue: AppModel(config: .load(), sessions: sessions))
    }

    init(model: AppModel) {
        _model = State(initialValue: model)
    }

    /// UI tests start from a clean device state. Debug builds only.
    private static var didReset = false
    private static func prepareForTestsIfAsked(_ sessions: KeychainSessionStore) {
        #if DEBUG
            guard !didReset else { return }
            didReset = true
            if ProcessInfo.processInfo.environment["TT_RESET_STATE"] == "1" {
                sessions.wipe()
                UIPrefs().removeAll()
                try? FileManager.default.removeItem(at: FilePushCursorStore.defaultDirectory)
                if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("tianting"))
                }
            }
            // TC-FILE-07-10: the sandbox copies are gone (no way for a test to reach the app's container otherwise).
            if ProcessInfo.processInfo.environment["TT_TEST_DROP_SANDBOX"] == "1", let root = AppModel.attachmentRoot {
                try? FileManager.default.removeItem(at: root)
            }
            if let legacy = TestHooks.legacySession { sessions.seedLegacySession(userId: legacy.userId, token: legacy.token) }
        #endif
    }

    public var body: some View {
        Group {
            // The save page replaces everything, so there is no page under it for a back gesture to reach (AC-ACC-01-12).
            if model.recovery != nil {
                RecoveryCodePage()
            } else if model.booting {
                TC.bg.ignoresSafeArea()
            } else if let store = model.store {
                LoggedInView()
                    .environment(store)
                    .id(model.loginId)
            } else {
                LoginPage()
            }
        }
        .overlay { ToastLayer() }
        .overlay(alignment: .topLeading) { TestStateProbe() }
        .environment(model)
        .background(TC.bg.ignoresSafeArea())
        .tint(TC.brand)
        // At the root: a session can end on the login page or the save page too.
        .fullScreenCover(item: Binding(get: { model.fatal.map(FatalItem.init) }, set: { _ in })) { item in
            KickedDialog(reason: item.reason).environment(model)
        }
        .onAppear {
            // Windows exist once the first frame is on its way.
            DispatchQueue.main.async { model.theme.apply() }
        }
        .task { await model.restore() }
        .onOpenURL { model.handle(url: $0) }
    }
}

private struct LoggedInView: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        @Bindable var model = model
        ZStack {
            NavigationStack(path: $model.path) {
                MainTabs()
                    // Keyed by route: a deep link from one chat to another must not keep the old page's state.
                    .navigationDestination(for: Route.self) { RouteView(route: $0).id($0) }
            }
            NoticeBannerLayer()
            DialogLayer()
        }
    }
}

private struct FatalItem: Identifiable {
    let reason: FatalReason
    var id: String { "fatal" }
}

private struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .chat(let id): ChatPage(convId: id)
        case .chatInfo(let id): ChatInfoPage(convId: id)
        case .notice(let id): GroupNoticePage(convId: id)
        case .members(let id, let mode): GroupMembersPage(convId: id, wanted: mode)
        case .invite(let id): GroupInvitePage(convId: id)
        case .groupNew: GroupNewPage()
        case .requests: RequestsPage()
        case .addFriend: AddFriendPage()
        case .groups: GroupsPage()
        case .apply(let id, let context): ApplyPage(userId: id, context: context)
        case .user(let id, let context): UserPage(userId: id, context: context)
        case .remark(let id): RemarkPage(userId: id)
        case .settings: SettingsPage()
        case .blocks: BlocksPage()
        case .privacy: PrivacyPage()
        case .appearance: AppearancePage()
        case .notices: NoticesPage()
        case .accountSecurity: AccountSecurityPage()
        case .security(let action): SecurityFormPage(action: action)
        case .editNickname: EditNicknamePage()
        case .privacyNotice: PrivacyNoticePage()
        }
    }
}

/// The three first-level pages and the tab bar (F-UI-01). Second-level pages are pushed over all of this, so the tab bar
/// goes away with no extra work (AC-UI-01-6). The pages stay alive, which keeps their scroll positions.
private struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(.chats) { ChatsPage() }
                page(.contacts) { ContactsPage() }
                page(.me) { MePage() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TabBar()
        }
        .background(TC.bg)
        .ttNavigationBar(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                switch model.tab {
                case .chats: PlusMenu()
                case .contacts: ContactsAddButton()
                case .me: EmptyView()
                }
            }
        }
    }

    private var title: String {
        switch model.tab {
        case .chats: return "消息"
        case .contacts: return "通讯录"
        case .me: return "我"
        }
    }

    private func page<V: View>(_ tab: AppTab, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .opacity(model.tab == tab ? 1 : 0)
            .allowsHitTesting(model.tab == tab)
            .accessibilityHidden(model.tab != tab)
    }
}

/// The bottom tab bar (F-UI-01, F-UI-23): badges carry the same identifiers as the web.
private struct TabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            TC.divider.frame(height: 1)
            HStack(spacing: 0) {
                item(.chats, "消息", .chats, badge: store.totalUnread, badgeId: "tab-badge")
                item(.contacts, "通讯录", .contacts, badge: store.requests.unseen, badgeId: "tab-contacts-badge")
                item(.me, "我", .me, badge: 0, badgeId: "")
            }
        }
        .background(TC.surface.ignoresSafeArea(edges: .bottom))
    }

    private func item(_ tab: AppTab, _ label: String, _ icon: IconName, badge: Int, badgeId: String) -> some View {
        let selected = model.tab == tab
        return ZStack(alignment: .top) {
            Button {
                model.selectTab(tab)
            } label: {
                VStack(spacing: 2) {
                    Icon(name: icon, size: 24)
                    Text(label).font(TTFont.caption).lineLimit(1).minimumScaleFactor(0.6)
                }
                .foregroundStyle(selected ? TC.brand : TC.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 49)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tab-\(tab.rawValue)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if badge > 0 {
                CountBadge(text: badgeText(badge))
                    .offset(x: 16, y: 2)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(badgeId)
            }
        }
    }
}
