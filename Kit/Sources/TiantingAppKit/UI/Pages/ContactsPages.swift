import SwiftUI
import TiantingIM

struct ContactsAddButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.push(.addFriend)
        } label: {
            Icon(name: .addFriend).foregroundStyle(TC.textPrimary)
                .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
        }
        .accessibilityLabel("添加朋友")
        .accessibilityIdentifier("contacts-add")
    }
}

/// A brand-tinted square for the two fixed entries (PRD-ui 6.6).
private struct EntryIcon: View {
    let name: IconName

    var body: some View {
        Icon(name: name, size: 22)
            .foregroundStyle(TC.onBrand)
            .frame(width: 40, height: 40)
            .background(TC.brandFill, in: RoundedRectangle(cornerRadius: TR.md))
    }
}

struct GroupLetter: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(TTFont.caption)
            .foregroundStyle(TC.textSecondary)
            .padding(.horizontal, TS.s4)
            .padding(.vertical, TS.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TC.bg)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Contacts (PRD-ui F-UI-13): "新的朋友", "群聊", friends. Open mode still lists friends only.
struct ContactsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ConnBanner()
            ScrollView {
                LazyVStack(spacing: 0) {
                    RowButton(id: "entry-requests", action: { model.push(.requests) }) {
                        EntryIcon(name: .newFriends)
                        Text("新的朋友").font(TTFont.body).foregroundStyle(TC.textPrimary)
                        Spacer()
                        if store.requests.unseen > 0 {
                            CountBadge(text: badgeText(store.requests.unseen))
                                .accessibilityIdentifier("requests-badge")
                        }
                    }
                    RowButton(id: "entry-groups", action: { model.push(.groups) }) {
                        EntryIcon(name: .groups)
                        Text("群聊").font(TTFont.body).foregroundStyle(TC.textPrimary)
                        Spacer()
                    }
                    friendSection
                }
            }
            .accessibilityIdentifier("contacts")
        }
        .background(TC.bg)
    }

    @ViewBuilder private var friendSection: some View {
        if !store.socialLoaded {
            RowsSkeleton(id: "contacts-skeleton")
        } else if store.friends.isEmpty {
            EmptyStateView(text: "还没有朋友", id: "contacts-empty") {
                Button("添加朋友") { model.push(.addFriend) }
                    .buttonStyle(TTButtonStyle())
                    .accessibilityIdentifier("contacts-empty-add")
            }
        } else {
            let sections = groupByPinyin(store.friends, name: { $0.displayName }, id: { $0.userId })
            ForEach(sections, id: \.letter) { section in
                GroupLetter(letter: section.letter).accessibilityIdentifier("group-\(section.letter)")
                ForEach(section.items, id: \.userId) { f in
                    RowButton(id: "friend-row", action: { model.push(.user(f.userId, UserContext(source: .card))) }) {
                        Avatar(id: f.userId, name: f.displayName, size: 40, src: f.profile?.avatar)
                        Text(f.displayName).font(TTFont.body).foregroundStyle(TC.textPrimary).lineLimit(1)
                        if f.profile?.official == true { OfficialTag() }
                        if f.blocked {
                            Text("已拉黑").font(TTFont.caption).foregroundStyle(TC.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Text(verbatim: "\(store.friends.count) 位朋友")
                .font(TTFont.small)
                .foregroundStyle(TC.textTertiary)
                .padding(TS.s4)
                .accessibilityIdentifier("contacts-count")
        }
    }
}

/// New friends (PRD-ui F-UI-25). Entering marks everything seen; requests arriving while here are seen too (200ms debounce).
struct RequestsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var busy: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.requests.items.isEmpty {
                    EmptyStateView(text: "暂无新的朋友", id: "requests-empty")
                } else {
                    ForEach(store.requests.items, id: \.rowKey) { row($0) }
                }
            }
        }
        .accessibilityIdentifier("requests")
        .background(TC.bg)
        .ttNavigationBar("新的朋友")
        .onAppear { store.client.markFriendRequestsSeen() }
        .task(id: store.requests.unseen) {
            guard store.requests.unseen > 0 else { return }
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled { store.client.markFriendRequestsSeen() }
        }
    }

    private func row(_ r: FriendRequest) -> some View {
        HStack(spacing: TS.s2) {
            Button {
                if r.direction == .incoming, r.status == .pending {
                    showDetail(r)
                } else {
                    model.push(.user(r.userId, UserContext(source: .card)))
                }
            } label: {
                HStack(spacing: TS.s3) {
                    Avatar(id: r.userId, name: r.displayName, size: 40, src: r.profile?.avatar)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.displayName).font(TTFont.body).foregroundStyle(TC.textPrimary).lineLimit(1)
                        Text(requestSecondLine(r))
                            .font(TTFont.small)
                            .foregroundStyle(TC.textSecondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("request-line2")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("request-row")
            if let state = requestStateText(r) {
                Text(state)
                    .font(TTFont.small)
                    .foregroundStyle(TC.textTertiary)
                    .fixedSize()
                    .accessibilityIdentifier("request-state")
            } else {
                Button(busy == r.userId ? "处理中…" : "同意") { respond(r.userId, .accept) }
                    .buttonStyle(TTButtonStyle(small: true))
                    .disabled(busy == r.userId)
                    .fixedSize()
                    .accessibilityIdentifier("request-accept")
            }
        }
        .padding(.horizontal, TS.s4)
        .padding(.vertical, TS.s2)
        .frame(minHeight: 60)
        .background(TC.surface)
        .overlay(alignment: .bottom) { TC.divider.frame(height: 1).padding(.leading, TS.s4) }
    }

    private func showDetail(_ r: FriendRequest) {
        model.hub.present(id: "request-sheet", sheet: true) {
            VStack(alignment: .leading, spacing: TS.s3) {
                HStack(spacing: TS.s3) {
                    Avatar(id: r.userId, name: r.displayName, size: 40, src: r.profile?.avatar)
                    VStack(alignment: .leading) {
                        Text(r.displayName).font(TTFont.body).foregroundStyle(TC.textPrimary)
                        Text(verbatim: "账号：\(r.userId)").font(TTFont.small).foregroundStyle(TC.textSecondary)
                    }
                }
                if !r.message.isEmpty {
                    Text(r.message).font(TTFont.body).foregroundStyle(TC.textPrimary)
                }
                if let source = applySourceText(r.item.source) {
                    Text(source)
                        .font(TTFont.small)
                        .foregroundStyle(TC.textSecondary)
                        .accessibilityIdentifier("request-source")
                }
                BlockButton(title: "同意", id: "sheet-accept") {
                    model.hub.dismissDialog()
                    respond(r.userId, .accept)
                }
                BlockButton(title: "拒绝", kind: .secondary, id: "sheet-reject") {
                    model.hub.dismissDialog()
                    respond(r.userId, .reject)
                }
                BlockButton(title: "查看资料", kind: .secondary, id: "sheet-profile") {
                    model.hub.dismissDialog()
                    model.push(.user(r.userId, UserContext(source: .card)))
                }
            }
        }
    }

    private func respond(_ userId: String, _ action: IMClient.FriendResponse) {
        guard busy == nil else { return }
        busy = userId
        Task {
            do {
                try await store.client.respondFriend(userId, action)
            } catch {
                let code = errorCode(error)
                model.hub.show(errorText(code, cmd: "friendRespond"))
                if code == 4045 { await store.client.refreshSocial() }  // The row then shows "已过期".
            }
            busy = nil
        }
    }
}

extension FriendRequest {
    fileprivate var rowKey: String { "\(userId)/\(direction.rawValue)" }
}

/// Add a friend (PRD-ui F-UI-26): exact match only; absent, unsearchable and banned look the same.
struct AddFriendPage: View {
    private enum Result: Equatable {
        case found(SearchedUser)
        case none
    }

    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var keyword = ""
    @State private var error = ""
    @State private var result: Result?
    @State private var searching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s3) {
                TTTextField(placeholder: "输入对方账号", text: $keyword, id: "search-input", ascii: true, submit: .search) { submit() }
                if !error.isEmpty { FieldError(text: error, id: "search-error") }
                HStack(spacing: TS.s2) {
                    Text(verbatim: "我的账号：\(store.me)")
                        .font(TTFont.small)
                        .foregroundStyle(TC.textSecondary)
                        .textSelection(.enabled)
                    CopyButton(text: store.me)
                }
                if searching {
                    Text("搜索中…")
                        .font(TTFont.caption)
                        .foregroundStyle(TC.textTertiary)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("search-loading")
                }
                if !searching, let result {
                    switch result {
                    case .none:
                        Text("未找到该用户")
                            .font(TTFont.body)
                            .foregroundStyle(TC.textSecondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("search-result")
                    case .found(let user):
                        SearchCard(user: user)
                    }
                }
            }
            .padding(TS.s4)
        }
        .background(TC.bg)
        .ttNavigationBar("添加朋友")
    }

    private func submit() {
        let kw = trimText(keyword)
        guard !kw.isEmpty, !searching else { return }
        guard isValidUserId(kw) else {
            error = errorText(4004)
            result = nil
            return
        }
        searching = true
        error = ""
        Task {
            do {
                let user = try await store.client.searchUser(kw)
                result = user.map(Result.found) ?? Result.none
            } catch {
                result = nil
                self.error = errorText(errorCode(error), cmd: "userSearch")
            }
            searching = false
        }
    }
}

private struct SearchCard: View {
    let user: SearchedUser
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    /// After accepting or applying, the local state is newer.
    private var relation: Relation {
        let local = store.relation(user.userId)
        return local != .none ? local : user.relation
    }

    private var context: UserContext {
        UserContext(
            source: .search,
            profile: Profile(nickname: user.nickname, avatar: user.avatar, official: user.official))
    }

    var body: some View {
        let name = store.displayName(user.userId)
        VStack(alignment: .leading, spacing: TS.s3) {
            Button {
                model.push(.user(user.userId, context))
            } label: {
                HStack(spacing: TS.s3) {
                    Avatar(id: user.userId, name: name, size: 48, src: user.avatar)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: TS.s1) {
                            Text(name).font(TTFont.body).foregroundStyle(TC.textPrimary)
                            if user.official { OfficialTag() }
                        }
                        Text(verbatim: "账号：\(user.userId)").font(TTFont.small).foregroundStyle(TC.textSecondary)
                        if let note {
                            Text(note).font(TTFont.small).foregroundStyle(TC.textSecondary)
                                .accessibilityIdentifier("search-note")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .accessibilityIdentifier("search-card")
            action
        }
        .padding(TS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.lg))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-result")
    }

    private var note: String? {
        switch relation {
        case .`self`: return "这是你自己"
        case .pendingOut: return "已发送申请"
        case .blocked: return "已加入黑名单"
        default: return nil
        }
    }

    @ViewBuilder private var action: some View {
        switch relation {
        case .friend:
            BlockButton(title: "发消息", id: "search-chat") {
                model.push(.chat(c2cConvId(store.me, user.userId)))
            }
        case .pendingIn:
            BlockButton(title: "通过验证", id: "search-accept") {
                Task {
                    do {
                        try await store.client.respondFriend(user.userId, .accept)
                    } catch {
                        model.hub.show(errorText(errorCode(error), cmd: "friendRespond"))
                    }
                }
            }
        case .pendingOut:
            BlockButton(title: "重新发送", kind: .secondary, id: "search-resend") {
                model.push(.apply(user.userId, context))
            }
        case .blocked:
            BlockButton(title: "查看资料", kind: .secondary, id: "search-view") {
                model.push(.user(user.userId, context))
            }
        case .none:
            BlockButton(title: "添加到通讯录", id: "search-add") {
                model.push(.apply(user.userId, context))
            }
        default:
            EmptyView()
        }
    }
}

/// Apply to add a friend (PRD-ui F-UI-27). A pending result looks the same whether or not the other side exists or
/// blocked me (no enumeration).
struct ApplyPage: View {
    let userId: String
    let context: UserContext
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var message: String?
    @State private var remark = ""
    @State private var sending = false

    private var nickname: String {
        store.profile(userId)?.nickname.nonEmpty ?? context.profile?.nickname.nonEmpty ?? ""
    }
    private var myName: String { store.profile(store.me)?.nickname.nonEmpty ?? store.me }
    private var text: String { message ?? "我是\(myName)" }
    private var messageTooLong: Bool { textLength(text) > maxApplyMessage }
    private var remarkTooLong: Bool { textLength(remark) > maxRemark }

    var body: some View {
        let name = nickname.nonEmpty ?? userId
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s3) {
                HStack(spacing: TS.s3) {
                    Avatar(
                        id: userId, name: name, size: 48,
                        src: store.profile(userId)?.avatar ?? context.profile?.avatar)
                    Text(name)
                        .font(TTFont.title)
                        .foregroundStyle(TC.textPrimary)
                        .accessibilityIdentifier("apply-name")
                }
                Text("发送添加朋友申请").font(TTFont.small).foregroundStyle(TC.textSecondary)
                TTTextEditor(
                    text: Binding(get: { text }, set: { message = $0 }), id: "apply-message", label: "发送添加朋友申请")
                HStack {
                    Spacer()
                    Text(verbatim: "\(textLength(text)) / \(maxApplyMessage)")
                        .font(TTFont.caption)
                        .foregroundStyle(TC.textTertiary)
                        .accessibilityIdentifier("apply-count")
                }
                if messageTooLong { FieldError(text: "最多 \(maxApplyMessage) 个字", id: "apply-message-error") }
                Text("设置备注").font(TTFont.small).foregroundStyle(TC.textSecondary)
                TTTextField(placeholder: name, text: $remark, id: "apply-remark", autocapitalize: true)
                if remarkTooLong { FieldError(text: "最多 \(maxRemark) 个字", id: "apply-remark-error") }
                BlockButton(title: sending ? "发送中…" : "发送", id: "apply-send") { send() }
                    .disabled(sending || messageTooLong || remarkTooLong)
            }
            .padding(TS.s4)
        }
        .background(TC.bg)
        .ttNavigationBar("申请添加朋友")
        .onAppear {
            if userId == store.me {
                model.hub.show("不能添加自己")
                model.pop()
            }
        }
        .task(id: userId) { await store.loadProfiles([userId, store.me]) }
    }

    private func send() {
        guard !sending, !messageTooLong, !remarkTooLong, userId != store.me else { return }
        sending = true
        var options = ApplyFriendOptions(
            message: trimText(text), source: context.source ?? .other, sourceRef: context.sourceRef)
        let r = trimText(remark)
        if !r.isEmpty { options.remark = r }
        Task {
            do {
                let status = try await store.client.applyFriend(userId, options: options)
                if status == "accepted" {
                    model.hub.show("已添加到通讯录")
                    model.replaceTop(with: .user(userId, UserContext(source: context.source)))
                } else {
                    model.hub.show("已发送")
                    model.pop()
                }
            } catch {
                model.hub.show(errorText(errorCode(error), cmd: "friendApply"))
            }
            sending = false
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// The user card (PRD-ui F-UI-14). Source of the profile: friend / request / block item → cache → route state → userId only.
/// An invisible user looks the same as an absent one; it never says "用户不存在".
struct UserPage: View {
    let userId: String
    let context: UserContext
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var busy = false

    private var friend: Friend? { store.friends.first { $0.userId == userId } }
    private var profile: Profile? {
        if let p = friend?.profile { return p }
        if let p = store.requests.items.first(where: { $0.userId == userId && $0.profile != nil })?.profile { return p }
        if let p = store.blocks.first(where: { $0.userId == userId })?.item.profile { return p }
        if let p = store.profile(userId) { return Profile(nickname: p.nickname, avatar: p.avatar, official: p.official) }
        return context.profile
    }
    private var nickname: String { profile?.nickname ?? "" }
    private var name: String { friend?.remark.nonEmpty ?? nickname.nonEmpty ?? userId }
    private var official: Bool { profile?.official ?? false }
    private var relation: Relation { store.relation(userId) }
    private var isFriend: Bool { friend != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: TS.s4) {
                head
                actions
            }
            .padding(TS.s4)
        }
        .background(TC.bg)
        .ttNavigationBar()
        .toolbar {
            if relation != .`self` {
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
        }
        .task(id: userId) { await store.loadProfiles([userId]) }
    }

    private var head: some View {
        HStack(alignment: .top, spacing: TS.s3) {
            Avatar(id: userId, name: name, size: 64, src: profile?.avatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: TS.s1) {
                    Text(name)
                        .font(TTFont.large)
                        .foregroundStyle(TC.textPrimary)
                        .accessibilityIdentifier("user-name")
                    if official { OfficialTag() }
                }
                if friend?.remark.isEmpty == false, !nickname.isEmpty {
                    Text(verbatim: "昵称：\(nickname)").font(TTFont.small).foregroundStyle(TC.textSecondary)
                        .accessibilityIdentifier("user-nickname")
                }
                Text(verbatim: "账号：\(userId)").font(TTFont.small).foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("user-id")
                if relation == .blocked {
                    Text("已加入黑名单").font(TTFont.small).foregroundStyle(TC.textSecondary)
                        .accessibilityIdentifier("user-blocked")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(TS.s4)
        .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.lg))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("user-head")
    }

    private var applyContext: UserContext {
        UserContext(source: context.source ?? .card, sourceRef: context.sourceRef, profile: profile)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: TS.s2) {
            if relation == .pendingIn {
                BlockButton(title: "通过验证", id: "user-accept") {
                    run("friendRespond") { try await store.client.respondFriend(userId, .accept) }
                }
                .disabled(busy)
            }
            if relation == .pendingOut {
                Text("已发送申请，等待验证")
                    .font(TTFont.small)
                    .foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("user-pending")
                BlockButton(title: "重新发送", kind: .secondary, id: "user-resend") {
                    model.push(.apply(userId, applyContext))
                }
            }
            if relation == .none {
                BlockButton(title: "添加到通讯录", id: "user-add") { model.push(.apply(userId, applyContext)) }
            }
            if relation != .`self`,
                canChat(relation: relation, isFriend: isFriend, mode: store.settings.mode, official: official)
            {
                BlockButton(title: "发消息", kind: relation == .friend ? .primary : .secondary, id: "user-chat") {
                    model.push(.chat(c2cConvId(store.me, userId)))
                }
            }
            if isFriend, relation == .friend {
                BlockButton(title: "设置备注", kind: .secondary, id: "user-remark") { model.push(.remark(userId)) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("user-actions")
    }

    private var moreMenu: some View {
        Menu {
            if isFriend, relation == .blocked {
                Button("设置备注") { model.push(.remark(userId)) }
            }
            if relation == .blocked {
                Button("移出黑名单") { run("unblock") { try await store.client.unblock(userId) } }
            } else {
                Button("加入黑名单") { confirmBlock() }
            }
            if isFriend {
                Button("删除朋友") { confirmDelete() }
            }
        } label: {
            Icon(name: .more).foregroundStyle(TC.textPrimary)
                .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("user-more")
    }

    private func confirmBlock() {
        model.hub.confirm(
            id: "block-dialog", text: "加入黑名单后，你将不再收到对方的私聊消息和好友申请；在共同的群聊里仍能看到对方的发言", ok: "确定"
        ) {
            run("block") { try await store.client.block(userId) }
        }
    }

    private func confirmDelete() {
        var text = "确定删除朋友\"\(name)\"？"
        if store.settings.mode == .friends { text += "\n删除后你们将无法继续私聊" }
        model.hub.confirm(id: "delete-dialog", text: text, ok: "删除", danger: true) {
            run("friendDelete") { try await store.client.deleteFriend(userId) }
        }
    }

    private func run(_ cmd: String, _ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await op()
            } catch {
                model.hub.show(errorText(errorCode(error), cmd: cmd))
            }
            busy = false
        }
    }
}

/// Set a remark (PRD-ui F-UI-28): only for my own friends. Remarks show only on my devices.
struct RemarkPage: View {
    let userId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var value: String?
    @State private var saving = false

    private var friend: Friend? { store.friends.first { $0.userId == userId } }
    private var current: String { friend?.remark ?? "" }
    private var text: String { value ?? current }
    private var tooLong: Bool { textLength(text) > maxRemark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s2) {
                TTTextField(
                    placeholder: friend?.profile?.nickname.nonEmpty ?? "备注",
                    text: Binding(get: { text }, set: { value = $0 }), id: "remark-input", autocapitalize: true)
                if tooLong { FieldError(text: "最多 \(maxRemark) 个字", id: "remark-error") }
            }
            .padding(TS.s4)
        }
        .background(TC.bg)
        .ttNavigationBar("设置备注")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { done() }
                    .disabled(tooLong || saving)
                    .foregroundStyle(TC.brand)
                    .accessibilityIdentifier("remark-done")
            }
        }
        .onAppear {
            if store.socialLoaded, friend == nil { model.pop() }
        }
    }

    private func done() {
        guard !saving, !tooLong else { return }
        let next = trimText(text)
        if next == current {
            model.pop()
            return
        }
        saving = true
        Task {
            do {
                try await store.client.setFriendRemark(userId, next)
            } catch {
                model.hub.show(errorText(errorCode(error), cmd: "friendRemark"))
            }
            saving = false
            model.pop()
        }
    }
}

/// Group list (PRD-ui F-UI-32): reloaded on each entry; not limited by the 500 conversations.
struct GroupsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var groups: [MyGroup]?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if failed {
                    Button("加载失败，点击重试") {
                        failed = false
                        groups = nil
                        Task { await load() }
                    }
                    .font(TTFont.body)
                    .foregroundStyle(TC.brand)
                    .padding(TS.s5)
                    .accessibilityIdentifier("groups-retry")
                } else if let groups {
                    if groups.isEmpty {
                        EmptyStateView(text: "还没有加入群聊", id: "groups-empty")
                    } else {
                        Text(verbatim: "\(groups.count) 个群聊")
                            .font(TTFont.small)
                            .foregroundStyle(TC.textSecondary)
                            .padding(TS.s3)
                            .accessibilityIdentifier("groups-count")
                        ForEach(sortedGroups(groups), id: \.groupId) { g in
                            RowButton(id: "group-row", action: { model.push(.chat(groupConvId(g.groupId))) }) {
                                Avatar(id: g.groupId, name: g.name, size: 40, group: true)
                                Text(g.name).font(TTFont.body).foregroundStyle(TC.textPrimary).lineLimit(1)
                                Spacer(minLength: TS.s2)
                                Text(verbatim: "\(g.memberCount) 人")
                                    .font(TTFont.small)
                                    .foregroundStyle(TC.textSecondary)
                                    .fixedSize()
                            }
                        }
                    }
                } else {
                    RowsSkeleton(id: "groups-skeleton")
                }
            }
        }
        .accessibilityIdentifier("groups")
        .background(TC.bg)
        .ttNavigationBar("群聊")
        .task(id: store.connected) {
            if store.connected { await load() }
        }
    }

    private func load() async {
        do {
            groups = try await store.client.loadMyGroups()
        } catch {
            failed = true
        }
    }
}

/// F-UI-32 rule 2: by name with the contacts' order, then groupId bytes.
public func sortedGroups(_ groups: [MyGroup]) -> [MyGroup] {
    groups.sorted { a, b in
        a.name == b.name ? a.groupId.utf8.lexicographicallyPrecedes(b.groupId.utf8) : nameLess(a.name, b.name)
    }
}
