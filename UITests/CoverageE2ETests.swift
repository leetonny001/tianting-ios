import TiantingIM
import XCTest

/// The remaining page-level ACs that a real server can drive.
final class CoverageE2ETests: E2ECase {
    func testStartChatDialogFromBothEntries() async throws {
        // AC-UI-05-1, 05-2, 05-3, 05-5, 05-7, AC-UI-33-3
        let (me, bob) = (uid("a"), uid("b"))
        let peerBob = try await peer(bob)
        try await importUsers([me])
        try await launchAndLogin(me)

        // Empty state and "+" open the same dialog; the scrim closes it.
        try await tap("chats-empty-start")
        try await see("start-chat-dialog")
        XCTAssertFalse(el("start-chat-submit").isEnabled)
        el("start-chat-dialog-scrim").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        try await gone(el("start-chat-dialog"))
        try await tap("plus-button")
        try await tapMenuItem("发起单聊")
        try await see("start-chat-dialog")

        // Return in the field starts the chat; a stranger has an empty page where sending works.
        try await type("\(bob)\n", into: "start-chat-input")
        try await see("chat-title")
        try await gone(el("start-chat-dialog"))
        try await send("第一句")
        try await sent("第一句")
        try await until("peer got it") { peerBob.messages(self.c2c(me, bob)).contains { $0.body.text == "第一句" } }
        try await back()
        try await see(conv("第一句"))

        // Myself (AC-UI-05-3).
        try await tap("plus-button")
        try await tapMenuItem("发起单聊")
        try await type(me, into: "start-chat-input")
        try await tap("start-chat-submit") { !self.el("start-chat-dialog").exists }
        try await see("chat-title")
        try await send("自己")
        try await sent("自己")
        try await back()

        // AC-UI-05-5, 05-8: "添加朋友" goes to the search page.
        try await tap("plus-button")
        try await tapMenuItem("添加朋友")
        try await see("search-input")
    }

    func testChatInfoAndUserCardRoutes() async throws {
        // AC-UI-12-2, AC-UI-14-1, AC-UI-14-2, AC-UI-15-3, AC-UI-14-10
        let (me, bob) = (uid("a"), uid("b"))
        _ = try await peer(bob)
        try await importUsers([me])
        try await makeFriends(me, bob)
        try await launchAndLogin(me)
        try await startChat(with: bob)
        try await send("你好")
        try await sent("你好")
        try await tap("chat-more")
        try await see("info-sub")
        XCTAssertEqual(label("info-sub"), "账号：\(bob)")
        try await tap("info-head")
        try await see("user-chat")
        XCTAssertEqual(label("user-id"), "账号：\(bob)")
        try await tap("user-chat")
        try await see(message("你好"))

        // My own card has no actions (AC-UI-14-2).
        let mine = all("msg-avatar").element(boundBy: 0)
        try await see(mine)
        mine.tap()
        try await see("user-id")
        XCTAssertEqual(label("user-id"), "账号：\(me)")
        XCTAssertFalse(el("user-chat").exists)
        XCTAssertFalse(el("user-add").exists)
        XCTAssertFalse(el("user-more").exists)

        // Absent and invisible users look the same (AC-UI-14-10).
        openLink("tianting://user/nobody\(uid("x"))")
        try await see("user-add")
        XCTAssertFalse(staticText(containing: "用户不存在").exists)
        let hidden = uid("frank")
        try await importUsers([hidden])
        try await sleep(500)
        openLink("tianting://user/\(hidden)")
        try await see(el("user-id", labelContains: hidden))
        try await see("user-add")
        XCTAssertFalse(staticText(containing: "用户不存在").exists)

        // "我" has no edit entry (AC-UI-15-3).
        openLink("tianting://me")
        try await see("me-name")
        XCTAssertFalse(staticText(containing: "编辑").exists)
    }

    func testApplyRulesAndSources() async throws {
        // AC-UI-27-3, 27-4, 27-5, 27-6, 27-8, AC-UI-14-11, AC-UI-14-9, AC-UI-28-2, 28-3, AC-UI-13-7, 13-8, 13-2, AC-UI-29-3
        let (me, bob, carol, frank) = (uid("a"), uid("b"), uid("c"), uid("f"))
        let peerBob = try await peer(bob, nickname: "博")
        let peerCarol = try await peer(carol)
        try await importUsers([me, frank])
        let g = try await hostedGroup(name: "来源群", members: [me, carol])
        try await peerCarol.block(me)
        _ = try peerBob.send(c2c(me, bob), "陌生人消息")
        try await launchAndLogin(me)

        // Applying to myself goes back with a toast (AC-UI-27-8).
        openLink("tianting://contacts/apply/\(me)")
        try await see("toast")
        XCTAssertEqual(label("toast"), "不能添加自己")
        try await sleep(1500)

        // Too long (AC-UI-27-3).
        openLink("tianting://contacts/apply/\(frank)")
        try await see("apply-send")
        try await clearAndType(String(repeating: "长", count: 51), into: "apply-message")
        try await see("apply-message-error")
        XCTAssertEqual(label("apply-message-error"), "最多 50 个字")
        XCTAssertFalse(el("apply-send").isEnabled)
        try await clearAndType("附言", into: "apply-message")
        try await type(String(repeating: "备", count: 33), into: "apply-remark")
        try await see("apply-remark-error")
        XCTAssertEqual(label("apply-remark-error"), "最多 32 个字")
        XCTAssertFalse(el("apply-send").isEnabled)

        // Someone who blocked me reads like anyone else (AC-UI-27-5).
        openLink("tianting://contacts/apply/\(carol)")
        try await see("apply-send")
        try await tap("apply-send") { self.el("toast").exists }
        XCTAssertEqual(label("toast"), "已发送")
        try await sleep(1500)

        // bob applied first: my apply is an accept (AC-UI-27-4), then the card has "发消息".
        try await peerBob.applyFriend(me, options: ApplyFriendOptions(message: "加我", source: .search))
        try await sleep(400)
        openLink("tianting://contacts/apply/\(bob)")
        try await see("apply-send")
        try await tap("apply-send") { self.el("toast").exists }
        XCTAssertEqual(label("toast"), "已添加到通讯录")
        try await see("user-chat")

        // Remark rules (AC-UI-28-2, 28-3, AC-UI-13-7).
        try await tap("user-remark")
        try await see("remark-input")
        try await clearAndType(String(repeating: "备", count: 33), into: "remark-input")
        try await see("remark-error")
        // Too long does nothing. Checked by tapping: iOS 18 does not report a disabled toolbar button as not enabled.
        el("remark-done").tap()
        try await sleep(800)
        XCTAssertTrue(el("remark-input").exists)
        try await clearAndType("阿博", into: "remark-input")
        try await tap("remark-done") { !self.el("remark-input").exists }
        try await until("remark on the card") { self.label("user-name") == "阿博" }
        openLink("tianting://contacts")
        try await see("group-A")
        try await see(el("friend-row", labelContains: "阿博"))

        // Blocked friends stay listed with a tag (AC-UI-13-8); strangers and myself do not appear (AC-UI-13-2).
        el("friend-row", labelContains: "阿博").tap()
        try await tap("user-more")
        try await tapMenuItem("加入黑名单")
        try await tap("dialog-ok")
        try await see("user-blocked")
        openLink("tianting://contacts")
        try await see(el("friend-row", labelContains: "已拉黑"))
        XCTAssertEqual(all("friend-row").count, 1)

        // A pending request's card (AC-UI-14-9), and a block list row without a profile (AC-UI-29-3).
        let dave = uid("d")
        let peerDave = try await peer(dave)
        try await peerDave.applyFriend(me, options: ApplyFriendOptions(message: "", source: .group, sourceRef: g.groupId))
        try await sleep(500)
        openLink("tianting://user/\(dave)")
        try await see("user-accept")
        try await tap("user-accept")
        try await see("user-remark")
        openLink("tianting://user/\(frank)")
        try await see("user-more")
        try await tap("user-more")
        try await tapMenuItem("加入黑名单")
        try await tap("dialog-ok")
        try await see("user-blocked")
        openLink("tianting://me/settings/blocks")
        try await see(el("block-row", labelContains: frank))
    }

    func testApplySourceFromGroupAvatar() async throws {
        // AC-UI-14-11, AC-UI-27-6: the source travels with the route.
        let (me, carol) = (uid("a"), uid("c"))
        let peerCarol = try await peer(carol)
        try await importUsers([me])
        let g = try await hostedGroup(name: "来源群", members: [me, carol])
        _ = try peerCarol.send(g.convId, "看我头像")
        try await launchAndLogin(me)
        try await see(conv("来源群"))
        conv("来源群").tap()
        try await see(message("看我头像"))
        try await tap("msg-avatar")
        try await tap("user-add")
        try await tap("apply-send") { self.el("toast").exists }
        try await until("request arrives") {
            peerCarol.friendRequests().items.contains { $0.userId == me && $0.item.source == .group }
        }
    }

    func testStrangerLimitAndLeftElsewhere() async throws {
        // AC-UI-31-3, AC-UI-33-8
        let (me, bob) = (uid("a"), uid("b"))
        _ = try await peer(bob)
        try await importUsers([me])
        try await signed("PATCH", "/admin/settings/social", ["strangerMsgLimit": 2])
        defer { Task { try? await signed("PATCH", "/admin/settings/social", ["strangerMsgLimit": 20]) } }
        let g = try await hostedGroup(name: "别处退群", members: [me, bob])
        try await launchAndLogin(me)
        try await startChat(with: bob)
        for t in ["一", "二"] {
            try await send(t)
            try await sent(t)
        }
        try await send("三")
        let third = message("三")
        try await see(third)
        try await until("failed") { (third.value as? String) == "发送失败" }
        try await see("permission-tip")
        XCTAssertEqual(label("permission-tip"), "对方回复之前，最多只能发送 2 条消息")
        try await back()

        // Same account on another device leaves the group.
        try await see(conv("别处退群"))
        conv("别处退群").tap()
        try await see(composer)
        let other = try await peer(me)
        try await other.leaveGroup(g.groupId)
        try await see("chat-blocked-tip", timeout: 3)
        XCTAssertEqual(label("chat-blocked-tip"), "你已退出该群聊")
        XCTAssertEqual(label("composer-disabled"), "你已退出该群聊")
    }

    func testCreateGroupWithBlockerAndLongList() async throws {
        // AC-UI-35-4, AC-UI-01-8, AC-UI-04-1 at scale.
        let (me, bob, carol) = (uid("a"), uid("b"), uid("c"))
        _ = try await peer(bob)
        let peerCarol = try await peer(carol)
        try await importUsers([me])
        try await makeFriends(me, bob)
        try await makeFriends(me, carol)
        // A conversation list longer than the screen.
        for i in 0..<20 { try await hostedGroup(name: "长列表\(i)", members: [me, bob]) }
        try await launchAndLogin(me)
        try await see(conv("长列表"))
        let list = el("conv-list")
        list.swipeUp(velocity: .fast)
        try await sleep(600)
        let top = conv("长列表19")
        try await until("scrolled away") { !top.exists || !top.isHittable }
        try await tap("tab-chats")
        try await until("back at the top") { top.exists && top.isHittable }

        try await tap("plus-button")
        try await tapMenuItem("发起群聊")
        for u in [bob, carol] {
            let row = el("pick-row", labelContains: u)
            try await see(row)
            for _ in 0..<4 where (row.value as? String) != "selected" {
                row.tap()
                try await sleep(600)
            }
        }
        try await until("two picked") { self.el("pick-done").label.contains("2") }
        // carol blocks me just before submitting.
        try await peerCarol.block(me)
        try await sleep(300)
        try await tap("pick-done")
        try await see("group-name-sheet")
        try await tap("group-create") { !self.el("group-name-sheet").exists }
        try await see("toast")
        XCTAssertTrue(label("toast").contains("不是你的好友，无法邀请"))
        try await until("marked red") { (self.el("pick-row", labelContains: carol).value as? String) == "error" }
        XCTAssertTrue(el("pick-done").exists, "no group was created, still on this page")
    }
}
