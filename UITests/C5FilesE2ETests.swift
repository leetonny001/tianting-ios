import TiantingIM
import XCTest

/// FE-685 with cached images: deleting a conversation clears its draft, failed message and cached files (AC-CVS-03-8), and
/// a deletion from another device while this one was not running leaves nothing on disk after the next start
/// (AC-CVS-03-10, the page part; the SDK part is FE-682). The real im-server and scripts/fake_s3.py.
@MainActor
final class C5FilesE2ETests: FilesCase {
    /// Bytes after a JPEG's end marker are ignored by decoders but stay in the cached file: what the byte scan looks for.
    private func markedJpeg(_ marker: String) -> Data {
        jpeg(240, 180, color: (60, 140, 90)) + Data(marker.utf8)
    }

    private func deleteFromMenu(_ name: String) async throws {
        try await convAction(listRow(name), "删除")
        try await see("conv-delete-dialog")
    }

    /// TC-CVS-03-08 (iOS): a conversation with a draft, a failed message and a cached image holding the marker. "删除"
    /// asks "删除后聊天记录不再显示，确定删除？"; "取消" keeps everything; confirmed, the row goes, the data directory no longer
    /// holds the marker, and the chat opened again from "发起单聊" is empty with no draft.
    func testTC_CVS_03_08_deleteCancelKeepsConfirmClearsDraftFailedAndCache() async throws {
        let me = uid("xa"), you = uid("xb")
        try await importUsers([me], nicknames: [me: "甲"])
        let marker = "ZXQ-CVS-2-\(uid("k"))"
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        try await peerSendsImage(
            peer, conv, original: markedJpeg(marker + "-o"), width: 240, height: 180, thumb: markedJpeg(marker + "-t"))
        try await say(peer, conv, marker + "-text")
        try await launchFiles(me, env: ["TT_TEST_SCAN": marker])
        try await tapElement(listRow(you))
        try await until("image loaded", timeout: 15) { self.value(self.imageBubbles.firstMatch).hasSuffix("loaded") }
        // A failed message: the peer refuses me for a moment (4036).
        try await peer.block(me)
        try await send(marker + "-failed")
        try await until("failed") { (self.message(marker + "-failed").value as? String) == "发送失败" }
        try await peer.unblock(me)
        try await typeInComposer("草稿-甲")
        try await back()
        try await until("draft in the row") { self.listRow(you).label.contains("[草稿] 草稿-甲") }
        try await until("on disk", timeout: 15) { self.probeInt("scan") > 0 }

        try await deleteFromMenu(you)
        XCTAssertEqual(label("dialog-text"), "删除后聊天记录不再显示，确定删除？")
        try await tap("dialog-cancel")
        try await gone(el("conv-delete-dialog"))
        try await sleep(1000)
        XCTAssertTrue(listRow(you).label.contains("[草稿] 草稿-甲"), "cancel changes nothing")
        try await tapElement(listRow(you))
        try await see(message(marker + "-failed"))
        XCTAssertEqual(message(marker + "-failed").value as? String, "发送失败")
        XCTAssertEqual(imageBubbles.count, 1)
        XCTAssertEqual(composerText(), "草稿-甲")
        try await back()

        try await deleteFromMenu(you)
        try await tap("dialog-ok")
        try await gone(listRow(you))
        try await until("purged from disk", timeout: 20) { self.probeInt("scan") == 0 }
        try await startChat(with: you)
        try await sleep(1500)
        XCTAssertEqual(all("message").count, 0)
        XCTAssertEqual(imageBubbles.count, 0)
        XCTAssertEqual(composerText(), "", "no draft")
        XCTAssertFalse(el("permission-tip").exists, "the failed message's tip went with it")
        XCTAssertEqual(probeInt("scan"), 0)
    }

    /// TC-CVS-03-10 (iOS page part): the app is not running while my other device deletes the conversation and the peer
    /// sends a new message; at the next start only the new one shows and the data directory (local database with its
    /// -wal, the file cache) no longer holds the old text or image; again after a second cold start.
    func testTC_CVS_03_10_coldStartOnlyNewNothingOldOnDisk() async throws {
        let me = uid("ya"), you = uid("yb")
        try await importUsers([me], nicknames: [me: "甲"])
        let marker = "ZXQ-CVS-1-\(uid("k"))"
        let bob = try await filesPeer(you)
        let conv = c2c(me, you)
        try await say(bob, conv, marker + "-text")
        try await peerSendsImage(
            bob, conv, original: markedJpeg(marker + "-o"), width: 240, height: 180, thumb: markedJpeg(marker + "-t"))
        try await launchFiles(me, env: ["TT_TEST_SCAN": marker])
        try await tapElement(listRow(you))
        try await see(message(marker + "-text"))
        try await until("image loaded", timeout: 15) { self.value(self.imageBubbles.firstMatch).hasSuffix("loaded") }
        try await until("on disk", timeout: 15) { self.probeInt("scan") > 0 }
        app.terminate()

        let other = try await peer(me)
        try await until("other device has it", timeout: 10) { self.peerConv(other, conv) != nil }
        try await other.deleteConv(conv)
        try await say(bob, conv, "新的一条")

        try await launchFiles(me, reset: false, env: ["TT_TEST_SCAN": marker])
        try await see(self.conv("新的一条"), timeout: 15)
        try await until("purged from disk", timeout: 20) { self.probeInt("scan") == 0 }
        try await tapElement(listRow(you))
        try await see(message("新的一条"))
        try await sleep(1500)
        XCTAssertEqual(all("message").count, 1)
        XCTAssertEqual(imageBubbles.count, 0)

        app.terminate()
        try await launchFiles(me, reset: false, env: ["TT_TEST_SCAN": marker])
        try await tapElement(listRow(you))
        try await see(message("新的一条"))
        try await sleep(1500)
        XCTAssertEqual(all("message").count, 1, "still only the new one after a cold start")
        try await until("scanned", timeout: 5) { self.probeInt("scan") >= 0 }
        XCTAssertEqual(probeInt("scan"), 0)
    }
}
