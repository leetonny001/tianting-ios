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

/// The login page (PRD-ui F-UI-03): demo login only in the first phase.
struct LoginPage: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var nickname = ""
    @State private var error = ""
    @State private var busy = false

    private var trimmed: String { trimText(username) }
    private var nicknameTooLong: Bool { textLength(nickname) > maxNickname }
    private var canSubmit: Bool { !trimmed.isEmpty && !nicknameTooLong && !busy }

    var body: some View {
        ScrollView {
            VStack(spacing: TS.s5) {
                Logo().padding(.top, TS.s6)
                if model.config.demoLogin {
                    form
                } else {
                    Text("请从业务方入口进入天听")
                        .font(TTFont.body)
                        .foregroundStyle(TC.textSecondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("login-hint")
                }
            }
            .padding(TS.s5)
            .frame(maxWidth: Tokens.Size.container)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TC.bg.ignoresSafeArea())
    }

    @ViewBuilder private var form: some View {
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
            case .success(let session): model.login(session)
            case .failure(let text): error = text
            }
        }
    }
}
