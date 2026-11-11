import TiantingIM
import UIKit
import XCTest

/// Shared steps of the C6 end-to-end cases (FE-695): the real im-server in test mode with IM_MOD_ENABLED=1, a test-only
/// IM_REPORT_KEY and a caller with moderation.words and report.read (scripts/e2e-server.sh). Words are marker strings
/// made up per test (ZXQ-MOD-…, which check_e2e_leftovers.py looks for in os_log), never real ones; they are never
/// printed.
extension E2ECase {
    /// The message menu after a long press, top to bottom, including "举报".
    func c6Menu(_ e: XCUIElement) async throws -> [String] {
        try await longPress(e)
        let titles = ["复制", "引用", "撤回", "举报", "重发", "删除"]
        try await until("menu") { titles.contains { self.app.buttons[$0].firstMatch.exists } }
        try await sleep(400)
        let shown = titles.filter { app.buttons[$0].firstMatch.exists }
        return shown.sorted { app.buttons[$0].firstMatch.frame.minY < app.buttons[$1].firstMatch.frame.minY }
    }

    func closeC6Menu() async throws {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.2)).tap()
        for t in ["复制", "举报", "删除"] { try await gone(app.buttons[t].firstMatch, timeout: 4) }
    }

    /// Adds a word to the list (signed, moderation.words) and waits until the server blocks it: the list applies within
    /// 10 seconds (AC-MOD-01-1). A probe pair of users sends until one message fails with 4510.
    func addWord(_ word: String) async throws {
        try await signed("POST", "/admin/moderation/words", ["word": word])
        let (p, q) = (uid("pp"), uid("pq"))
        try await importUsers([p, q])
        let probe = try await peer(p)
        let conv = c2c(p, q)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard case .ok(let m) = try probe.send(conv, "探针 \(word) \(uid("n"))") else { throw E2EError.failed("probe") }
            try await until("probe settled", timeout: 12) {
                let s = probe.messages(conv).first { $0.clientMsgId == m.clientMsgId }?.status
                return s == .sent || s == .failed
            }
            if probe.messages(conv).first(where: { $0.clientMsgId == m.clientMsgId })?.error == .code(4510) { return }
            try await sleep(500)
        }
        XCTFail("the word was never applied")
        throw E2EError.failed("word")
    }

    /// The report queue (GET /admin/reports, report.read): one item per target, newest first.
    func reportQueue() async throws -> [[String: Any]] {
        try await signed("GET", "/admin/reports")["items"] as? [[String: Any]] ?? []
    }

    func latestAt(_ item: [String: Any]) -> Int64 {
        (item["latestAt"] as? NSNumber)?.int64Value ?? 0
    }

    /// Fails and stops the test when the element is gone: reading its value afterwards would only stall the run.
    func mustExist(_ id: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard el(id).exists else {
            XCTFail("\(id): \(why)", file: file, line: line)
            throw E2EError.failed(id)
        }
    }

    func pickReason(_ reason: String) async throws {
        let e = el("report-reason-\(reason)")
        try await tap("report-reason-\(reason)") { (e.value as? String) == "已选择" }
    }

    /// The user card's "更多" menu, by its item titles.
    func userMenu() async throws -> [String] {
        try await tap("user-more")
        let titles = ["设置备注", "加入黑名单", "移出黑名单", "删除朋友", "举报"]
        try await until("user menu") { titles.contains { self.app.buttons[$0].firstMatch.exists } }
        try await sleep(400)
        return titles.filter { app.buttons[$0].firstMatch.exists }
    }

    func closeUserMenu() async throws {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        try await gone(app.buttons["加入黑名单"].firstMatch, timeout: 4)
        try await gone(app.buttons["移出黑名单"].firstMatch, timeout: 4)
    }

    /// The other device reports `n` times (4040s count too, backend 115) until my daily quota (IM_REPORT_DAILY, 20) is gone.
    func useUpReports(_ other: IMClient) async throws {
        for _ in 0..<40 {
            do {
                _ = try await other.report(.user(uid("nobody"), reason: .spam))
            } catch let e as IMError where e.code == 4292 {
                return
            } catch let e as IMError where e.code == 4290 {
                try await sleep(600)
            } catch {}
        }
        XCTFail("quota never ran out")
    }
}

/// FE-695: the report entries, the report sheet and 4510's copy on iOS. Test names carry the TC numbers or the
/// frontend-chat issue numbers; the same cases as tianting-web e2e/c6.spec.ts and tianting-android C6E2eTest / C6UiTest.
@MainActor
final class C6E2ETests: E2ECase {
    private var relay: TCPProxy?
    private var faultOn = false

    override func tearDown() async throws {
        relay?.stop()
        relay = nil
        if faultOn { try? await admin("POST", "/admin/test/faults", ["evidenceWrite": false]) }
        try? await setSystemAppearance("light")
        try await super.tearDown()
    }

    private func launchAs(_ userId: String, env: [String: String] = [:]) async throws {
        launch(env: env)
        try await login(userId)
    }

    // MARK: Message menu and the c2c report (AC-MOD-03-1 page part, AC-MOD-03-9)

    /// TC-MOD-03-09 (iOS), frontend-chat 77, 78, 79: "举报" is on someone else's sent message and not on my own. The
    /// sheet: six reasons in order, none chosen, "提交" disabled until one is, the hint "所选内容将提交给平台审核". Success says
    /// "已提交，感谢你的反馈", then asks about blocking the sender; "加入黑名单" blocks them. The report is in the queue
    /// (AC-MOD-03-1) and the reported user's client hears nothing about it.
    func testTC_MOD_03_09_c2cMessageReportHintToastThenBlock() async throws {
        let (a, b) = (uid("ma"), uid("mb"))
        try await importUsers([a, b], nicknames: [a: "甲", b: "乙乙"])
        let bob = try await peer(b)
        let other = try await peer(a)
        let conv = c2c(a, b)
        try await say(bob, conv, "要举报的话")
        try await launchAs(a)
        try await openConv("乙乙")
        try await see(message("要举报的话"))
        try await send("我说的话")
        try await sent("我说的话")
        let mine = try await c6Menu(message("我说的话"))
        XCTAssertFalse(mine.contains("举报"), "not on my own: \(mine)")
        try await closeC6Menu()
        let shown = try await c6Menu(message("要举报的话"))
        XCTAssertEqual(shown, ["复制", "引用", "举报"])
        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        var bobEvents = 0
        let sub = bob.on { e in
            if case .messages = e { bobEvents += 1 }
        }
        defer { sub.cancel() }
        try await tapMenuItem("举报")
        try await see("report-sheet")
        XCTAssertEqual(label("report-hint"), "所选内容将提交给平台审核")
        let reasons = [("spam", "垃圾广告"), ("abuse", "辱骂骚扰"), ("porn", "色情低俗"), ("fraud", "诈骗"), ("illegal", "违法违规"), ("other", "其他")]
        for (k, title) in reasons {
            XCTAssertEqual(el("report-reason-\(k)").label, title)
            XCTAssertEqual(el("report-reason-\(k)").value as? String, "未选择", k)
        }
        let ys = reasons.map { el("report-reason-\($0.0)").frame.minY }
        XCTAssertEqual(ys, ys.sorted(), "the order of frontend-chat 78")
        XCTAssertFalse(el("report-submit").isEnabled, "no reason yet")
        try await pickReason("abuse")
        XCTAssertTrue(el("report-submit").isEnabled)
        try await tap("report-submit")
        try await toast("已提交，感谢你的反馈")
        try await see("report-block-dialog")
        XCTAssertFalse(el("report-sheet").exists)
        XCTAssertTrue(label("dialog-text").hasPrefix("要把对方加入黑名单吗？"), label("dialog-text"))
        try await sleep(1000)
        XCTAssertEqual(bobEvents, 0, "the reported user hears nothing (F-MOD-03 rule 7)")
        try await tap("dialog-ok")
        try await until("blocked", timeout: 5) { other.blocks().contains { $0.userId == b } }
        let queue = try await reportQueue()
        XCTAssertTrue(
            queue.contains {
                $0["targetType"] as? String == "message" && $0["convType"] as? String == "c2c" && latestAt($0) >= t0 - 1000
            }, "in the queue")
    }

    // MARK: Recall lines (AC-MOD-03-11 page part, frontend-chat 89, 93)

    /// TC-MOD-03-11 (iOS): in a group where I am an admin, someone else's message they recalled has "举报" after the line
    /// (named "举报这条消息", at least 44 × 44, the line's words unchanged); my own message recalled by the owner and the
    /// message I recalled myself have none (frontend-chat 89). "撤回" comes before "举报" in the menu (13.3). The report
    /// asks nothing about blocking (79) and is in the queue with the group and the msgId.
    func testTC_MOD_03_11_recallLineReportOnlyWhenSomeoneElseRecalled() async throws {
        let (o, w, a) = (uid("go"), uid("gw"), uid("ga"))
        let g = try await c4Group("举报群", [(o, "群主"), (w, "丙丙"), (a, "甲")])
        let owner = try await peer(o)
        let wc = try await peer(w)
        try await owner.setGroupAdmin(g.groupId, userId: a, admin: true)
        let gone1 = try await say(wc, g.convId, "丙要撤回的话")
        try await say(wc, g.convId, "丙的另一句")
        try await launchAs(a)
        try await openConv("举报群")
        try await see(message("丙的另一句"))
        try await wc.recall(g.convId, gone1.msgId!)
        let line = el("msg-recalled", labelContains: "丙丙撤回了一条消息")
        try await see(line)
        XCTAssertEqual(line.label, "丙丙撤回了一条消息", "the line's words are unchanged")
        try await see("recall-report")
        let r = el("recall-report")
        XCTAssertEqual(r.label, "举报这条消息")
        XCTAssertGreaterThanOrEqual(r.frame.width, 43.99)  // 44 pt, with float noise
        XCTAssertGreaterThanOrEqual(r.frame.height, 43.99)
        XCTAssertTrue(r.isHittable)

        // The menu: 撤回 then 举报 (I am an admin).
        let menu = try await c6Menu(message("丙的另一句"))
        XCTAssertEqual(menu, ["复制", "引用", "撤回", "举报"])
        try await tapMenuItem("撤回")
        try await see(el("msg-recalled", labelContains: "你撤回了"))
        // My own message recalled by the owner.
        try await send("甲的话")
        try await sent("甲的话")
        let copy = await peerCopy(owner, g.convId, "甲的话")
        let mineOnServer = try XCTUnwrap(copy)
        try await owner.recall(g.convId, mineOnServer.msgId!)
        try await see(el("msg-recalled", labelContains: "群主撤回了"))
        try await sleep(1000)
        XCTAssertEqual(all("recall-report").count, 1, "only the line of 丙's own recall")

        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        try await tap("recall-report")
        try await see("report-sheet")
        try await pickReason("illegal")
        try await tap("report-submit")
        try await toast("已提交，感谢你的反馈")
        try await gone(el("report-sheet"))
        try await staysGone(el("report-block-dialog"))
        let queue = try await reportQueue()
        XCTAssertTrue(
            queue.contains {
                $0["convId"] as? String == g.convId && ($0["msgIds"] as? [String]) == [gone1.msgId!] && latestAt($0) >= t0 - 1000
            }, "the group message is in the queue")
    }

    /// frontend-chat 92: "举报" only on what this device has read (seq ≤ readSeq). With the app in the background a new
    /// message is not read (my other device sees readSeq stay); back in the foreground it is read and the recall line
    /// gets its "举报" without reopening the page.
    func testIssue92ReportOnlyAfterReadAndTheLineFollows() async throws {
        let (o, w, a) = (uid("ro"), uid("rw"), uid("ra"))
        let g = try await c4Group("已读群", [(o, "群主"), (w, "丙丙"), (a, "甲")])
        let wc = try await peer(w)
        let other = try await peer(a)
        try await say(wc, g.convId, "先来一句")
        try await launchAs(a)
        try await openConv("已读群")
        try await see(message("先来一句"))
        try await sleep(1500)  // reads are reported at most once a second
        XCUIDevice.shared.press(.home)
        try await until("in the background") { self.app.state != .runningForeground }
        let late = try await say(wc, g.convId, "后台时的话")
        try await wc.recall(g.convId, late.msgId!)
        try await sleep(2500)
        _ = try? await other.loadHistory(g.convId)
        XCTAssertLessThan(peerConv(other, g.convId)?.readSeq ?? 0, late.seq!, "not read while in the background")
        app.activate()
        try await see(el("msg-recalled", labelContains: "丙丙撤回了一条消息"), timeout: 15)
        try await see("recall-report", timeout: 10)
        try await until("read now", timeout: 10) { (self.peerConv(other, g.convId)?.readSeq ?? 0) >= late.seq! }
    }

    // MARK: The user card and the group (F-MOD-03 rule 8, frontend-chat 77, 79, 83)

    /// frontend-chat 77, 79, 83: the user card's menu has "举报" (not for myself). After the report "取消" does not block;
    /// once blocked, a second report asks nothing. A stranger with no relation is 4040 "无法举报该内容" and the sheet closes.
    func testIssue79UserCardReportCancelThenBlockedAsksNothing4040Closes() async throws {
        let (a, b, s) = (uid("ua"), uid("ub"), uid("us"))
        try await importUsers([a, b, s], nicknames: [a: "甲", b: "乙乙", s: "陌生人"])
        let bob = try await peer(b)
        let other = try await peer(a)
        try await say(bob, c2c(a, b), "你好")
        try await launchAs(a)
        try await openConv("乙乙")
        try await see(message("你好"))
        try await send("我自己")
        try await sent("我自己")
        // My own card has no menu at all.
        let avatars = all("msg-avatar")
        try await tapElement(avatars.element(boundBy: avatars.count - 1))
        try await see("user-id")
        XCTAssertTrue(label("user-id").contains(a))
        XCTAssertFalse(el("user-more").exists, "nothing to report about myself")
        try await back()
        try await tapElement(all("msg-avatar").element(boundBy: 0))
        try await see("user-more")
        let items = try await userMenu()
        XCTAssertEqual(items.last, "举报", "\(items)")
        try await tapMenuItem("举报")
        try await see("report-sheet")
        try await pickReason("spam")
        try await tap("report-submit")
        try await toast("已提交，感谢你的反馈")
        try await see("report-block-dialog")
        try await tap("dialog-cancel")
        try await gone(el("report-block-dialog"))
        try await sleep(1500)
        XCTAssertFalse(other.blocks().contains { $0.userId == b }, "cancel does not block")
        _ = try await userMenu()
        try await tapMenuItem("加入黑名单")
        try await tap("dialog-ok")
        try await see("user-blocked")
        _ = try await userMenu()
        try await tapMenuItem("举报")
        try await see("report-sheet")
        try await pickReason("other")
        try await tap("report-submit")
        try await toast("已提交，感谢你的反馈")
        try await gone(el("report-sheet"))
        try await staysGone(el("report-block-dialog"))

        // A stranger: no friend, no chat, no group in common.
        openLink("tianting://user/\(s)")
        try await see(el("user-id", labelContains: s))
        _ = try await userMenu()
        try await tapMenuItem("举报")
        try await see("report-sheet")
        try await pickReason("fraud")
        try await tap("report-submit")
        try await toast("无法举报该内容")
        try await gone(el("report-sheet"))
    }

    /// F-MOD-03 rule 8, frontend-chat 77, 79, 83: the group settings page of a current member has "举报"; it asks nothing
    /// about blocking. Once my daily quota is gone (4292) the sheet says "今天的举报次数已用完" and closes.
    func testGroupSettingsReportNoBlockQuestionThen4292Closes() async throws {
        let (o, a) = (uid("so"), uid("sa"))
        let g = try await c4Group("设置群", [(o, "群主"), (a, "甲"), (uid("sw"), "丙")])
        let other = try await peer(a)
        try await launchAs(a)
        try await openConv("设置群")
        try await tap("chat-more")
        try await see("group-report")
        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        try await tap("group-report")
        try await see("report-sheet")
        try await pickReason("porn")
        try await tap("report-submit")
        try await toast("已提交，感谢你的反馈")
        try await gone(el("report-sheet"))
        try await staysGone(el("report-block-dialog"))
        let queue = try await reportQueue()
        XCTAssertTrue(queue.contains { $0["groupId"] as? String == g.groupId && latestAt($0) >= t0 - 1000 })

        try await useUpReports(other)
        try await tap("group-report")
        try await see("report-sheet")
        try await pickReason("spam")
        try await tap("report-submit")
        try await toast("今天的举报次数已用完")
        try await gone(el("report-sheet"))
    }

    // MARK: Failures keep the form (frontend-chat 83, 84; FE-693 item 2)

    /// frontend-chat 83, 84: while it submits the button says "提交中…", "取消" and the scrim do nothing; a timeout says
    /// "网络异常，请稍后重试" and keeps the reason and the note; a server error (5000, evidence write failing) keeps them too;
    /// nothing goes out again by itself; a manual "提交" then succeeds. The note: a paste over 200 code points is cut with
    /// a hint, one more key does nothing.
    func testIssue83TimeoutAnd5000KeepTheFormForAManualRetry() async throws {
        let (a, b) = (uid("fa"), uid("fb"))
        try await importUsers([a, b], nicknames: [a: "甲", b: "乙乙"])
        let bob = try await peer(b)
        try await say(bob, c2c(a, b), "要举报的话")
        let r = TCPProxy(targetPort: try XCTUnwrap(URLComponents(string: http)?.port.map(UInt16.init)))
        try r.start()
        relay = r
        try await launchAs(a, env: ["TIANTING_SERVER": r.url])
        try await openConv("乙乙")
        _ = try await c6Menu(message("要举报的话"))
        try await tapMenuItem("举报")
        try await see("report-sheet")
        try await pickReason("fraud")

        // The note (frontend-chat 84): a long paste is cut to 200 with a hint; a key at 200 does nothing.
        UIPasteboard.general.string = String(repeating: "长", count: 250)
        let note = el("report-note")
        try await focus(note)
        note.tap()
        let pastes = [app.menuItems["Paste"].firstMatch, app.buttons["Paste"].firstMatch, app.menuItems["粘贴"].firstMatch]
        try await until("edit menu") { pastes.contains { $0.exists } }
        try await sleep(300)
        pastes.first { $0.exists }!.tap()
        try await see("report-clipped")
        XCTAssertEqual(label("report-clipped"), "补充说明最多 200 个字，超出的部分已去掉")
        XCTAssertEqual(label("report-count"), "已输入 200 个字，最多 200 个")
        XCTAssertEqual((note.value as? String)?.count, 200)
        note.typeText("多")
        try await sleep(500)
        XCTAssertEqual(label("report-count"), "已输入 200 个字，最多 200 个", "typing stops at 200")
        XCTAssertEqual((note.value as? String)?.count, 200)
        XCTAssertFalse(el("report-clipped").exists)
        try await tap("report-reason-fraud")  // A reason takes the focus off the note: the keyboard goes.
        try await until("keyboard gone") { !self.app.keyboards.firstMatch.exists }

        // 5000: the evidence write fails on the server. The form stays as filled in; nothing is sent again by itself.
        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        try await admin("POST", "/admin/test/faults", ["evidenceWrite": true])
        faultOn = true
        try await tap("report-submit")
        try await toast("服务异常，请稍后重试")
        try mustExist("report-sheet", "kept")
        XCTAssertEqual(el("report-reason-fraud").value as? String, "已选择")
        XCTAssertEqual((note.value as? String)?.count, 200)
        try await admin("POST", "/admin/test/faults", ["evidenceWrite": false])
        faultOn = false
        try await sleep(2500)
        XCTAssertEqual(el("report-submit").label, "提交", "not retried by itself")
        let queue = try await reportQueue()
        XCTAssertFalse(
            queue.contains { ($0["convType"] as? String) == "c2c" && self.latestAt($0) >= t0 - 1000 }, "no record (AC-MOD-03-14)")

        // A timeout: the ack never comes back. While it runs the sheet is locked.
        r.holdResponses = true
        try await tap("report-submit")
        try await until("submitting") { self.el("report-submit").label == "提交中…" }
        XCTAssertFalse(el("report-submit").isEnabled)
        XCTAssertFalse(el("report-cancel").isEnabled)
        XCTAssertFalse(el("report-reason-spam").isEnabled)
        el("report-sheet-scrim").tap()
        try await sleep(800)
        try mustExist("report-sheet", "locked while submitting")
        try await toast("网络异常，请稍后重试", timeout: 15)
        try mustExist("report-sheet", "kept")
        XCTAssertEqual(el("report-reason-fraud").value as? String, "已选择")
        XCTAssertEqual((note.value as? String)?.count, 200)
        XCTAssertEqual(el("report-submit").label, "提交")
        r.holdResponses = false
        r.down = true
        try await sleep(500)
        r.down = false
        try await until("back online", timeout: 15) { r.upgrades >= 2 }
        try await sleep(1500)
        try mustExist("report-sheet", "still there after the reconnect")

        // The manual resubmit (the server kept the first one: within 24 hours it answers with the same reportId).
        try await tap("report-submit")
        try await toast("已提交，感谢你的反馈")
        try await see("report-block-dialog")
        try await tap("dialog-cancel")
        try await gone(el("report-block-dialog"))
    }

    // MARK: 4510 (AC-MOD-02-9, frontend-chat 76, 81, 82)

    /// TC-MOD-02-09 (iOS), frontend-chat 76, 81: with the switch read as off (4510 does not depend on it) a message with a
    /// listed word fails: "消息包含不当内容，无法发送", the input empties, the mark reads the reason and does not offer a
    /// resend, the menu has only "复制" and "删除"; the peer never gets it.
    func testTC_MOD_02_09_blockedSendFailsCopyNoRetryEvenWithTheSwitchOff() async throws {
        let (a, b) = (uid("ba"), uid("bb"))
        try await importUsers([a, b], nicknames: [a: "甲", b: "乙乙"])
        let word = "ZXQ-MOD-\(uid("w"))"
        try await addWord(word)
        let bob = try await peer(b)
        try await say(bob, c2c(a, b), "你好")
        try await launchAs(a, env: ["TT_TEST_MODERATION_OFF": "1"])
        try await openConv("乙乙")
        let text = "含\(word)的话"
        try await typeInComposer(text)
        try await tapSend()
        try await toast("消息包含不当内容，无法发送")
        XCTAssertEqual(composerText(), "", "the input empties")
        let m = message(text)
        try await until("failed") { (m.value as? String) == "发送失败" }
        let mark = el("failed-icon")
        XCTAssertEqual(mark.label, "发送失败，消息包含不当内容，无法发送")
        XCTAssertFalse(mark.elementType == .button, "not a resend button")
        mark.tap()
        try await staysGone(el("retry-dialog"))
        let menu = try await c6Menu(m)
        XCTAssertEqual(menu, ["复制", "删除"])
        try await closeC6Menu()
        _ = try? await bob.loadHistory(c2c(a, b))
        XCTAssertFalse(bob.messages(c2c(a, b)).contains { $0.body.text == text }, "never delivered")
        capture("tc-mod-02-09-blocked")
    }

    /// frontend-chat 76: features.moderation off: no "举报" in the message menu, on a recall line, on the user card or in
    /// the group settings.
    func testIssue76SwitchOffNoEntryAnywhere() async throws {
        let (o, w, a) = (uid("xo"), uid("xw"), uid("xa"))
        let g = try await c4Group("关闭群", [(o, "群主"), (w, "丙丙"), (a, "甲")])
        let wc = try await peer(w)
        try await say(wc, g.convId, "一句话")
        let gone1 = try await say(wc, g.convId, "撤回的话")
        try await wc.recall(g.convId, gone1.msgId!)
        try await launchAs(a, env: ["TT_TEST_MODERATION_OFF": "1"])
        try await openConv("关闭群")
        try await see(el("msg-recalled", labelContains: "丙丙撤回了一条消息"))
        let menu = try await c6Menu(message("一句话"))
        XCTAssertFalse(menu.contains("举报"), "\(menu)")
        try await closeC6Menu()
        XCTAssertFalse(el("recall-report").exists)
        try await tapElement(all("msg-avatar").element(boundBy: 0))
        let items = try await userMenu()
        XCTAssertFalse(items.contains("举报"), "\(items)")
        try await closeUserMenu()
        try await back()
        try await tap("chat-more")
        try await see("group-leave")
        XCTAssertFalse(el("group-report").exists)
    }

    /// frontend-chat 82 (P-48 ⑥): a group name, a notice, a new group's name and a friend request note with a listed word
    /// say "内容包含不当信息，请修改后重试" and keep what was typed (the rename sheet and the naming sheet stay open).
    func testIssue82GroupNameNoticeCreateAndApplyKeepTheInput() async throws {
        let (a, b, c, s) = (uid("na"), uid("nb"), uid("nc"), uid("ns"))
        try await importUsers([a, b, c, s], nicknames: [a: "甲", b: "乙", c: "丙", s: "陌生人"])
        try await makeFriends(a, b)
        try await makeFriends(a, c)
        let word = "ZXQ-MOD-\(uid("w"))"
        try await addWord(word)
        let g = try await hostedGroup(name: "原来的群名", members: [a, b], owner: a)
        _ = g
        try await launchAs(a)
        try await openConv("原来的群名")
        try await tap("chat-more")
        try await tap("group-name")
        try await see("rename-sheet")
        try await clearAndType("群\(word)", into: "rename-input")
        try await tap("rename-save")
        try await toast("内容包含不当信息，请修改后重试")
        try mustExist("rename-sheet", "the sheet stays")
        XCTAssertEqual(el("rename-input").value as? String, "群\(word)")
        try await tap("rename-sheet-scrim")
        try await gone(el("rename-sheet"))

        try await tap("group-notice")
        try await tap("notice-edit")
        try await type("公告\(word)", into: "notice-input")
        try await tap("notice-save")
        try await toast("内容包含不当信息，请修改后重试")
        XCTAssertEqual(el("notice-input").value as? String, "公告\(word)")
        try await back()
        try await back()
        try await back()

        // A new group's name.
        try await tap("plus-button")
        try await tapMenuItem("发起群聊")
        for name in ["乙", "丙"] {
            let row = el("pick-row", labelContains: name)
            try await see(row)
            for _ in 0..<4 where (row.value as? String) != "selected" {
                row.tap()
                try await sleep(600)
            }
        }
        try await until("two picked") { self.el("pick-done").label.contains("2") }
        try await tap("pick-done")
        try await see("group-name-sheet")
        try await type("新群\(word)", into: "group-name-input")
        try await tap("group-create")
        try await toast("内容包含不当信息，请修改后重试")
        try mustExist("group-name-sheet", "the sheet stays")
        XCTAssertEqual(el("group-name-input").value as? String, "新群\(word)")
        try await tap("group-name-sheet-scrim")
        try await back()

        // A friend request note.
        openLink("tianting://contacts/apply/\(s)")
        try await see("apply-send")
        try await clearAndType("附言\(word)", into: "apply-message")
        try await tap("apply-send")
        try await toast("内容包含不当信息，请修改后重试")
        XCTAssertEqual(el("apply-message").value as? String, "附言\(word)")
        try mustExist("apply-send", "still on the page")
    }

    // MARK: Accessibility and dark mode (AC-CHAT-90-8, 90-9)

    /// TC-CHAT-90-44 (iOS): the recall line's "举报" and every control of the sheet have names (VoiceOver reads the
    /// reasons with "已选择" / "未选择"), the system audit finds nothing without a description; the menu's "举报" is also an
    /// accessibility action. The sheet follows the theme with tokens (surface: #FFFFFF light, #1B1E25 dark).
    func testTC_CHAT_90_44_namedLightAndDark() async throws {
        let (o, w, a) = (uid("yo"), uid("yw"), uid("ya"))
        let g = try await c4Group("无障碍群", [(o, "群主"), (w, "丙丙"), (a, "甲")])
        let wc = try await peer(w)
        try await say(wc, g.convId, "一句话")
        let gone1 = try await say(wc, g.convId, "撤回的话")
        try await wc.recall(g.convId, gone1.msgId!)
        try await launchAs(a)
        try await openConv("无障碍群")
        try await see("recall-report")
        try audit()
        let menu = try await c6Menu(message("一句话"))
        XCTAssertTrue(menu.contains("举报"))
        XCTAssertEqual(app.buttons["举报"].firstMatch.identifier, "menu-report")
        try await tapMenuItem("举报")
        try await see("report-sheet")
        XCTAssertEqual(el("report-note").label, "补充说明（可选）")
        XCTAssertEqual(el("report-title").label, "举报")
        XCTAssertEqual(label("report-count"), "已输入 0 个字，最多 200 个")
        try audit()
        for (mode, surface) in [("light", (0xFF, 0xFF, 0xFF)), ("dark", (0x1B, 0x1E, 0x25))] {
            try await setSystemAppearance(mode)
            try await sleep(800)
            let f = el("report-sheet").frame
            let p = pixel(atX: f.midX, y: f.minY + 4)
            XCTAssertTrue(abs(p.r - surface.0) <= 4 && abs(p.g - surface.1) <= 4 && abs(p.b - surface.2) <= 4, "\(mode) \(p)")
            try audit()
            capture("tc-chat-90-44-report-sheet-\(mode)")
        }
        try await tap("report-cancel")
        try await gone(el("report-sheet"))
    }

    private func audit() throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription]) { issue in
            print("A11Y-ISSUE \(issue.compactDescription): \(issue.element?.debugDescription.prefix(200) ?? "-")")
            return false
        }
    }
}
