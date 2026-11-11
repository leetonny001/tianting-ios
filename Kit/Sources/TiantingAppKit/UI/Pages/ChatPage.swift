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
    @State private var edit = EditState.empty
    @State private var emojiOpen = false
    @State private var handle = ComposerHandle()
    @State private var atBottom = true
    @State private var anchorId: String?
    @State private var listWidth: CGFloat = 320
    @State private var plusOpen = false
    @State private var picking: PickKind?
    /// The quote bar (F-QUO-01, AC-QUO-01-5): only the msgId, also in the draft (issue 41).
    @State private var quoteId: String?
    /// The @ picker is open for the @ at this position (F-MEN-01 rule 5).
    @State private var pickerAt: Int?
    /// The image shown full screen (by clientMsgId): closes with a toast when it is recalled or deleted (AC-RCL-03-8).
    @State private var viewer: String?
    /// After a jump (quote, "有人@我") the row with this seq is highlighted for 2 seconds.
    @State private var highlight: Int64?
    @State private var jump = JumpRequest(seq: nil, tick: 0)
    /// "有人@我" (F-MEN-03 rule 3): firstMentionSeq, taken once when the page opens (the server clears it once read, issue 40).
    @State private var mentionAt: Int64?
    @State private var mentionTaken = false
    @State private var listHeight: CGFloat = 600

    private var isGroup: Bool { type == .group }
    private var conv: Conversation? { store.conversation(convId) }
    private var snapshot: ConversationSnapshot? { store.snapshot(convId) }
    private var messages: [Message] { store.messages(convId) }
    private var unknown: Bool { conv == nil && snapshot == nil && messages.isEmpty }
    private var block: ChatBlock? { chatBlock(snapshot: snapshot, probe: probe) }
    /// Group not in the list and no snapshot: ask the server first; until then neither input nor "not in group" (G-UI-26).
    private var probing: Bool { isGroup && unknown && probe != .done && probe != .notMember && probe != .notFound }
    /// A group not in the list: its name from `getGroupInfo` once the probe let us in (frontend-chat 66).
    @State private var probedName: String?
    /// Quote, recall and @ (C4): only with features.msgActions (PRD-ui F-UI-09 rule 4).
    private var actionsOn: Bool { model.msgActionsEnabled }
    /// @ opens the picker only in a group with the switch on (AC-MEN-01-6).
    private var canMention: Bool { isGroup && actionsOn }
    /// Reporting (C6): features.moderation off means no "举报" in the menu or on recall lines (frontend-chat 76); which
    /// messages get one is the SDK's `canReport` (77, 88, 89, 92).
    private var reportOn: Bool { model.moderationEnabled }

    var body: some View {
        VStack(spacing: 0) {
            ConnBanner()
            ZStack(alignment: .bottomTrailing) {
                list
                if newCount > 0 { newPill }
            }
            .overlay(alignment: .topTrailing) { if mentionAt != nil { mentionJump } }
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
            // Before this page marks the conversation read, which clears the count here (issue 40).
            takeMention()
            store.setActive(convId)
            if let draft = model.drafts.draft(convId) {
                // Text, @ ranges and the quote bar come back (AC-MEN-01-10).
                edit = EditState(text: draft.text, ranges: canMention ? draft.mentions : [])
                quoteId = actionsOn ? draft.quote : nil
                model.drafts.remove(convId)
            }
            #if DEBUG
                // UI tests: long text without typing thousands of characters (AC-UI-10-4).
                if let seed = ProcessInfo.processInfo.environment["TT_TEST_COMPOSER_TEXT"], edit.text.isEmpty {
                    edit = EditState(text: String(repeating: "字", count: Int(seed) ?? 0))
                }
            #endif
        }
        .onDisappear {
            store.clearActive(convId)
            if block == nil { model.drafts.put(convId, Draft(text: edit.text, mentions: edit.ranges, quote: quoteId)) }
        }
        .onChange(of: store.deletedTicks[convId]) { _, _ in
            // Deleted on another device while open: the input empties too (frontend-chat 55); the SDK purged the rows.
            edit = .empty
            quoteId = nil
            pickerAt = nil
            model.drafts.remove(convId)
        }
        .onChange(of: block) { _, next in
            // F-UI-33 rule 5: what was typed is not kept.
            if next != nil {
                edit = .empty
                quoteId = nil
                pickerAt = nil
                model.drafts.remove(convId)
                emojiOpen = false
            }
        }
        .task(id: conv == nil) { takeMention() }
        .onChange(of: viewing?.deleted) { _, deleted in
            // The image shown full screen was recalled or deleted: close it and say so (AC-RCL-03-8).
            guard viewer != nil, deleted == true else { return }
            let recalled = viewing?.recalled == true
            viewer = nil
            model.hub.show(recalled ? messageRecalledText : messageDeletedText)
        }
        .fullScreenCover(isPresented: Binding(get: { viewerFileId != nil }, set: { if !$0 { viewer = nil } })) {
            if let fileId = viewerFileId {
                ImageViewer(fileId: fileId, mime: viewing?.body.image?.mime ?? "image/jpeg")
                    .environment(model)
                    .environment(store)
            }
        }
        .task(id: "\(store.connected)") { await probeIfUnknown() }
        .task(id: conv == nil) {
            if conv != nil, (conv?.maxSeq ?? 0) > 0, store.client.messages(convId).isEmpty { await loadMore() }
        }
        .task(id: to) {
            await store.loadProfiles([isGroup ? store.me : to])
        }
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            switch picking {
            case .images: PhotoPicker { picked($0, kind: .images) }.ignoresSafeArea()
            case .files: DocumentPicker { picked($0, kind: .files) }.ignoresSafeArea()
            case nil: EmptyView()
            }
        }
    }

    private var viewing: Message? {
        guard let viewer else { return nil }
        return messages.first { $0.clientMsgId == viewer }
    }

    private var viewerFileId: String? {
        guard let m = viewing, m.deleted != true, let id = m.body.fileId, !id.isEmpty else { return nil }
        return id
    }

    // MARK: Recall, quote, mentions (FE-669, FE-670)

    private func takeMention() {
        guard !mentionTaken, let conv else { return }
        mentionTaken = true
        if actionsOn, (conv.mentionUnread ?? 0) > 0 { mentionAt = conv.firstMentionSeq }
    }

    private func act(_ action: MenuAction, _ m: Message) {
        switch action {
        case .copy:
            // The live message: one deleted while the menu was open has no text left to copy.
            let live = store.messages(convId).first { $0.clientMsgId == m.clientMsgId }
            guard let text = live?.body.text, live?.deleted != true else { return }
            UIPasteboard.general.string = text
            model.hub.show("已复制")
        case .quote:
            guard let id = m.msgId else { return }
            quoteId = id
            handle.focus()  // F-UI-10 rule 7
        case .recall:
            // 4097 by windowSeconds, 4030 "你没有权限撤回这条消息" (AC-RCL-02-5); never retried (issue 26). On success the SDK
            // shows the recall here at once.
            guard let id = m.msgId else { return }
            let client = store.client
            let hub = model.hub
            let conv = convId
            Task {
                do {
                    try await client.recall(conv, id)
                } catch {
                    hub.show(recallErrorText(error))
                }
            }
        case .report:
            // One message (frontend-chat 85); a c2c one asks about blocking after success, a group one does not (79).
            if let request = ReportRequest.message(m) { model.presentReport(request) }
        case .retry:
            store.client.retry(convId, m.clientMsgId)  // The menu's "重发" does not ask again (F-UI-09 rule 3).
        case .delete:
            store.client.removeFailed(convId, m.clientMsgId)
        }
    }

    /// Jumps to `seq` (F-QUO-02 rule 5): pages up while it is within `limit` of the loaded range ("有人@我" passes no
    /// limit and pages until it is there, issue 40), then scrolls and highlights.
    private func jumpTo(_ seq: Int64?, limit: Int64) async {
        while true {
            let loaded = store.client.messages(convId).compactMap(\.seq)
            switch jumpPlan(seq, loaded: loaded, limit: limit) {
            case .here:
                jump = JumpRequest(seq: seq, tick: jump.tick + 1)
                return
            case .tooEarly:
                model.hub.show("消息太早，请翻页查看")
                return
            case .missing:
                model.hub.show("消息不存在")
                return
            case .load(let count):
                if history == .end {
                    model.hub.show("消息不存在")
                    return
                }
                if history == .loading {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let before = store.messages(convId)
                anchorId = before.first?.clientMsgId  // Keep the place while rows go on top.
                history = .loading
                do {
                    let more = try await store.client.loadHistory(convId, limit: count)
                    history = more ? .idle : .end
                    if store.messages(convId).count == before.count { anchorId = nil }
                    if !more, !store.client.messages(convId).contains(where: { $0.seq == seq }) {
                        model.hub.show("消息不存在")
                        return
                    }
                } catch {
                    history = .error
                    anchorId = nil
                    return
                }
            }
        }
    }

    private var mentionJump: some View {
        Button {
            let seq = mentionAt
            mentionAt = nil
            Task { await jumpTo(seq, limit: .max) }
        } label: {
            Text("有人@我")
                .font(TTFont.caption)
                .foregroundStyle(TC.onBrand)
                .padding(.horizontal, TS.s3)
                .padding(.vertical, TS.s2)
                .frame(minHeight: Tokens.Size.touchMin)
                .background(TC.brandFill, in: Capsule())
        }
        .padding(TS.s3)
        .accessibilityLabel("有人@我，点击查看")
        .accessibilityIdentifier("mention-jump")
    }

    private func pickMention(name: String, userId: String?) {
        guard let at = pickerAt else { return }
        pickerAt = nil
        let r = insertMention(edit.text, edit.ranges, at: at, name: name, userId: userId)
        edit = EditState(text: r.text, selStart: r.caret, ranges: r.ranges)
        handle.focus()
    }

    // MARK: Images and files (FE-637)

    private func pick(_ kind: PickKind) {
        plusOpen = false
        if let items = testPicked(kind) {
            picked(items, kind: kind)
        } else {
            picking = kind
        }
    }

    /// More than 9: none is sent (H16). "文件" with images asks first (F-FILE-03 rule 2, AC-FILE-03-6).
    private func picked(_ results: [Result<Picked, PickFailed>], kind: PickKind) {
        picking = nil
        var items: [Picked] = []
        var failed: PickFailed?
        for r in results {
            switch r {
            case .success(let p): items.append(p)
            case .failure(let e): failed = e
            }
        }
        if let failed { model.hub.show(failed.storage ? storageFullText : "无法读取所选文件") }
        guard !items.isEmpty else { return }
        if items.count > maxPick {
            for p in items { try? FileManager.default.removeItem(at: p.file) }
            model.hub.show(pickTooManyText)
            return
        }
        if kind == .files, items.contains(where: { looksLikeImage(mime: $0.mime, name: $0.name) }) {
            model.hub.present(id: "keep-info-dialog") {
                ConfirmDialog(text: keepMetadataTip, ok: "发送") { sendPicked(items, kind: kind) }
            }
            return
        }
        sendPicked(items, kind: kind)
    }

    private func sendPicked(_ items: [Picked], kind: PickKind) {
        guard let media = model.media else { return }
        for p in items {
            do {
                if kind == .images {
                    try media.sendImage(convId, p)
                } else {
                    let size = (try? FileManager.default.attributesOfItem(atPath: p.file.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if size > fileMaxBytes {
                        try? FileManager.default.removeItem(at: p.file)
                        model.hub.show("文件过大，最大 100 MB")
                        continue
                    }
                    try media.sendFile(convId, p)
                }
                atBottom = true
            } catch {
                try? FileManager.default.removeItem(at: p.file)
                model.hub.show(error is IMConnectionError ? "正在连接，请稍后再发送" : errorText(5000))
            }
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
            return probe == .notMember || probe == .notFound ? "群聊" : (probedName ?? to)
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
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                listWidth = $0.width
                listHeight = $0.height
            }
            .onChange(of: jump) { _, next in
                guard let seq = next.seq, let id = messages.first(where: { $0.seq == seq })?.clientMsgId else { return }
                // A lazy stack estimates rows it has not built: scroll again once they are there (AC-QUO-02-3, AC-MEN-03-6).
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { proxy.scrollTo(id, anchor: .center) }
                highlight = seq
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if highlight == seq { highlight = nil }
                }
            }
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
        // Worked out here, while the body is tracked: reading the conversation makes a new readSeq redraw the rows, so
        // "举报" shows once a message has been read (frontend-chat 92) without reopening the page.
        _ = conv?.readSeq
        let reportable = reportOn ? Set(list.filter { store.client.canReport($0) }.map(\.clientMsgId)) : []
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
                    messageRow(
                        m, tip: tips[m.clientMsgId], maxBubble: maxBubble, reportable: reportable.contains(m.clientMsgId))
                        .modifier(Highlight(on: m.seq != nil && m.seq == highlight))
                        .modifier(TopRowTrigger(active: m.clientMsgId == firstMessageId, onReachTop: reachedTop))
                        .modifier(
                            VisibleTrigger(active: m.seq != nil && m.seq == mentionAt, height: listHeight) {
                                mentionAt = nil  // That message is in view: no button (issue 40).
                            })
                }
            }
            .id(row.id)
        }
    }

    private func reachedTop() {
        if history == .idle { Task { await loadMore() } }
    }

    @ViewBuilder
    private func messageRow(_ m: Message, tip: Int?, maxBubble: CGFloat, reportable: Bool) -> some View {
        if m.deleted == true {
            if let notice = recallNotice(convId: convId, message: m, me: store.me) {
                // The table of F-RCL-02 rule 1a (F-UI-42 rule 4); no menu on recall or deletion lines (F-RCL-03 rule 6).
                // Someone else's message recalled by someone else, read here: "举报" after the line (F-MOD-03 rule 2a).
                RecallRow(notice: notice, onReport: reportable ? { act(.report, m) } : nil)
            } else {
                TipCapsule(text: messageDeletedText).accessibilityIdentifier("msg-deleted")
            }
        } else if m.type == .tip {
            TipRow(message: m, convId: convId)
        } else {
            BubbleRow(
                message: m,
                isSelf: m.from == store.me,
                showName: isGroup && m.from != store.me,
                maxBubble: maxBubble,
                context: isGroup ? UserContext(source: .group, sourceRef: to) : UserContext(source: .conv),
                convId: convId,
                actionsOn: actionsOn,
                reportOn: reportOn,
                reportable: reportable,
                myRole: conv?.myRole,
                onAction: { act($0, m) },
                onQuote: { q in Task { await jumpTo(q.seq, limit: quoteJumpMax) } },
                onOpenImage: { viewer = m.clientMsgId })
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
            Composer(
                edit: $edit, emojiOpen: $emojiOpen, plusOpen: $plusOpen, handle: handle, showPlus: model.filesEnabled,
                canMention: canMention,
                quoteText: actionsOn ? quoteId.map { id in quoteBarText(messages.first { $0.msgId == id }) { store.displayName($0) } } : nil,
                onQuoteCancel: { quoteId = nil },
                onMention: { pickerAt = $0 },
                onSend: send, onPick: pick
            )
            .sheet(
                isPresented: Binding(get: { pickerAt != nil }, set: { if !$0 { pickerAt = nil } }),
                onDismiss: { handle.focus() }  // Closed without a pick: the @ stays as plain text (issue 39).
            ) {
                MentionPicker(groupId: to, myRole: conv?.myRole, onPick: pickMention) { pickerAt = nil }
                    .environment(model)
                    .environment(store)
                    .presentationDetents([.medium, .large])
            }
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

    /// The quote goes up as its msgId only; mentions only in a group, from ranges that still start with an @ (AC-MEN-01-5).
    /// With the switch off neither is sent.
    private func send() {
        let quote = actionsOn ? quoteId.map { QuoteRef(msgId: $0) } : nil
        let mentions = canMention ? mentionsToSend(edit.text, edit.ranges) : nil
        do {
            if case .ok = try store.client.send(convId, edit.text, quote: quote, mentions: mentions) {
                edit = .empty
                quoteId = nil
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
            probe = .done
            if isGroup, store.client.messages(convId).isEmpty, let info = try? await store.client.getGroupInfo(to) {
                probedName = info.name
            }
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

/// A jump target for the list's reader; the tick makes the same seq jump again.
private struct JumpRequest: Equatable {
    var seq: Int64?
    var tick: Int
}

/// The jump target's row (AC-QUO-02-3, AC-MEN-03-6): `surfaceSelected` behind it for 2 seconds (the same token as H5 and
/// Android, issue 48), and an element that says where the jump landed.
private struct Highlight: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content
                .background(TC.surfaceSelected, in: RoundedRectangle(cornerRadius: TR.md))
                .overlay(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("已定位到这条消息")
                        .accessibilityIdentifier("msg-highlight")
                }
        } else {
            content
        }
    }
}

/// Fires once the row is inside the list's visible height ("有人@我" goes once that message is in view, issue 40).
private struct VisibleTrigger: ViewModifier {
    let active: Bool
    let height: CGFloat
    let onVisible: () -> Void

    func body(content: Content) -> some View {
        if active {
            content.onGeometryChange(for: Bool.self) { proxy in
                let frame = proxy.frame(in: .scrollView)
                return frame.maxY > 0 && frame.minY < height
            } action: { visible in
                if visible { onVisible() }
            }
        } else {
            content
        }
    }
}

/// A recall line (PRD-chat F-RCL-02 rule 1a): the same table as the list summary, names by the local rule (remark first).
/// No menu (F-RCL-03 rule 6). With `onReport` (C6: someone else's message recalled by someone else and read here, SDK
/// `canReport`) a "举报" button follows the line (F-MOD-03 rule 2a, AC-MOD-03-11): the line's text and size stay as they
/// are (`msg-recalled` holds only the recall words), the button's touch area is at least 44 × 44 (frontend-chat 93).
private struct RecallRow: View {
    let notice: RecallNotice
    var onReport: (() -> Void)?
    @Environment(IMStore.self) private var store

    var body: some View {
        let text = recallText(notice) { store.displayName($0) }
        Group {
            if let onReport {
                HStack(spacing: 0) {
                    TipCapsuleText(text: text).accessibilityIdentifier("msg-recalled")
                    Button(action: onReport) {
                        Text("举报")
                            .font(TTFont.caption)
                            .foregroundStyle(TC.brand)
                            .padding(.horizontal, TS.s2)
                            .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("举报这条消息")
                    .accessibilityIdentifier("recall-report")
                }
                .frame(maxWidth: .infinity)
            } else {
                TipCapsule(text: text).accessibilityIdentifier("msg-recalled")
            }
        }
        .task(id: notice) { await store.loadProfiles([notice.operatorId, notice.sender].filter { $0 != store.me }) }
    }
}

/// The capsule of `TipCapsule` without its row frame.
private struct TipCapsuleText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TTFont.caption)
            .foregroundStyle(TC.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, TS.s2)
            .padding(.vertical, TS.s1)
            .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.sm))
    }
}

/// Centered small text in a capsule: tips and deleted messages (F-UI-40 rule 1, F-UI-42 rule 1). No menu, no avatar.
private struct TipCapsule: View {
    let text: String

    var body: some View {
        TipCapsuleText(text: text)
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
/// menu (PRD-ui 3.4). Messages without menu items get no menu at all (F-UI-09 rule 5). C4: sent images and files have a
/// menu too (quote, recall); the quote sits on top of the bubble; a message that mentions me is outlined.
private struct BubbleRow: View {
    let message: Message
    let isSelf: Bool
    let showName: Bool
    let maxBubble: CGFloat
    let context: UserContext
    let convId: String
    let actionsOn: Bool
    /// features.moderation (C6).
    let reportOn: Bool
    /// `reportOn` and the SDK's `canReport` when the list was drawn (it follows readSeq, frontend-chat 92).
    let reportable: Bool
    let myRole: GroupRole?
    let onAction: (MenuAction) -> Void
    let onQuote: (QuoteView) -> Void
    let onOpenImage: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    private var supported: Bool { [.text, .image, .file].contains(message.type) }
    /// Whether a long press does anything. The items themselves are worked out when the menu opens (`MessageMenu`):
    /// "撤回" follows the server time then, not when this row was drawn (AC-RCL-01-8).
    private var items: [MenuAction] {
        menuItems(message, actionsOn: actionsOn, canRetry: store.client.canRetry(message), canReport: reportable) {
            store.client.messageActions(message, myRole: myRole)
        }
    }
    private var hasMenu: Bool { !items.isEmpty }
    /// Bumped when a recall time limit passes (2 minutes, 7 days after `ts` by server time): SwiftUI builds the context
    /// menu with the row, so the row is drawn again then and the next long press has no "撤回" (AC-RCL-01-8). A redraw
    /// while the menu is open would change the open menu too, so then it waits until the menu closes: a tap on "撤回"
    /// after the limit gets the server's 4097 (issue 37).
    @State private var recallEpoch = 0
    @State private var menuOpen = false
    @State private var epochPending = false
    private var mentioned: Bool { actionsOn && mentionsMe(message, me: store.me) }

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
                if message.isAttachment, isSelf, message.seq == nil {
                    AttachmentStatus(message: message, convId: convId)
                }
            }
            if isSelf { avatar }
            if !isSelf { Spacer(minLength: 0) }
        }
        .padding(.vertical, TS.s3 / 2)
        .task(id: message.from) { await store.loadProfiles([message.from]) }
        .task(id: "\(message.clientMsgId)|\(message.status)|\(message.deleted == true)|\(recallEpoch)") {
            guard items.contains(.recall) else { return }
            let now = store.client.serverNow()
            guard let deadline = [recallWindowMs, groupRecallWindowMs].map({ message.ts + $0 }).first(where: { $0 > now })
            else { return }
            try? await Task.sleep(for: .milliseconds(deadline - now + 300))
            if Task.isCancelled { return }
            if menuOpen { epochPending = true } else { recallEpoch += 1 }
        }
        .task(id: message.body.quote?.from) {
            if let from = message.body.quote?.from, !from.isEmpty { await store.loadProfiles([from]) }
        }
    }

    private var avatar: some View {
        Button {
            model.push(.user(message.from, context))
        } label: {
            Avatar(
                id: message.from, name: store.displayName(message.from), size: 40,
                src: store.profile(message.from)?.avatar, local: isSelf ? model.media?.localAvatar : nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看 \(store.displayName(message.from)) 的资料")
        .accessibilityIdentifier("msg-avatar")
    }

    @ViewBuilder private var status: some View {
        switch message.status {
        case .sent:
            EmptyView()
        case .failed where !attachmentDeleteOnly(message) && !store.client.canRetry(message):
            // Blocked content (4510, SDK canRetry false): no "重发" anywhere (frontend-chat 81). The mark is not a button and
            // says why (issue 94); the menu has "复制" and "删除".
            Icon(name: .failed, size: 20)
                .foregroundStyle(TC.danger)
                .frame(width: Tokens.Size.touchMin, height: Tokens.Size.touchMin)
                .accessibilityElement()
                .accessibilityLabel("发送失败，\(failedReason)")
                .accessibilityIdentifier("failed-icon")
        case .failed:
            Button {
                let id = message.clientMsgId
                let client = store.client
                let conv = convId
                if attachmentDeleteOnly(message) {
                    // The source is gone: only deleting is left (F-FILE-07 rule 4).
                    model.hub.confirm(id: "delete-dialog", text: sourceMissingText, ok: "删除", danger: true) {
                        client.removeFailed(conv, id)
                    }
                } else {
                    model.hub.confirm(id: "retry-dialog", text: "重发该消息？", ok: "重发") { client.retry(conv, id) }
                }
            } label: {
                Icon(name: .failed, size: 20)
                    .foregroundStyle(TC.danger)
                    .frame(width: Tokens.Size.touchMin, height: Tokens.Size.touchMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发送失败，点击重发")
            .accessibilityIdentifier("failed-icon")
        case .queued, .sending, .processing, .uploading:
            Spinner()
                .foregroundStyle(TC.textTertiary)
                .accessibilityElement()
                .accessibilityLabel("发送中")
                .accessibilityIdentifier("sending-icon")
        }
    }

    /// Why a failed message cannot be sent again (the only such case besides a missing source is 4510).
    private var failedReason: String {
        if case .code(let code)? = message.error { return errorText(code, cmd: "send") }
        return contentBlockedSendText
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isSelf ? TR.lg : TR.sm,
            bottomLeadingRadius: TR.lg,
            bottomTrailingRadius: TR.lg,
            topTrailingRadius: isSelf ? TR.sm : TR.lg)
    }

    @ViewBuilder private var bubble: some View {
        switch message.type {
        case .image:
            withMenu(ImageBubble(message: message, convId: convId, onOpen: onOpenImage), shape: RoundedRectangle(cornerRadius: TR.lg))
        case .file:
            withMenu(FileBubble(message: message, convId: convId, isSelf: isSelf), shape: RoundedRectangle(cornerRadius: TR.lg))
        default:
            textBubble
        }
    }

    /// The menu, and the same items as accessibility actions (13.4: a long-press menu needs an assistive way in; VoiceOver
    /// lists them under "操作").
    @ViewBuilder private func withMenu<V: View, S: Shape>(_ v: V, shape: S) -> some View {
        if hasMenu {
            v.contextMenu {
                MessageMenu(
                    message: message, convId: convId, actionsOn: actionsOn, reportOn: reportOn, myRole: myRole,
                    epoch: recallEpoch, onAction: onAction)
            } preview: {
                // The same bubble; it is on screen only while the menu is open. The preview is hosted on its own and
                // gets no environment from the row: pass the models (an image bubble reads them).
                v.environment(model).environment(store)
                    .onAppear { menuOpen = true }
                    .onDisappear {
                        menuOpen = false
                        if epochPending {
                            epochPending = false
                            recallEpoch += 1
                        }
                    }
            }
            .accessibilityActions {
                ForEach(items, id: \.self) { a in
                    Button(a.title) { onAction(a) }
                }
            }
        } else {
            v
        }
    }

    @ViewBuilder private var textBubble: some View {
        let content = VStack(alignment: .leading, spacing: TS.s1) {
            if let q = message.body.quote, actionsOn {
                QuoteBlock(quote: q, color: foreground, onTap: { onQuote(q) })
            }
            Text(supported ? (message.body.text ?? "") : "[暂不支持的消息]")
                .font(TTFont.body)
                .foregroundStyle(foreground)
                .accessibilityIdentifier("message")
                .accessibilityLabel(mentioned ? "\(message.body.text ?? "")，提到了你" : (supported ? (message.body.text ?? "") : "[暂不支持的消息]"))
                .accessibilityValue(messageStatusValue(message.status))
        }
        .padding(.horizontal, TS.s3)
        .padding(.vertical, TS.s2)
        .background(isSelf ? TC.bubbleSelfBg : TC.bubbleOtherBg, in: bubbleShape)
        .overlay {
            if mentioned {
                // Mentions me: the whole bubble is outlined in the brand color (F-MEN-01 rule 4; a token, dark follows).
                bubbleShape.stroke(TC.brand, lineWidth: 2)
            } else if !isSelf, scheme == .light {
                // A 1px divider around others' bubbles in light mode only (PRD-ui 6.5).
                bubbleShape.stroke(TC.divider, lineWidth: 1)
            }
        }
        .contentShape(.contextMenuPreview, bubbleShape)
        withMenu(content, shape: bubbleShape)
    }

    private var foreground: Color {
        if !supported { return TC.textSecondary }
        return isSelf ? TC.bubbleSelfText : TC.bubbleOtherText
    }
}

/// The quote on top of a bubble (F-QUO-02 rule 3): the four states' text from the SDK's quoteLabel, a normal one with the
/// original sender's name. `Text` with a String is plain text, nothing is parsed (AC-QUO-02-5). A tap jumps (rule 5).
private struct QuoteBlock: View {
    let quote: QuoteView
    let color: Color
    let onTap: () -> Void
    @Environment(IMStore.self) private var store

    var body: some View {
        let text = quoteBlockText(quote) { store.displayName($0) }
        Button(action: onTap) {
            HStack(spacing: TS.s1 + 2) {
                color.opacity(0.6).frame(width: 3).frame(minHeight: 20)
                Text(verbatim: text)
                    .font(TTFont.caption)
                    .foregroundStyle(color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("引用：\(text)")
        .accessibilityValue(quote.state.rawValue)
        .accessibilityHint("查看引用的消息")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("msg-quote")
    }
}

/// The context menu's items, worked out when it opens (AC-RCL-01-8): the menu stays as it was while open, so a recall
/// tapped after the limit gets the server's 4097.
private struct MessageMenu: View {
    let message: Message
    let convId: String
    let actionsOn: Bool
    let reportOn: Bool
    let myRole: GroupRole?
    /// The row's recall epoch: a new value makes this menu be built again.
    let epoch: Int
    let onAction: (MenuAction) -> Void
    @Environment(IMStore.self) private var store

    var body: some View {
        let live = store.client.messages(convId).first { $0.clientMsgId == message.clientMsgId } ?? message
        let items = menuItems(
            live, actionsOn: actionsOn, canRetry: store.client.canRetry(live),
            canReport: reportOn && store.client.canReport(live)
        ) {
            store.client.messageActions(live, myRole: myRole)
        }
        ForEach(items, id: \.self) { a in
            Button(a.title, role: a == .delete ? .destructive : nil) { onAction(a) }
                .accessibilityIdentifier("menu-\(a.rawValue)")
        }
    }
}
