import TiantingIM
import XCTest

/// Second batch against the real server (IM_V13_ADMIN_FEATURES=1): mute bar, deleted placeholder, ban dialog.
final class ModerationE2ETests: E2ECase {
    func testUserMuteShowsBarEverywhereAndUnmuteRestores() async throws {
        let (me, bob) = (uid("u"), uid("b"))
        _ = try await peer(bob)
        let g = try await hostedGroup(name: "禁言群", members: [me, bob])
        try await launchAndLogin(me)
        try await see(conv("禁言群"))
        conv("禁言群").tap()
        try await see(composer)

        // AC-UI-41-1
        let r = try await signed(
            "POST", "/admin/mute", ["scope": "user", "userId": me, "durationSeconds": 600, "reason": "e2e"])
        let until = (r["mutedUntil"] as! NSNumber).int64Value
        let bar = "你已被禁言，解除时间：\(monthDay(until))"
        try await see(el("composer-disabled", labelContains: bar), timeout: 3)
        XCTAssertFalse(composer.exists)

        // Single chat too.
        try await back()
        try await startChat(with: bob)
        try await see(el("composer-disabled", labelContains: bar))
        XCTAssertFalse(composer.exists)

        // AC-UI-41-3
        try await signed("POST", "/admin/unmute", ["scope": "user", "userId": me, "reason": "e2e"])
        try await see(composer, timeout: 3)
        try await send("恢复了")
        try await sent("恢复了")
        _ = g
    }

    func testGroupAllMuteBarForMemberAndRecovery() async throws {
        // AC-UI-41-6, AC-ADM-42-1, AC-ADM-42-2
        let (me, owner, g) = (uid("u"), uid("o"), uid("g"))
        _ = try await peer(owner)
        try await admin("POST", "/admin/users/import", ["users": [["userId": me]]])
        try await signed("POST", "/admin/groups", ["groupId": g, "name": "全员群", "members": [me, owner], "owner": owner])
        try await launchAndLogin(me)
        try await see(conv("全员群"))
        conv("全员群").tap()
        try await see(composer)

        try await signed("POST", "/admin/mute", ["scope": "groupAll", "groupId": g, "reason": "e2e"])
        try await see("composer-disabled", timeout: 3)
        XCTAssertEqual(label("composer-disabled"), "群主已开启全员禁言")
        XCTAssertFalse(composer.exists)

        try await signed("POST", "/admin/unmute", ["scope": "groupAll", "groupId": g, "reason": "e2e"])
        try await see(composer, timeout: 3)
        try await send("恢复了")
        try await sent("恢复了")
    }

    func testGroupAllMuteDoesNotBlockOwner() async throws {
        // F-ADM-42: the owner gets the event but keeps the composer and can send.
        let (me, other, g) = (uid("o"), uid("m"), uid("g"))
        try await admin("POST", "/admin/users/import", ["users": [["userId": me], ["userId": other]]])
        try await signed("POST", "/admin/groups", ["groupId": g, "name": "群主群", "members": [me, other], "owner": me])
        try await signed("POST", "/admin/mute", ["scope": "groupAll", "groupId": g, "reason": "e2e"])
        try await launchAndLogin(me)
        try await see(conv("群主群"))
        conv("群主群").tap()
        try await see(composer)
        XCTAssertFalse(app.descendants(matching: .any)["composer-disabled"].exists)
        try await send("群主发言")
        try await sent("群主发言")
    }

    func testGroupMuteOnlyThatGroupAndPermanentText() async throws {
        // AC-UI-41-2, AC-UI-41-5
        let (me, bob) = (uid("u"), uid("b"))
        _ = try await peer(bob)
        let g1 = try await hostedGroup(name: "一群", members: [me, bob])
        _ = try await hostedGroup(name: "二群", members: [me, bob])
        try await signed(
            "POST", "/admin/mute",
            ["scope": "group", "groupId": g1.groupId, "userId": me, "durationSeconds": NSNull(), "reason": "e2e"])
        try await launchAndLogin(me)
        try await see(conv("一群"))
        conv("一群").tap()
        try await see("composer-disabled")
        XCTAssertEqual(label("composer-disabled"), "你已被禁言")
        XCTAssertFalse(composer.exists)
        try await back()
        conv("二群").tap()
        try await see(composer)
        try await send("二群能发")
        try await sent("二群能发")
        try await back()
        try await startChat(with: bob)
        try await see(composer)
        XCTAssertFalse(el("composer-disabled").exists)
    }

    func testDeletedMessageLeavesNoOriginalText() async throws {
        let (me, bob, late) = (uid("u"), uid("b"), uid("l"))
        let peerBob = try await peer(bob, nickname: "博")
        try await importUsers([late])
        let g = try await hostedGroup(name: "删除群", members: [me, bob, late])
        let secret = "ZXQ-DEL-\(uid("x"))"
        try await launchAndLogin(me)
        try await see(conv("删除群"))
        conv("删除群").tap()
        try await see(composer)

        _ = try peerBob.send(g.convId, secret)
        try await see(message(secret))
        XCTAssertTrue(app.debugDescription.contains(secret), "control: visible before deletion")
        var msgId: String?
        try await until("acked") {
            msgId = peerBob.messages(g.convId).last { $0.body.text == secret }?.msgId
            return msgId != nil
        }

        try await signed(
            "POST", "/admin/messages/delete", ["convId": g.convId, "msgIds": [msgId!], "reason": "e2e"])

        // AC-UI-42-1
        try await see("msg-deleted", timeout: 3)
        XCTAssertEqual(label("msg-deleted"), "该消息已被删除")
        XCTAssertFalse(app.debugDescription.contains(secret), "the original text is nowhere on screen")
        // AC-UI-42-4: no menu.
        el("msg-deleted").press(forDuration: 0.8)
        try await staysGone(app.buttons["复制"].firstMatch)

        // AC-UI-42-2: the list's summary.
        try await back()
        try await see(conv("该消息已被删除"))
        XCTAssertFalse(conv("该消息已被删除").label.contains("博:"), "no sender prefix")
        XCTAssertFalse(app.debugDescription.contains(secret))

        // Relaunch from the local database: still gone.
        app.terminate()
        launch(reset: false)
        try await see(conv("该消息已被删除"))
        conv("该消息已被删除").tap()
        try await see("msg-deleted")
        XCTAssertFalse(app.debugDescription.contains(secret))
        try await back()
        try await logout()

        // AC-UI-42-3: a member who was offline sees the placeholder.
        try await login(late)
        try await see(conv("该消息已被删除"))
        conv("该消息已被删除").tap()
        try await see("msg-deleted")
        XCTAssertFalse(app.debugDescription.contains(secret))
    }

    func testBanWhileOnlineThenLoginRefused() async throws {
        let me = uid("ban")
        try await importUsers([me])
        try await launchAndLogin(me)
        try await see("conv-list")

        // AC-UI-43-3
        let r = try await signed("POST", "/admin/users/\(me)/ban", ["durationSeconds": 86_400, "reason": "e2e"])
        let until = ((r["ban"] as! [String: Any])["until"] as! NSNumber).int64Value
        let text = "账号已被封禁，解封时间：\(dateTime(until))"
        try await see("kicked-dialog", timeout: 3)
        XCTAssertEqual(label("kicked-text"), text)

        // AC-UI-18-1 (3.6 table): neither an edge swipe, a swipe down, nor a tap outside closes it.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        try await sleep(500)
        XCTAssertTrue(el("kicked-dialog").exists, "edge swipe")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        try await sleep(500)
        XCTAssertTrue(el("kicked-dialog").exists, "swipe down")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        try await sleep(500)
        XCTAssertTrue(el("kicked-dialog").exists, "tap outside")
        capture("kicked-dialog")

        // Only OK closes it, and login is refused with the same copy (AC-UI-43-1).
        try await tap("kicked-ok")
        try await see("login-submit")
        try await type(me, into: "login-username")
        try await tap("login-submit")
        try await see("login-error")
        XCTAssertEqual(label("login-error"), text)
        XCTAssertTrue(el("login-submit").exists)
    }

    func testPermanentBan() async throws {
        let me = uid("ban")
        try await importUsers([me])
        try await launchAndLogin(me)
        try await signed("POST", "/admin/users/\(me)/ban", ["durationSeconds": NSNull(), "reason": "e2e"])
        try await see("kicked-dialog", timeout: 3)
        XCTAssertEqual(label("kicked-text"), "账号已被封禁")
        try await tap("kicked-ok")
        try await see("login-submit")
        try await type(me, into: "login-username")
        try await tap("login-submit")
        try await see("login-error")
        XCTAssertEqual(label("login-error"), "账号已被封禁")
    }

    func testForceLogoutDialog() async throws {
        // F-UI-18: a kick (4012).
        let me = uid("kick")
        try await importUsers([me])
        try await launchAndLogin(me)
        try await admin("POST", "/admin/users/\(me)/force-logout", [:])
        try await see("kicked-dialog", timeout: 3)
        XCTAssertFalse(label("kicked-text").isEmpty)
        try await tap("kicked-ok")
        try await see("login-submit")
        // AC-UI-18-3: another account sees nothing of the previous one.
        let other = uid("other")
        try await login(other)
        try await tap("tab-contacts")
        try await see("contacts-empty")
    }
}
