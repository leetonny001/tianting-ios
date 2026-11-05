import SwiftUI
import TiantingIM

/// Avatars (PRD-ui F-UI-21): round for users, rounded square for groups. Images load only from https; anything else, or a
/// failed load, keeps the placeholder.
struct Avatar: View {
    let id: String
    let name: String
    let size: CGFloat
    var group = false
    var src: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: group ? TR.group : size / 2, style: .continuous)
        ZStack {
            shape.fill(Tokens.avatar[avatarColorIndex(id)])
            Text(avatarInitial(name))
                .font(.system(size: size * 0.42))
                .foregroundStyle(TC.onBrand)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let url = httpsURL(src) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
                .frame(width: size, height: size)
                .clipShape(shape)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// AC-UI-21-4, AC-UI-21-5: https only; "", http and others have no URL at all.
func httpsURL(_ raw: String?) -> URL? {
    guard let raw, raw.lowercased().hasPrefix("https://"), let url = URL(string: raw), url.host != nil else { return nil }
    return url
}

/// The "官方" tag (F-UI-14 rule 6).
struct OfficialTag: View {
    var body: some View {
        Text("官方")
            .font(TTFont.caption)
            .foregroundStyle(TC.brand)
            .padding(.horizontal, TS.s1)
            .background(TC.surfaceSelected, in: RoundedRectangle(cornerRadius: TR.sm))
            .fixedSize()
            .accessibilityIdentifier("official")
    }
}

/// A red count badge.
struct CountBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TTFont.caption)
            .foregroundStyle(TC.onBadge)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(TC.badgeBg, in: Capsule())
            .fixedSize()
    }
}
