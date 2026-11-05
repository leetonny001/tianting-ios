import SwiftUI
import TiantingIM

/// Group data for a page (the counterpart of web's `useGroupInfo`): fetched on entry and on reconnect, then updated by
/// `groupChanged`. `gone` means 4033 / 4043.
@MainActor
@Observable
final class GroupInfoModel {
    private(set) var info: GroupInfo?
    private(set) var gone = false
    let groupId: String
    private let store: IMStore

    init(store: IMStore, groupId: String) {
        self.store = store
        self.groupId = groupId
    }

    func refresh() async {
        do {
            info = try await store.client.getGroupInfo(groupId)
        } catch {
            if let code = (error as? IMError)?.code, code == 4033 || code == 4043 { gone = true }
        }
    }

    func apply(_ next: GroupInfo?) {
        if let next { info = next }
    }

    func markGone() {
        gone = true
    }
}

/// Group members in pages (F-UI-38 rule 1): load more dedupes by userId; reload refetches up to the count held, so the
/// list does not snap back to the first page, and a newer reload drops older results.
@MainActor
@Observable
final class GroupMembersModel {
    private(set) var members: [GroupMemberInfo] = []
    private(set) var loaded = false
    private(set) var hasMore = false
    private var cursor = ""
    private var generation = 0
    private var busy = false
    let groupId: String
    private let store: IMStore

    init(store: IMStore, groupId: String) {
        self.store = store
        self.groupId = groupId
    }

    private func merged(_ list: [GroupMemberInfo], _ page: [GroupMemberInfo]) -> [GroupMemberInfo] {
        var seen = Set(list.map(\.userId))
        return list + page.filter { seen.insert($0.userId).inserted }
    }

    private func publish(_ list: [GroupMemberInfo], _ next: String) {
        cursor = next
        members = list
        hasMore = !next.isEmpty
        loaded = true
    }

    func reload() async {
        generation += 1
        let mine = generation
        busy = true
        defer { if mine == generation { busy = false } }
        let target = members.count
        do {
            var list: [GroupMemberInfo] = []
            var next = ""
            repeat {
                let page = try await store.client.loadGroupMembers(groupId, cursor: next.isEmpty ? nil : next)
                if mine != generation { return }
                list = merged(list, page.members)
                next = page.nextCursor
            } while !next.isEmpty && list.count < target
            publish(list, next)
        } catch {
            // Keep the list; the next groupChanged or reconnect reloads.
        }
    }

    func loadMore() async {
        guard !busy, !cursor.isEmpty else { return }
        let mine = generation
        busy = true
        defer { if mine == generation { busy = false } }
        do {
            let page = try await store.client.loadGroupMembers(groupId, cursor: cursor)
            if mine != generation { return }
            publish(merged(members, page.members), page.nextCursor)
        } catch {
            // Retried on the next scroll.
        }
    }
}

private struct GroupSync: ViewModifier {
    let convId: String
    let info: GroupInfoModel
    var members: GroupMembersModel?
    @Environment(IMStore.self) private var store

    func body(content: Content) -> some View {
        content
            .task(id: store.connected) {
                guard store.connected else { return }
                async let a: Void = info.refresh()
                async let b: Void = members?.reload() ?? ()
                _ = await (a, b)
            }
            .onChange(of: store.groupTicks[info.groupId]) { _, _ in
                info.apply(store.groupInfos[info.groupId])
                Task { await members?.reload() }
            }
            .onChange(of: store.snapshot(convId) != nil) { _, removed in
                if removed { info.markGone() }
            }
    }
}

extension View {
    fileprivate func groupSync(_ convId: String, info: GroupInfoModel, members: GroupMembersModel? = nil) -> some View {
        modifier(GroupSync(convId: convId, info: info, members: members))
    }
}

/// Chat info: read-only for single chats (F-UI-12), group settings for groups (F-UI-36), and only the name plus a note once
/// out of the group.
struct ChatInfoPage: View {
    let convId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var gone = false

    var body: some View {
        if let parsed = try? parseConvIdStrict(convId, me: store.me) {
            if parsed.convType == .group, store.snapshot(convId) == nil, !gone {
                GroupSettingsPage(convId: convId, store: store, onGone: { gone = true })
            } else {
                readOnly(parsed)
            }
        } else {
            Color.clear.onAppear { leaveInvalid(model, convId) }
        }
    }

    private func readOnly(_ parsed: ParsedConvId) -> some View {
        let isGroup = parsed.convType == .group
        let to = parsed.to
        let conv = store.conversation(convId)
        let snapshot = store.snapshot(convId)
        let local = isGroup ? to : store.displayName(to)
        let name = !isGroup && local != to ? local : (conv?.name ?? snapshot?.name ?? (isGroup ? "群聊" : to))
        return ScrollView {
            VStack(spacing: TS.s3) {
                Button {
                    if !isGroup { model.push(.user(to, UserContext(source: .conv))) }
                } label: {
                    HStack(spacing: TS.s3) {
                        Avatar(id: to, name: name, size: 64, group: isGroup, src: isGroup ? nil : store.profile(to)?.avatar)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: TS.s1) {
                                Text(name).font(TTFont.title).foregroundStyle(TC.textPrimary)
                                if !isGroup, store.profile(to)?.official == true { OfficialTag() }
                            }
                            Text(isGroup ? "群聊" : "账号：\(to)")
                                .font(TTFont.small)
                                .foregroundStyle(TC.textSecondary)
                                .accessibilityIdentifier("info-sub")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(TS.s4)
                    .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.lg))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowPressStyle())
                .disabled(isGroup)
                .accessibilityIdentifier("info-head")
                if isGroup, conv == nil {
                    Text(removedBlock(reason: snapshot?.reason).tip)
                        .font(TTFont.small)
                        .foregroundStyle(TC.textSecondary)
                        .accessibilityIdentifier("info-removed")
                }
            }
            .padding(TS.s3)
        }
        .background(TC.bg)
        .ttNavigationBar("聊天信息")
        .task(id: to) {
            if !isGroup { await store.loadProfiles([to]) }
        }
    }
}

/// Group settings (PRD-ui F-UI-36): entries by my role and whether the group is hosted.
private struct GroupSettingsPage: View {
    let convId: String
    let onGone: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var info: GroupInfoModel
    @State private var members: GroupMembersModel
    @State private var busy = false

    init(convId: String, store: IMStore, onGone: @escaping () -> Void) {
        self.convId = convId
        self.onGone = onGone
        let gid = groupId(ofConv: convId)
        _info = State(initialValue: GroupInfoModel(store: store, groupId: gid))
        _members = State(initialValue: GroupMembersModel(store: store, groupId: gid))
    }

    var body: some View {
        Group {
            if let group = info.info {
                content(group)
            } else {
                RowsSkeleton(id: "group-skeleton")
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(TC.bg)
        .ttNavigationBar(info.info.map { "聊天信息（\($0.memberCount)）" } ?? "聊天信息")
        .groupSync(convId, info: info, members: members)
        .onChange(of: info.gone) { _, gone in
            if gone { onGone() }
        }
    }

    private func content(_ group: GroupInfo) -> some View {
        let can = GroupPermissions(role: group.myRole, managed: group.managed, owner: group.owner)
        return ScrollView {
            VStack(spacing: TS.s3) {
                grid(can)
                RowButton(id: "all-members", action: { model.push(.members(convId, .view)) }) {
                    Text(verbatim: "查看全部成员（\(group.memberCount)）").font(TTFont.body).foregroundStyle(TC.textPrimary)
                    Spacer()
                    Icon(name: .forward, size: 16).foregroundStyle(TC.textTertiary)
                }
                VStack(spacing: 0) {
                    nameRow(group, editable: can.canManage)
                    RowButton(id: "group-notice", action: { model.push(.notice(convId)) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("群公告").font(TTFont.body).foregroundStyle(TC.textPrimary)
                            Text(group.notice.nonEmpty ?? "暂无群公告")
                                .font(TTFont.small)
                                .foregroundStyle(TC.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("group-notice-preview")
                        }
                        Spacer()
                    }
                }
                if can.isOwner {
                    VStack(spacing: 0) {
                        RowButton(id: "manage-admin", action: { model.push(.members(convId, .admin)) }) {
                            Text("设置管理员").font(TTFont.body).foregroundStyle(TC.textPrimary)
                            Spacer()
                        }
                        RowButton(id: "manage-transfer", action: { model.push(.members(convId, .transfer)) }) {
                            Text("转让群主").font(TTFont.body).foregroundStyle(TC.textPrimary)
                            Spacer()
                        }
                    }
                }
                VStack(spacing: 0) {
                    RowButton(id: "group-leave", action: { confirmLeave(can) }) {
                        Text("退出群聊").font(TTFont.body).foregroundStyle(TC.danger)
                        Spacer()
                    }
                    if can.canDissolve {
                        RowButton(id: "group-dissolve", action: confirmDissolve) {
                            Text("解散群聊").font(TTFont.body).foregroundStyle(TC.danger)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.vertical, TS.s3)
        }
    }

    private func grid(_ can: GroupPermissions) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: TS.s3) {
            ForEach(members.members.prefix(memberGridSize), id: \.userId) { m in
                let name = store.displayName(m.userId)
                Button {
                    model.push(.user(m.userId, UserContext(source: .group, sourceRef: info.groupId)))
                } label: {
                    VStack(spacing: TS.s1) {
                        Avatar(id: m.userId, name: name, size: 48, src: m.avatar)
                        Text(name).font(TTFont.caption).foregroundStyle(TC.textSecondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("grid-member")
            }
            if can.canInvite {
                gridOp("+", label: "邀请成员", id: "grid-invite") { model.push(.invite(convId)) }
            }
            if can.canManage {
                gridOp("−", label: "移出成员", id: "grid-kick") { model.push(.members(convId, .kick)) }
            }
        }
        .padding(TS.s3)
        .background(TC.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("member-grid")
    }

    private func gridOp(_ mark: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(mark)
                .font(.title2)
                .foregroundStyle(TC.textSecondary)
                .frame(width: 48, height: 48)
                .overlay(RoundedRectangle(cornerRadius: TR.md).stroke(TC.borderInput, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func nameRow(_ group: GroupInfo, editable: Bool) -> some View {
        let row = HStack(spacing: TS.s3) {
            Text("群聊名称").font(TTFont.body).foregroundStyle(TC.textPrimary).fixedSize()
            Spacer()
            Text(group.name).font(TTFont.small).foregroundStyle(TC.textSecondary).lineLimit(1)
        }
        if editable {
            RowButton(id: "group-name", action: { rename(group) }) { row }
                .accessibilityValue("可修改")
        } else {
            RowContainer { row }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group-name")
        }
    }

    private func rename(_ group: GroupInfo) {
        let gid = info.groupId
        let store = store
        let info = info
        let hub = model.hub
        hub.present(id: "rename-sheet", sheet: true) {
            RenameDialog(current: group.name) { name in
                Task {
                    do {
                        try await store.client.updateGroup(gid, name: name)
                        await info.refresh()
                    } catch {
                        let code = errorCode(error)
                        hub.show(errorText(code, cmd: "groupUpdate"))
                        if code == 4030 { await info.refresh() }
                    }
                }
            }
        }
    }

    private func confirmLeave(_ can: GroupPermissions) {
        let gid = info.groupId
        model.hub.confirm(id: "leave-confirm", text: can.leaveText, ok: "退出", danger: true) {
            act("groupLeave") { try await store.client.leaveGroup(gid) }
        }
    }

    private func confirmDissolve() {
        let gid = info.groupId
        model.hub.confirm(id: "dissolve-confirm", text: "解散后，所有成员将被移出群聊，且不能恢复", ok: "解散", danger: true) {
            act("groupDissolve") { try await store.client.dissolveGroup(gid) }
        }
    }

    private func act(_ cmd: String, _ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await op()
                model.popToRoot()
            } catch {
                let code = errorCode(error)
                model.hub.show(errorText(code, cmd: cmd))
                if code == 4030 { await info.refresh() }
            }
            busy = false
        }
    }
}

private struct RenameDialog: View {
    let current: String
    let onSave: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var value: String

    init(current: String, onSave: @escaping (String) -> Void) {
        self.current = current
        self.onSave = onSave
        _value = State(initialValue: current)
    }

    private var tooLong: Bool { textLength(value) > maxGroupName }
    private var empty: Bool { textLength(value) == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: TS.s3) {
            Text("修改群聊名称").font(TTFont.title).foregroundStyle(TC.textPrimary)
            TTTextField(placeholder: "群聊名称", text: $value, id: "rename-input", autocapitalize: true)
            if tooLong { FieldError(text: "最多 \(maxGroupName) 个字") }
            HStack(spacing: TS.s3) {
                Button {
                    model.hub.dismissDialog()
                } label: {
                    Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(TTButtonStyle(kind: .secondary))
                Button {
                    let name = trimText(value)
                    model.hub.dismissDialog()
                    if name != current { onSave(name) }
                } label: {
                    Text("保存").frame(maxWidth: .infinity)
                }
                .buttonStyle(TTButtonStyle())
                .disabled(tooLong || empty)
                .accessibilityIdentifier("rename-save")
            }
        }
    }
}

/// Group notice (PRD-ui F-UI-37): plain text with line breaks; owner and admins edit, empty clears.
struct GroupNoticePage: View {
    let convId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        NoticeContent(convId: convId, store: store)
    }
}

private struct NoticeContent: View {
    let convId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var info: GroupInfoModel
    @State private var draft: String?
    @State private var saving = false

    init(convId: String, store: IMStore) {
        self.convId = convId
        _info = State(initialValue: GroupInfoModel(store: store, groupId: groupId(ofConv: convId)))
    }

    private var canEdit: Bool {
        guard let role = info.info?.myRole else { return false }
        return role == .owner || role == .admin
    }
    private var length: Int { textLength(draft ?? "") }
    private var tooLong: Bool { length > maxNotice }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s3) {
                if let group = info.info {
                    if draft != nil {
                        editor
                    } else {
                        reader(group)
                    }
                } else {
                    RowsSkeleton(id: "notice-skeleton")
                }
            }
            .padding(TS.s4)
        }
        .background(TC.bg)
        .ttNavigationBar("群公告")
        .toolbar {
            if canEdit, let group = info.info {
                ToolbarItem(placement: .topBarTrailing) {
                    if draft == nil {
                        Button("编辑") { draft = group.notice }
                            .foregroundStyle(TC.brand)
                            .accessibilityIdentifier("notice-edit")
                    } else {
                        Button("完成") { save() }
                            .disabled(tooLong || saving)
                            .foregroundStyle(TC.brand)
                            .accessibilityIdentifier("notice-save")
                    }
                }
            }
        }
        .groupSync(convId, info: info)
        .onChange(of: info.gone) { _, gone in
            if gone { model.popToRoot() }
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: TS.s2) {
            TTTextEditor(
                text: Binding(get: { draft ?? "" }, set: { draft = $0 }), id: "notice-input", minHeight: 240, label: "群公告")
            Text(verbatim: "已输入 \(length) / \(maxNotice)")
                .font(TTFont.caption)
                .foregroundStyle(tooLong ? TC.danger : TC.textTertiary)
                .accessibilityIdentifier("notice-count")
        }
    }

    @ViewBuilder private func reader(_ group: GroupInfo) -> some View {
        if group.notice.isEmpty {
            Text("暂无群公告")
                .font(TTFont.body)
                .foregroundStyle(TC.textSecondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("notice-empty")
        } else {
            Text(verbatim: group.notice)
                .font(TTFont.body)
                .foregroundStyle(TC.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("notice-text")
            Text(noticeMeta(group))
                .font(TTFont.small)
                .foregroundStyle(TC.textSecondary)
                .accessibilityIdentifier("notice-meta")
                .task(id: group.noticeBy) { await store.loadProfiles([group.noticeBy]) }
        }
        if !canEdit {
            Text("仅群主和管理员可编辑")
                .font(TTFont.small)
                .foregroundStyle(TC.textSecondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("notice-readonly")
        }
    }

    private func noticeMeta(_ group: GroupInfo) -> String {
        let name = store.displayName(group.noticeBy)
        return group.noticeAt > 0 ? "\(name) \(formatTime(group.noticeAt))" : name
    }

    private func save() {
        guard let draft, !tooLong, !saving else { return }
        let next = trimText(draft)
        if next == info.info?.notice {
            self.draft = nil
            return
        }
        saving = true
        Task {
            do {
                try await store.client.updateGroup(info.groupId, notice: next)
                self.draft = nil
                await info.refresh()
            } catch {
                let code = errorCode(error)
                model.hub.show(errorText(code, cmd: "groupUpdate"))
                if code == 4030 {
                    self.draft = nil
                    await info.refresh()
                }
            }
            saving = false
        }
    }
}

/// Group members (PRD-ui F-UI-38): the server's order, no local sort or filter; pages load near the end.
struct GroupMembersPage: View {
    let convId: String
    let wanted: MemberMode
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        MembersContent(convId: convId, wanted: wanted, store: store)
    }
}

private struct MembersContent: View {
    let convId: String
    let wanted: MemberMode
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var info: GroupInfoModel
    @State private var members: GroupMembersModel
    @State private var picked: [String] = []
    @State private var viewOnly = false
    @State private var busy = false

    init(convId: String, wanted: MemberMode, store: IMStore) {
        self.convId = convId
        self.wanted = wanted
        let gid = groupId(ofConv: convId)
        _info = State(initialValue: GroupInfoModel(store: store, groupId: gid))
        _members = State(initialValue: GroupMembersModel(store: store, groupId: gid))
    }

    private var mode: MemberMode {
        viewOnly ? .view : allowedMemberMode(wanted, role: info.info?.myRole)
    }

    private var title: String {
        switch mode {
        case .view: return "群成员" + (info.info.map { "（\($0.memberCount)）" } ?? "")
        case .kick: return "移出成员"
        case .admin: return "设置管理员"
        case .transfer: return "转让群主"
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !members.loaded {
                    RowsSkeleton(id: "members-skeleton")
                } else {
                    let list = members.members
                    ForEach(Array(list.enumerated()), id: \.element.userId) { index, m in
                        row(m)
                            .onAppear {
                                if index >= list.count - 5, members.hasMore { Task { await members.loadMore() } }
                            }
                    }
                }
            }
        }
        .accessibilityIdentifier("member-list")
        .background(TC.bg)
        .ttNavigationBar(title)
        .toolbar {
            if mode == .kick {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("移出（\(picked.count)）") { confirmKick() }
                        .disabled(picked.isEmpty)
                        .foregroundStyle(TC.danger)
                        .accessibilityIdentifier("kick-submit")
                }
            }
        }
        .groupSync(convId, info: info, members: members)
        .onChange(of: info.gone) { _, gone in
            if gone { model.popToRoot() }
        }
    }

    @ViewBuilder private func row(_ m: GroupMemberInfo) -> some View {
        let name = store.displayName(m.userId)
        if mode == .view {
            RowButton(id: "member-row", action: {
                model.push(.user(m.userId, UserContext(source: .group, sourceRef: info.groupId)))
            }) {
                body(m, name)
            }
            .accessibilityValue(m.userId)
        } else {
            let can = memberSelectable(member: m.role, mode: mode, myRole: info.info?.myRole) && m.userId != store.me
            RowButton(id: "member-row", action: { pick(m) }) {
                if mode == .kick {
                    Image(systemName: picked.contains(m.userId) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked.contains(m.userId) ? TC.brand : TC.borderInput)
                        .accessibilityHidden(true)
                }
                body(m, name)
            }
            .disabled(!can)
            .opacity(can ? 1 : 0.5)
            .accessibilityValue(m.userId)
        }
    }

    @ViewBuilder private func body(_ m: GroupMemberInfo, _ name: String) -> some View {
        Avatar(id: m.userId, name: name, size: 40, src: m.avatar)
        Text(m.userId == store.me ? "\(name)（我）" : name)
            .font(TTFont.body)
            .foregroundStyle(TC.textPrimary)
            .lineLimit(1)
        if m.official { OfficialTag() }
        if let label = roleLabel(m.role) {
            Text(label)
                .font(TTFont.caption)
                .foregroundStyle(TC.brand)
                .accessibilityIdentifier("member-role")
        }
        Spacer(minLength: 0)
    }

    private func pick(_ m: GroupMemberInfo) {
        switch mode {
        case .admin:
            run("groupSetAdmin") {
                try await store.client.setGroupAdmin(info.groupId, userId: m.userId, admin: m.role != .admin)
            }
        case .transfer:
            let text = "确定将群主转让给 \(store.displayName(m.userId))？转让后你将成为普通成员"
            model.hub.confirm(id: "transfer-confirm", text: text, ok: "转让") {
                run("groupTransfer", thenView: true) {
                    try await store.client.transferGroupOwner(info.groupId, to: m.userId)
                }
            }
        case .kick:
            if let i = picked.firstIndex(of: m.userId) {
                picked.remove(at: i)
            } else if picked.count >= maxGroupBatch {
                model.hub.show("一次最多移出 \(maxGroupBatch) 人")
            } else {
                picked.append(m.userId)
            }
        case .view:
            break
        }
    }

    private func confirmKick() {
        let ids = picked
        model.hub.confirm(id: "kick-confirm", text: "确定将 \(ids.count) 人移出群聊？", ok: "移出", danger: true) {
            run("groupKick", thenView: true) {
                _ = try await store.client.kickFromGroup(info.groupId, members: ids)
            }
        }
    }

    private func run(_ cmd: String, thenView: Bool = false, _ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                try await op()
                if thenView {
                    picked = []
                    viewOnly = true
                }
                await info.refresh()
                await members.reload()
            } catch {
                let code = errorCode(error)
                model.hub.show(errorText(code, cmd: cmd))
                if code == 4030 || code == 4046 {
                    await info.refresh()
                    await members.reload()
                }
            }
            busy = false
        }
    }
}

/// The friend multi-select (F-UI-35 rule 2, F-UI-39 rule 1). `joined` shows "已在群里" and cannot be picked; `errors` are red.
struct FriendPicker: View {
    let selected: [String]
    var joined: Set<String> = []
    var errors: Set<String> = []
    let onToggle: (String) -> Void
    @Environment(IMStore.self) private var store
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TTTextField(placeholder: "搜索", text: $query, id: "pick-search", submit: .search)
                .padding(TS.s3)
            if !selected.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TS.s2) {
                        ForEach(selected, id: \.self) { id in
                            let friend = store.friends.first { $0.userId == id }
                            Avatar(id: id, name: friend?.displayName ?? id, size: 36, src: friend?.profile?.avatar)
                        }
                    }
                    .padding(.horizontal, TS.s3)
                    .padding(.bottom, TS.s2)
                }
                .accessibilityIdentifier("pick-strip")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !store.socialLoaded {
                        RowsSkeleton(id: "pick-skeleton")
                    } else {
                        let sections = groupByPinyin(
                            filterFriends(store.friends, query: query), name: { $0.displayName }, id: { $0.userId })
                        ForEach(sections, id: \.letter) { section in
                            GroupLetter(letter: section.letter)
                            ForEach(section.items, id: \.userId) { row($0) }
                        }
                    }
                }
            }
            .accessibilityIdentifier("pick-list")
        }
        .background(TC.bg)
    }

    private func row(_ f: Friend) -> some View {
        let inGroup = joined.contains(f.userId)
        let on = inGroup || selected.contains(f.userId)
        let error = errors.contains(f.userId)
        return RowButton(id: "pick-row", action: { onToggle(f.userId) }) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? TC.brand : TC.borderInput)
                .accessibilityHidden(true)
            Avatar(id: f.userId, name: f.displayName, size: 40, src: f.profile?.avatar)
            Text(f.displayName)
                .font(TTFont.body)
                .foregroundStyle(error ? TC.danger : TC.textPrimary)
                .lineLimit(1)
            if inGroup {
                Text("已在群里").font(TTFont.caption).foregroundStyle(TC.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .disabled(inGroup)
        .accessibilityValue(error ? "error" : (on ? "selected" : ""))
    }
}

/// Start a group (PRD-ui F-UI-35).
struct GroupNewPage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var selected: [String] = []
    @State private var errors: Set<String> = []

    var body: some View {
        FriendPicker(selected: selected, errors: errors) { id in
            if let i = selected.firstIndex(of: id) {
                selected.remove(at: i)
            } else {
                selected.append(id)
            }
        }
        .ttNavigationBar("发起群聊")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成（\(selected.count)）") { askName() }
                    .disabled(selected.count < minGroupPick)
                    .foregroundStyle(TC.brand)
                    .accessibilityIdentifier("pick-done")
            }
        }
    }

    private func askName() {
        guard selected.count >= minGroupPick else { return }
        let members = selected
        let model = model
        let store = store
        model.hub.present(id: "group-name-sheet", sheet: true) {
            GroupNameDialog { name in
                do {
                    let result = try await store.client.createGroup(name: name.isEmpty ? nil : name, members: members)
                    model.hub.dismissDialog()
                    model.replaceTop(with: .chat(result.conv.convId))
                } catch {
                    model.hub.dismissDialog()
                    let e = error as? IMError
                    model.hub.show(
                        memberErrorText(
                            code: errorCode(error), userId: e?.userId, cmd: "groupCreate", me: store.me
                        ) { store.displayName($0) })
                    if let bad = e?.userId { errors = [bad] }
                }
            }
        }
    }
}

private struct GroupNameDialog: View {
    let onCreate: (String) async -> Void
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var creating = false

    private var tooLong: Bool { textLength(name) > maxGroupName }

    var body: some View {
        VStack(alignment: .leading, spacing: TS.s3) {
            Text("群聊名称（选填）").font(TTFont.title).foregroundStyle(TC.textPrimary)
            TTTextField(placeholder: "群聊名称", text: $name, id: "group-name-input", autocapitalize: true)
            if tooLong { FieldError(text: "最多 \(maxGroupName) 个字") }
            HStack(spacing: TS.s3) {
                Button {
                    model.hub.dismissDialog()
                } label: {
                    Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(TTButtonStyle(kind: .secondary))
                Button {
                    guard !creating else { return }
                    creating = true
                    Task {
                        await onCreate(trimText(name))
                        creating = false
                    }
                } label: {
                    Text("创建").frame(maxWidth: .infinity)
                }
                .buttonStyle(TTButtonStyle())
                .disabled(tooLong || creating)
                .accessibilityIdentifier("group-create")
            }
        }
    }
}

/// Invite members (PRD-ui F-UI-39): loaded members show "已在群里"; the server ignores the rest who already joined.
struct GroupInvitePage: View {
    let convId: String
    @Environment(IMStore.self) private var store

    var body: some View {
        InviteContent(convId: convId, store: store)
    }
}

private struct InviteContent: View {
    let convId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var members: GroupMembersModel
    @State private var selected: [String] = []
    @State private var errors: Set<String> = []
    @State private var busy = false

    init(convId: String, store: IMStore) {
        self.convId = convId
        _members = State(initialValue: GroupMembersModel(store: store, groupId: groupId(ofConv: convId)))
    }

    var body: some View {
        FriendPicker(selected: selected, joined: Set(members.members.map(\.userId)), errors: errors) { id in
            if let i = selected.firstIndex(of: id) {
                selected.remove(at: i)
            } else if selected.count >= maxGroupBatch {
                model.hub.show("一次最多邀请 \(maxGroupBatch) 人")
            } else {
                selected.append(id)
            }
        }
        .ttNavigationBar("邀请成员")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成（\(selected.count)）") { invite() }
                    .disabled(selected.isEmpty || busy)
                    .foregroundStyle(TC.brand)
                    .accessibilityIdentifier("pick-done")
            }
        }
        .task(id: store.connected) {
            if store.connected { await members.reload() }
        }
    }

    private func invite() {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let result = try await store.client.inviteToGroup(members.groupId, members: selected)
                model.hub.show(inviteResultText(result, me: store.me) { store.displayName($0) })
                if result.added.isEmpty {
                    errors = Set(result.failed.map(\.userId))
                } else {
                    model.pop()
                }
            } catch {
                model.hub.show(errorText(errorCode(error), cmd: "groupInvite"))
            }
            busy = false
        }
    }
}
