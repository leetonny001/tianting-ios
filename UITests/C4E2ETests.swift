import TiantingIM
import UIKit
import XCTest

/// Shared steps of the C4 end-to-end cases (FE-669, FE-670): the real im-server in test mode with
/// IM_MSG_ACTIONS_ENABLED=1 (scripts/e2e-server.sh), the app on the simulator, the other accounts as real `IMClient`s in the
/// test runner. Quoted text and @ content are asserted in memory, never printed.
extension E2ECase {
    /// A peer sends and waits for the ack (4290: wait and send the same message again).
    @discardableResult
    func say(_ c: IMClient, _ conv: String, _ text: String, quote: QuoteRef? = nil, mentions: Mentions? = nil) async throws
        -> Message
    {
        guard case .ok(let first) = try c.send(conv, text, quote: quote, mentions: mentions) else {
            throw E2EError.failed("send rejected")
        }
        let id = first.clientMsgId
        for _ in 0..<50 {
            try await until("peer ack", timeout: 15) {
                let s = c.messages(conv).first { $0.clientMsgId == id }?.status
                return s == .sent || s == .failed
            }
            let m = c.messages(conv).first { $0.clientMsgId == id }!
            if m.status == .sent { return m }
            try await sleep(300)
            c.retry(conv, id)
        }
        throw E2EError.failed("peer send kept failing")
    }

    /// The peer's copy of a message by text, after pulling history.
    func peerCopy(_ c: IMClient, _ conv: String, _ text: String) async -> Message? {
        _ = try? await c.loadHistory(conv)
        return c.messages(conv).first { $0.body.text == text }
    }

    func longPress(_ e: XCUIElement) async throws {
        try await see(e)
        try await sleep(300)
        e.press(forDuration: 1.0)
    }

    /// Which of the menu items show after a long press.
    func menuShown() async throws -> [String] {
        let copy = app.buttons["复制"].firstMatch
        let quote = app.buttons["引用"].firstMatch
        try await until("menu") { copy.exists || quote.exists }
        try await sleep(400)
        return ["复制", "引用", "撤回", "重发", "删除"].filter { app.buttons[$0].firstMatch.exists }
    }

    func closeMenu() async throws {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)).tap()
        try await gone(app.buttons["复制"].firstMatch, timeout: 4)
        try await gone(app.buttons["引用"].firstMatch, timeout: 4)
    }

    func toast(_ text: String, timeout: TimeInterval = 8) async throws {
        try await see(el("toast", labelContains: text), timeout: timeout)
    }

    func composerText() -> String { composer.exists ? (composer.value as? String ?? "") : "" }

    func typeInComposer(_ text: String) async throws {
        try await see(composer)
        try await focus(composer)
        composer.typeText(text)
        try await sleep(300)
    }

    func tapSend() async throws {
        try await tap("send-button") { self.composerText().isEmpty }
    }

    /// An item of the system edit menu by any of its titles (the system may label it in Chinese: 全选, 粘贴).
    func editMenu(_ titles: String...) async throws {
        try await see(composer)
        try await focus(composer)
        composer.tap()  // On a focused text view a tap opens the edit menu.
        let items = titles.flatMap { [app.menuItems[$0].firstMatch, app.buttons[$0].firstMatch] }
        try await until("edit menu \(titles)") { items.contains { $0.exists } }
        try await sleep(300)
        items.first { $0.exists }!.tap()
        try await sleep(300)
    }

    func clearComposer() async throws {
        let n = composerText().count
        if n == 0 { return }
        try await focus(composer)
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        try await sleep(300)
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: n + 2))
        try await until("composer empty") { self.composerText().isEmpty }
    }

    /// Picks a member in the @ picker by userId.
    func pickMember(_ userId: String) async throws {
        let row = el("mention-row", labelContains: userId)
        try await see(row, timeout: 10)
        try await sleep(500)  // The sheet is still moving up: a tap now can miss.
        for _ in 0..<4 {
            if row.exists, row.isHittable { row.tap() }
            try await sleep(700)
            if !el("mention-picker").exists { return }
        }
        try await gone(el("mention-picker"), timeout: 5)
    }

    func imClock(_ ms: Int64?) async throws {
        if let ms {
            try await admin("POST", "/admin/test/clock", ["nowMs": ms])
        } else {
            try await admin("POST", "/admin/test/clock", ["nowMs": NSNull()])
        }
    }

    func c4Now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func probe(_ key: String) -> Int {
        let s = el("test-state").exists ? (el("test-state").value as? String ?? "") : ""
        guard let r = s.range(of: "\(key)=") else { return -99 }
        let rest = s[r.upperBound...]
        let neg = rest.hasPrefix("-")
        let digits = (neg ? rest.dropFirst() : rest).prefix { $0.isNumber }
        return (Int(digits) ?? -99) * (neg ? -1 : 1)
    }

    /// A group with nicknames: the first one is the owner (a signed call names the owner).
    func c4Group(_ name: String, _ users: [(String, String)]) async throws -> (groupId: String, convId: String) {
        try await importUsers(users.map(\.0), nicknames: Dictionary(uniqueKeysWithValues: users))
        return try await hostedGroup(name: name, members: users.map(\.0), owner: users[0].0)
    }

    func tapElement(_ e: XCUIElement) async throws {
        try await until("hittable element") { e.exists && e.isHittable }
        e.tap()
    }

    func openConv(_ name: String) async throws {
        try await tapElement(conv(name))
        try await see("chat-title")
    }
}

/// FE-669: recall and quote; FE-670: @ and mention reminders. Test names carry the TC numbers.
@MainActor
final class C4E2ETests: E2ECase {
    /// The existing TCP proxy (AccountSupport.swift): "down" cuts the app's connections and refuses new ones; peers connect
    /// to the server directly and stay online.
    private var relay: TCPProxy?

    override func tearDown() async throws {
        relay?.stop()
        relay = nil
        try? await imClock(nil)
        try await super.tearDown()
    }

    private func startRelay() throws -> TCPProxy {
        let r = TCPProxy(targetPort: try XCTUnwrap(URLComponents(string: http)?.port.map(UInt16.init)))
        try r.start()
        relay = r
        return r
    }

    private func launchAs(_ userId: String, env: [String: String] = [:]) async throws {
        launch(env: env)
        try await login(userId)
    }

    // MARK: Recall (FE-669)

    /// TC-RCL-01-01, TC-RCL-03-10 (page part): my recall shows at once and reaches the peer and my other device within
    /// 2 seconds (plus slack for the test's polling); the peer's recall shows "对方撤回了一条消息"; the line has no menu;
    /// the page and the app's data directory no longer hold the text (AC-RCL-01-1, AC-RCL-03-10, AC-RCL-03-2 on iOS).
    func testTC_RCL_01_01_TC_RCL_03_10_recallBothSidesNoMenuOnTheLine() async throws {
        let (a, b) = (uid("ra"), uid("rb"))
        try await importUsers([a, b], nicknames: [a: "甲", b: "乙"])
        let marker = "ZXQ-RCL-\(uid("k"))"
        let bob = try await peer(b)
        let other = try await peer(a)
        let conv = c2c(a, b)
        try await launchAs(a, env: ["TT_TEST_STATE": "1", "TT_TEST_SCAN": marker])
        try await startChat(with: b)
        let mine = marker + "-1"
        try await send(mine)
        try await sent(mine)
        try await until("bob has it") { bob.messages(conv).contains { $0.body.text == mine } }
        _ = await peerCopy(other, conv, mine)
        try await until("my other device has it") { other.messages(conv).contains { $0.body.text == mine } }
        try await until("on disk before the recall", timeout: 15) { self.probe("scan") > 0 }
        let bobCopy = bob.messages(conv).first { $0.body.text == mine }!
        try await longPress(message(mine))
        let hasRecall = try await menuShown().contains("撤回")
        XCTAssertTrue(hasRecall)
        let t0 = Date()
        try await tapMenuItem("撤回")
        try await see(el("msg-recalled", labelContains: "你撤回了一条消息"), timeout: 5)
        try await until("bob sees the recall", timeout: 3) {
            bob.messages(conv).first { $0.clientMsgId == bobCopy.clientMsgId }?.recalled == true
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3.5)
        let bobRow = bob.messages(conv).first { $0.clientMsgId == bobCopy.clientMsgId }!
        XCTAssertEqual(bobRow.recalledBy, a)
        XCTAssertEqual(bob.recallText(bobRow), "对方撤回了一条消息")
        try await until("my other device sees it", timeout: 3) {
            other.messages(conv).contains { $0.seq == bobCopy.seq && $0.recalled == true }
        }
        // The peer recalls theirs.
        let theirs = marker + "-2"
        let m2 = try await say(bob, conv, theirs)
        try await see(message(theirs))
        try await bob.recall(conv, m2.msgId!)
        try await see(el("msg-recalled", labelContains: "对方撤回了一条消息"), timeout: 5)
        // The lines have no menu (F-RCL-03 rule 6).
        all("msg-recalled").firstMatch.press(forDuration: 1.0)
        try await staysGone(app.buttons["复制"].firstMatch)
        XCTAssertFalse(app.buttons["引用"].firstMatch.exists)
        XCTAssertFalse(staticText(containing: marker).exists, "no original text on the page")
        try await until("nothing on disk", timeout: 20) { self.probe("scan") == 0 }
        try await back()
        try await see(el("conv-item", labelContains: "对方撤回了一条消息"))
    }

    /// TC-RCL-01-08: "撤回" by the message's ts and server time; a menu opened before the limit and tapped after it gets
    /// 4097's "发送时间超过 2 分钟，无法撤回" and the message stays; the next long press has no "撤回" (worked out when the
    /// menu opens). [IM 钟] makes the messages 125 and 100 seconds old (AC-RCL-01-8).
    func testTC_RCL_01_08_menuByServerTimeAnd4097AfterTheLimitWhileOpen() async throws {
        let (a, b) = (uid("ta"), uid("tb"))
        try await importUsers([a, b])
        let me2 = try await peer(a)
        let conv = c2c(a, b)
        try await say(me2, conv, "先说一句")
        try await launchAs(a)
        try await openConv(b)
        try await imClock(c4Now() - 125_000)
        try await say(me2, conv, "125 秒前")
        let t100 = Date().addingTimeInterval(-100)
        try await imClock(c4Now() - 100_000)
        try await say(me2, conv, "100 秒前")
        try await imClock(nil)
        try await longPress(message("125 秒前"))
        let items1 = try await menuShown()
        XCTAssertEqual(items1, ["复制", "引用"], "over 2 minutes: no 撤回")
        try await closeMenu()
        try await longPress(message("100 秒前"))
        let items2 = try await menuShown()
        XCTAssertEqual(items2, ["复制", "引用", "撤回"])
        // The menu stays open past 120 seconds.
        while Date().timeIntervalSince(t100) < 123 { try await sleep(250) }
        try await tapMenuItem("撤回")
        try await toast("发送时间超过 2 分钟，无法撤回")
        XCTAssertTrue(message("100 秒前").exists)
        XCTAssertFalse(el("msg-recalled").exists)
        try await longPress(message("100 秒前"))
        let items3 = try await menuShown()
        XCTAssertEqual(items3, ["复制", "引用"], "worked out again on this long press")
        try await closeMenu()
    }

    /// TC-RCL-02-04, TC-RCL-02-05: admin a recalls member m's message: a, m and n see rule 1a row 3, the list summary the
    /// same; a recalling the other admin's message has "撤回" and gets "你没有权限撤回这条消息" (AC-RCL-02-4, 02-5).
    func testTC_RCL_02_04_TC_RCL_02_05_adminRecallThreeViewsAndAdmin4030() async throws {
        let (o, a, a2, m, n) = (uid("o"), uid("a"), uid("x"), uid("m"), uid("n"))
        let name = "撤回群\(uid("g"))"
        let (g, conv) = try await c4Group(
            name, [(o, "群主"), (a, "管理甲"), (a2, "管理乙"), (m, "成员丙"), (n, "成员丁")])
        let owner = try await peer(o)
        try await owner.setGroupAdmin(g, userId: a, admin: true)
        try await owner.setGroupAdmin(g, userId: a2, admin: true)
        let mc = try await peer(m)
        let nc = try await peer(n)
        let a2c = try await peer(a2)
        try await say(a2c, conv, "管理员乙的话")
        let mm = try await say(mc, conv, "成员丙的话")
        try await launchAs(a)
        try await openConv(name)
        try await longPress(message("成员丙的话"))
        let hasRecall = try await menuShown().contains("撤回")
        XCTAssertTrue(hasRecall)
        try await tapMenuItem("撤回")
        try await see(el("msg-recalled", labelContains: "你撤回了 成员丙 的一条消息"), timeout: 5)
        try await until("m sees it", timeout: 5) { mc.messages(conv).first { $0.clientMsgId == mm.clientMsgId }?.recalled == true }
        _ = await mc.getUsers([a])
        _ = await nc.getUsers([a])
        XCTAssertEqual(mc.recallText(mc.messages(conv).first { $0.clientMsgId == mm.clientMsgId }!), "管理甲撤回了你的一条消息")
        _ = await peerCopy(nc, conv, "管理员乙的话")
        try await until("n sees it", timeout: 5) { nc.messages(conv).contains { $0.recalled == true } }
        XCTAssertEqual(nc.recallText(nc.messages(conv).first { $0.recalled == true }!), "管理甲撤回了一条成员消息")
        try await until("n's list", timeout: 5) { nc.conversations().first { $0.convId == conv }?.lastMsg?.recalled == true }
        let last = nc.conversations().first { $0.convId == conv }!.lastMsg!
        XCTAssertEqual(nc.recallText(convId: conv, lastMsg: last), "管理甲撤回了一条成员消息")
        // The other admin: "撤回" is there (this side does not know roles), the server says 4030.
        try await longPress(message("管理员乙的话"))
        let hasRecall2 = try await menuShown().contains("撤回")
        XCTAssertTrue(hasRecall2)
        try await tapMenuItem("撤回")
        try await toast("你没有权限撤回这条消息")
        XCTAssertTrue(message("管理员乙的话").exists)
        try await back()
        try await see(el("conv-item", labelContains: "你撤回了 成员丙 的一条消息"))
    }

    /// TC-RCL-03-03: recalled while the app is offline (the relay is cut): after the connection is back the message turns
    /// into "对方撤回了一条消息" (AC-RCL-03-3).
    func testTC_RCL_03_03_recalledWhileOfflineShowsAfterReconnect() async throws {
        let (a, b) = (uid("oa"), uid("ob"))
        try await importUsers([a, b])
        let r = try startRelay()
        let bob = try await peer(b)
        let conv = c2c(a, b)
        let secret = "ZXQ-RCL-2-\(uid("s"))"
        let m = try await say(bob, conv, secret)
        launch(env: ["TIANTING_SERVER": r.url])
        try await login(a)
        try await openConv(b)
        try await see(message(secret))
        r.down = true
        try await see("conn-banner", timeout: 20)
        try await bob.recall(conv, m.msgId!)
        try await sleep(1500)
        XCTAssertTrue(message(secret).exists, "offline: nothing has arrived")
        r.down = false
        try await see(el("msg-recalled", labelContains: "对方撤回了一条消息"), timeout: 45)
        XCTAssertFalse(message(secret).exists)
    }

    /// TC-RCL-03-04: the app is killed, the peer recalls, the app starts cold: the recall text shows, and no file in the
    /// app's data directory holds the original (AC-RCL-03-4).
    func testTC_RCL_03_04_killedThenRecalledColdStartShowsRecallAndDiskIsClean() async throws {
        let (a, b) = (uid("ka"), uid("kb"))
        try await importUsers([a, b])
        let bob = try await peer(b)
        let conv = c2c(a, b)
        let secret = "ZXQ-RCL-1-\(uid("s"))"
        let m = try await say(bob, conv, secret)
        let env = ["TT_TEST_STATE": "1", "TT_TEST_SCAN": secret]
        try await launchAs(a, env: env)
        try await openConv(b)
        try await see(message(secret))
        try await until("in the local database", timeout: 15) { self.probe("scan") > 0 }
        app.terminate()
        try await bob.recall(conv, m.msgId!)
        launch(reset: false, env: env)
        try await see("tab-chats", timeout: 15)
        try await see(el("conv-item", labelContains: "对方撤回了一条消息"), timeout: 20)
        try await openConv(b)
        try await see(el("msg-recalled", labelContains: "对方撤回了一条消息"))
        XCTAssertFalse(message(secret).exists)
        try await until("the original is gone from disk", timeout: 20) { self.probe("scan") == 0 }
    }

    /// TC-RCL-03-06: u1 recalls the last message of a group: u1's list shows "你撤回了一条消息", n's "{u1}撤回了一条消息"
    /// (AC-RCL-03-6).
    func testTC_RCL_03_06_groupOwnLastRecallListSummary() async throws {
        let (o, a, n) = (uid("o"), uid("a"), uid("n"))
        let name = "摘要群\(uid("g"))"
        let (_, conv) = try await c4Group(name, [(o, "群主"), (a, "爱丽丝"), (n, "成员丁")])
        let nc = try await peer(n)
        try await say(try await peer(o), conv, "开始")
        try await launchAs(a)
        try await openConv(name)
        try await send("我的最后一条")
        try await sent("我的最后一条")
        try await longPress(message("我的最后一条"))
        _ = try await menuShown()
        try await tapMenuItem("撤回")
        try await see(el("msg-recalled", labelContains: "你撤回了一条消息"), timeout: 5)
        try await back()
        try await see(el("conv-item", labelContains: "你撤回了一条消息"))
        XCTAssertFalse(self.conv(name).label.contains("爱丽丝:"))
        try await until("n's list", timeout: 5) { nc.conversations().first { $0.convId == conv }?.lastMsg?.recalled == true }
        _ = await nc.getUsers([a])
        XCTAssertEqual(
            nc.recallText(convId: conv, lastMsg: nc.conversations().first { $0.convId == conv }!.lastMsg!), "爱丽丝撤回了一条消息")
    }

    // MARK: Quote (FE-669)

    /// TC-QUO-01-05 (text), TC-QUO-02-05, TC-QUO-01-01: "引用" shows the bar, cancel removes it and sends no quote; quoting
    /// and sending: the peer gets quote.state=normal with the original summary, the bubble shows it; HTML stays plain text
    /// in the bar and the bubble (AC-QUO-01-5, AC-QUO-02-5, AC-QUO-01-1).
    func testTC_QUO_01_05_TC_QUO_02_05_quoteBarCancelSendAndHtmlIsPlain() async throws {
        let (a, b) = (uid("qa"), uid("qb"))
        try await importUsers([a, b], nicknames: [a: "甲", b: "乙"])
        let bob = try await peer(b)
        let conv = c2c(a, b)
        let html = "<img src=x onerror=alert(1)><b>粗</b>ZXQ-QUO-2"
        try await say(bob, conv, html)
        try await launchAs(a)
        try await openConv("乙")  // The list shows the peer's nickname.
        try await longPress(message(html))
        _ = try await menuShown()
        try await tapMenuItem("引用")
        try await see("quote-bar")
        XCTAssertEqual(label("quote-bar-text"), "引用：乙: \(html)", "as written, not parsed")
        XCTAssertEqual(el("quote-cancel").label, "取消引用")
        try await tap("quote-cancel")
        try await gone(el("quote-bar"))
        try await send("不带引用")
        let plain = await peerCopy(bob, conv, "不带引用")
        try await until("bob got it") { bob.messages(conv).contains { $0.body.text == "不带引用" } }
        XCTAssertNil((plain ?? bob.messages(conv).first { $0.body.text == "不带引用" })?.body.quote, "cancelled: no quote")
        try await longPress(message(html))
        _ = try await menuShown()
        try await tapMenuItem("引用")
        try await see("quote-bar")
        try await send("回复你")
        try await until("bob got the quote") { bob.messages(conv).contains { $0.body.text == "回复你" } }
        let q = bob.messages(conv).first { $0.body.text == "回复你" }!.body.quote!
        XCTAssertEqual(q.state, .normal)
        XCTAssertEqual(q.text, html)
        XCTAssertFalse(el("quote-bar").exists, "sent: the bar goes")
        let block = el("msg-quote", labelContains: html)
        try await see(block, timeout: 10)
        XCTAssertEqual(block.label, "引用：乙: \(html)")
    }

    /// TC-QUO-02-03: 700 messages, about 20 loaded: a quote 100-odd above the loaded range pages up, scrolls and
    /// highlights; one 500 above says "消息太早，请翻页查看" and loads nothing (AC-QUO-02-3).
    func testTC_QUO_02_03_jumpWithin200HighlightsBeyondIsTooEarly() async throws {
        let (a, b) = (uid("ja"), uid("jb"))
        try await importUsers([a, b])
        let bob = try await peer(b)
        let conv = c2c(a, b)
        var sent: [Message] = []
        for i in 1...698 {
            sent.append(try await say(bob, conv, "第\(i)条"))
            try await sleep(40)  // The send limit is 20 a second.
        }
        let far = sent[180]  // the 181st
        let near = sent[580]  // the 581st
        try await say(bob, conv, "q2", quote: QuoteRef(msgId: far.msgId!))
        try await say(bob, conv, "q1", quote: QuoteRef(msgId: near.msgId!))
        try await launchAs(a)
        try await openConv(b)
        try await see(message("q1"))
        try await sleep(2000)
        XCTAssertFalse(message("第581条").exists, "not loaded yet")
        try await tapElement(el("msg-quote", labelContains: "第181条"))
        try await toast("消息太早，请翻页查看")
        XCTAssertFalse(message("第581条").exists, "too early: nothing was paged in")
        try await tapElement(el("msg-quote", labelContains: "第581条"))
        try await see("msg-highlight", timeout: 20)
        try await see(message("第581条"))
        XCTAssertTrue(message("第581条").isHittable, "scrolled into view")
        XCTAssertTrue(message("第582条").exists, "the loaded range stays contiguous")
        try await gone(el("msg-highlight"), timeout: 5)
    }

    // MARK: @ (FE-670)

    /// Group: owner o, a (the app), w (nickname 小王, a's remark 老板), u3.
    private func mentionGroup() async throws -> (g: String, conv: String, name: String, ids: [String], peers: [String: IMClient]) {
        let (o, a, w, u3) = (uid("o"), uid("a"), uid("w"), uid("u"))
        let name = "提醒群\(uid("g"))"
        let (g, conv) = try await c4Group(name, [(o, "群主"), (a, "爱丽丝"), (w, "小王"), (u3, "路人")])
        try await makeFriends(a, w, remarkA: "老板")
        let oc = try await peer(o)
        let wc = try await peer(w)
        let u3c = try await peer(u3)
        try await say(oc, conv, "大家好")
        return (g, conv, name, [o, a, w, u3], ["o": oc, "w": wc, "u3": u3c])
    }

    /// TC-MEN-01-01, TC-MEN-01-07: @ picks w (the list shows the remark 老板 and the userId), the text has the nickname
    /// "@小王 ", w gets mentions=[w] and "[有人@我]" (mentionUnread 1), u3 does not; nothing has 老板 (AC-MEN-01-1, 01-7).
    func testTC_MEN_01_01_TC_MEN_01_07_nicknameNotRemarkU2FlaggedU3Not() async throws {
        let g = try await mentionGroup()
        let (a, w) = (g.ids[1], g.ids[2])
        try await launchAs(a)
        try await openConv(g.name)
        try await typeInComposer("@")
        try await see("mention-picker", timeout: 10)
        let row = el("mention-row", labelContains: w)
        try await see(row, timeout: 10)
        XCTAssertTrue(row.label.contains("老板"), "the picker shows the remark")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'mention-row' AND label CONTAINS %@", a)).firstMatch.exists, "not me")
        try await pickMember(w)
        try await until("inserted") { self.composerText() == "@小王 " }
        try await typeInComposer("看一下ZXQ-MEN-1")
        try await tapSend()
        let wc = g.peers["w"]!
        let text = "@小王 看一下ZXQ-MEN-1"
        try await until("w got it") { wc.messages(g.conv).contains { $0.body.text == text } }
        let got = wc.messages(g.conv).first { $0.body.text == text }!
        XCTAssertEqual(got.body.mentions?.userIds, [w])
        XCTAssertFalse(got.body.text!.contains("老板"))
        try await until("w's [有人@我]", timeout: 10) { wc.conversations().first { $0.convId == g.conv }?.mentionUnread == 1 }
        let u3c = g.peers["u3"]!
        _ = await peerCopy(u3c, g.conv, text)
        try await until("u3 got it") { u3c.messages(g.conv).contains { $0.body.text == text } }
        XCTAssertEqual(u3c.conversations().first { $0.convId == g.conv }?.mentionUnread ?? 0, 0)
    }

    /// TC-MEN-01-05, TC-MEN-01-12: the inserted "@小王 " replaced by other text sends no mentions; one backspace right after
    /// "你好 @小王 " removes all of it and sends none (AC-MEN-01-5, 01-12).
    func testTC_MEN_01_05_TC_MEN_01_12_deletedOrBackspacedMentionIsNotSent() async throws {
        let g = try await mentionGroup()
        let (a, w) = (g.ids[1], g.ids[2])
        try await launchAs(a)
        try await openConv(g.name)
        try await typeInComposer("@")
        try await pickMember(w)
        try await until("inserted") { self.composerText() == "@小王 " }
        try await editMenu("Select All", "全选")
        composer.typeText("删掉了")
        try await until("replaced") { self.composerText() == "删掉了" }
        try await tapSend()
        try await typeInComposer("你好 @")
        try await pickMember(w)
        try await until("inserted") { self.composerText() == "你好 @小王 " }
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        try await until("one backspace removes the mention") { self.composerText() == "你好 " }
        try await typeInComposer("退格了")
        try await tapSend()
        let wc = g.peers["w"]!
        try await until("w got both") {
            wc.messages(g.conv).contains { $0.body.text == "删掉了" } && wc.messages(g.conv).contains { $0.body.text == "你好 退格了" }
        }
        XCTAssertNil(wc.messages(g.conv).first { $0.body.text == "删掉了" }!.body.mentions)
        XCTAssertNil(wc.messages(g.conv).first { $0.body.text == "你好 退格了" }!.body.mentions)
        XCTAssertEqual(wc.conversations().first { $0.convId == g.conv }?.mentionUnread ?? 0, 0)
    }

    /// TC-MEN-01-06: in a single chat @ opens nothing and stays as a character (AC-MEN-01-6).
    func testTC_MEN_01_06_singleChatAtOpensNoPicker() async throws {
        let (a, b) = (uid("sa"), uid("sb"))
        try await importUsers([a, b])
        let bob = try await peer(b)
        try await say(bob, c2c(a, b), "在吗")
        try await launchAs(a)
        try await openConv(b)
        try await typeInComposer("@")
        try await staysGone(el("mention-picker"))
        XCTAssertEqual(composerText(), "@")
    }

    /// TC-MEN-01-08: a@b.com opens nothing; a full-width ＠ at the line start opens the picker; a pasted "@w" sends no
    /// mentions (AC-MEN-01-8).
    func testTC_MEN_01_08_emailNoFullWidthYesPasteNoMentions() async throws {
        let g = try await mentionGroup()
        let (a, w) = (g.ids[1], g.ids[2])
        try await launchAs(a)
        try await openConv(g.name)
        try await typeInComposer("a@b.com")
        try await staysGone(el("mention-picker"))
        try await clearComposer()
        try await typeInComposer("＠")
        try await see("mention-picker", timeout: 10)
        try await tap("mention-cancel")
        try await gone(el("mention-picker"))
        XCTAssertEqual(composerText(), "＠", "closed: the @ stays as text")
        try await clearComposer()
        UIPasteboard.general.string = "@\(w) 粘贴的"
        try await editMenu("Paste", "粘贴")
        try await until("pasted") { self.composerText() == "@\(w) 粘贴的" }
        try await staysGone(el("mention-picker"))
        try await tapSend()
        let wc = g.peers["w"]!
        try await until("w got it") { wc.messages(g.conv).contains { $0.body.text == "@\(w) 粘贴的" } }
        XCTAssertNil(wc.messages(g.conv).first { $0.body.text == "@\(w) 粘贴的" }!.body.mentions)
    }

    /// TC-MEN-01-10: text, an @ and a quote kept as a draft: the list shows "[草稿]", coming back restores all three, and
    /// sending mentions w with the quote (AC-MEN-01-10).
    func testTC_MEN_01_10_draftKeepsTextMentionAndQuote() async throws {
        let g = try await mentionGroup()
        let (a, w) = (g.ids[1], g.ids[2])
        try await say(g.peers["o"]!, g.conv, "群主的通知")
        try await launchAs(a)
        try await openConv(g.name)
        try await longPress(message("群主的通知"))
        _ = try await menuShown()
        try await tapMenuItem("引用")
        try await see("quote-bar")
        try await typeInComposer("收到 @")
        try await pickMember(w)
        try await until("inserted") { self.composerText() == "收到 @小王 " }
        try await back()
        try await see(el("conv-item", labelContains: "[草稿] 收到 @小王"))
        try await openConv(g.name)
        try await see("quote-bar")
        XCTAssertEqual(label("quote-bar-text"), "引用：群主: 群主的通知")
        XCTAssertEqual(composerText(), "收到 @小王 ")
        try await tapSend()
        let wc = g.peers["w"]!
        try await until("w got it") {
            wc.messages(g.conv).contains { $0.body.text?.hasPrefix("收到 @小王") == true }
        }
        let got = wc.messages(g.conv).first { $0.body.text?.hasPrefix("收到 @小王") == true }!
        XCTAssertEqual(got.body.mentions?.userIds, [w])
        XCTAssertEqual(got.body.quote?.text, "群主的通知")
        try await until("w is mentioned", timeout: 10) { wc.conversations().first { $0.convId == g.conv }?.mentionUnread == 1 }
    }

    /// TC-MEN-02-04: a member's picker has no "所有人"; once an admin it has, and "@所有人" sends mentions.all
    /// (AC-MEN-02-4).
    func testTC_MEN_02_04_allOnlyForOwnerAndAdmin() async throws {
        let g = try await mentionGroup()
        let a = g.ids[1]
        try await launchAs(a)
        try await openConv(g.name)
        try await typeInComposer("@")
        try await see(el("mention-row"), timeout: 10)
        XCTAssertFalse(el("mention-all").exists, "a member does not see 所有人")
        try await tap("mention-cancel")
        try await gone(el("mention-picker"))
        try await g.peers["o"]!.setGroupAdmin(g.g, userId: a, admin: true)
        try await sleep(1500)
        try await clearComposer()
        try await typeInComposer("@")
        try await see("mention-all", timeout: 10)
        XCTAssertEqual(el("mention-all").label, "所有人")
        try await sleep(500)
        try await tap("mention-all")
        try await gone(el("mention-picker"))
        try await until("inserted") { self.composerText() == "@所有人 " }
        try await typeInComposer("开会")
        try await tapSend()
        let wc = g.peers["w"]!
        try await until("w got it") { wc.messages(g.conv).contains { $0.body.text == "@所有人 开会" } }
        XCTAssertEqual(wc.messages(g.conv).first { $0.body.text == "@所有人 开会" }!.body.mentions?.all, true)
    }

    /// TC-MEN-02-05: the fourth "@所有人" in an hour: the message fails, "@所有人次数已用完" shows, and after the connection
    /// drops and comes back it is not sent again (AC-MEN-02-5).
    func testTC_MEN_02_05_4293FailsToastsAndIsNotResentAfterReconnect() async throws {
        let (a, o) = (uid("a"), uid("o"))
        let name = "次数群\(uid("g"))"
        let (_, conv) = try await c4Group(name, [(a, "爱丽丝"), (o, "成员")])
        let other = try await peer(a)  // the same user's other device uses the hour's three
        for i in 1...3 { try await say(other, conv, "@所有人 第\(i)次", mentions: Mentions(all: true)) }
        let oc = try await peer(o)
        let r = try startRelay()
        launch(env: ["TIANTING_SERVER": r.url])
        try await login(a)
        try await openConv(name)
        try await typeInComposer("@")
        try await see("mention-all", timeout: 10)
        try await sleep(500)
        try await tap("mention-all")
        try await gone(el("mention-picker"))
        try await typeInComposer("第4次")
        try await tapSend()
        try await toast("@所有人次数已用完")
        try await see("failed-icon", timeout: 5)
        r.down = true
        try await see("conn-banner", timeout: 20)
        r.down = false
        try await gone(el("conn-banner"), timeout: 45)
        try await sleep(3000)
        _ = try? await oc.loadHistory(conv)
        XCTAssertFalse(oc.messages(conv).contains { $0.body.text == "@所有人 第4次" }, "never sent again")
        XCTAssertTrue(el("failed-icon").exists)
    }

    /// TC-MEN-03-05: a conversation with a draft that mentions me: the list shows "[有人@我]", not "[草稿]" (AC-MEN-03-5).
    func testTC_MEN_03_05_mentionBeatsDraftInTheList() async throws {
        let g = try await mentionGroup()
        let a = g.ids[1]
        try await launchAs(a)
        try await openConv(g.name)
        try await typeInComposer("我的草稿")
        try await back()
        try await see(el("conv-item", labelContains: "[草稿] 我的草稿"))
        try await say(g.peers["o"]!, g.conv, "@爱丽丝 看一下", mentions: Mentions(userIds: [a]))
        let row = el("conv-item", labelContains: "[有人@我]")
        try await see(row, timeout: 10)
        XCTAssertFalse(row.label.contains("[草稿]"))
        XCTAssertTrue(row.label.contains("@爱丽丝 看一下"), "with a mention the last message follows (issue 38)")
    }

    /// TC-MEN-03-06: 100 unread with the mention at the 10th: "有人@我" shows, a tap pages up to it, scrolls, highlights,
    /// and the button goes (AC-MEN-03-6).
    func testTC_MEN_03_06_hundredUnreadJumpButton() async throws {
        let (o, a) = (uid("o"), uid("a"))
        let name = "百条群\(uid("g"))"
        let (_, conv) = try await c4Group(name, [(o, "群主"), (a, "爱丽丝")])
        let oc = try await peer(o)
        for i in 1...100 {
            if i == 10 {
                try await say(oc, conv, "第10条@爱丽丝", mentions: Mentions(userIds: [a]))
            } else {
                try await say(oc, conv, "第\(i)条")
            }
            try await sleep(40)
        }
        try await launchAs(a)
        try await see(el("conv-item", labelContains: "[有人@我]"), timeout: 10)
        try await openConv(name)
        try await see(message("第100条"))
        try await see("mention-jump", timeout: 5)
        XCTAssertEqual(el("mention-jump").label, "有人@我，点击查看")
        try await tap("mention-jump")
        try await see("msg-highlight", timeout: 20)
        let target = message("第10条@爱丽丝")
        try await see(target)
        XCTAssertTrue(target.label.contains("提到了你"), "the mentioned bubble says so")
        XCTAssertTrue(target.isHittable)
        XCTAssertFalse(el("mention-jump").exists, "the button goes")
    }

    // MARK: Accessibility (AC-CHAT-90-8, 90-9)

    /// TC-CHAT-90-30, TC-CHAT-90-31 (iOS): the menu items, the recall line, the quote bar and the quote on a bubble, the @
    /// picker and its "所有人" have names; the system audit finds no element without a description; light and dark
    /// screenshots. No new icon (the cancel uses `close` from PRD-ui 6.6); colors are tokens (check_sources.py).
    func testTC_CHAT_90_30_TC_CHAT_90_31_c4PagesNamedLightAndDark() async throws {
        let g = try await mentionGroup()
        let (o, a) = (g.ids[0], g.ids[1])
        _ = o
        let wc = g.peers["w"]!
        try await say(wc, g.conv, "要引用的话")
        let gone1 = try await say(wc, g.conv, "要撤回的话")
        try await wc.recall(g.conv, gone1.msgId!)
        let first = wc.messages(g.conv).first { $0.body.text == "要引用的话" }!
        try await say(wc, g.conv, "带引用", quote: QuoteRef(msgId: first.msgId!))
        try await g.peers["o"]!.setGroupAdmin(g.g, userId: a, admin: true)
        try await launchAs(a)
        try await openConv(g.name)
        try await see(el("msg-recalled", labelContains: "老板撤回了一条消息"))  // a remark is the local display name
        try await see(el("msg-quote", labelContains: "要引用的话"))
        try await longPress(message("要引用的话"))
        let shown = try await menuShown()
        XCTAssertEqual(shown, ["复制", "引用", "撤回"])
        try await tapMenuItem("引用")
        try await see("quote-bar")
        try audit()
        for mode in ["light", "dark"] {
            try await setSystemAppearance(mode)
            try await sleep(600)
            capture("tc-chat-90-30-chat-\(mode)")
        }
        try await typeInComposer("@")
        try await see("mention-all", timeout: 10)
        try await see(el("mention-row"), timeout: 10)
        XCTAssertEqual(el("mention-search").label, "搜索群成员")
        try audit()
        capture("tc-chat-90-30-picker-dark")
        try await setSystemAppearance("light")
        try await sleep(600)
        capture("tc-chat-90-30-picker-light")
        try await tap("mention-cancel")
    }

    private func audit() throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription]) { issue in
            print("A11Y-ISSUE \(issue.compactDescription): \(issue.element?.debugDescription.prefix(200) ?? "-")")
            return false
        }
    }
}
