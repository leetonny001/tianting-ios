import SwiftUI

/// Primary, secondary and danger buttons (PRD-ui 6.1); at least 44 tall (`size.touch.min`), text wraps at large sizes.
struct TTButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, danger
    }

    var kind: Kind = .primary
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? TTFont.small : TTFont.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? TS.s3 : TS.s4)
            .padding(.vertical, TS.s2)
            .frame(minHeight: Tokens.Size.touchMin)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: TR.md))
            .overlay {
                if kind != .primary {
                    RoundedRectangle(cornerRadius: TR.md).stroke(TC.borderInput, lineWidth: 1)
                }
            }
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return TC.onBrand
        case .secondary: return TC.textPrimary
        case .danger: return TC.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? TC.brandFillPressed : TC.brandFill
        default: return pressed ? TC.bg : TC.surface
        }
    }
}

/// A full-width form button.
struct BlockButton: View {
    let title: String
    var kind: TTButtonStyle.Kind = .primary
    var id: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(TTButtonStyle(kind: kind))
        .optionalIdentifier(id)
    }
}

/// A list row: at least 52 tall, background `surface`, bottom divider.
struct RowContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: TS.s3) { content() }
                .padding(.horizontal, TS.s4)
                .padding(.vertical, TS.s2)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            TC.divider.frame(height: 1).padding(.leading, TS.s4)
        }
        .background(TC.surface)
    }
}

/// A tappable row.
struct RowButton<Content: View>: View {
    var id: String?
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            RowContainer(content: content).contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .optionalIdentifier(id)
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Bordered single-line input, 16pt or larger (F-UI-03 rule 9).
struct TTTextField: View {
    let placeholder: String
    @Binding var text: String
    var id: String?
    var autocapitalize = false
    /// Account ids are ASCII; a pinyin keyboard would turn them into candidates.
    var ascii = false
    var submit: SubmitLabel = .done
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(TC.textTertiary))
            .font(TTFont.body)
            .foregroundStyle(TC.textPrimary)
            .keyboardType(ascii ? .asciiCapable : .default)
            .textInputAutocapitalization(autocapitalize ? .sentences : .never)
            .autocorrectionDisabled(!autocapitalize)
            .submitLabel(submit)
            .onSubmit(onSubmit)
            .padding(.horizontal, TS.s3)
            .padding(.vertical, TS.s2)
            .frame(minHeight: Tokens.Size.touchMin)
            .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.md))
            .overlay(RoundedRectangle(cornerRadius: TR.md).stroke(TC.borderInput, lineWidth: 1))
            .accessibilityLabel(placeholder)
            .optionalIdentifier(id)
    }
}

/// Bordered multi-line input.
struct TTTextEditor: View {
    @Binding var text: String
    var id: String?
    var minHeight: CGFloat = 96
    var label = ""

    var body: some View {
        TextEditor(text: $text)
            .font(TTFont.body)
            .foregroundStyle(TC.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(TS.s1)
            .frame(minHeight: minHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.md))
            .overlay(RoundedRectangle(cornerRadius: TR.md).stroke(TC.borderInput, lineWidth: 1))
            .accessibilityLabel(label)
            .optionalIdentifier(id)
    }
}

/// A section's red hint under an input.
struct FieldError: View {
    let text: String
    var id: String?

    var body: some View {
        Text(text)
            .font(TTFont.small)
            .foregroundStyle(TC.danger)
            .optionalIdentifier(id)
    }
}

/// Empty states (F-UI-20).
struct EmptyStateView<Actions: View>: View {
    let text: String
    var id: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: TS.s4) {
            Text(text)
                .font(TTFont.body)
                .foregroundStyle(TC.textSecondary)
                .multilineTextAlignment(.center)
                .optionalIdentifier(id)
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(TS.s6)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(text: String, id: String? = nil) {
        self.init(text: text, id: id) { EmptyView() }
    }
}

/// Skeletons (F-UI-20): 6 placeholder rows.
struct RowsSkeleton: View {
    let id: String
    var avatar: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: TS.s3) {
                    Circle().fill(TC.divider).frame(width: avatar, height: avatar)
                    VStack(alignment: .leading, spacing: TS.s2) {
                        RoundedRectangle(cornerRadius: TR.sm).fill(TC.divider).frame(width: 120, height: 12)
                        RoundedRectangle(cornerRadius: TR.sm).fill(TC.divider).frame(height: 10)
                    }
                }
                .padding(.horizontal, TS.s4)
                .padding(.vertical, TS.s3)
            }
        }
        .background(TC.surface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加载中")
        .accessibilityIdentifier(id)
    }
}

extension View {
    @ViewBuilder
    func optionalIdentifier(_ id: String?) -> some View {
        if let id {
            accessibilityIdentifier(id)
        } else {
            self
        }
    }

    /// Top bar colors (PRD-ui 6.1); height and back behavior are the system's (PRD-ui 3.5 rule 2).
    func ttNavigationBar(_ title: String = "") -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TC.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// Shrinks to its content, up to `maxWidth`, unlike `.frame(maxWidth:)` which takes all it can get (F-UI-07 rule 5).
struct MaxWidth: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        return s.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? width, width), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
