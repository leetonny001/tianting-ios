import SwiftUI
import TiantingIM

/// The chat page (PRD-ui F-UI-06 to F-UI-10, F-UI-31, F-UI-33, F-UI-40 to F-UI-42). The route's conversation id goes
/// through strict parsing first (G-UI-03); a bad one goes back to the list.
struct ChatPage: View {
    let convId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        if let parsed = try? parseConvIdStrict(convId, me: store.me) {
            ChatContent(convId: convId, type: parsed.convType, to: parsed.to)
        } else {
            Color.clear.onAppear { leaveInvalid(model, convId) }
        }
    }
}

@MainActor
/// Leaves only this conversation's pages: another deep link may already have changed the stack.
func leaveInvalid(_ model: AppModel, _ convId: String) {
    model.hub.show("会话不存在")
    model.path.removeAll { $0 == .chat(convId) || $0 == .chatInfo(convId) }
}

private enum HistoryState {
    case idle, loading, end, error
}

private struct ChatContent: View {
    let convId: String
    let type: ConvType
    let to: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    @State private var probe = ChatProbe.idle
    @State private var history = HistoryState.idle
    @State private var newCount = 0
    @State private var text = ""
    @State private var emojiOpen = false
    @State private var handle = ComposerHandle()
    @State private var atBottom = true
    @State private var anchorId: String?
    @State private var listWidth: CGFloat = 320

    private var isGroup: Bool { type == .group }
    private var conv: Conversation? { store.conversation(convId) }
    private var snapshot: ConversationSnapshot? { store.snapshot(convId) }
    private var messages: [Message] { store.messages(convId) }
    private var unknown: Bool { conv == nil && snapshot == nil && messages.isEmpty }
    private var block: ChatBlock? { chatBlock(snapshot: snapshot, probe: probe) }
    /// Group not in the list and no snapshot: ask the server first; until then neither input nor "not in group" (G-UI-26).
    private var probing: Bool { isGroup && unknown && probe != .notMember && probe != .notFound }

    var body: some View {
        VStack(spacing: 0) {
            ConnBanner()
            ZStack(alignment: .bottomTrailing) {
                list
                if newCount > 0 { newPill }
            }
            bottomBar
        }
        .background(TC.chatBg)
        .ttNavigationBar()
        .toolbar {
            ToolbarItem(placement: .principal) { title }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.push(.chatInfo(convId))
                } label: {
                    Icon(name: .more).foregroundStyle(TC.textPrimary)
                        .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
                }
                .accessibilityLabel("聊天信息")
                .accessibilityIdentifier("chat-more")
            }
        }
        .onAppear {
            store.setActive(convId)
            if let draft = model.drafts.draft(convId) {
                text = draft
                model.drafts.remove(convId)
            }
            #if DEBUG
                // UI tests: long text without typing thousands of characters (AC-UI-10-4).
                if let seed = ProcessInfo.processInfo.environment["TT_TEST_COMPOSER_TEXT"], text.isEmpty {
                    text = String(repeating: "字", count: Int(seed) ?? 0)
                }
            #endif
        }
        .onDisappear {
            store.clearActive(convId)
            if block == nil { model.drafts.put(convId, text) }
        }
        .onChange(of: block) { _, next in
            // F-UI-33 rule 5: what was typed is not kept.
            if next != nil {
                text = ""
                model.drafts.remove(convId)
                emojiOpen = false
            }
        }
        .task(id: "\(store.connected)") { await probeIfUnknown() }
        .task(id: conv == nil) {
            if conv != nil, (conv?.maxSeq ?? 0) > 0, store.client.messages(convId).isEmpty { await loadMore() }
        }
        .task(id: to) {
            await store.loadProfiles([isGroup ? store.me : to])
        }
    }

    // MARK: Title (F-UI-06 rule 2)

    private var titleName: String {
        if !isGroup {
            let local = store.displayName(to)
            if local != to { return local }  // Remark, then nickname.
        }
        if let name = conv?.name ?? snapshot?.name { return name }
        if isGroup {
            return probe == .notMember || probe == .notFound ? "群聊" : to
        }
        return to
    }

    private var titleCount: String {
        guard isGroup, snapshot == nil, let n = conv?.memberCount else { return "" }
        return "（\(n)）"
    }

    private var title: some View {
        HStack(spacing: 2) {
            Text(titleName).lineLimit(1)
            if !isGroup, store.profile(to)?.official == true { OfficialTag() }
            if !titleCount.isEmpty { Text(titleCount).fixedSize() }
        }
        .font(TTFont.title)
        .foregroundStyle(TC.textPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(titleName + titleCount)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("chat-title")
    }

    // MARK: Message list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    historyHeader
                    rowsView
                    if probing {
                        Text("加载中…")
                            .font(TTFont.caption)
                            .foregroundStyle(TC.textTertiary)
                            .padding(TS.s3)
                            .accessibilityIdentifier("chat-probing")
                    }
                    if let block {
                        Text(block.tip)
                            .font(TTFont.caption)
                            .foregroundStyle(TC.textTertiary)
                            .padding(TS.s3)
                            .accessibilityIdentifier("chat-blocked-tip")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear {
                            atBottom = true
                            newCount = 0
                        }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, TS.s3)
                .padding(.vertical, TS.s2)
                // A new stack for the first row. With `defaultScrollAnchor(.bottom)` the stack that was empty can reserve the
                // row's space and not draw it until the next scroll (seen on iOS 27): the first message stays invisible.
                .id(messages.isEmpty)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("message-list")
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            .onChange(of: messages) { old, new in
                handleMessagesChange(old: old, new: new, proxy: proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .simultaneousGesture(TapGesture().onEnded { if emojiOpen { emojiOpen = false } })
            .background { JumpBridge(tick: jumpTick) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    @State private var jumpTick = 0

    private func handleMessagesChange(old: [Message], new: [Message], proxy: ScrollViewProxy) {
        if let anchor = anchorId {
            anchorId = nil
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            return
        }
        guard new.count > old.count else { return }
        if atBottom || new.last?.from == store.me || old.isEmpty {
            newCount = 0
            DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            newCount += new.count - old.count
        }
    }

    @ViewBuilder private var historyHeader: some View {
        if !messages.isEmpty {
            Group {
                switch history {
                case .loading:
                    Text("加载中…").foregroundStyle(TC.textTertiary)
                case .end:
                    Text("没有更多了").foregroundStyle(TC.textTertiary)
                case .error:
                    Button("加载失败，点击重试") { Task { await loadMore() } }
                        .foregroundStyle(TC.brand)
                case .idle:
                    Color.clear.frame(height: 1)
                }
            }
            .font(TTFont.caption)
            .padding(.vertical, TS.s1)
            .accessibilityIdentifier("history-state")
        }
    }

    private var rowsView: some View {
        let list = messages
        let tips = permissionTips(list, tips: store.sendTips[convId])
        let rows = chatRows(list)
        let firstMessageId = list.first?.clientMsgId
        let maxBubble = listWidth * 0.7  // F-UI-07 rule 5
        return ForEach(rows) { row in
            Group {
                switch row {
                case .divider(_, let ts):
                    Text(formatTime(ts))
                        .font(TTFont.caption)
                        .foregroundStyle(TC.textTertiary)
                        .padding(.vertical, TS.s3)
                case .message(let m):
                    messageRow(m, tip: tips[m.clientMsgId], maxBubble: maxBubble)
                        .modifier(TopRowTrigger(active: m.clientMsgId == firstMessageId, onReachTop: reachedTop))
                }
            }
            .id(row.id)
        }
    }

    private func reachedTop() {
        if history == .idle { Task { await loadMore() } }
    }

    @ViewBuilder
    private func messageRow(_ m: Message, tip: Int?, maxBubble: CGFloat) -> some View {
        if m.deleted == true {
            TipCapsule(text: messageDeletedText).accessibilityIdentifier("msg-deleted")
        } else if m.type == .tip {
            TipRow(message: m, convId: convId)
        } else {
            BubbleRow(
                message: m,
                isSelf: m.from == store.me,
                showName: isGroup && m.from != store.me,
                maxBubble: maxBubble,
                context: isGroup ? UserContext(source: .group, sourceRef: to) : UserContext(source: .conv),
                convId: convId)
            if let tip {
                permissionTip(tip)
            }
        }
    }

    private func permissionTip(_ code: Int) -> some View {
        VStack(spacing: TS.s1) {
            Text(errorText(code, cmd: "send", strangerMsgLimit: store.settings.strangerMsgLimit))
                .font(TTFont.caption)
                .foregroundStyle(TC.textTertiary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("permission-tip")
            if code == 4035 {
                Button("发送好友申请") { model.push(.apply(to, UserContext(source: .conv))) }
                    .font(TTFont.caption)
                    .foregroundStyle(TC.brand)
                    .accessibilityIdentifier("permission-apply")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, TS.s2)
    }

    private var newPill: some View {
        Button {
            jumpTick += 1
            newCount = 0
        } label: {
            Text(verbatim: "↓ \(newCount) 条新消息")
                .font(TTFont.caption)
                .foregroundStyle(TC.onBrand)
                .padding(.horizontal, TS.s3)
                .padding(.vertical, TS.s2)
                .frame(minHeight: Tokens.Size.touchMin)
                .background(TC.brandFill, in: Capsule())
        }
        .padding(TS.s3)
        .accessibilityIdentifier("new-messages")
    }

    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        if probing {
            EmptyView()
        } else if let block {
            disabledBar(block.bar)
        } else if let mute = store.mute(convId) {
            disabledBar(mutedText(mute))
        } else {
            Composer(text: $text, emojiOpen: $emojiOpen, handle: handle, onSend: send)
        }
    }

    private func disabledBar(_ text: String) -> some View {
        Text(text)
            .font(TTFont.small)
            .foregroundStyle(TC.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchMin)
            .padding(TS.s2)
            .background(TC.surface.ignoresSafeArea(edges: .bottom))
            .accessibilityIdentifier("composer-disabled")
    }

    private func send() {
        do {
            if case .ok = try store.client.send(convId, text) {
                text = ""
                atBottom = true
            }
        } catch {
            model.hub.show(errorText(5000))
        }
    }

    // MARK: Loading

    private func probeIfUnknown() async {
        guard unknown, store.connected else { return }
        probe = .loading
        do {
            _ = try await store.client.loadHistory(convId)
            probe = .idle
        } catch {
            switch (error as? IMError)?.code {
            case 4033: probe = .notMember
            case 4043: probe = .notFound
            case 4032: leaveInvalid(model, convId)
            default: probe = .idle
            }
        }
    }

    private func loadMore() async {
        guard history != .loading, history != .end else { return }
        let before = store.messages(convId)
        anchorId = before.first?.clientMsgId
        history = .loading
        do {
            let more = try await store.client.loadHistory(convId)
            history = more ? .idle : .end
            if store.messages(convId).count == before.count { anchorId = nil }
        } catch {
            history = .error
            anchorId = nil
        }
    }
}

/// Fires when the oldest row is really within 40pt of the list's top (F-MSG-05). `onAppear` is not enough: a lazy stack
/// creates rows ahead of the visible area, which would page history in while the list opens at the bottom.
private struct TopRowTrigger: ViewModifier {
    let active: Bool
    let onReachTop: () -> Void

    func body(content: Content) -> some View {
        if active {
            content.onGeometryChange(for: Bool.self) { proxy in
                let frame = proxy.frame(in: .scrollView)
                return frame.minY > -40 && frame.minY < 40
            } action: { atTop in
                if atTop { onReachTop() }
            }
        } else {
            content
        }
    }
}

/// A jump request from outside the reader's scope.
private struct JumpBridge: View {
    let tick: Int
    let jump: () -> Void

    var body: some View {
        Color.clear.onChange(of: tick) { _, _ in jump() }
    }
}

/// Centered small text in a capsule: tips and deleted messages (F-UI-40 rule 1, F-UI-42 rule 1). No menu, no avatar.
private struct TipCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TTFont.caption)
            .foregroundStyle(TC.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, TS.s2)
            .padding(.vertical, TS.s1)
            .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.sm))
            .padding(.vertical, TS.s1 + TS.s1)
            .frame(maxWidth: .infinity)
    }
}

/// Group tips (F-UI-40): the copy comes from `body.tip` and local display names.
private struct TipRow: View {
    let message: Message
    let convId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        let tip = message.body.tip
        let text = tip.map { t in tipText(t, me: store.me) { store.displayName($0) } } ?? "[群通知]"
        Group {
            if tip?.kind == "noticeUpdated" {
                Button {
                    model.push(.notice(convId))
                } label: {
                    TipCapsule(text: text)
                }
                .buttonStyle(.plain)
            } else {
                TipCapsule(text: text)
            }
        }
        .accessibilityIdentifier("tip")
        .task(id: message.clientMsgId) {
            guard let tip else { return }
            await store.loadProfiles(([tip.actor] + tip.targets).filter { !$0.isEmpty })
        }
    }
}

/// A message bubble (F-UI-07, F-UI-08): avatar on the outer side, status on the inner side; a long press opens the system
/// menu (PRD-ui 3.4). Messages without menu items get no menu at all (F-UI-09 rule 5).
private struct BubbleRow: View {
    let message: Message
    let isSelf: Bool
    let showName: Bool
    let maxBubble: CGFloat
    let context: UserContext
    let convId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    private var supported: Bool { message.type == .text }
    private var hasMenu: Bool { supported || message.status == .failed }

    var body: some View {
        HStack(alignment: .top, spacing: TS.s2) {
            if isSelf { Spacer(minLength: 0) }
            if !isSelf { avatar }
            VStack(alignment: isSelf ? .trailing : .leading, spacing: TS.s1) {
                if showName {
                    Text(store.displayName(message.from))
                        .font(TTFont.caption)
                        .foregroundStyle(TC.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("msg-name")
                }
                HStack(alignment: .center, spacing: TS.s1) {
                    if isSelf { status }
                    MaxWidth(width: maxBubble) { bubble }
                }
            }
            if isSelf { avatar }
            if !isSelf { Spacer(minLength: 0) }
        }
        .padding(.vertical, TS.s3 / 2)
        .task(id: message.from) { await store.loadProfiles([message.from]) }
    }

    private var avatar: some View {
        Button {
            model.push(.user(message.from, context))
        } label: {
            Avatar(
                id: message.from, name: store.displayName(message.from), size: 40,
                src: store.profile(message.from)?.avatar)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看 \(store.displayName(message.from)) 的资料")
        .accessibilityIdentifier("msg-avatar")
    }

    @ViewBuilder private var status: some View {
        switch message.status {
        case .sent:
            EmptyView()
        case .failed:
            Button {
                let id = message.clientMsgId
                let client = store.client
                let conv = convId
                model.hub.confirm(id: "retry-dialog", text: "重发该消息？", ok: "重发") { client.retry(conv, id) }
            } label: {
                Icon(name: .failed, size: 20)
                    .foregroundStyle(TC.danger)
                    .frame(width: Tokens.Size.touchMin, height: Tokens.Size.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发送失败，点击重发")
            .accessibilityIdentifier("failed-icon")
        case .queued, .sending, .processing, .uploading: // 附件的两种状态（F-FILE-07），页面在 FE-637 细化
            Spinner()
                .foregroundStyle(TC.textTertiary)
                .accessibilityElement()
                .accessibilityLabel("发送中")
                .accessibilityIdentifier("sending-icon")
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isSelf ? TR.lg : TR.sm,
            bottomLeadingRadius: TR.lg,
            bottomTrailingRadius: TR.lg,
            topTrailingRadius: isSelf ? TR.sm : TR.lg)
    }

    @ViewBuilder private var bubble: some View {
        let content = Text(supported ? (message.body.text ?? "") : "[暂不支持的消息]")
            .font(TTFont.body)
            .foregroundStyle(foreground)
            .padding(.horizontal, TS.s3)
            .padding(.vertical, TS.s2)
            .background(isSelf ? TC.bubbleSelfBg : TC.bubbleOtherBg, in: bubbleShape)
            .overlay {
                // A 1px divider around others' bubbles in light mode only (PRD-ui 6.5).
                if !isSelf, scheme == .light { bubbleShape.stroke(TC.divider, lineWidth: 1) }
            }
            .contentShape(.contextMenuPreview, bubbleShape)
            .accessibilityIdentifier("message")
            .accessibilityValue(messageStatusValue(message.status))
        if hasMenu {
            content.contextMenu { menu }
        } else {
            content
        }
    }

    private var foreground: Color {
        if !supported { return TC.textSecondary }
        return isSelf ? TC.bubbleSelfText : TC.bubbleOtherText
    }

    /// Reads the live message at tap time: a message deleted while the menu was open has no text left to copy.
    @ViewBuilder private var menu: some View {
        if supported {
            Button("复制") {
                let live = store.messages(convId).first { $0.clientMsgId == message.clientMsgId }
                guard let text = live?.body.text, live?.deleted != true else { return }
                UIPasteboard.general.string = text
                model.hub.show("已复制")
            }
        }
        if message.status == .failed {
            Button("重发") { store.client.retry(convId, message.clientMsgId) }
            Button("删除", role: .destructive) { store.client.removeFailed(convId, message.clientMsgId) }
        }
    }
}
