import TiantingIM
import XCTest

/// Two accounts, groups, failures: the core of the app against the real server.
final class ChatE2ETests: E2ECase {
    func testTwoAccountsChatBothWays() async throws {
        let (me, bob) = (uid("alice"), uid("bob"))
        let peerBob = try await peer(bob, nickname: "博")
        try await importUsers([me])
        let conv = c2c(me, bob)
        try await launchAndLogin(me)

        try await startChat(with: bob)
        try await send("你好bob")
        try await sent("你好bob")
        // A stranger's title is the account until the conversation brings the nickname (F-UI-33 rule 1).
        try await until("title from the conversation") { self.label("chat-title") == "博" }
        try await until("peer gets it") { peerBob.messages(conv).contains { $0.body.text == "你好bob" } }
        try await staysGone(el("msg-name"))  // Single chats show no names (AC-UI-07-2).

        // Peer answers: it shows while on the page and does not count as unread (AC-UI-06-4).
        _ = try peerBob.send(conv, "你好alice")
        try await see(message("你好alice"))
        try await staysGone(el("tab-badge"))

        // Back on the list: a new message counts; opening clears it (AC-UI-06-4, AC-UI-23-3).
        try await back()
        try await see(self.conv("博"))
        XCTAssertTrue(self.conv("博").label.contains("你好alice"))
        _ = try peerBob.send(conv, "第二条")
        try await see(self.conv("第二条"))
        XCTAssertTrue(self.conv("第二条").label.contains("未读 1"))
        try await see("tab-badge")
        XCTAssertEqual(label("tab-badge"), "1")
        self.conv("第二条").tap()
        try await see(message("第二条"))
        try await back()
        try await gone(el("tab-badge"))
    }

    func testChatInfoPageSetsActiveToNil() async throws {
        // AC-UI-06-7: on the info page a new message counts as unread.
        let (me, bob) = (uid("a"), uid("b"))
        let peerBob = try await peer(bob)
        try await importUsers([me])
        try await launchAndLogin(me)
        try await startChat(with: bob)
        try await send("开始")
        try await sent("开始")
        try await tap("chat-more")
        try await see("info-sub")
        XCTAssertEqual(label("info-sub"), "账号：\(bob)")
        _ = try peerBob.send(c2c(me, bob), "在信息页收到")
        try await until("peer sent") {
            peerBob.messages(c2c(me, bob)).last?.status == .sent
        }
        try await sleep(500)
        try await back()
        try await see(message("在信息页收到"))
        try await back()
        // Back on the chat page it reads again; the unread was seen by coming back.
        try await see(conv("在信息页收到"))
    }

    func testGroupChat() async throws {
        let (me, bob, carol) = (uid("a"), uid("b"), uid("c"))
        let peerBob = try await peer(bob, nickname: "阿博")
        let peerCarol = try await peer(carol)
        let g = try await hostedGroup(name: "周末球局", members: [me, bob, carol])
        try await launchAndLogin(me)

        try await see(conv("周末球局"))
        _ = try peerBob.send(g.convId, "晚上好")
        // AC-UI-04-1: others' messages carry the sender's name; mine do not.
        try await see(conv("阿博: 晚上好"))
        conv("周末球局").tap()
        try await see("chat-title")
        XCTAssertEqual(label("chat-title"), "周末球局（3）")  // AC-UI-06-1
        try await see(message("晚上好"))
        try await see(el("msg-name", labelContains: "阿博"))  // AC-UI-07-2
        try await send("收到")
        try await sent("收到")
        try await until("both get it") {
            peerBob.messages(g.convId).contains { $0.body.text == "收到" }
                && peerCarol.messages(g.convId).contains { $0.body.text == "收到" }
        }
        try await back()
        try await see(conv("收到"))
        XCTAssertFalse(conv("周末球局").label.contains(":"), "my own message has no prefix (AC-UI-04-1)")

        // Member count follows the server while on the page (AC-UI-06-8).
        conv("周末球局").tap()
        try await see("chat-title")
        let dave = uid("d")
        try await importUsers([dave])
        try await admin("POST", "/admin/groups/\(g.groupId)/members", ["members": [dave]])
        try await until("title 4") { self.label("chat-title") == "周末球局（4）" }

        // Tapping an avatar opens the card (AC-UI-07-7).
        try await tap("msg-avatar")
        try await see("user-id")
        try await back()
    }

    func testRemovedDissolvedAndBackInGroup() async throws {
        let (me, bob) = (uid("a"), uid("b"))
        _ = try await peer(bob)
        let g = try await hostedGroup(name: "将被移出", members: [me, bob])
        try await launchAndLogin(me)
        try await see(conv("将被移出"))
        conv("将被移出").tap()
        try await see(composer)

        // AC-UI-33-4
        try await admin("DELETE", "/admin/groups/\(g.groupId)/members", ["members": [me]])
        try await see("chat-blocked-tip", timeout: 3)
        XCTAssertEqual(label("chat-blocked-tip"), "你已不在该群")
        XCTAssertEqual(label("composer-disabled"), "你已不在该群，无法发送消息")
        XCTAssertFalse(composer.exists)
        XCTAssertEqual(label("chat-title"), "将被移出")
        // The info page keeps the name (AC-UI-12-5).
        try await tap("chat-more")
        try await see("info-removed")
        XCTAssertEqual(label("info-removed"), "你已不在该群")
        try await back()

        // AC-UI-33-11: invited back, the composer returns.
        try await admin("POST", "/admin/groups/\(g.groupId)/members", ["members": [me]])
        try await see(composer, timeout: 3)
        try await gone(el("composer-disabled"))
        try await send("又回来了")
        try await sent("又回来了")

        // AC-UI-33-14: dissolved.
        try await signed("DELETE", "/admin/groups/\(g.groupId)")
        try await see("chat-blocked-tip", timeout: 3)
        XCTAssertEqual(label("chat-blocked-tip"), "群聊已解散")
        XCTAssertEqual(label("composer-disabled"), "群聊已解散")
        try await back()
        try await gone(conv("将被移出"))
    }

    func testPermissionTipsAndFailedMessages() async throws {
        // Friends mode: a non-friend gets 4035 from the real server.
        try await setFriendsMode()
        let (me, carol) = (uid("a"), uid("c"))
        _ = try await peer(carol)
        try await importUsers([me])
        try await launchAndLogin(me)

        // AC-UI-05-6: warning before chatting with a non-friend.
        try await tap("plus-button")
        try await tapMenuItem("发起单聊")
        try await type(carol, into: "start-chat-input")
        try await tap("start-chat-submit")
        try await see("start-chat-warning")
        XCTAssertEqual(label("start-chat-warning"), "对方不是你的好友，可能无法发送消息")
        try await tap("start-chat-anyway")
        try await see("chat-title")

        // AC-UI-31-1, AC-UI-31-4: failed with one tip however many fail.
        try await send("一")
        let first = message("一")
        try await see(first)
        try await until("failed") { (first.value as? String) == "发送失败" }
        try await see("permission-tip")
        XCTAssertEqual(label("permission-tip"), "对方开启了好友验证，你还不是他的好友")
        XCTAssertFalse(el("toast").exists, "no toast for 4035")
        try await send("二")
        let second = message("二")
        try await see(second)
        try await until("failed") { (second.value as? String) == "发送失败" }
        try await sleep(300)
        XCTAssertEqual(all("permission-tip").count, 1)
        XCTAssertGreaterThanOrEqual(el("failed-icon").frame.width, 44)  // AC-UI-08-4

        // AC-UI-08-2: "!" asks first; cancel changes nothing.
        all("failed-icon").element(boundBy: 0).tap()
        try await see("retry-dialog")
        XCTAssertEqual(label("dialog-text"), "重发该消息？")
        try await tap("dialog-cancel")
        try await gone(el("retry-dialog"))

        // AC-UI-09-4: the failed menu has copy, resend, delete. AC-UI-09-5: delete removes it.
        second.press(forDuration: 1.0)
        try await tapMenuItem("删除")
        try await gone(second)

        // AC-UI-16-2: logging out warns about the remaining one.
        try await back()
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("logout")
        try await see("logout-dialog")
        XCTAssertEqual(label("dialog-text"), "有 1 条消息未发送，退出后将丢失")
        try await tap("dialog-cancel")
        try await back()
        try await tap("tab-chats")

        // Link to apply with source conv (AC-UI-31-1).
        try await startChatAnyway(carol)
        try await see(first)
        try await see("permission-apply")
        try await tap("permission-apply")
        try await see("apply-send")
    }

    private func startChatAnyway(_ user: String) async throws {
        try await tap("plus-button")
        try await tapMenuItem("发起单聊")
        try await type(user, into: "start-chat-input")
        try await tap("start-chat-submit")
        try await see("start-chat-warning")
        try await tap("start-chat-anyway")
        try await see("chat-title")
    }

    func testBlockedByPeerAndNoToast() async throws {
        // AC-UI-31-2: 4036, message failed, tip, no toast.
        let (me, bob) = (uid("a"), uid("b"))
        let peerBob = try await peer(bob)
        try await importUsers([me])
        try await peerBob.block(me)
        try await launchAndLogin(me)
        try await startChat(with: bob)
        try await send("被拒收")
        let m = message("被拒收")
        try await see(m)
        try await until("failed") { (m.value as? String) == "发送失败" }
        try await see("permission-tip")
        XCTAssertEqual(label("permission-tip"), "消息已发出，但被对方拒收了")
        XCTAssertFalse(el("toast").exists)

        // AC-UI-08-2: "!" then "重发" succeeds once allowed; the tip goes with the failure.
        try await peerBob.unblock(me)
        try await tap("failed-icon")
        try await see("retry-dialog")
        try await tap("dialog-ok")
        try await sent("被拒收")
        try await gone(el("permission-tip"))
        try await gone(el("failed-icon"))
        try await until("one message at the peer") {
            peerBob.messages(self.c2c(me, bob)).filter { $0.body.text == "被拒收" }.count == 1
        }
    }

    func testHistoryPagingAndNewMessagePill() async throws {
        // F-UI-06 rules 5, 6, 7: opens at the bottom, pages older messages in, "↓ N 条新消息" while scrolled up.
        let (me, bob) = (uid("a"), uid("b"))
        let peerBob = try await peer(bob)
        try await importUsers([me])
        let conv = c2c(me, bob)
        for i in 0..<45 {
            _ = try peerBob.send(conv, "历史\(String(format: "%02d", i))")
            try await sleep(120)
        }
        try await until("peer's all acked") { peerBob.messages(conv).filter { $0.status == .sent }.count == 45 }
        try await launchAndLogin(me)
        try await see(self.conv("历史44"))
        self.conv("历史44").tap()
        // AC-UI-06-3: the last message is whole, above the input area.
        let last = message("历史44")
        try await see(last)
        try await until("last message on screen") { last.isHittable }
        XCTAssertLessThanOrEqual(last.frame.maxY, composer.frame.minY)

        // Scroll to the very first: pages load on the way, "没有更多了" at the top.
        let list = el("message-list")
        var scrolls = 0
        while !message("历史00").exists, scrolls < 30 {
            list.swipeDown(velocity: .fast)
            try await sleep(400)
            scrolls += 1
        }
        try await see(message("历史00"))
        try await see(el("history-state", labelContains: "没有更多了"))
        // Rows are in order.
        XCTAssertLessThan(message("历史00").frame.minY, message("历史01").frame.minY)

        // Scrolled up: a new message shows the pill, and it does not move the view.
        let before = message("历史00").frame.minY
        _ = try peerBob.send(conv, "新消息一")
        try await see("new-messages")
        XCTAssertEqual(label("new-messages"), "↓ 1 条新消息")
        XCTAssertEqual(message("历史00").frame.minY, before, accuracy: 1)
        try await tap("new-messages")
        let fresh = message("新消息一")
        try await see(fresh)
        try await until("jumped to bottom") { fresh.isHittable }
        try await gone(el("new-messages"))
    }

    func testOverLimit() async throws {
        // AC-UI-10-4, AC-UI-10-3
        let (me, bob) = (uid("a"), uid("b"))
        _ = try await peer(bob)
        try await importUsers([me])
        launch(env: ["TT_TEST_COMPOSER_TEXT": "5003"])
        try await login(me)
        try await startChat(with: bob)
        try await see("over-limit")
        XCTAssertEqual(label("over-limit"), "已超出 3 字")
        XCTAssertFalse(el("send-button").isEnabled)
        // Return does not send either.
        try await focus(composer)
        composer.typeText("\n")
        try await sleep(500)
        XCTAssertFalse(message("字").exists)
        // Five lines at most: the very long text does not take the screen.
        XCTAssertLessThan(composer.frame.height, 200)
        // Deleting back to 5000 is in the unit tests (testOverLimitCount): XCUITest's delete key has no effect on this
        // UIKit text view, while real touches do.
    }

    func testEmojiAndDraft() async throws {
        let (me, bob) = (uid("a"), uid("b"))
        let peerBob = try await peer(bob)
        try await importUsers([me])
        try await launchAndLogin(me)
        try await startChat(with: bob)
        try await focus(composer)

        // AC-UI-11-1: the emoji goes to the caret. AC-UI-11-2: one code point arrives.
        composer.typeText("你好世界")
        try await sleep(300)
        // Placing the caret between two characters would depend on glyph positions; the caret logic has a unit test
        // (testInsertAtCaret) and here the emoji goes in at the caret, which is at the end.
        try await tap("emoji-button")
        try await see("emoji-panel")
        XCTAssertGreaterThan(all("emoji-item").count, 10)
        all("emoji-item").element(boundBy: 0).tap()
        try await until("inserted") { (self.composer.value as? String) == "你好世界😀" }
        try await tap("send-button") { (self.composer.value as? String ?? "").isEmpty }
        try await sent("你好世界😀")
        try await until("peer got emoji") {
            peerBob.messages(self.c2c(me, bob)).contains { $0.body.text == "你好世界😀" }
        }

        // AC-UI-24-1, 24-3: drafts.
        try await focus(composer)
        composer.typeText("明天见")
        try await sleep(300)
        try await back()
        try await see(conv("[草稿] 明天见"))
        conv("[草稿] 明天见").tap()
        try await until("draft restored") { (self.composer.value as? String) == "明天见" }
        // Sending the restored draft ends it (AC-UI-24-3's whitespace rule is in testDraftsWhitespaceRemoves).
        try await tap("send-button") { (self.composer.value as? String ?? "").isEmpty }
        try await sent("明天见")
        try await back()
        try await gone(conv("[草稿]"))
        try await see(conv("明天见"))

        // AC-UI-24-4: a draft does not survive logout.
        conv("明天见").tap()
        try await see(composer)
        try await focus(composer)
        composer.typeText("别留下")
        try await sleep(300)
        try await back()
        try await see(conv("[草稿] 别留下"))
        try await logout()
        try await login(me)
        try await see(conv("明天见"))
        XCTAssertFalse(conv("[草稿]").exists)
    }

    func testCopyMenuAndCustomless() async throws {
        // AC-UI-09-1, AC-UI-09-3
        let (me, bob) = (uid("a"), uid("b"))
        _ = try await peer(bob)
        try await importUsers([me])
        try await launchAndLogin(me)
        try await startChat(with: bob)
        try await send("复制我")
        try await sent("复制我")
        message("复制我").press(forDuration: 1.0)
        let copy = app.buttons["复制"].firstMatch
        try await see(copy)
        XCTAssertFalse(app.buttons["重发"].exists, "sent messages only have copy")
        XCTAssertFalse(app.buttons["删除"].exists)
        copy.tap()
        try await see("toast")
        XCTAssertEqual(label("toast"), "已复制")
        try await sleep(2500)
        XCTAssertFalse(el("toast").exists, "a toast lasts 2 seconds (F-UI-19)")
    }

    func testUnknownConversations() async throws {
        let me = uid("a")
        try await importUsers([me])
        try await launchAndLogin(me)

        // AC-UI-33-1: malformed; AC-UI-33-2: not a participant.
        openLink("tianting://chat/abc")
        try await see("toast")
        XCTAssertEqual(label("toast"), "会话不存在")
        try await see("tab-chats")
        try await sleep(2200)
        openLink("tianting://chat/c2c%3Abob%3Acarol")
        try await see("toast")
        XCTAssertEqual(label("toast"), "会话不存在")
        try await sleep(1500)

        // AC-UI-33-6: no such group.
        openLink("tianting://chat/group%3Anotexist\(uid("x"))")
        try await see("composer-disabled")
        XCTAssertEqual(label("composer-disabled"), "群聊不存在或已解散")
        XCTAssertEqual(label("chat-title"), "群聊")
        XCTAssertFalse(composer.exists)

        // AC-UI-33-5 after a fresh start: 4033 means "你已不在该群".
        let bob = uid("b")
        let g = try await hostedGroup(name: "别人的群", members: [bob])
        openLink("tianting://chat/group%3A\(g.groupId)")
        try await see(el("composer-disabled", labelContains: "你已不在该群"))
        XCTAssertEqual(label("chat-title"), "群聊")
    }
}
