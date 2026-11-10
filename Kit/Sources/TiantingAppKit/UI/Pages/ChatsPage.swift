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
    /// "[有人@我]" over "[草稿]" (F-MEN-03 rule 2); with a mention the last message's summary follows (issue 38).
    private var prefix: SummaryPrefix { summaryPrefix(conv, hasDraft: draft != nil) }

    var body: some View {
        Button {
            model.push(.chat(conv.convId))
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: TS.s3) {
                    Avatar(id: avatarId, name: name, size: 48, group: isGroup)
                        .overlay(alignment: .topTrailing) {
                            if conv.unread > 0 {
                                CountBadge(text: badgeText(Int(conv.unread))).offset(x: 6, y: -6)
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
                        summaryLine
                    }
                }
                .padding(.horizontal, TS.s4)
                .padding(.vertical, TS.s2)
                .frame(maxWidth: .infinity, minHeight: Tokens.Size.convItem - 1, alignment: .leading)
                TC.divider.frame(height: 1).padding(.leading, 76)
            }
            .background(TC.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("conv-item")
        .task(id: conv.lastMsg?.from) {
            var ids: [String] = []
            if let from = conv.lastMsg?.from, isGroup, !from.isEmpty { ids.append(from) }
            if !isGroup { ids.append(avatarId) }
            await store.loadProfiles(ids)
        }
    }

    @ViewBuilder private var summaryLine: some View {
        if prefix == .mention {
            // The same danger color as "[草稿]" (issue 38).
            HStack(spacing: TS.s1) {
                Text("[有人@我]").foregroundStyle(TC.danger).fixedSize()
                Text(summary).foregroundStyle(TC.textSecondary).lineLimit(1)
            }
            .font(TTFont.small)
        } else if prefix == .draft, let draft {
            HStack(spacing: TS.s1) {
                Text("[草稿]").foregroundStyle(TC.danger).fixedSize()
                Text(draft).foregroundStyle(TC.textSecondary).lineLimit(1)
            }
            .font(TTFont.small)
        } else if conv.lastMsg != nil {
            Text(summary).font(TTFont.small).foregroundStyle(TC.textSecondary).lineLimit(1)
        }
    }

    /// The whole row reads as one element: name, summary or draft, and unread.
    private var accessibilityText: String {
        var parts = [name]
        if prefix == .mention {
            parts.append("[有人@我] \(summary)")
        } else if prefix == .draft, let draft {
            parts.append("[草稿] \(draft)")
        } else if conv.lastMsg != nil {
            parts.append(summary)
        }
        if conv.unread > 0 { parts.append("未读 \(badgeText(Int(conv.unread)))") }
        return parts.joined(separator: "，")
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
