import TiantingIM
import XCTest

/// Contacts and friends against the real server.
final class SocialE2ETests: E2ECase {
    func testSearchApplyAcceptRemarkBlockDelete() async throws {
        let (me, bob) = (uid("a"), uid("b"))
        let peerBob = try await peer(bob, nickname: "博")
        try await importUsers([me])
        try await launchAndLogin(me)
        try await tap("tab-contacts")
        try await see("contacts-empty")  // AC-UI-13-5

        // AC-UI-26-3: bad format stays local.
        try await tap("contacts-add")
        try await type("a b\n", into: "search-input")
        try await see("search-error")
        XCTAssertEqual(label("search-error"), "账号格式不正确")

        // AC-UI-26-1
        try await clearAndType("\(bob)\n", into: "search-input")
        try await see("search-add")
        XCTAssertTrue(staticText(containing: "账号：\(bob)").exists)
        try await tap("search-add")

        // AC-UI-27-1, AC-UI-27-2: default text and counter, then "已发送" and back.
        try await see("apply-send")
        let defaultText = "我是\(me)"
        try await until("default message") { (self.el("apply-message").value as? String) == defaultText }
        XCTAssertEqual(label("apply-count"), "\(defaultText.unicodeScalars.count) / 50")
        try await clearAndType("球友", into: "apply-message")
        try await type("B哥", into: "apply-remark")
        try await tap("apply-send")
        try await see("toast")
        XCTAssertEqual(label("toast"), "已发送")
        try await see("search-input")

        do {
            try await until("request arrives") { peerBob.friendRequests().items.contains { $0.userId == me && $0.message == "球友" } }
        } catch {
            print("E2E-REQUESTS \(peerBob.friendRequests().items.map { ($0.userId, $0.message, $0.status.rawValue) })")
            throw error
        }
        try await peerBob.respondFriend(me, .accept)

        // Friend shows with the remark (AC-UI-13-4, AC-UI-27-2).
        try await back()
        try await see(el("friend-row", labelContains: "B哥"))
        XCTAssertEqual(label("contacts-count"), "1 位朋友")
        XCTAssertEqual(pinyinGroup("B哥"), "B")
        try await see("group-B")

        // Card: remark first, nickname second (AC-UI-14-3).
        el("friend-row", labelContains: "B哥").tap()
        try await see("user-name")
        XCTAssertEqual(label("user-name"), "B哥")
        XCTAssertEqual(label("user-nickname"), "昵称：博")
        XCTAssertEqual(label("user-id"), "账号：\(bob)")

        // AC-UI-28-1: change the remark. AC-UI-28-4 is covered by not sending when unchanged (unit logic).
        try await tap("user-remark")
        try await clearAndType("老板", into: "remark-input")
        try await tap("remark-done")
        try await until("remark") { self.label("user-name") == "老板" }

        // AC-UI-14-4: block.
        try await tap("user-more")
        try await tapMenuItem("加入黑名单")
        try await see("block-dialog")
        XCTAssertEqual(label("dialog-text"), "加入黑名单后，你将不再收到对方的私聊消息和好友申请；在共同的群聊里仍能看到对方的发言")
        try await tap("dialog-ok")
        try await see("user-blocked")
        try await tap("user-more")
        let unblock = app.buttons["移出黑名单"].firstMatch
        try await see(unblock)
        unblock.tap()
        try await gone(el("user-blocked"))

        // AC-UI-14-5, AC-UI-14-6 (open mode): delete stays on the card.
        try await tap("user-more")
        try await tapMenuItem("删除朋友")
        try await see("delete-dialog")
        XCTAssertFalse(label("dialog-text").contains("无法继续私聊"))
        try await tap("dialog-ok")
        try await see("user-add")
        try await back()
        try await see("contacts-empty")
    }

    func testIncomingRequestSeenAcceptRejectAndBadge() async throws {
        let (me, carol, dave) = (uid("a"), uid("c"), uid("d"))
        let peerCarol = try await peer(carol)
        let peerDave = try await peer(dave)
        try await importUsers([me])
        try await launchAndLogin(me)
        try await peerCarol.applyFriend(me, options: ApplyFriendOptions(message: "我是carol", source: .search))
        try await sleep(200)
        try await peerDave.applyFriend(me, options: ApplyFriendOptions(message: "", source: .search))

        // AC-UI-13-6
        try await see("tab-contacts-badge")
        try await until("two requests") { self.label("tab-contacts-badge") == "2" }
        try await tap("tab-contacts")
        try await see("requests-badge")

        // AC-UI-25-1, AC-UI-25-5
        try await tap("entry-requests")
        try await see("request-row")
        try await gone(el("tab-contacts-badge"))
        let rows = all("request-row")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("请求添加你为朋友"), "newest (dave) first")
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("我是carol"))

        // AC-UI-25-3: detail sheet and reject.
        rows.element(boundBy: 0).tap()
        try await see("request-sheet")
        XCTAssertEqual(label("request-source"), "通过搜索添加")
        try await tap("sheet-reject")
        try await see(staticText(containing: "已拒绝"))

        // AC-UI-25-2: accept.
        try await tap("request-accept")
        try await see(staticText(containing: "已添加"))
        try await until("carol sees me") { peerCarol.relationOf(me) == .friend }
        try await back()
        try await see(el("friend-row", labelContains: carol))
    }

    func testBlocksAndPrivacyAndSearchNotFoundSameUI() async throws {
        let (me, bob, eve) = (uid("a"), uid("b"), uid("e"))
        let peerBob = try await peer(bob)
        try await importUsers([me, eve])
        try await launchAndLogin(me)
        try await tap("tab-me")
        XCTAssertEqual(label("me-id"), "账号：\(me)")  // AC-UI-15-1
        try await tap("me-settings")
        // AC-UI-16-6 + M4
        XCTAssertTrue(el("settings-privacy").exists && el("settings-blocks").exists && el("settings-appearance").exists)
        XCTAssertTrue(el("about").exists && el("logout").exists)
        XCTAssertLessThan(el("settings-privacy").frame.minY, el("settings-blocks").frame.minY)
        XCTAssertLessThan(el("about").frame.minY, el("logout").frame.minY)
        // AC-UI-16-1
        try await tap("logout")
        try await see("logout-dialog")
        XCTAssertEqual(label("dialog-text"), "确定退出登录？")
        try await tap("dialog-cancel")
        try await gone(el("logout-dialog"))

        // AC-UI-20-3
        try await tap("settings-blocks")
        try await see("blocks-empty")
        try await back()

        // AC-UI-30-1: closing the switch hides me from search.
        try await tap("settings-privacy")
        let sw = app.switches["privacy-switch"].firstMatch
        try await see(sw)
        XCTAssertEqual(sw.value as? String, "1")
        sw.switches.firstMatch.tap()
        try await until("switch off") { (sw.value as? String) == "0" }
        try await until("settings applied") { true }
        try await sleep(300)
        let hidden = try await peerBob.searchUser(me)
        XCTAssertNil(hidden)
        sw.switches.firstMatch.tap()
        try await until("switch on") { (sw.value as? String) == "1" }
        try await sleep(300)
        let visible = try await peerBob.searchUser(me)
        XCTAssertNotNil(visible)
        try await back()

        // AC-UI-29-1, 29-2: order and removal.
        try await back()
        try await tap("tab-contacts")
        try await tap("contacts-add")
        for u in [bob, eve] {
            try await clearAndType("\(u)\n", into: "search-input")
            try await tap("search-card")
            try await tap("user-more")
            try await tapMenuItem("加入黑名单")
            try await tap("dialog-ok")
            try await see("user-blocked")
            XCTAssertFalse(el("user-add").exists, "no add for blocked (AC-UI-14-8)")
            try await back()
            try await sleep(1100)
        }
        try await back()
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("settings-blocks")
        try await see("block-row")
        XCTAssertEqual(all("block-row").count, 2)
        XCTAssertTrue(all("block-row").element(boundBy: 0).label.contains(eve), "newest first")
        all("block-remove").element(boundBy: 1).tap()
        try await see("toast")
        XCTAssertEqual(label("toast"), "已移出黑名单")
        try await until("one left") { self.all("block-row").count == 1 }
        XCTAssertTrue(all("block-row").element(boundBy: 0).label.contains(eve))

        // AC-UI-26-2: unknown and hidden read the same.
        try await back()
        try await back()
        try await tap("tab-contacts")
        try await tap("contacts-add")
        try await type("nobody\(uid("x"))\n", into: "search-input")
        try await see("search-result")
        XCTAssertEqual(label("search-result"), "未找到该用户")
        // AC-UI-26-4: self.
        try await clearAndType("\(me)\n", into: "search-input")
        try await see("search-note")
        XCTAssertEqual(label("search-note"), "这是你自己")
    }

    func testFriendsModeCardAndDeleteText() async throws {
        // AC-UI-14-6, AC-UI-14-7
        try await setFriendsMode()
        let (me, bob, carol) = (uid("a"), uid("b"), uid("c"))
        _ = try await peer(bob)
        try await importUsers([me, carol])
        try await makeFriends(me, bob)
        try await launchAndLogin(me)
        try await tap("tab-contacts")
        try await see(el("friend-row", labelContains: bob))
        el("friend-row", labelContains: bob).tap()
        try await see("user-chat")
        try await tap("user-more")
        try await tapMenuItem("删除朋友")
        try await see("delete-dialog")
        XCTAssertTrue(label("dialog-text").contains("删除后你们将无法继续私聊"))
        try await tap("dialog-cancel")

        // A stranger in friends mode has no chat button.
        openLink("tianting://user/\(carol)")
        try await see("user-add")
        try await staysGone(el("user-chat"))
    }

    func testGroupListAndNames() async throws {
        // AC-UI-32-1, AC-UI-13-1
        let me = uid("a")
        let others = ["Al\(uid("x"))", "Bo\(uid("x"))", "zh\(uid("x"))"]
        try await importUsers([me] + others, nicknames: [others[2]: "张三"])
        for o in others { try await makeFriends(me, o) }
        try await hostedGroup(name: "周末球局", members: [me, others[0]])
        try await hostedGroup(name: "Alpha", members: [me, others[1], others[2]])
        try await launchAndLogin(me)
        try await tap("tab-contacts")
        try await see("group-A")
        try await see("group-B")
        try await see("group-Z")
        XCTAssertEqual(label("contacts-count"), "3 位朋友")
        XCTAssertTrue(all("friend-row").element(boundBy: 2).label.contains("张三"))

        try await tap("entry-groups")
        try await see("groups-count")
        XCTAssertEqual(label("groups-count"), "2 个群聊")
        let rows = all("group-row")
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("Alpha"))
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("3 人"))
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("周末球局"))
    }
}
