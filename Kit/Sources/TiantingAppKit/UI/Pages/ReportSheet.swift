import SwiftUI
import TiantingIM

extension AppModel {
    /// Opens the report sheet (PRD-chat F-MOD-03 rule 8, FE-695): a bottom sheet of the root dialog layer, like the app's
    /// other sheets. The entries decide whether it shows at all (`moderationEnabled`, SDK `canReport`).
    func presentReport(_ request: ReportRequest) {
        let form = ReportForm(request)
        hub.present(id: "report-sheet", sheet: true) { ReportSheet(form: form) }
    }
}

/// The report sheet: the six reasons (none preselected), an optional note counted in code points (at most 200; typing
/// stops there, a longer paste is cut with a hint), "所选内容将提交给平台审核", "提交" and "取消". While submitting the button
/// says "提交中…", nothing can be changed and the sheet cannot be closed. Success: "已提交，感谢你的反馈", then for a c2c
/// message or a user not yet blocked "要把对方加入黑名单吗？" (a failed block has its own toast; the report stands).
/// 4040, 4030 and 4292 toast and close; anything else toasts and keeps what was filled in for a manual retry.
struct ReportSheet: View {
    let form: ReportForm
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store
    /// The note field has the keyboard; picking a reason or submitting puts it away.
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: TS.s3) {
            HStack(spacing: TS.s2) {
                Icon(name: .report, size: 20).foregroundStyle(TC.textPrimary)
                Text("举报").font(TTFont.title).foregroundStyle(TC.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("report-title")
            Text("请选择举报理由").font(TTFont.small).foregroundStyle(TC.textSecondary)
            VStack(spacing: 0) {
                ForEach(reportReasons, id: \.reason.rawValue) { item in
                    reasonRow(item.reason, item.title)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("report-reasons")
            Text("补充说明（可选）").font(TTFont.small).foregroundStyle(TC.textSecondary)
            TTTextEditor(
                text: Binding(get: { form.note }, set: { form.editNote($0) }), id: "report-note", minHeight: 72,
                label: "补充说明（可选）"
            )
            .focused($noteFocused)
            .disabled(form.busy)
            HStack {
                if form.clipped {
                    FieldError(text: reportNoteClippedText, id: "report-clipped")
                }
                Spacer(minLength: TS.s2)
                Text(verbatim: "\(form.noteCount)/\(reportNoteMax)")
                    .font(TTFont.caption)
                    .foregroundStyle(TC.textTertiary)
                    .accessibilityLabel("已输入 \(form.noteCount) 个字，最多 \(reportNoteMax) 个")
                    .accessibilityIdentifier("report-count")
            }
            Text(reportHintText)
                .font(TTFont.small)
                .foregroundStyle(TC.textSecondary)
                .accessibilityIdentifier("report-hint")
            HStack(spacing: TS.s3) {
                Button {
                    model.hub.dismissDialog()
                } label: {
                    Text("取消").frame(maxWidth: .infinity)
                }
                .buttonStyle(TTButtonStyle(kind: .secondary))
                .disabled(form.busy)
                .accessibilityIdentifier("report-cancel")
                Button {
                    submit()
                } label: {
                    Text(form.busy ? "提交中…" : "提交").frame(maxWidth: .infinity)
                }
                .buttonStyle(TTButtonStyle())
                .disabled(!form.canSubmit)
                .accessibilityIdentifier("report-submit")
            }
        }
        .onChange(of: form.busy) { _, busy in model.hub.lockDialog(busy) }
    }

    private func reasonRow(_ reason: ReportReason, _ title: String) -> some View {
        let selected = form.reason == reason
        return Button {
            noteFocused = false
            form.reason = reason
        } label: {
            HStack(spacing: TS.s3) {
                // A radio mark drawn with shapes (no SF Symbol, PRD-ui B-3); colors are tokens.
                ZStack {
                    Circle().stroke(selected ? TC.brand : TC.textTertiary, lineWidth: 2)
                    if selected { Circle().fill(TC.brand).padding(5) }
                }
                .frame(width: 20, height: 20)
                Text(title).font(TTFont.body).foregroundStyle(TC.textPrimary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: Tokens.Size.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("report-reason-\(reason.rawValue)")
        .disabled(form.busy)  // After the element is made, so VoiceOver reads it as dimmed too.
    }

    private func submit() {
        noteFocused = false
        let hub = model.hub
        let client = store.client
        let store = store
        let form = form
        Task {
            switch await form.submit(client, isBlocked: { id in store.blocks.contains { $0.userId == id } }) {
            case .ignored:
                return
            case .done(let ask):
                hub.show(reportDoneText)
                if let ask {
                    hub.present(id: "report-block-dialog") {
                        ConfirmDialog(text: reportAskBlockText + "\n" + blockExplainText, ok: "加入黑名单") {
                            Task {
                                do {
                                    try await client.block(ask)
                                } catch {
                                    hub.show(errorText(errorCode(error), cmd: "block"))
                                }
                            }
                        }
                    }
                } else if hub.dialog?.id == "report-sheet" {
                    hub.dismissDialog()
                }
            case .failed(let text, let close):
                hub.show(text)
                if close, hub.dialog?.id == "report-sheet" { hub.dismissDialog() }
            }
        }
    }
}
