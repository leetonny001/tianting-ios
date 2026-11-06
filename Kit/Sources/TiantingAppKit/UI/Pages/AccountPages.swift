import SwiftUI
import TiantingIM
import UniformTypeIdentifiers
import WebKit

/// "保存恢复码" (F-ACC-05 rule 1, AC-ACC-01-12): the code, "复制", the warning and one way out, "我已保存". The root view shows it
/// in place of everything else, so no back gesture has anywhere to go, and nothing is reachable before confirming. Without a
/// code (the newest generation is unconfirmed and this device never saw it) it asks for the password to make a new one.
struct RecoveryCodePage: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s4) {
                Text("保存恢复码")
                    .font(TTFont.large)
                    .foregroundStyle(TC.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, TS.s5)
                Text(recoveryLostText)
                    .font(TTFont.body)
                    .foregroundStyle(TC.danger)
                    .accessibilityIdentifier("recovery-warning")
                if let code = model.recovery?.code {
                    codeSection(code)
                } else {
                    regenerateSection
                }
            }
            .padding(TS.s5)
            .frame(maxWidth: Tokens.Size.container)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TC.bg.ignoresSafeArea())
        .accessibilityIdentifier("recovery-page")
    }

    @ViewBuilder private func codeSection(_ code: String) -> some View {
        Text(verbatim: code)
            .font(.system(.title3, design: .monospaced))
            .foregroundStyle(TC.textPrimary)
            .textSelection(.enabled)
            .privacySensitive()
            .padding(TS.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.md))
            .accessibilityIdentifier("recovery-code")
        BlockButton(title: "复制", kind: .secondary, id: "recovery-copy") { copy(code) }
        if !error.isEmpty { FieldError(text: error, id: "recovery-error") }
        BlockButton(title: busy ? "提交中…" : "我已保存", id: "recovery-confirm") { confirm() }
            .disabled(busy)
    }

    @ViewBuilder private var regenerateSection: some View {
        Text("需要输入密码生成新的恢复码")
            .font(TTFont.body)
            .foregroundStyle(TC.textSecondary)
            .accessibilityIdentifier("recovery-needs-password")
        LabeledField(label: "当前密码") {
            TTSecureField(placeholder: "当前密码", text: $password, id: "recovery-password", submit: .go) { regenerate() }
        }
        if !error.isEmpty { FieldError(text: error, id: "recovery-error") }
        BlockButton(title: busy ? "提交中…" : "生成恢复码", id: "recovery-regenerate") { regenerate() }
            .disabled(password.isEmpty || busy)
        // Forgot the password: the only way on is the recovery code on the login page, so this page must not trap anyone.
        TextLink(title: "退出登录", id: "recovery-logout") { model.logout() }
    }

    /// Local to this device, not the universal clipboard. It reads back, so a failure is not reported as a copy (13.4).
    private func copy(_ code: String) {
        if !TestHooks.copyFails {
            UIPasteboard.general.setItems([[UTType.plainText.identifier: code]], options: [.localOnly: true])
        }
        if !TestHooks.copyFails, UIPasteboard.general.string == code {
            model.hub.show("已复制")
        } else {
            model.hub.show("复制失败，请手动记下")
        }
    }

    private func confirm() {
        guard !busy else { return }
        busy = true
        error = ""
        Task {
            defer { busy = false }
            do {
                try await model.confirmRecovery()
            } catch let e as AccountError where e.reason == "recoveryCodeStale" {
                // The SDK ended the session: the dialog says so, then the login page (AC-ACC-05-15).
            } catch {
                self.error = accountFailure(error, page: .password).text
            }
        }
    }

    private func regenerate() {
        guard !busy, !password.isEmpty else { return }
        busy = true
        error = ""
        let secret = password
        Task {
            defer { busy = false }
            do {
                try await model.requestRecoveryCode(password: secret)
                password = ""
            } catch {
                let f = accountFailure(error, page: .password)
                if f.clearPassword { password = "" }
                self.error = f.text
            }
        }
    }
}

/// The notice version changed since this account last saw it (F-ACC-10 rule 2): shown once; nothing depends on the answer.
struct PrivacyUpdateDialog: View {
    let dismiss: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(spacing: TS.s4) {
            Text("隐私说明已更新")
                .font(TTFont.body)
                .foregroundStyle(TC.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("privacy-update-text")
            HStack(spacing: TS.s3) {
                Button(action: open) { Text("查看").frame(maxWidth: .infinity) }
                    .buttonStyle(TTButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("privacy-update-open")
                Button(action: dismiss) { Text("知道了").frame(maxWidth: .infinity) }
                    .buttonStyle(TTButtonStyle(kind: .primary))
                    .accessibilityIdentifier("privacy-update-ok")
            }
        }
    }
}

/// "隐私说明" (F-ACC-10): the configured page, without scripts. A failure says so and blocks nothing.
struct PrivacyNoticePage: View {
    @Environment(AppModel.self) private var model
    @State private var state = PrivacyWebView.LoadState.loading

    var body: some View {
        ZStack {
            if let url = model.noticeURL {
                PrivacyWebView(url: url, state: $state)
                    .opacity(state == .loaded ? 1 : 0)
                    .accessibilityIdentifier("privacy-web")
            }
            switch state {
            case .loading:
                Spinner(size: 24).accessibilityIdentifier("privacy-loading")
            case .failed:
                Text("暂时打不开，请稍后重试")
                    .font(TTFont.body)
                    .foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("privacy-error")
            case .loaded:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TC.bg)
        .ttNavigationBar("隐私说明")
        .onAppear { if model.noticeURL == nil { state = .failed } }
    }
}

struct PrivacyWebView: UIViewRepresentable {
    enum LoadState { case loading, loaded, failed }

    let url: URL
    @Binding var state: LoadState

    func makeCoordinator() -> Coordinator { Coordinator(state: $state) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var state: LoadState

        init(state: Binding<LoadState>) {
            _state = state
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                state = .failed
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if state == .loading { state = .loaded }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            state = .failed
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            state = .failed
        }
    }
}
