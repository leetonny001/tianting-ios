import SwiftUI
import TiantingIM

/// The logo: mark and name (PRD-ui 1.4 B-1: own design).
struct Logo: View {
    var body: some View {
        VStack(spacing: TS.s3) {
            Text("听")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(TC.onBrand)
                .frame(width: 72, height: 72)
                .background(TC.brandFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            Text("天听")
                .font(TTFont.large)
                .foregroundStyle(TC.textPrimary)
                .accessibilityIdentifier("login-logo")
        }
    }
}

enum LoginRoute: Hashable {
    case account, register, recover, privacy
}

/// The way in (PRD-chat 13.3, F-ACC-07 rule 5): `GET /v1/config` decides the entries, and without it nothing is guessed.
struct LoginPage: View {
    @Environment(AppModel.self) private var model
    @State private var path: [LoginRoute] = []

    var body: some View {
        ZStack {
            NavigationStack(path: $path) {
                LoginHome(path: $path)
                    .navigationDestination(for: LoginRoute.self) { route in
                        switch route {
                        case .account: AccountLoginPage(path: $path)
                        case .register: RegisterPage(path: $path)
                        case .recover: RecoverPage()
                        case .privacy: PrivacyNoticePage()
                        }
                    }
            }
            DialogLayer()
        }
        .task { await model.loadLoginConfig() }
    }
}

private struct LoginHome: View {
    @Binding var path: [LoginRoute]
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: TS.s5) {
                Logo().padding(.top, TS.s6)
                switch model.loginConfig {
                case .loading:
                    Spinner(size: 24).accessibilityIdentifier("login-loading")
                case .failed:
                    Text(networkErrorText)
                        .font(TTFont.body)
                        .foregroundStyle(TC.textSecondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("login-config-error")
                    BlockButton(title: "重试", kind: .secondary, id: "login-config-retry") {
                        Task { await model.loadLoginConfig() }
                    }
                case .loaded(let config):
                    let entry = loginEntry(config, buildDemoLogin: model.config.demoLogin)
                    if entry.showDemo {
                        DemoLoginForm()
                        BlockButton(title: "使用账号登录", kind: .secondary, id: "login-use-account") { path.append(.account) }
                    } else {
                        AccountLoginForm(path: $path)
                    }
                    if entry.privacyURL != nil { PrivacyLink(id: "login-privacy") { path.append(.privacy) } }
                }
            }
            .padding(TS.s5)
            .frame(maxWidth: Tokens.Size.container)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TC.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The demo form (PRD-ui F-UI-03), unchanged (AC-ACC-07-6).
private struct DemoLoginForm: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var nickname = ""
    @State private var error = ""
    @State private var busy = false

    private var trimmed: String { trimText(username) }
    private var nicknameTooLong: Bool { textLength(nickname) > maxNickname }
    private var canSubmit: Bool { !trimmed.isEmpty && !nicknameTooLong && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: TS.s2) {
            Text("用户名").font(TTFont.small).foregroundStyle(TC.textSecondary)
            TTTextField(placeholder: "用户名", text: $username, id: "login-username", ascii: true, submit: .go) { submit() }
        }
        VStack(alignment: .leading, spacing: TS.s2) {
            Text("昵称（选填）").font(TTFont.small).foregroundStyle(TC.textSecondary)
            TTTextField(placeholder: "昵称（选填）", text: $nickname, id: "login-nickname", autocapitalize: true, submit: .go) {
                submit()
            }
            if nicknameTooLong { FieldError(text: "昵称最多 32 个字", id: "login-nickname-error") }
        }
        if !error.isEmpty {
            FieldError(text: error, id: "login-error")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        BlockButton(title: busy ? "登录中…" : "登录", id: "login-submit") { submit() }
            .disabled(!canSubmit)
        Text("演示环境：输入任意用户名即可登录")
            .font(TTFont.small)
            .foregroundStyle(TC.textTertiary)
            .multilineTextAlignment(.center)
    }

    private func submit() {
        guard canSubmit else { return }  // Also stops double submits (AC-UI-03-3).
        guard isValidUserId(trimmed) else {
            error = errorText(4004)
            return
        }
        busy = true
        error = ""
        let name = trimText(nickname)
        let user = trimmed
        Task {
            let outcome = await DemoLoginService(server: model.config.server).login(username: user, nickname: name)
            busy = false
            switch outcome {
            case .success(let session): await model.login(session)
            case .failure(let text): error = text
            }
        }
    }
}

/// Reached from the demo form ("使用账号登录").
private struct AccountLoginPage: View {
    @Binding var path: [LoginRoute]

    var body: some View {
        ScrollView {
            VStack(spacing: TS.s5) {
                AccountLoginForm(path: $path)
            }
            .padding(TS.s5)
            .frame(maxWidth: Tokens.Size.container)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TC.bg.ignoresSafeArea())
        .ttNavigationBar("账号登录")
    }
}

/// Account login (F-ACC-02). "忘记密码" is always there (F-ACC-05 rule 5).
private struct AccountLoginForm: View {
    @Binding var path: [LoginRoute]
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false

    private var canSubmit: Bool { !trimText(username).isEmpty && !password.isEmpty && !busy }

    var body: some View {
        LabeledField(label: "用户名") {
            TTTextField(placeholder: "用户名", text: $username, id: "account-username", ascii: true, submit: .next)
        }
        LabeledField(label: "密码") {
            TTSecureField(placeholder: "密码", text: $password, id: "account-password", submit: .go) { submit() }
        }
        if !error.isEmpty {
            FieldError(text: error, id: "account-error").frame(maxWidth: .infinity, alignment: .leading)
        }
        BlockButton(title: busy ? "登录中…" : "登录", id: "account-submit") { submit() }
            .disabled(!canSubmit)
        HStack {
            if showsRegister {
                TextLink(title: "注册", id: "account-register") { path.append(.register) }
            }
            Spacer()
            TextLink(title: "忘记密码", id: "account-forgot") { path.append(.recover) }
        }
    }

    private var showsRegister: Bool {
        guard case .loaded(let c) = model.loginConfig else { return false }
        return loginEntry(c, buildDemoLogin: model.config.demoLogin).showRegister
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = ""
        let user = trimText(username)
        let secret = password
        Task {
            defer { busy = false }
            do {
                try await model.accountLogin(username: user, password: secret)
            } catch {
                show(accountFailure(error, page: .login), user: user, secret: secret)
            }
        }
    }

    private func show(_ failure: AccountFailure, user: String, secret: String) {
        if failure.clearPassword { password = "" }
        if failure.deleteAt != nil {
            let model = model
            model.hub.confirm(
                id: "delete-pending-dialog", text: deletionPendingText(deleteAt: failure.deleteAt), ok: "撤销注销"
            ) {
                Task { await cancelDeletion(user: user, secret: secret) }
            }
            return
        }
        error = failure.text
    }

    /// F-ACC-08 rule 2: then an ordinary login.
    private func cancelDeletion(user: String, secret: String) async {
        busy = true
        defer { busy = false }
        do {
            try await model.cancelDeletion(username: user, password: secret)
            model.hub.show("已撤销注销")
            try await model.accountLogin(username: user, password: secret)
        } catch {
            show(accountFailure(error, page: .login), user: user, secret: secret)
        }
    }
}

/// A small link-styled button, 44 tall.
struct TextLink: View {
    let title: String
    var id: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).font(TTFont.small).foregroundStyle(TC.brand) }
            .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
            .optionalIdentifier(id)
    }
}

struct PrivacyLink: View {
    var id: String
    let action: () -> Void

    var body: some View {
        TextLink(title: "隐私说明", id: id, action: action)
    }
}

/// Registration (F-ACC-01, AC-ACC-01-13, AC-ACC-01-18): whatever fails, what was typed stays.
private struct RegisterPage: View {
    @Binding var path: [LoginRoute]
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var invite = ""
    @State private var usernameError = ""
    @State private var error = ""
    @State private var busy = false

    private var entry: LoginEntry? {
        guard case .loaded(let c) = model.loginConfig else { return nil }
        return loginEntry(c, buildDemoLogin: model.config.demoLogin)
    }
    private var nicknameTooLong: Bool { textLength(nickname) > maxNickname }
    private var canSubmit: Bool {
        !trimText(username).isEmpty && !password.isEmpty && !nicknameTooLong && !busy
            && (entry?.askInviteCode != true || !trimText(invite).isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s4) {
                LabeledField(label: "用户名") {
                    TTTextField(placeholder: "用户名", text: $username, id: "register-username", ascii: true, submit: .next)
                    if !usernameError.isEmpty { FieldError(text: usernameError, id: "register-username-error") }
                }
                LabeledField(label: "密码") {
                    TTSecureField(placeholder: "密码", text: $password, id: "register-password", choosesNew: true, submit: .next)
                }
                LabeledField(label: "昵称（选填）") {
                    TTTextField(placeholder: "昵称（选填）", text: $nickname, id: "register-nickname", autocapitalize: true, submit: .next)
                    if nicknameTooLong { FieldError(text: "昵称最多 32 个字", id: "register-nickname-error") }
                }
                if entry?.askInviteCode == true {
                    LabeledField(label: "邀请码") {
                        TTTextField(placeholder: "邀请码", text: $invite, id: "register-invite", ascii: true, submit: .go) { submit() }
                    }
                }
                if !error.isEmpty { FieldError(text: error, id: "register-error") }
                BlockButton(title: busy ? "提交中…" : "注册", id: "register-submit") { submit() }
                    .disabled(!canSubmit)
                Text(recoveryLostText)
                    .font(TTFont.small)
                    .foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("register-recovery-hint")
                if entry?.privacyURL != nil {
                    HStack(spacing: 0) {
                        Text("注册即表示你已阅读").font(TTFont.small).foregroundStyle(TC.textSecondary)
                        PrivacyLink(id: "register-privacy") { path.append(.privacy) }
                    }
                }
            }
            .padding(TS.s5)
            .frame(maxWidth: Tokens.Size.container)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TC.bg.ignoresSafeArea())
        .ttNavigationBar("注册")
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = ""
        usernameError = ""
        let name = trimText(nickname)
        let code = trimText(invite)
        let ask = entry?.askInviteCode == true
        let user = trimText(username)
        let secret = password
        Task {
            defer { busy = false }
            do {
                try await model.accountRegister(
                    username: user, password: secret, nickname: name.isEmpty ? nil : name, inviteCode: ask ? code : nil)
            } catch {
                let f = accountFailure(error, page: .register)
                if f.onUsername { usernameError = f.text } else { self.error = f.text }
            }
        }
    }
}

/// Forgot password: only the recovery code route (F-ACC-05 rule 6, AC-ACC-05-10).
private struct RecoverPage: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var code = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false

    private var canSubmit: Bool { !trimText(username).isEmpty && !trimText(code).isEmpty && !password.isEmpty && !busy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s4) {
                LabeledField(label: "用户名") {
                    TTTextField(placeholder: "用户名", text: $username, id: "recover-username", ascii: true, submit: .next)
                }
                LabeledField(label: "恢复码") {
                    TTTextField(placeholder: "恢复码", text: $code, id: "recover-code", ascii: true, submit: .next)
                }
                LabeledField(label: "新密码") {
                    TTSecureField(placeholder: "新密码", text: $password, id: "recover-password", choosesNew: true, submit: .go) { submit() }
                }
                if !error.isEmpty { FieldError(text: error, id: "recover-error") }
                BlockButton(title: busy ? "提交中…" : "找回密码", id: "recover-submit") { submit() }
                    .disabled(!canSubmit)
                Text(recoveryLostText)
                    .font(TTFont.small)
                    .foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("recover-recovery-hint")
            }
            .padding(TS.s5)
            .frame(maxWidth: Tokens.Size.container)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TC.bg.ignoresSafeArea())
        .ttNavigationBar("忘记密码")
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = ""
        let user = trimText(username)
        let recovery = trimText(code)
        let secret = password
        Task {
            defer { busy = false }
            do {
                try await model.accountRecover(username: user, recoveryCode: recovery, newPassword: secret)
            } catch {
                self.error = accountFailure(error, page: .recover).text
            }
        }
    }
}
