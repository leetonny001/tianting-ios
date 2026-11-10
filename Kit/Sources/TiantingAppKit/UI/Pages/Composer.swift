import SwiftUI
import TiantingIM
import UIKit

/// Lets the page insert text at the caret of the UIKit text view.
@MainActor
final class ComposerHandle {
    weak var textView: UITextView?

    /// An emoji at the caret: it goes through the same edit model as typing, so @ ranges after it move along.
    func insert(_ emoji: String, edit: inout EditState) {
        let range = textView?.selectedRange ?? NSRange(location: edit.selStart, length: edit.selEnd - edit.selStart)
        let result = insertText(emoji, into: edit.text, range: range)
        edit = applyEdit(
            edit, text: result.text, selStart: result.caret.location, selEnd: result.caret.location, composing: false,
            canMention: false
        ).state
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
///
/// @ (PRD-chat F-MEN-01 rule 5, `applyEdit` in Core/Mentions.swift): every change goes through the edit model. While
/// `markedTextRange` is set (composing) neither the ranges change nor the picker opens; the committed text is compared with
/// the text before the composition once. The caret cannot rest inside a mention; one backspace right after one removes it.
struct ComposerTextView: UIViewRepresentable {
    @Binding var edit: EditState
    let handle: ComposerHandle
    var maxLines = 5
    var canMention = false
    let onReturn: () -> Void
    let onBeginEditing: () -> Void
    var onMention: (Int) -> Void = { _ in }

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
        context.coordinator.push(edit, to: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        // The page changed the text (sent, draft, a picked mention, an emoji): show it with its caret. Never while
        // composing, which would drop the marked text.
        if view.text != edit.text, view.markedTextRange == nil { context.coordinator.push(edit, to: view) }
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
        /// Set while this side writes into the view: the delegate calls that causes are not edits.
        private var pushing = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func push(_ edit: EditState, to view: UITextView) {
            pushing = true
            defer { pushing = false }
            if view.text != edit.text { view.text = edit.text }
            let length = (view.text as NSString).length
            let start = max(0, min(edit.selStart, length))
            let end = max(start, min(edit.selEnd, length))
            let range = NSRange(location: start, length: end - start)
            if view.selectedRange != range { view.selectedRange = range }
        }

        func textViewDidChange(_ view: UITextView) {
            guard !pushing else { return }
            let sel = view.selectedRange
            let composing = view.markedTextRange != nil
            let r = applyEdit(
                parent.edit, text: view.text, selStart: sel.location, selEnd: sel.location + sel.length,
                composing: composing, canMention: parent.canMention)
            if !composing { push(r.state, to: view) }
            parent.edit = r.state
            if let at = r.trigger { parent.onMention(at) }
        }

        /// A caret moved into a mention goes to its end (or its start, coming from behind).
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !pushing, view.markedTextRange == nil, parent.edit.composeBase == nil, view.text == parent.edit.text
            else { return }
            let sel = view.selectedRange
            var start = sel.location
            var end = sel.location + sel.length
            if start == end {
                let c = clampCaret(start, parent.edit.ranges, prev: parent.edit.selStart)
                if c != start {
                    start = c
                    end = c
                    pushing = true
                    view.selectedRange = NSRange(location: c, length: 0)
                    pushing = false
                }
            }
            if start != parent.edit.selStart || end != parent.edit.selEnd {
                var next = parent.edit
                next.selStart = start
                next.selEnd = end
                parent.edit = next
            }
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
    @Binding var edit: EditState
    @Binding var emojiOpen: Bool
    @Binding var plusOpen: Bool
    let handle: ComposerHandle
    var showPlus = false
    var canMention = false
    /// The quote bar's text (nil: no bar).
    var quoteText: String?
    var onQuoteCancel: () -> Void = {}
    var onMention: (Int) -> Void = { _ in }
    let onSend: () -> Void
    var onPick: (PickKind) -> Void = { _ in }

    private var text: String { edit.text }
    private var over: Int { overLimitCount(text) }
    private var disabled: Bool { trimText(text).isEmpty || over > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TC.divider.frame(height: 1)
            if let quoteText { QuoteBar(text: quoteText, onCancel: onQuoteCancel) }
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
                    edit: $edit, handle: handle, canMention: canMention,
                    onReturn: { if !disabled { onSend() } },
                    onBeginEditing: {
                        emojiOpen = false
                        plusOpen = false
                    },
                    onMention: onMention
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
            if emojiOpen { EmojiPanel { handle.insert($0, edit: &edit) } }
            if plusOpen, showPlus { AttachPanel(onPick: onPick) }
        }
        .background(TC.surface.ignoresSafeArea(edges: .bottom))
    }
}

/// The quote bar above the input (F-QUO-01, F-QUO-02 rule 3; 13.4 "引用条": normal, recalled, deleted, expired). Plain
/// text (AC-QUO-02-5); "取消引用" uses the existing close icon (PRD-ui 6.6).
private struct QuoteBar: View {
    let text: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: TS.s2) {
            TC.brand.frame(width: 3, height: 32)
            Text(verbatim: text)
                .font(TTFont.small)
                .foregroundStyle(TC.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("引用：\(text)")
                .accessibilityIdentifier("quote-bar-text")
            Button(action: onCancel) {
                Icon(name: .close, size: 20)
                    .foregroundStyle(TC.textSecondary)
                    .frame(width: Tokens.Size.touchMin, height: Tokens.Size.touchMin)
            }
            .accessibilityLabel("取消引用")
            .accessibilityIdentifier("quote-cancel")
        }
        .padding(.leading, TS.s1)
        .background(TC.bg, in: RoundedRectangle(cornerRadius: TR.sm))
        .padding(.horizontal, TS.s3)
        .padding(.top, TS.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quote-bar")
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
