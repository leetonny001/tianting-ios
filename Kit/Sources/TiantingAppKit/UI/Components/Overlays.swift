import SwiftUI
import TiantingIM

/// The connection bar (F-UI-17, F-CONN-02): shown by the SDK's `banner` event after its delay; pushes content down.
struct ConnBanner: View {
    @Environment(IMStore.self) private var store
    @Environment(AppModel.self) private var model

    var body: some View {
        if store.banner {
            HStack(spacing: TS.s2) {
                if model.online {
                    Spinner()
                    Text("连接中…")
                } else {
                    Icon(name: .failed, size: 16)
                    Text("网络不可用")
                }
            }
            .font(TTFont.small)
            .foregroundStyle(TC.warningText)
            .frame(maxWidth: .infinity, minHeight: Tokens.Size.banner)
            .background(TC.warningBg)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conn-banner")
        }
    }
}

/// The root dialog layer. Centered (container width − 48) or at the bottom (`sheet`); tapping the scrim dismisses.
struct DialogLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let dialog = model.hub.dialog {
            ZStack(alignment: dialog.sheet ? .bottom : .center) {
                TC.scrim
                    .ignoresSafeArea()
                    .accessibilityIdentifier("\(dialog.id)-scrim")
                    .accessibilityLabel("关闭")
                    .accessibilityAddTraits(.isButton)
                    .onTapGesture {
                        if dialog.dismissible { model.hub.dismissDialog() }
                    }
                ScrollView {
                    dialog.content
                        .padding(TS.s4)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
                .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.lg))
                .padding(.horizontal, dialog.sheet ? TS.s2 : TS.s5)
                .padding(.bottom, dialog.sheet ? TS.s2 : 0)
                .padding(.vertical, dialog.sheet ? 0 : TS.s5)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(dialog.id)
                .accessibilityAddTraits(.isModal)
            }
            .id(dialog.id)
        }
    }
}

struct ConfirmDialog: View {
    let text: String
    let ok: String
    var danger = false
    var cancel = "取消"
    let onOk: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: TS.s4) {
            Text(text)
                .font(TTFont.body)
                .foregroundStyle(TC.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dialog-text")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: TS.s3) { buttons }
                VStack(spacing: TS.s2) { buttons }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button {
            model.hub.dismissDialog()
        } label: {
            Text(cancel).frame(maxWidth: .infinity)
        }
        .buttonStyle(TTButtonStyle(kind: .secondary))
        .accessibilityIdentifier("dialog-cancel")
        Button {
            model.hub.dismissDialog()
            onOk()
        } label: {
            Text(ok).frame(maxWidth: .infinity)
        }
        .buttonStyle(TTButtonStyle(kind: danger ? .danger : .primary))
        .accessibilityIdentifier("dialog-ok")
    }
}

/// The toast layer (F-UI-19): above the input area, inside the keyboard-safe region.
struct ToastLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer()
            if let toast = model.hub.toast {
                Text(toast.text)
                    .font(TTFont.small)
                    .foregroundStyle(TC.onBrand)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, TS.s4)
                    .padding(.vertical, TS.s2)
                    .background(TC.textSecondary, in: RoundedRectangle(cornerRadius: TR.md))
                    .padding(.horizontal, TS.s5)
                    .padding(.bottom, 72)
                    .id(toast.id)
                    .accessibilityIdentifier("toast")
            }
        }
        .allowsHitTesting(false)
        .onChange(of: model.hub.toast?.id) { _, id in
            if id != nil, let text = model.hub.toast?.text {
                UIAccessibility.post(notification: .announcement, argument: text)
            }
        }
    }
}

/// The kicked dialog (F-UI-18, AC-UI-18-1): presented full-screen over everything so no back gesture reaches the page
/// below, and `interactiveDismissDisabled` so it cannot be swiped away. Only "确定" closes it.
struct KickedDialog: View {
    let reason: FatalReason
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            TC.scrim.ignoresSafeArea()
            ScrollView {
                VStack(spacing: TS.s4) {
                    Text(fatalText(reason))
                        .font(TTFont.body)
                        .foregroundStyle(TC.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("kicked-text")
                    BlockButton(title: "确定", id: "kicked-ok") {
                        model.logout(keepNoticeSeen: true)
                    }
                }
                .padding(TS.s4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.lg))
            .padding(TS.s5)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kicked-dialog")
        }
        .interactiveDismissDisabled()
        .presentationBackground(.clear)
    }
}
