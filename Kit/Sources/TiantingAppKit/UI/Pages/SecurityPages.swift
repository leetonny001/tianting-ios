import SwiftUI
import TiantingIM

/// "账号安全" (PRD-chat 13.3): hidden from demo sessions. Other sessions and recent logins come from `GET /v1/account/events`.
struct AccountSecurityPage: View {
    @Environment(AppModel.self) private var model
    @State private var events: AccountEvents?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row("修改密码", id: "security-password") { model.push(.security(.changePassword)) }
                row("重新生成恢复码", id: "security-regenerate") { model.push(.security(.regenerateCode)) }
                row("退出其他设备", id: "security-logout-others") { model.push(.security(.logoutOthers)) }
                row("注销账号", id: "security-delete", danger: true) { confirmDelete() }
                section
            }
        }
        .background(TC.bg)
        .ttNavigationBar("账号安全")
        .task { await load() }
    }

    @ViewBuilder private var section: some View {
        VStack(alignment: .leading, spacing: TS.s2) {
            if let events {
                Text(otherSessionsText(events.otherSessions))
                    .font(TTFont.small)
                    .foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("security-other-sessions")
                Text("最近登录记录")
                    .font(TTFont.body)
                    .foregroundStyle(TC.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, TS.s2)
                if events.events.isEmpty {
                    Text("暂无记录").font(TTFont.small).foregroundStyle(TC.textSecondary)
                        .accessibilityIdentifier("security-events-empty")
                }
                ForEach(Array(events.events.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: accountEventText(e.kind)).font(TTFont.body).foregroundStyle(TC.textPrimary)
                        Text(verbatim: [formatDateTime(e.at), platformText(e.platform)].compactMap { $0 }.joined(separator: " · "))
                            .font(TTFont.small)
                            .foregroundStyle(TC.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("security-event")
                    .padding(.vertical, TS.s1)
                }
            } else if failed {
                Text(networkErrorText).font(TTFont.small).foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("security-events-error")
                BlockButton(title: "重试", kind: .secondary, id: "security-events-retry") { Task { await load() } }
            } else {
                Spinner().accessibilityIdentifier("security-events-loading")
            }
        }
        .padding(TS.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func otherSessionsText(_ s: AccountEvents.OtherSessions) -> String {
        guard s.count > 0 else { return "没有其他已登录的设备" }
        if let at = s.lastActiveAt { return "其他 \(s.count) 台设备已登录，最近活跃：\(formatDateTime(at))" }
        return "其他 \(s.count) 台设备已登录"
    }

    private func row(_ title: String, id: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        RowButton(id: id, action: action) {
            Text(title).font(TTFont.body).foregroundStyle(danger ? TC.danger : TC.textPrimary)
            Spacer()
            Icon(name: .forward, size: 16).foregroundStyle(TC.textTertiary)
        }
    }

    private func load() async {
        failed = false
        do {
            events = try await model.account.listEvents()
        } catch {
            failed = events == nil
        }
    }

    private func confirmDelete() {
        let model = model
        model.hub.confirm(id: "delete-dialog", text: deletionWarningText, ok: "继续", danger: true) {
            model.push(.security(.deleteAccount))
        }
    }
}

/// The password forms of "账号安全". A wrong password stays here with a hint (AC-ACC-04-10, AC-ACC-08-6).
struct SecurityFormPage: View {
    let action: SecurityAction
    @Environment(AppModel.self) private var model
    @State private var current = ""
    @State private var next = ""
    @State private var error = ""
    @State private var busy = false

    private var canSubmit: Bool { !current.isEmpty && (action != .changePassword || !next.isEmpty) && !busy }

    private var title: String {
        switch action {
        case .changePassword: return "修改密码"
        case .regenerateCode: return "重新生成恢复码"
        case .logoutOthers: return "退出其他设备"
        case .deleteAccount: return "注销账号"
        }
    }

    private var hint: String? {
        switch action {
        case .changePassword: return "修改后其他设备会下线，并生成新的恢复码"
        case .regenerateCode: return "旧恢复码还能用 7 天。\(recoveryLostText)"
        case .logoutOthers: return "其他设备会下线，密码不变"
        case .deleteAccount: return deletionWarningText
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s4) {
                if let hint {
                    Text(hint).font(TTFont.small).foregroundStyle(action == .deleteAccount ? TC.danger : TC.textSecondary)
                        .accessibilityIdentifier("security-form-hint")
                }
                LabeledField(label: "当前密码") {
                    TTSecureField(placeholder: "当前密码", text: $current, id: "security-current", submit: action == .changePassword ? .next : .go) {
                        if action != .changePassword { submit() }
                    }
                }
                if action == .changePassword {
                    LabeledField(label: "新密码") {
                        TTSecureField(placeholder: "新密码", text: $next, id: "security-new", choosesNew: true, submit: .go) { submit() }
                    }
                }
                if !error.isEmpty { FieldError(text: error, id: "security-error") }
                BlockButton(title: busy ? "提交中…" : title, kind: action == .deleteAccount ? .danger : .primary, id: "security-submit") {
                    submit()
                }
                .disabled(!canSubmit)
            }
            .padding(TS.s5)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TC.bg)
        .ttNavigationBar(title)
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = ""
        let secret = current
        let new = next
        let model = model
        Task {
            defer { busy = false }
            do {
                switch action {
                case .changePassword:
                    try await model.changePassword(old: secret, new: new)
                    model.pop()
                    model.hub.show("密码已修改")
                case .regenerateCode:
                    try await model.requestRecoveryCode(password: secret)
                    model.pop()
                case .logoutOthers:
                    try await model.logoutOthers(password: secret)
                    model.pop()
                    model.hub.show("已退出其他设备")
                case .deleteAccount:
                    try await model.account.requestDelete(password: secret)
                    model.hub.show("已申请注销，7 天内登录可撤销")
                }
            } catch {
                let f = accountFailure(error, page: .password)
                if f.clearPassword { current = "" }
                self.error = f.text
            }
        }
    }
}

/// F-ACC-06: this device shows the new nickname at once; others follow the 10-minute cache.
struct EditNicknamePage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var text = ""
    @State private var error = ""
    @State private var busy = false

    private var trimmed: String { trimText(text) }
    private var tooLong: Bool { textLength(trimmed) > maxNickname }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s4) {
                LabeledField(label: "昵称") {
                    TTTextField(placeholder: "昵称", text: $text, id: "nickname-input", autocapitalize: true, submit: .done) { submit() }
                    if tooLong { FieldError(text: "昵称最多 32 个字", id: "nickname-too-long") }
                }
                if !error.isEmpty { FieldError(text: error, id: "nickname-error") }
                BlockButton(title: busy ? "提交中…" : "保存", id: "nickname-submit") { submit() }
                    .disabled(trimmed.isEmpty || tooLong || busy)
            }
            .padding(TS.s5)
        }
        .background(TC.bg)
        .ttNavigationBar("修改昵称")
        .onAppear { if text.isEmpty { text = store.profile(store.me)?.nickname ?? "" } }
    }

    private func submit() {
        guard !trimmed.isEmpty, !tooLong, !busy else { return }
        busy = true
        error = ""
        let name = trimmed
        Task {
            defer { busy = false }
            do {
                try await model.account.updateProfile(nickname: name)
                model.pop()
            } catch {
                self.error = accountFailure(error, page: .nickname).text
            }
        }
    }
}
