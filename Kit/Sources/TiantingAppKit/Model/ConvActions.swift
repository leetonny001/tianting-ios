import Foundation
import TiantingIM

/// The conversation menu's actions (PRD-chat C5, FE-685). The SDK changes the list optimistically and rolls back on any
/// failure; the page only says why, never retries (frontend-chat 56).
extension AppModel {
    public func toggleConvPinned(_ conv: Conversation) async {
        guard let client = store?.client else { return }
        do {
            try await client.setConvPinned(conv.convId, !conv.isPinned)
        } catch {
            hub.show(convActionErrorText(error, cmd: "convSet"))
        }
    }

    public func toggleConvNotifyOff(_ conv: Conversation) async {
        guard let client = store?.client else { return }
        do {
            try await client.setConvNotifyOff(conv.convId, !conv.isNotifyOff)
        } catch {
            hub.show(convActionErrorText(error, cmd: "convSet"))
        }
    }

    /// "删除" asks first (F-CVS-03 rule 7); "取消" changes nothing (AC-CVS-03-8).
    public func askDeleteConv(_ convId: String) {
        deletingConv = convId
        hub.confirm(id: "conv-delete-dialog", text: convDeleteConfirmText, ok: "删除", danger: true) { [weak self] in
            guard let self else { return }
            self.deletingConv = nil
            Task { await self.deleteConv(convId) }
        }
    }

    /// After the confirmation. On success the SDK has purged messages (memory, local database, cached files), dropped
    /// failed and queued messages and cancelled uploads (frontend-chat 59), then `.convDeleted` drops the draft. On failure
    /// the conversation comes back as it was, draft included.
    public func deleteConv(_ convId: String) async {
        guard let client = store?.client else { return }
        do {
            try await client.deleteConv(convId)
        } catch {
            hub.show(convActionErrorText(error, cmd: "convDelete"))
        }
    }

    /// `.convDeleted`, mine or from another device: the draft goes (frontend-chat 55), and a confirmation still open for
    /// this conversation closes.
    func convDeleted(_ convId: String) {
        drafts.remove(convId)
        if deletingConv == convId, hub.dialog?.id == "conv-delete-dialog" {
            deletingConv = nil
            hub.dismissDialog()
        }
    }
}
