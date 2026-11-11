import SwiftUI

/// Lucide icons (PRD-ui 6.6, ISC): template images tinted by foreground color. scripts/py/gen_icons.py makes the assets.
enum IconName: String {
    case chats, contacts, me, plus, addFriend, forward, more, failed, loading, smile, users, newFriends, groups, settings
    case image, file, close, notifyOff, report
}

struct Icon: View {
    let name: IconName
    var size: CGFloat = 24

    var body: some View {
        Image("icon-\(name.rawValue)", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The "sending" spinner.
struct Spinner: View {
    var size: CGFloat = 16
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Icon(name: .loading, size: size)
            .rotationEffect(.degrees(on ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}
