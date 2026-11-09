import SwiftUI
import TiantingIM
import UIKit

/// Lets the page insert text at the caret of the UIKit text view.
@MainActor
final class ComposerHandle {
    weak var textView: UITextView?

    func insert(_ emoji: String, text: inout String) {
        let range = textView?.selectedRange ?? NSRange(location: (text as NSString).length, length: 0)
        let result = insertText(emoji, into: text, range: range)
        text = result.text
        textView?.text = result.text
        textView?.selectedRange = result.caret
    }

    func focus() {
        textView?.becomeFirstResponder()
    }

    func blur() {
        textView?.resignFirstResponder()
    }
}

/// A UIKit text view because SwiftUI's vertical TextField cannot tell a return key from a typed newline nor expose the
/// caret. Return sends only outside IME composition: while `markedTextRange` is set the system just commits the candidate
/// and no "\n" arrives (F-UI-10 rule 6, AC-UI-10-2, AC-UI-10-7).
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let handle: ComposerHandle
    var maxLines = 5
    let onReturn: () -> Void
    let onBeginEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = UIColor(TC.textPrimary)
        view.tintColor = UIColor(TC.brand)
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = false
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.isScrollEnabled = true
        view.accessibilityIdentifier = "composer-input"
        view.accessibilityLabel = "输入消息"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handle.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
        handle.textView = view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let line = uiView.font?.lineHeight ?? 22
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let height = min(fit.height, line * CGFloat(maxLines) + insets)
        return CGSize(width: width, height: ceil(max(height, line + insets)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            parent.onBeginEditing()
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", view.markedTextRange == nil {
                parent.onReturn()
                return false
            }
            return true
        }
    }
}

/// The input area (PRD-ui F-UI-10, F-UI-11): emoji button, input growing to 5 lines, send button. Over 5000 code points it
/// shows "已超出 N 字" and cannot send (C-28). With `features.files` a "+" opens images and files (13.3).
struct Composer: View {
    @Binding var text: String
    @Binding var emojiOpen: Bool
    @Binding var plusOpen: Bool
    let handle: ComposerHandle
    var showPlus = false
    let onSend: () -> Void
    var onPick: (PickKind) -> Void = { _ in }

    private var over: Int { overLimitCount(text) }
    private var disabled: Bool { trimText(text).isEmpty || over > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TC.divider.frame(height: 1)
            HStack(alignment: .bottom, spacing: TS.s2) {
                Button {
                    emojiOpen.toggle()
                    plusOpen = false
                    if emojiOpen { handle.blur() } else { handle.focus() }
                } label: {
                    Icon(name: .smile)
                        .foregroundStyle(TC.textSecondary)
                        .frame(width: Tokens.Size.touchMin, height: Tokens.Size.touchMin)
                }
                .accessibilityLabel("表情")
                .accessibilityIdentifier("emoji-button")
                ComposerTextView(
                    text: $text, handle: handle,
                    onReturn: { if !disabled { onSend() } },
                    onBeginEditing: {
                        emojiOpen = false
                        plusOpen = false
                    }
                )
                .background(TC.bg, in: RoundedRectangle(cornerRadius: TR.md))
                .overlay(RoundedRectangle(cornerRadius: TR.md).stroke(TC.borderInput, lineWidth: 1))
                if showPlus {
                    Button {
                        plusOpen.toggle()
                        emojiOpen = false
                        if plusOpen { handle.blur() }
                    } label: {
                        Icon(name: .plus)
                            .foregroundStyle(TC.textSecondary)
                            .frame(width: Tokens.Size.touchMin, height: Tokens.Size.touchMin)
                    }
                    .accessibilityLabel("发送图片或文件")
                    .accessibilityIdentifier("attach-button")
                }
                Button("发送", action: onSend)
                    .buttonStyle(TTButtonStyle(small: true))
                    .disabled(disabled)
                    .fixedSize()
                    .accessibilityIdentifier("send-button")
            }
            .padding(.horizontal, TS.s2)
            .padding(.vertical, TS.s2)
            if over > 0 {
                FieldError(text: "已超出 \(over) 字", id: "over-limit")
                    .padding(.horizontal, TS.s3)
                    .padding(.bottom, TS.s2)
            }
            if emojiOpen { EmojiPanel { handle.insert($0, text: &text) } }
            if plusOpen, showPlus { AttachPanel(onPick: onPick) }
        }
        .background(TC.surface.ignoresSafeArea(edges: .bottom))
    }
}

private struct EmojiPanel: View {
    let onPick: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Size.touchMin))], spacing: 0) {
                ForEach(emojiList, id: \.self) { e in
                    Button {
                        onPick(e)
                    } label: {
                        Text(e)
                            .font(.title2)
                            .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
                    }
                    .accessibilityIdentifier("emoji-item")
                }
            }
            .padding(.horizontal, TS.s2)
        }
        .frame(height: 240)
        .accessibilityIdentifier("emoji-panel")
    }
}
