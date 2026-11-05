import SwiftUI
import TiantingIM

struct CopyButton: View {
    let text: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("复制") {
            UIPasteboard.general.string = text
            model.hub.show("已复制")
        }
        .font(TTFont.small)
        .foregroundStyle(TC.brand)
        .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
        .accessibilityIdentifier("copy-button")
    }
}

/// Me (PRD-ui F-UI-15): no profile editing in the first phase.
struct MePage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        let profile = store.profile(store.me)
        let name = profile?.nickname.nonEmpty ?? store.me
        ScrollView {
            VStack(spacing: TS.s3) {
                HStack(spacing: TS.s3) {
                    Avatar(id: store.me, name: name, size: 64, src: profile?.avatar)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: TS.s1) {
                            Text(name)
                                .font(TTFont.large)
                                .foregroundStyle(TC.textPrimary)
                                .accessibilityIdentifier("me-name")
                            if store.official { OfficialTag() }
                        }
                        HStack(spacing: TS.s1) {
                            Text(verbatim: "账号：\(store.me)")
                                .font(TTFont.small)
                                .foregroundStyle(TC.textSecondary)
                                .accessibilityIdentifier("me-id")
                            CopyButton(text: store.me)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(TS.s4)
                .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.lg))
                .accessibilityElement(children: .contain)
                .padding(.horizontal, TS.s3)
                .padding(.top, TS.s3)
                RowButton(id: "me-settings", action: { model.push(.settings) }) {
                    Icon(name: .settings).foregroundStyle(TC.textSecondary)
                    Text("设置").font(TTFont.body).foregroundStyle(TC.textPrimary)
                    Spacer()
                    Icon(name: .forward, size: 16).foregroundStyle(TC.textTertiary)
                }
            }
        }
        .background(TC.bg)
        .task(id: store.connected) { await store.loadProfiles([store.me]) }
    }
}

/// Settings (PRD-ui F-UI-16).
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row("隐私", id: "settings-privacy") { model.push(.privacy) }
                row("黑名单", id: "settings-blocks", detail: store.blocks.isEmpty ? nil : String(store.blocks.count)) {
                    model.push(.blocks)
                }
                row("外观", id: "settings-appearance") { model.push(.appearance) }
                VStack(alignment: .leading, spacing: TS.s1) {
                    Text("关于天听").font(TTFont.body).foregroundStyle(TC.textPrimary)
                    Text(verbatim: "版本 \(model.config.version)（构建 \(model.config.build)）")
                        .font(TTFont.small)
                        .foregroundStyle(TC.textSecondary)
                        .accessibilityIdentifier("app-version")
                    Text("图标：Lucide（ISC 许可）").font(TTFont.small).foregroundStyle(TC.textSecondary)
                }
                .padding(TS.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TC.surface)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("about")
                TC.divider.frame(height: 1)
                RowButton(id: "logout", action: confirmLogout) {
                    Text("退出登录").font(TTFont.body).foregroundStyle(TC.danger)
                    Spacer()
                }
            }
        }
        .background(TC.bg)
        .ttNavigationBar("设置")
    }

    private func row(_ title: String, id: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        RowButton(id: id, action: action) {
            Text(title).font(TTFont.body).foregroundStyle(TC.textPrimary)
            Spacer()
            if let detail {
                Text(detail).font(TTFont.small).foregroundStyle(TC.textSecondary)
            }
            Icon(name: .forward, size: 16).foregroundStyle(TC.textTertiary)
        }
    }

    private func confirmLogout() {
        let pending = store.pendingCount
        let text = pending > 0 ? "有 \(pending) 条消息未发送，退出后将丢失" : "确定退出登录？"
        let model = model
        model.hub.confirm(id: "logout-dialog", text: text, ok: "退出", danger: true) {
            model.logout()
        }
    }
}

/// Blocked users (PRD-ui F-UI-29); the SDK's list is newest first.
struct BlocksPage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var busy: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.blocks.isEmpty {
                    EmptyStateView(text: "黑名单为空", id: "blocks-empty")
                } else {
                    ForEach(store.blocks, id: \.userId) { b in
                        HStack(spacing: TS.s2) {
                            Button {
                                model.push(.user(b.userId, UserContext(source: .card)))
                            } label: {
                                HStack(spacing: TS.s3) {
                                    Avatar(id: b.userId, name: b.displayName, size: 40, src: b.item.profile?.avatar)
                                    Text(b.displayName).font(TTFont.body).foregroundStyle(TC.textPrimary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowPressStyle())
                            .accessibilityIdentifier("block-row")
                            Button("移出") { unblock(b.userId) }
                                .buttonStyle(TTButtonStyle(kind: .secondary, small: true))
                                .disabled(busy == b.userId)
                                .fixedSize()
                                .accessibilityIdentifier("block-remove")
                        }
                        .padding(.horizontal, TS.s4)
                        .padding(.vertical, TS.s2)
                        .background(TC.surface)
                        .overlay(alignment: .bottom) { TC.divider.frame(height: 1).padding(.leading, TS.s4) }
                    }
                }
            }
        }
        .accessibilityIdentifier("blocks")
        .background(TC.bg)
        .ttNavigationBar("黑名单")
    }

    private func unblock(_ userId: String) {
        guard busy == nil else { return }
        busy = userId
        Task {
            do {
                try await store.client.unblock(userId)
                model.hub.show("已移出黑名单")
            } catch {
                model.hub.show(errorText(errorCode(error), cmd: "unblock"))
            }
            busy = nil
        }
    }
}

/// Privacy (PRD-ui F-UI-30): the switch is disabled during the request and goes back on failure.
struct PrivacyPage: View {
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    @State private var pending: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TS.s2) {
                RowContainer {
                    Toggle(isOn: Binding(get: { pending ?? store.settings.searchable }, set: toggle)) {
                        Text("允许通过账号搜索到我").font(TTFont.body).foregroundStyle(TC.textPrimary)
                    }
                    .tint(TC.brandFill)
                    .disabled(pending != nil)
                    .accessibilityIdentifier("privacy-switch")
                }
                Text("关闭后，其他人无法通过账号搜索到你；已经是朋友、同在一个群聊或和你聊过天的人仍可以看到你的资料")
                    .font(TTFont.small)
                    .foregroundStyle(TC.textSecondary)
                    .padding(.horizontal, TS.s4)
            }
        }
        .background(TC.bg)
        .ttNavigationBar("隐私")
    }

    private func toggle(_ next: Bool) {
        pending = next
        Task {
            do {
                try await store.client.setSearchable(next)
            } catch {
                model.hub.show(errorText(errorCode(error), cmd: "setPrivacy"))
            }
            pending = nil
        }
    }
}

/// Appearance (PRD-ui F-UI-16, F-UI-22).
struct AppearancePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(ThemePref.allCases, id: \.self) { pref in
                    RowButton(id: "appearance-\(pref.rawValue)", action: { model.theme.set(pref) }) {
                        Text(pref.label).font(TTFont.body).foregroundStyle(TC.textPrimary)
                        Spacer()
                        if model.theme.pref == pref {
                            Image(systemName: "checkmark").foregroundStyle(TC.brand)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityAddTraits(model.theme.pref == pref ? .isSelected : [])
                }
            }
        }
        .background(TC.bg)
        .ttNavigationBar("外观")
    }
}
