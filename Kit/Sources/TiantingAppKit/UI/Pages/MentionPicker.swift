import SwiftUI
import TiantingIM

/// The @ member picker (PRD-chat F-MEN-01 rules 4, 6, F-MEN-02 rule 3, 13.4 "@ 选择", issue 39): a bottom sheet with
/// "搜索群成员" (`keyword`, searched after typing stops for 300 ms), loading, no result and failed states (tap to retry;
/// closing it leaves the @ as plain text and sending still works). Rows show the local display name (remark first), the
/// avatar and the userId, so same names can be told apart; the inserted text is the public nickname, else the userId, never
/// the remark (R-CF-03). "所有人" only for the owner and admins (AC-MEN-02-4). I am not in the list (F-MEN-03 rule 6).
struct MentionPicker: View {
    let groupId: String
    let myRole: GroupRole?
    let onPick: (_ name: String, _ userId: String?) -> Void
    let onClose: () -> Void
    @Environment(IMStore.self) private var store
    @State private var members: GroupMembersModel?
    @State private var keyword = ""
    @State private var attempt = 0

    private var canAll: Bool {
        (myRole == .owner || myRole == .admin) && keyword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TS.s3) {
            Text("选择提醒的人")
                .font(TTFont.title)
                .foregroundStyle(TC.textPrimary)
                .accessibilityAddTraits(.isHeader)
            TTTextField(placeholder: "搜索群成员", text: $keyword, id: "mention-search", submit: .search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if canAll {
                        row(id: "mention-all", label: "所有人") {
                            Text("@")
                                .font(TTFont.title)
                                .foregroundStyle(TC.onBrand)
                                .frame(width: 40, height: 40)
                                .background(TC.brandFill, in: Circle())
                        } text: {
                            Text("所有人").font(TTFont.body).foregroundStyle(TC.textPrimary)
                        } action: {
                            onPick("所有人", nil)
                        }
                    }
                    content
                }
            }
            Button {
                onClose()
            } label: {
                Text("取消").frame(maxWidth: .infinity)
            }
            .buttonStyle(TTButtonStyle(kind: .secondary))
            .accessibilityIdentifier("mention-cancel")
        }
        .padding(TS.s4)
        .background(TC.surface.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mention-picker")
        .task(id: "\(keyword)|\(attempt)") {
            let model = members ?? GroupMembersModel(store: store, groupId: groupId)
            members = model
            let k = keyword.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty {
                // 30 searches a minute per user (F-MEN-01 rule 6): search once typing stops.
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            await model.search(k)
        }
    }

    @ViewBuilder private var content: some View {
        if let members {
            let list = members.members.filter { $0.userId != store.me }
            if members.failed {
                Button("加载失败，点击重试") { attempt += 1 }
                    .font(TTFont.small)
                    .foregroundStyle(TC.brand)
                    .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchMin)
                    .accessibilityIdentifier("mention-error")
            } else if !members.loaded {
                state("加载中…", "mention-loading")
            } else if list.isEmpty {
                state("没有找到群成员", "mention-empty")
            } else {
                ForEach(list, id: \.userId) { m in
                    let shown = shownName(m)
                    row(id: "mention-row", label: "\(shown)，\(m.userId)") {
                        Avatar(id: m.userId, name: shown, size: 40, src: m.avatar)
                    } text: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shown).font(TTFont.body).foregroundStyle(TC.textPrimary).lineLimit(1)
                            Text(m.userId).font(TTFont.caption).foregroundStyle(TC.textSecondary).lineLimit(1)
                        }
                    } action: {
                        onPick(m.nickname.isEmpty ? m.userId : m.nickname, m.userId)
                    }
                }
                if members.hasMore {
                    Button("加载更多") { Task { await members.loadMore() } }
                        .font(TTFont.small)
                        .foregroundStyle(TC.brand)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchMin)
                        .accessibilityIdentifier("mention-more")
                }
            }
        } else {
            state("加载中…", "mention-loading")
        }
    }

    /// Remark first (local only, shown here but never sent), then the nickname this page got, then the userId.
    private func shownName(_ m: GroupMemberInfo) -> String {
        let local = store.displayName(m.userId)
        if local == m.userId, !m.nickname.isEmpty { return m.nickname }
        return local
    }

    private func state(_ text: String, _ id: String) -> some View {
        Text(text)
            .font(TTFont.small)
            .foregroundStyle(TC.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchMin)
            .accessibilityIdentifier(id)
    }

    private func row<A: View, T: View>(
        id: String, label: String, @ViewBuilder avatar: () -> A, @ViewBuilder text: () -> T, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: TS.s3) {
                avatar()
                text()
                Spacer(minLength: 0)
            }
            .frame(minHeight: Tokens.Size.touchMin + TS.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }
}
