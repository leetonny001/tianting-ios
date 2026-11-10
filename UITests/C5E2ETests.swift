import TiantingIM
import UIKit
import XCTest

/// Shared steps of the C5 end-to-end cases (FE-685): the real im-server in test mode with IM_CONV_SETTINGS_ENABLED=1
/// (scripts/e2e-server.sh), the app on the simulator, "my other device" and the other accounts as real `IMClient`s in the
/// test runner.
extension E2ECase {
    /// A list row by the name it starts with (a summary can hold a name too).
    func listRow(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'conv-item' AND label BEGINSWITH %@", name + "，")).firstMatch
    }

    /// The items of the conversation menu that show after a long press on a row.
    func convMenu(_ row: XCUIElement) async throws -> [String] {
        try await see(row)
        try await until("row hittable") { row.isHittable }
        try await sleep(300)
        row.press(forDuration: 1.0)
        let titles = ["置顶", "取消置顶", "免打扰", "取消免打扰", "删除"]
        try await until("conversation menu") { titles.contains { self.app.buttons[$0].firstMatch.exists } }
        try await sleep(400)
        return titles.filter { app.buttons[$0].firstMatch.exists }
    }

    func closeConvMenu() async throws {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        try await gone(app.buttons["删除"].firstMatch, timeout: 4)
    }

    /// Long press, then one of its items.
    func convAction(_ row: XCUIElement, _ title: String) async throws {
        let shown = try await convMenu(row)
        XCTAssertTrue(shown.contains(title), "menu has \(title): \(shown)")
        try await tapMenuItem(title)
    }

    func rowLabel(_ i: Int) -> String {
        let q = all("conv-item")
        return q.count > i ? q.element(boundBy: i).label : ""
    }

    /// The row's background: a point in its right padding, above the time.
    func rowBackground(_ row: XCUIElement) -> (Int, Int, Int) {
        let f = row.frame
        let p = pixel(atX: f.maxX - 4, y: f.minY + 4)
        return (p.r, p.g, p.b)
    }

    /// Screenshots go through color management: a small difference is the same color.
    func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        abs(a.0 - b.0) <= 4 && abs(a.1 - b.1) <= 4 && abs(a.2 - b.2) <= 4
    }

    /// Sends `n` texts from a peer, each acked.
    func sayMany(_ c: IMClient, _ conv: String, _ n: Int, _ prefix: String) async throws {
        for i in 1...n { try await say(c, conv, "\(prefix)\(i)") }
    }

    /// The peer's local view of a conversation.
    func peerConv(_ c: IMClient, _ conv: String) -> Conversation? { c.conversations().first { $0.convId == conv } }

    /// Settings are limited to 5 a second per user (F-CVS-04 rule 4): space the other device's calls.
    func settle() async throws { try await sleep(300) }
}

/// FE-685: the conversation menu, pin and notifications off in the list, delete, the total unread. Test names carry the TC
/// numbers.
@MainActor
final class C5E2ETests: E2ECase {
    private var relay: TCPProxy?

    override func tearDown() async throws {
        relay?.stop()
        relay = nil
        try? await setSystemAppearance("light")
        try await super.tearDown()
    }

    private func launchAs(_ userId: String, env: [String: String] = [:]) async throws {
        launch(env: env)
        try await login(userId)
    }

    private let lightPinned = (0xF3, 0xF4, 0xF8)
    private let lightSurface = (0xFF, 0xFF, 0xFF)
    private let darkPinned = (0x23, 0x26, 0x2E)
    private let darkSurface = (0x1B, 0x1E, 0x25)

    // MARK: Menu and pin (AC-CVS-01-6)

    /// TC-CVS-01-06 (iOS): a long press opens the menu with "置顶" "免打扰" "删除", words by state; a pin moves the row to
    /// the top with the `surface.pinned` background, light and dark; my other device gets it too. The system's audit finds
    /// no element without a description on the list, light and dark (AC-CHAT-90-9).
    func testTC_CVS_01_06_menuPinMovesToTopWithBackground() async throws {
        let (a, b, c, d) = (uid("pa"), uid("pb"), uid("pc"), uid("pd"))
        try await importUsers([a, b, c, d], nicknames: [a: "甲", b: "乙乙", c: "丙丙", d: "丁丁"])
        let other = try await peer(a)
        for (u, t) in [(b, "一"), (c, "二"), (d, "三")] {
            let p = try await peer(u)
            try await say(p, c2c(a, u), t)
        }
        try await setSystemAppearance("light")
        try await launchAs(a)
        try await see(listRow("乙乙"))
        try await until("newest first") { self.rowLabel(0).contains("丁丁") && self.rowLabel(2).contains("乙乙") }

        let shown = try await convMenu(listRow("乙乙"))
        XCTAssertEqual(shown, ["置顶", "免打扰", "删除"])
        try await tapMenuItem("置顶")
        try await until("pinned first") { self.rowLabel(0).contains("乙乙") && self.rowLabel(0).contains("已置顶") }
        XCTAssertTrue(rowLabel(1).contains("丁丁"), "the rest by time")
        try await until("my other device has the pin", timeout: 5) { self.peerConv(other, self.c2c(a, b))?.isPinned == true }
        try await sleep(500)
        XCTAssertTrue(near(rowBackground(all("conv-item").element(boundBy: 0)), lightPinned), "\(rowBackground(all("conv-item").element(boundBy: 0)))")
        XCTAssertTrue(near(rowBackground(all("conv-item").element(boundBy: 1)), lightSurface))
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        capture("c5-pinned-light")

        let again = try await convMenu(listRow("乙乙"))
        XCTAssertEqual(again, ["取消置顶", "免打扰", "删除"])
        try await closeConvMenu()

        try await setSystemAppearance("dark")
        try await sleep(1000)
        XCTAssertTrue(near(rowBackground(all("conv-item").element(boundBy: 0)), darkPinned), "\(rowBackground(all("conv-item").element(boundBy: 0)))")
        XCTAssertTrue(near(rowBackground(all("conv-item").element(boundBy: 1)), darkSurface))
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        capture("c5-pinned-dark")
        try await setSystemAppearance("light")

        // Unpinning puts it back by time.
        try await convAction(listRow("乙乙"), "取消置顶")
        try await until("back by time") { self.rowLabel(2).contains("乙乙") && !self.rowLabel(2).contains("已置顶") }
    }

    /// AC-CVS-01-2 on the page: the 21st pin fails with 4220: "最多置顶 20 个会话", and the row goes back (no retry).
    func testTC_CVS_01_02_21stPinSays4220AndRollsBack() async throws {
        let (a, o) = (uid("la"), uid("lo"))
        try await importUsers([a, o], nicknames: [a: "甲", o: "群主"])
        var groups: [String] = []
        for i in 1...21 {
            groups.append(try await hostedGroup(name: "置顶群\(two(i))", members: [o, a], owner: o).convId)
        }
        let other = try await peer(a)
        try await until("other device has the groups", timeout: 15) { other.conversations().count >= 21 }
        for g in groups.prefix(20) {
            try await other.setConvPinned(g, true)
            try await settle()
        }
        try await launchAs(a)
        let last = listRow("置顶群21")
        try await see(all("conv-item").firstMatch, timeout: 15)
        for _ in 0..<8 where !(last.exists && last.isHittable) { app.swipeUp() }
        try await convAction(last, "置顶")
        try await see(el("toast", labelContains: "最多置顶 20 个会话"), timeout: 5)
        try await until("rolled back") { last.exists && !last.label.contains("已置顶") }
        try await sleep(1500)
        XCTAssertFalse(last.label.contains("已置顶"))
    }

    // MARK: Notifications off (AC-CVS-02-2, 02-3, 02-5, 02-6)

    /// TC-CVS-02-02, TC-CVS-02-03: normal unread 2 and 3, notifications off 5: the tab reads 5 ("消息，5 条未读",
    /// frontend-chat 67), the row "[5 条]", the dot and "免打扰"; notifications back on: 10. A draft wins over "[N 条]".
    func testTC_CVS_02_02_TC_CVS_02_03_badgeDotCountAndIcon() async throws {
        let (a, b, c, d) = (uid("na"), uid("nb"), uid("nc"), uid("nd"))
        try await importUsers([a, b, c, d], nicknames: [a: "甲", b: "乙乙", c: "丙丙", d: "丁丁"])
        let pb = try await peer(b)
        let pc = try await peer(c)
        let pd = try await peer(d)
        try await sayMany(pb, c2c(a, b), 2, "乙说")
        try await sayMany(pc, c2c(a, c), 3, "丙说")
        try await sayMany(pd, c2c(a, d), 5, "丁说")
        let other = try await peer(a)
        try await other.setConvNotifyOff(c2c(a, d), true)
        try await launchAs(a)
        try await see(listRow("丁丁"))
        try await until("badge 5") { self.el("tab-badge").exists && self.label("tab-badge") == "5" }
        XCTAssertEqual(label("tab-chats"), "消息，5 条未读")
        let row = listRow("丁丁")
        XCTAssertTrue(row.label.contains("[5 条] 丁说5"), row.label)
        XCTAssertTrue(row.label.contains("免打扰"))
        XCTAssertFalse(row.label.contains("未读 5"), "a dot, not a number")
        XCTAssertTrue(listRow("丙丙").label.contains("未读 3"))
        capture("c5-notify-off-light")

        try await convAction(row, "取消免打扰")
        try await until("badge 10") { self.label("tab-badge") == "10" }
        XCTAssertTrue(listRow("丁丁").label.contains("未读 5"))
        XCTAssertFalse(listRow("丁丁").label.contains("免打扰"))
        try await settle()
        try await convAction(listRow("丁丁"), "免打扰")
        try await until("badge 5 again") { self.label("tab-badge") == "5" && self.listRow("丁丁").label.contains("[5 条]") }

        // A draft wins over "[N 条]".
        try await tapElement(listRow("丁丁"))
        try await see("chat-title")
        try await typeInComposer("还没发")
        try await back()
        try await see(listRow("丁丁"))
        try await say(pd, c2c(a, d), "又一条")
        try await until("draft first") { self.listRow("丁丁").label.contains("[草稿] 还没发") }
        try await sleep(500)
        XCTAssertFalse(listRow("丁丁").label.contains("[1 条]"))
        XCTAssertEqual(label("tab-badge"), "5", "2 + 3; the conversation with notifications off adds nothing")
    }

    /// TC-CVS-02-05, TC-CVS-02-03 step 2: a group with notifications off, 5 unread, one mentions me, plus a normal 2: the
    /// tab reads 3 and the row "[有人@我]"; read past the mention: 2.
    func testTC_CVS_02_05_mentionInNotifyOffGroupCounts() async throws {
        let (a, o, c) = (uid("ma"), uid("mo"), uid("mc"))
        let g = try await c4Group("免打扰群", [(o, "群主"), (a, "爱丽丝")])
        try await importUsers([c], nicknames: [c: "丙丙"])
        let po = try await peer(o)
        let pc = try await peer(c)
        try await sayMany(pc, c2c(a, c), 2, "丙说")
        let other = try await peer(a)
        try await until("other device has the group", timeout: 10) { self.peerConv(other, g.convId) != nil }
        try await other.setConvNotifyOff(g.convId, true)
        try await sayMany(po, g.convId, 4, "群里")
        try await say(po, g.convId, "@爱丽丝 看一下", mentions: Mentions(userIds: [a]))
        try await launchAs(a)
        try await see(listRow("免打扰群"))
        try await until("badge 3") { self.el("tab-badge").exists && self.label("tab-badge") == "3" }
        let row = listRow("免打扰群")
        XCTAssertTrue(row.label.contains("[有人@我]"), row.label)
        XCTAssertTrue(row.label.contains("免打扰"))
        XCTAssertFalse(row.label.contains("条]"), "one prefix only")
        try await tapElement(row)
        try await see("chat-title")
        try await see(message("看一下"))
        try await back()
        try await until("badge 2") { self.label("tab-badge") == "2" }
    }

    /// TC-CVS-02-06 (iOS): in the foreground, messages in a single chat and a group with notifications off: the list
    /// updates within 2 seconds, no system notification is shown or waiting, the sound stand-in (`Alerts.ring`) is not
    /// called. In C5 the app has no notification or sound code at all (frontend-chat 58); FE-655 reruns this with C3.
    func testTC_CVS_02_06_foregroundNotifyOffNoNotificationNoSound() async throws {
        let (a, o) = (uid("fa"), uid("fo"))
        let g = try await c4Group("静音群", [(o, "群主"), (a, "爱丽丝")])
        let po = try await peer(o)
        try await say(po, c2c(a, o), "先来一条")
        let other = try await peer(a)
        try await until("other device has both", timeout: 10) {
            self.peerConv(other, g.convId) != nil && self.peerConv(other, self.c2c(a, o)) != nil
        }
        try await other.setConvNotifyOff(g.convId, true)
        try await settle()
        try await other.setConvNotifyOff(c2c(a, o), true)
        try await launchAs(a, env: ["TT_TEST_STATE": "1"])
        try await see(listRow("静音群"))
        try await until("both off") { self.listRow("静音群").label.contains("免打扰") && self.listRow("群主").label.contains("免打扰") }
        let t0 = Date()
        try await say(po, c2c(a, o), "单聊新消息")
        try await say(po, g.convId, "群里新消息")
        try await until("list updated", timeout: 3) {
            self.conv("单聊新消息").exists && self.conv("群里新消息").exists
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4)
        XCTAssertTrue(conv("单聊新消息").label.contains("[2 条]"))
        try await sleep(1500)
        XCTAssertEqual(probe("notes"), 0, "no system notification")
        XCTAssertEqual(probe("alerts"), 0, "the sound stand-in was not called")
        XCTAssertFalse(el("tab-badge").exists, "all unread is in conversations with notifications off")
        XCTAssertEqual(label("tab-chats"), "消息")
    }

    // MARK: Delete and other devices (AC-CVS-03-2, 04-1, 04-2, 04-5; frontend-chat 66)

    /// TC-CVS-03-02 (iOS as u1): deleted, then the peer sends one: the row comes back with unread 1 and only that message;
    /// the server's minSeq is 11; the old text is not in the app's data directory.
    func testTC_CVS_03_02_backWithOnlyTheNewMessage() async throws {
        let (a, b) = (uid("ra"), uid("rb"))
        try await importUsers([a, b], nicknames: [a: "甲", b: "乙乙"])
        let marker = "ZXQ-CVS-1-\(uid("k"))"
        let pb = try await peer(b)
        let conv = c2c(a, b)
        try await sayMany(pb, conv, 10, marker + "-")
        try await launchAs(a, env: ["TT_TEST_STATE": "1", "TT_TEST_SCAN": marker])
        try await tapElement(self.listRow("乙乙"))
        try await see(message(marker + "-10"))
        try await until("on disk", timeout: 15) { self.probe("scan") > 0 }
        try await back()
        try await convAction(self.listRow("乙乙"), "删除")
        try await see("conv-delete-dialog")
        try await tap("dialog-ok")
        try await gone(self.listRow("乙乙"))
        try await until("purged from disk", timeout: 20) { self.probe("scan") == 0 }
        try await say(pb, conv, "新的一条")
        try await see(self.conv("新的一条"), timeout: 5)
        XCTAssertTrue(self.conv("新的一条").label.contains("未读 1"), self.conv("新的一条").label)
        try await tapElement(self.conv("新的一条"))
        try await see(message("新的一条"))
        app.swipeDown()
        try await sleep(1500)
        XCTAssertEqual(all("message").count, 1, "only the new message")
        XCTAssertFalse(message(marker).exists)
        let fresh = try await peer(a)
        try await until("server's view", timeout: 10) { self.peerConv(fresh, conv) != nil }
        XCTAssertEqual(peerConv(fresh, conv)?.minSeq, 11)
        XCTAssertEqual(probe("scan"), 0)
    }

    /// TC-CVS-04-01 (iOS as D2): my other device pins and turns notifications off: the row moves to the top, gets the
    /// background and "免打扰" within 2 seconds.
    func testTC_CVS_04_01_otherDeviceSettingsWithin2s() async throws {
        let (a, b, c) = (uid("sa"), uid("sb"), uid("sc"))
        try await importUsers([a, b, c], nicknames: [a: "甲", b: "乙乙", c: "丙丙"])
        try await say(try await peer(b), c2c(a, b), "一")
        try await say(try await peer(c), c2c(a, c), "二")
        let other = try await peer(a)
        try await launchAs(a)
        try await until("by time") { self.rowLabel(0).contains("丙丙") && self.rowLabel(1).contains("乙乙") }
        var t0 = Date()
        try await other.setConvPinned(c2c(a, b), true)
        try await until("pinned on this device", timeout: 3) { self.rowLabel(0).contains("乙乙") && self.rowLabel(0).contains("已置顶") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
        try await settle()
        t0 = Date()
        try await other.setConvNotifyOff(c2c(a, b), true)
        try await until("notifications off on this device", timeout: 3) { self.rowLabel(0).contains("免打扰") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
        try await sleep(500)
        XCTAssertTrue(near(rowBackground(all("conv-item").element(boundBy: 0)), lightPinned))
    }

    /// TC-CVS-04-02 (iOS as D2): offline (the relay is cut) while my other device pins one conversation and deletes
    /// another; after the connection is back the list is the other device's.
    func testTC_CVS_04_02_offlineChangesAfterReconnect() async throws {
        let (a, b, c, d) = (uid("oa"), uid("ob"), uid("oc"), uid("od"))
        try await importUsers([a, b, c, d], nicknames: [a: "甲", b: "乙乙", c: "丙丙", d: "丁丁"])
        for (u, t) in [(b, "一"), (c, "二"), (d, "三")] { try await say(try await peer(u), c2c(a, u), t) }
        let other = try await peer(a)
        try await until("other device has them", timeout: 10) { other.conversations().count == 3 }
        let r = TCPProxy(targetPort: try XCTUnwrap(URLComponents(string: http)?.port.map(UInt16.init)))
        try r.start()
        relay = r
        launch(env: ["TIANTING_SERVER": r.url])
        try await login(a)
        try await until("three rows") { self.all("conv-item").count == 3 }
        r.down = true
        try await see("conn-banner", timeout: 15)
        try await other.setConvPinned(c2c(a, b), true)
        try await settle()
        try await other.deleteConv(c2c(a, c))
        try await sleep(1000)
        XCTAssertEqual(all("conv-item").count, 3, "nothing reached this device yet")
        r.down = false
        try await until("as on the other device", timeout: 20) {
            self.all("conv-item").count == 2 && self.rowLabel(0).contains("乙乙") && self.rowLabel(0).contains("已置顶")
        }
        XCTAssertTrue(rowLabel(1).contains("丁丁"))
        XCTAssertEqual(other.conversations().map(\.convId), [c2c(a, b), c2c(a, d)])
    }

    /// TC-CVS-04-05 (iOS as D2), frontend-chat 55: my other device deletes two conversations: within 2 seconds both leave
    /// the list; the open one's page empties, input included; the other's saved draft is gone; the local copies are gone
    /// from the data directory. New messages bring them back without a draft.
    func testTC_CVS_04_05_otherDeviceDeleteClearsPageDraftAndDisk() async throws {
        let (a, b, c) = (uid("da"), uid("db"), uid("dc"))
        try await importUsers([a, b, c], nicknames: [a: "甲", b: "乙乙", c: "丙丙"])
        let marker = "ZXQ-CVS-5-\(uid("k"))"
        let pb = try await peer(b)
        let pc = try await peer(c)
        try await say(pb, c2c(a, b), marker + "-b")
        try await say(pc, c2c(a, c), marker + "-c")
        let other = try await peer(a)
        try await until("other device has them", timeout: 10) { other.conversations().count == 2 }
        try await launchAs(a, env: ["TT_TEST_STATE": "1", "TT_TEST_SCAN": marker])
        try await tapElement(listRow("乙乙"))
        try await see(message(marker + "-b"))
        try await typeInComposer("乙的草稿")
        try await back()
        try await until("draft saved") { self.listRow("乙乙").label.contains("[草稿] 乙的草稿") }
        try await tapElement(listRow("丙丙"))
        try await see(message(marker + "-c"))
        try await typeInComposer("丙还没发")
        try await until("on disk", timeout: 15) { self.probe("scan") > 0 }

        let t0 = Date()
        try await other.deleteConv(c2c(a, c))
        try await until("open page emptied", timeout: 3) { !self.message(marker + "-c").exists && self.composerText().isEmpty }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
        XCTAssertFalse(el("chat-probing").exists)
        try await settle()
        try await other.deleteConv(c2c(a, b))
        try await back()
        try await until("both gone from the list", timeout: 3) { self.all("conv-item").count == 0 }
        try await until("purged from disk", timeout: 20) { self.probe("scan") == 0 }

        try await say(pb, c2c(a, b), "乙又来了")
        try await say(pc, c2c(a, c), "丙又来了")
        try await see(conv("乙又来了"), timeout: 5)
        try await see(conv("丙又来了"), timeout: 5)
        XCTAssertFalse(listRow("乙乙").label.contains("[草稿]"), "the draft went with the deletion")
        try await tapElement(listRow("丙丙"))
        try await see(message("丙又来了"))
        XCTAssertEqual(composerText(), "")
    }

    /// frontend-chat 66 and F-CVS-03 rule 4: a group whose conversation I deleted, opened from "我的群聊": the page is empty
    /// with the group's name and the input, not "加载中…" and not "你已不在该群"; a message brings it back to the list.
    func testEmptyGroupFromMyGroupsIsAnEmptyChatPage() async throws {
        let (a, o) = (uid("ga"), uid("go"))
        let g = try await c4Group("删过的群", [(o, "群主"), (a, "爱丽丝")])
        try await say(try await peer(o), g.convId, "群里一条")
        try await launchAs(a)
        try await see(listRow("删过的群"))
        try await convAction(listRow("删过的群"), "删除")
        try await tap("dialog-ok")
        try await gone(listRow("删过的群"))
        try await tap("tab-contacts")
        try await tap("entry-groups")
        try await tapElement(el("group-row", labelContains: "删过的群"))
        try await see("chat-title")
        try await until("group name in the title", timeout: 5) { self.label("chat-title") == "删过的群" }
        try await see(composer)
        try await staysGone(el("chat-probing"))
        XCTAssertFalse(el("chat-blocked-tip").exists)
        XCTAssertEqual(all("message").count, 0)
        try await send("我又来了")
        try await sent("我又来了")
        try await back()
        try await back()
        try await tap("tab-chats")
        try await see(listRow("删过的群"))
    }
}

/// AC-CVS-01-6 with `features.convSettings` off (or an older server): no menu; pins and notifications off it already has
/// still show (P-46 ②). A scripted server: the real one has the switch on for the whole run.
final class C5FakeServerTests: E2ECase {
    private var fake: FakeAccountServer!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeAccountServer()
        try fake.start()
    }

    override func tearDown() async throws {
        fake.stop()
        try await super.tearDown()
    }

    func testTC_CVS_01_06_noMenuWithTheSwitchOff() async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func serverRow(_ peer: String, _ name: String, unread: Int64, pinned: Bool, notifyOff: Bool, at: Int64) -> [String: Any] {
            var o: [String: Any] = [
                "convId": "c2c:alice:\(peer)", "type": "c2c", "name": name, "maxSeq": 3, "readSeq": 3 - unread, "minSeq": 1,
                "unread": unread, "updatedAt": at,
                "lastMsg": ["msgId": "m-\(peer)", "from": peer, "type": "text", "text": "你好", "ts": at],
            ]
            if pinned {
                o["pinned"] = true
                o["pinnedAt"] = at
            }
            if notifyOff { o["notifyOff"] = true }
            return o
        }
        fake.convs = [
            serverRow("bob", "乙乙", unread: 3, pinned: true, notifyOff: true, at: now - 60_000),
            serverRow("carol", "丙丙", unread: 1, pinned: false, notifyOff: false, at: now),
        ]
        launch(env: ["TIANTING_SERVER": fake.url])
        try await see("account-username")
        try await type("alice", into: "account-username")
        try await type("pw123456", into: "account-password")
        if !el("account-submit").isHittable { app.swipeUp() }
        try await tap("account-submit")
        try await see("tab-chats")
        let pinned = listRow("乙乙")
        try await see(pinned)
        XCTAssertTrue(rowLabel(0).contains("乙乙"), "pinned first")
        XCTAssertTrue(pinned.label.contains("已置顶"))
        XCTAssertTrue(pinned.label.contains("[3 条]"))
        XCTAssertTrue(pinned.label.contains("免打扰"))
        try await sleep(500)
        XCTAssertTrue(near(rowBackground(pinned), (0xF3, 0xF4, 0xF8)), "\(rowBackground(pinned))")
        XCTAssertEqual(label("tab-badge"), "1", "notifications off adds nothing")
        pinned.press(forDuration: 1.0)
        try await staysGone(app.buttons["取消置顶"].firstMatch)
        XCTAssertFalse(app.buttons["删除"].firstMatch.exists)
        XCTAssertFalse(app.buttons["取消免打扰"].firstMatch.exists)
    }
}
