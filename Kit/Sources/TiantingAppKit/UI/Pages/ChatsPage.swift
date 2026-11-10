import SwiftUI
import TiantingIM

/// The "+" menu (F-UI-05): 发起群聊, 添加朋友, 发起单聊.
struct PlusMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button {
                model.push(.groupNew)
            } label: {
                Text("发起群聊")
            }
            .accessibilityIdentifier("plus-new-group")
            Button {
                model.push(.addFriend)
            } label: {
                Text("添加朋友")
            }
            .accessibilityIdentifier("plus-add-friend")
            Button {
                presentStartChat(model)
            } label: {
                Text("发起单聊")
            }
            .accessibilityIdentifier("plus-start-chat")
        } label: {
            Icon(name: .plus).foregroundStyle(TC.textPrimary)
                .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("plus-button")
    }
}

@MainActor
func presentStartChat(_ model: AppModel) {
    guard let store = model.store else { return }
    model.hub.present(id: "start-chat-dialog") {
        StartChatDialog().environment(store)
    }
}

/// The conversation list (PRD-ui F-UI-04).
struct ChatsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ConnBanner()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("top")
                        content
                    }
                }
                .accessibilityIdentifier("conv-list")
                .onChange(of: model.chatsScrollTick) { _, _ in
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("top", anchor: .top) }
                }
            }
        }
        .background(TC.bg)
    }

    @ViewBuilder private var content: some View {
        if !store.convsLoaded && store.convs.isEmpty {
            RowsSkeleton(id: "chats-skeleton", avatar: 48)
        } else if store.convs.isEmpty {
            EmptyStateView(text: "还没有聊天", id: "chats-empty") {
                Button("发起单聊") { presentStartChat(model) }
                    .buttonStyle(TTButtonStyle())
                    .accessibilityIdentifier("chats-empty-start")
            }
        } else {
            let remarks = Dictionary(
                store.friends.filter { !$0.remark.isEmpty }.map { ($0.userId, $0.remark) }, uniquingKeysWith: { a, _ in a })
            ForEach(store.convs, id: \.convId) { conv in
                ConvItem(
                    conv: conv,
                    remark: conv.type == .c2c ? remarks[conversationAvatarId(conv, me: store.me)] : nil,
                    draft: model.drafts.text(conv.convId))
            }
            if store.truncated {
                Text("仅显示最近 500 个会话")
                    .font(TTFont.caption)
                    .foregroundStyle(TC.textTertiary)
                    .padding(TS.s4)
                    .accessibilityIdentifier("convs-truncated")
            }
        }
    }
}

private struct ConvItem: View {
    let conv: Conversation
    let remark: String?
    let draft: String?
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    private var isGroup: Bool { conv.type == .group }
    private var avatarId: String { conversationAvatarId(conv, me: store.me) }
    private var name: String { remark ?? conv.name }
    private var summary: String {
        conversationSummary(conv, me: store.me) { store.displayName($0) }
    }
    /// One prefix: "[有人@我]" > "[草稿]" > "[N 条]" (F-MEN-03 rule 2, frontend-chat 61); with a mention or "[N 条]" the last
    /// message's summary follows (issue 38).
    private var prefix: SummaryPrefix { summaryPrefix(conv, hasDraft: draft != nil) }
    /// The menu's items, by the current state (AC-CVS-01-6); none with features.convSettings off.
    private var menu: [ConvMenuItem] { convMenuItems(conv, enabled: model.convSettingsEnabled) }

    var body: some View {
        Button {
            model.push(.chat(conv.convId))
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: TS.s3) {
                    Avatar(id: avatarId, name: name, size: 48, group: isGroup)
                        .overlay(alignment: .topTrailing) {
                            switch convBadge(conv) {
                            case .count(let text): CountBadge(text: text).offset(x: 6, y: -6)
                            case .dot: UnreadDot().offset(x: 3, y: -3)
                            case .none: EmptyView()
                            }
                        }
                    VStack(alignment: .leading, spacing: TS.s1) {
                        HStack(spacing: TS.s1) {
                            Text(name).font(TTFont.body).foregroundStyle(TC.textPrimary).lineLimit(1)
                            if !isGroup, store.profile(avatarId)?.official == true { OfficialTag() }
                            Spacer(minLength: TS.s2)
                            if let ts = conv.lastMsg?.ts {
                                TimelineView(.everyMinute) { context in
                                    Text(formatTime(ts, now: context.date))
                                        .font(TTFont.caption)
                                        .foregroundStyle(TC.textTertiary)
                                        .fixedSize()
                                }
                            }
                        }
                        HStack(spacing: TS.s1) {
                            summaryLine
                            Spacer(minLength: 0)
                            if conv.isNotifyOff {
                                // PRD-ui 6.6 `bell-off`, text.tertiary; the row reads "免打扰" (AC-CVS-02-3).
                                Icon(name: .notifyOff, size: 16).foregroundStyle(TC.textTertiary)
                            }
                        }
                    }
                }
                .padding(.horizontal, TS.s4)
                .padding(.vertical, TS.s2)
                .frame(maxWidth: .infinity, minHeight: Tokens.Size.convItem - 1, alignment: .leading)
                TC.divider.frame(height: 1).padding(.leading, 76)
            }
            // Pinned rows stand apart (F-CVS-01, PRD-ui 6.1 `surface.pinned`, dark mode too).
            .background(conv.isPinned ? TC.surfacePinned : TC.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .contextMenu {
            // Long press (AC-CVS-01-6); the same items are VoiceOver actions below (13.4).
            ForEach(menu, id: \.action) { item in
                Button(role: item.action == .delete ? .destructive : nil) {
                    act(item.action)
                } label: {
                    Text(item.title)
                }
                .accessibilityIdentifier("conv-menu-\(item.action.rawValue)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            convRowAccessibilityText(name: name, conv: conv, prefix: prefix, summary: summary, draft: draft))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("conv-item")
        .accessibilityActions {
            ForEach(menu, id: \.action) { item in
                Button(item.title) { act(item.action) }
            }
        }
        .task(id: conv.lastMsg?.from) {
            var ids: [String] = []
            if let from = conv.lastMsg?.from, isGroup, !from.isEmpty { ids.append(from) }
            if !isGroup { ids.append(avatarId) }
            await store.loadProfiles(ids)
        }
    }

    private func act(_ action: ConvMenuAction) {
        let conv = conv
        switch action {
        case .pin: Task { await model.toggleConvPinned(conv) }
        case .notify: Task { await model.toggleConvNotifyOff(conv) }
        case .delete: model.askDeleteConv(conv.convId)
        }
    }

    @ViewBuilder private var summaryLine: some View {
        switch prefix {
        case .mention:
            // The same danger color as "[草稿]" (issue 38).
            HStack(spacing: TS.s1) {
                Text("[有人@我]").foregroundStyle(TC.danger).fixedSize()
                Text(summary).foregroundStyle(TC.textSecondary).lineLimit(1)
            }
            .font(TTFont.small)
        case .draft:
            HStack(spacing: TS.s1) {
                Text("[草稿]").foregroundStyle(TC.danger).fixedSize()
                Text(draft ?? "").foregroundStyle(TC.textSecondary).lineLimit(1)
            }
            .font(TTFont.small)
        case .unread(let n):
            // Notifications off (F-CVS-02 rule 5): the count is here, not at the avatar; N as it is (frontend-chat 61).
            HStack(spacing: TS.s1) {
                Text(verbatim: unreadPrefixText(n)).foregroundStyle(TC.textSecondary).fixedSize()
                if conv.lastMsg != nil { Text(summary).foregroundStyle(TC.textSecondary).lineLimit(1) }
            }
            .font(TTFont.small)
        case .none:
            if conv.lastMsg != nil {
                Text(summary).font(TTFont.small).foregroundStyle(TC.textSecondary).lineLimit(1)
            }
        }
    }
}

/// The unread mark of a conversation with notifications off: `badge.bg`, no number (PRD-ui F-UI-04 rule 4).
private struct UnreadDot: View {
    var body: some View {
        Circle().fill(TC.badgeBg).frame(width: 10, height: 10)
    }
}

/// 发起单聊 (F-UI-05, F-CONV-03): the same dialog from the "+" menu and the empty state.
struct StartChatDialog: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var value = ""
    @State private var error = ""
    @State private var warned = false
    @FocusState private var focused: Bool

    private var target: String { trimText(value) }

    var body: some View {
        VStack(alignment: .leading, spacing: TS.s4) {
            Text("发起单聊").font(TTFont.title).foregroundStyle(TC.textPrimary)
            TTTextField(placeholder: "输入对方账号", text: $value, id: "start-chat-input", ascii: true, submit: .go) { start() }
                .focused($focused)
                .onChange(of: value) { _, _ in
                    error = ""
                    warned = false
                }
            if !error.isEmpty { FieldError(text: error, id: "start-chat-error") }
            if warned {
                Text("对方不是你的好友，可能无法发送消息")
                    .font(TTFont.small)
                    .foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("start-chat-warning")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: TS.s3) { warnedButtons }
                    VStack(spacing: TS.s2) { warnedButtons }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: TS.s3) { buttons }
                    VStack(spacing: TS.s2) { buttons }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { focused = true }
    }

    @ViewBuilder private var buttons: some View {
        Button {
            model.hub.dismissDialog()
        } label: {
            Text("取消").frame(maxWidth: .infinity)
        }
        .buttonStyle(TTButtonStyle(kind: .secondary))
        .accessibilityIdentifier("start-chat-cancel")
        Button {
            start()
        } label: {
            Text("开始聊天").frame(maxWidth: .infinity)
        }
        .buttonStyle(TTButtonStyle())
        .disabled(target.isEmpty)
        .accessibilityIdentifier("start-chat-submit")
    }

    @ViewBuilder private var warnedButtons: some View {
        Button {
            model.hub.dismissDialog()
            model.push(.apply(target, UserContext(source: .other)))
        } label: {
            Text("添加朋友").frame(maxWidth: .infinity)
        }
        .buttonStyle(TTButtonStyle(kind: .secondary))
        .accessibilityIdentifier("start-chat-add")
        Button {
            open()
        } label: {
            Text("仍然发起").frame(maxWidth: .infinity)
        }
        .buttonStyle(TTButtonStyle())
        .accessibilityIdentifier("start-chat-anyway")
    }

    private func start() {
        guard !target.isEmpty else { return }
        guard isValidUserId(target) else {
            error = errorText(4004)
            return
        }
        if startChatNeedsWarning(
            target: target, me: store.me, mode: store.settings.mode, relation: store.relation(target))
        {
            warned = true
            return
        }
        open()
    }

    private func open() {
        model.hub.dismissDialog()
        model.push(.chat(c2cConvId(store.me, target)))
    }
}
