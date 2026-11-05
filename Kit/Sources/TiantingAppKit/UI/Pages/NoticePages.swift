import SwiftUI
import TiantingIM

/// Me → system notices (PRD-ui F-UI-44, PRD-live F-PUSH-12): newest `ts` first, at most 100. Opening clears the count and
/// nothing is counted while it stays open. The list is in memory only, which the footer says (rule 6, AC-PUSH-12-9).
struct NoticesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.notices?.list ?? []
        ScrollView {
            LazyVStack(spacing: TS.s2) {
                if list.isEmpty {
                    EmptyStateView(text: "暂无系统通知", id: "notices-empty") { EmptyView() }
                } else {
                    ForEach(list) { NoticeRow(notice: $0) }
                }
                Text("只显示本次打开以来收到的通知")
                    .font(TTFont.small)
                    .foregroundStyle(TC.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(TS.s4)
                    .accessibilityIdentifier("notices-footer")
            }
            .padding(.top, TS.s2)
        }
        .accessibilityIdentifier("notices")
        .background(TC.bg)
        .ttNavigationBar("系统通知")
        .onAppear { model.notices?.enterPage() }
        .onDisappear { model.notices?.leavePage() }
    }
}

private struct NoticeRow: View {
    let notice: Notice

    var body: some View {
        VStack(alignment: .leading, spacing: TS.s1) {
            // Verbatim: plain text only, no Markdown or links (NF-UI-12).
            Text(verbatim: notice.text)
                .font(TTFont.body)
                .foregroundStyle(TC.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: formatTime(notice.ts))
                .font(TTFont.caption)
                .foregroundStyle(TC.textSecondary)
        }
        .padding(.horizontal, TS.s4)
        .padding(.vertical, TS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TC.surface)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notice-item")
    }
}

/// The notice banner (F-UI-44 rule 2): top of the container, 5 seconds, a new one replaces the old; only for
/// `replayed=false`. Tapping opens the notices page.
struct NoticeBannerLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let banner = model.notices?.banner
        VStack(spacing: 0) {
            if let banner {
                Button {
                    model.openNotices()
                } label: {
                    Text(verbatim: banner.text)
                        .font(TTFont.small)
                        .foregroundStyle(TC.onBrand)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, TS.s4)
                        .padding(.vertical, TS.s3)
                        .frame(maxWidth: .infinity, minHeight: Tokens.Size.touchMin, alignment: .leading)
                        .background(TC.brandFill)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowPressStyle())
                .id(banner.n)
                .accessibilityIdentifier("notice-banner")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: banner?.n) { _, n in
            if n != nil, let text = model.notices?.banner?.text {
                UIAccessibility.post(notification: .announcement, argument: text)
            }
        }
    }
}
