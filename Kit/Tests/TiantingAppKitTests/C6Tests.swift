import TiantingIM
import TiantingIMTesting
import XCTest

@testable import TiantingAppKit

/// FE-695 (PRD-chat C6): the report sheet's rules and copy, the menu's "举报", 4510's copy on iOS, and the report form
/// against the SDK with a fake transport. Same cases as tianting-web's c6.test.tsx and tianting-android's C6Test /
/// C6UiTest. Marker strings only (ZXQ-RPT-*), no real words.
@MainActor
final class C6Tests: XCTestCase {
    private let me = "alice"
    private let note = "ZXQ-RPT-NOTE"

    private func msg(
        _ id: String, conv: String = "c2c:alice:bob", from: String = "bob", status: MessageStatus = .sent,
        type: MessageType = .text, error: SendFailure? = nil
    ) -> Message {
        let o: [String: Any] = [
            "clientMsgId": id, "msgId": id, "seq": 1, "convId": conv, "from": from, "type": type.rawValue,
            "body": ["text": "t"], "ts": 0, "status": status.rawValue,
        ]
        let data = try! JSONSerialization.data(withJSONObject: o)
        var m = try! JSONDecoder().decode(Message.self, from: data)
        m.error = error
        return m
    }

    // MARK: Copy and pure rules

    /// frontend-chat 78: six reasons in this order with these words, the same on three apps and the console.
    func testIssue78SixReasonsInOrder() {
        XCTAssertEqual(reportReasons.map(\.title), ["垃圾广告", "辱骂骚扰", "色情低俗", "诈骗", "违法违规", "其他"])
        XCTAssertEqual(reportReasons.map(\.reason), ReportReason.all)
        XCTAssertEqual(reportHintText, "所选内容将提交给平台审核")
        XCTAssertEqual(reportDoneText, "已提交，感谢你的反馈")
    }

    /// frontend-chat 84: code points like the server; one more key stops at 200, a paste is cut to 200 and says so.
    func testIssue84NoteCountsCodePointsTypingStopsPasteIsCut() {
        let full = String(repeating: "字", count: 199) + "😀"  // 200 code points, 201 UTF-16 units
        XCTAssertEqual(countCodePoints(full), 200)
        XCTAssertEqual(reportNoteInput(old: String(full.dropLast()), new: full).value, full, "exactly 200 is fine")
        let typed = reportNoteInput(old: full, new: full + "a")
        XCTAssertEqual(typed.value, full, "typing stops at 200")
        XCTAssertFalse(typed.clipped)
        let pasted = reportNoteInput(old: "开头", new: "开头" + String(repeating: "😀", count: 250))
        XCTAssertEqual(countCodePoints(pasted.value), 200)
        XCTAssertTrue(pasted.clipped)
        XCTAssertTrue(pasted.value.hasSuffix("😀"), "never cuts inside a code point")
        XCTAssertEqual(clampCodePoints("abc", max: 2), "ab")
        XCTAssertEqual(reportNoteClippedText, "补充说明最多 200 个字，超出的部分已去掉")
        XCTAssertNil(reportNote("  \n "), "a blank note is not sent")
        XCTAssertEqual(reportNote("  说明 "), "说明")
    }

    /// frontend-chat 83: 4040, 4030, 4292 have their words and close; 5000, 4290, a timeout and a lost connection keep the
    /// sheet. The note never shows in the copy.
    func testIssue83ErrorCopyAndWhichClose() {
        func e(_ code: Int) -> IMError { IMError(code: code, message: note) }
        XCTAssertEqual(reportErrorText(e(4040)), "无法举报该内容")
        XCTAssertEqual(reportErrorText(e(4030)), "举报功能暂不可用")
        XCTAssertEqual(reportErrorText(e(4292)), "今天的举报次数已用完")
        XCTAssertEqual(reportErrorText(e(5000)), "服务异常，请稍后重试")
        XCTAssertEqual(reportErrorText(e(4290)), "操作太频繁，请稍后再试")
        XCTAssertEqual(reportErrorText(IMConnectionError.timeout(cmd: "report")), "网络异常，请稍后重试")
        XCTAssertEqual(reportErrorText(IMConnectionError.closed), "网络异常，请稍后重试")
        for code in [4040, 4030, 4292] { XCTAssertTrue(reportErrorFinal(e(code)), "\(code)") }
        for code in [5000, 4290] { XCTAssertFalse(reportErrorFinal(e(code)), "\(code)") }
        XCTAssertFalse(reportErrorFinal(IMConnectionError.timeout(cmd: "report")))
        XCTAssertFalse(reportErrorFinal(IMConnectionError.notConnected))
    }

    /// P-48 ⑥ (frontend-chat 82): "send" keeps the message copy; every other command and the account pages use the form's.
    func testIssue82BlockedCopyBySceneP48() {
        XCTAssertEqual(errorText(4510, cmd: "send"), "消息包含不当内容，无法发送")
        XCTAssertEqual(errorText(4510, cmd: "send"), contentBlockedSendText)
        for cmd in ["groupCreate", "groupUpdate", "friendApply"] {
            XCTAssertEqual(errorText(4510, cmd: cmd), "内容包含不当信息，请修改后重试", cmd)
        }
        XCTAssertEqual(errorText(4510), contentBlockedFormText)
        XCTAssertEqual(
            memberErrorText(code: 4510, userId: nil, cmd: "groupCreate", me: me) { $0 }, "内容包含不当信息，请修改后重试")
        for page in [AccountPageKind.register, .nickname] {
            XCTAssertEqual(accountFailure(AccountError(status: 451, code: 4510), page: page).text, "内容包含不当信息，请修改后重试")
        }
    }

    /// frontend-chat 77, 81, 13.3: "举报" comes after "撤回" when the page says so (moderation and SDK canReport); a blocked
    /// failed message (SDK canRetry false) has only "复制" "删除".
    func testIssue77And81MenuReportAfterRecallBlockedHasCopyDeleteOnly() {
        let m = msg("m1")
        XCTAssertEqual(
            menuItems(m, actionsOn: true, canReport: true) { [.copy, .quote, .recall] }, [.copy, .quote, .recall, .report])
        XCTAssertEqual(menuItems(m, actionsOn: true, canReport: false) { [.copy, .quote] }, [.copy, .quote])
        XCTAssertEqual(menuItems(m, actionsOn: false, canReport: true) { [] }, [.copy, .report], "independent of msgActions")
        let image = msg("m2", type: .image)
        XCTAssertEqual(menuItems(image, actionsOn: false, canReport: true) { [] }, [.report], "a long press on an image")
        XCTAssertEqual(MenuAction.report.title, "举报")
        XCTAssertEqual(
            MenuAction.allCases.map(\.title), ["复制", "引用", "撤回", "举报", "重发", "删除"], "the order of PRD-chat 13.3")
        let blocked = msg("m3", from: me, status: .failed, error: .code(4510))
        let fake = Fake()
        XCTAssertFalse(fake.client.canRetry(blocked))
        XCTAssertEqual(
            menuItems(blocked, actionsOn: true, canRetry: fake.client.canRetry(blocked)) { [.copy] }, [.copy, .delete])
        let timedOut = msg("m4", from: me, status: .failed, error: .timeout)
        XCTAssertEqual(
            menuItems(timedOut, actionsOn: true, canRetry: fake.client.canRetry(timedOut)) { [.copy] }, [.copy, .retry, .delete])
        XCTAssertEqual(menuItems(msg("m5", status: .sent, type: .tip), actionsOn: true, canReport: true) { [] }, [])
    }

    /// frontend-chat 79, 85: one message per report; a c2c message offers blocking its sender, a group message does not.
    func testIssue79And85RequestTargetsAndBlockQuestion() {
        let c2c = ReportRequest.message(msg("m1"))!
        XCTAssertEqual(c2c.askBlock, "bob")
        XCTAssertEqual(
            c2c.input(reason: .abuse, note: nil), .message(convId: "c2c:alice:bob", msgIds: ["m1"], reason: .abuse))
        let group = ReportRequest.message(msg("m2", conv: "group:g1", from: "carol"))!
        XCTAssertNil(group.askBlock)
        XCTAssertEqual(ReportRequest(target: .group("g1")).input(reason: .spam, note: "x"), .group("g1", reason: .spam, note: "x"))
        XCTAssertEqual(ReportRequest(target: .user("bob"), askBlock: "bob").input(reason: .fraud, note: nil), .user("bob", reason: .fraud))
    }

    /// frontend-chat 76: entries follow features.moderation; a cache from before C6 and a server without the field are off.
    func testIssue76SwitchFromConfigOldCacheIsOff() throws {
        let old = try JSONDecoder().decode(CachedConfig.self, from: Data(#"{"files":true,"convSettings":true}"#.utf8))
        XCTAssertNil(old.moderation)
        let json = #"{"registerMode":"open","demoLogin":true,"features":{"files":true,"moderation":true},"limits":{"usernameMinLen":3,"usernameMaxLen":20,"passwordMinLen":8,"passwordMaxLen":64,"nicknameMaxLen":20,"deviceNameMaxLen":40}}"#
        XCTAssertEqual(CachedConfig(try JSONDecoder().decode(AccountConfig.self, from: Data(json.utf8))).moderation, true)
        func model(_ cached: String?) -> AppModel {
            let prefs = UIPrefs(defaults: UserDefaults(suiteName: "tt.c6.cfg.\(UUID().uuidString)")!)
            if let cached { prefs.set("ui.config", cached) }
            return AppModel(
                config: AppConfig(server: URL(string: "http://localhost:1"), demoLogin: true), sessions: MemorySessionStore(),
                theme: ThemeController(prefs: prefs), prefs: prefs, makeClient: { _, _ in Fake().client },
                makeAccount: { _, s in fakeAccount(store: s, clock: FakeClock()) })
        }
        XCTAssertFalse(model(nil).moderationEnabled)
        XCTAssertFalse(model(#"{"files":true,"convSettings":true}"#).moderationEnabled, "a cache from before C6: off")
        XCTAssertFalse(model(#"{"files":true,"moderation":false}"#).moderationEnabled)
        XCTAssertTrue(model(#"{"files":true,"moderation":true}"#).moderationEnabled)
    }

    // MARK: The form against the SDK (fake transport)

    private func online() async -> Fake {
        let fake = Fake()
        await fake.connect(me, convs: [convFrame("c2c:alice:bob", maxSeq: 3), convFrame("group:g1", maxSeq: 3)])
        return fake
    }

    /// AC-MOD-03-9 (page part), frontend-chat 78, 84, 85: nothing goes out without a reason; one frame with one msgId, the
    /// trimmed note; while it runs the form is busy and a second tap does nothing; success asks about blocking.
    func testTC_MOD_03_09_submitOnceWithReasonNoteAndBlockQuestion() async {
        let fake = await online()
        let form = ReportForm(ReportRequest.message(msg("m1"))!)
        XCTAssertFalse(form.canSubmit, "no reason preselected")
        let none = await form.submit(fake.client) { _ in false }
        XCTAssertEqual(none, .ignored)
        let c = fake.transport.current
        XCTAssertEqual(c.frames("report").count, 0)
        form.reason = .abuse
        form.editNote("  \(note)  ")
        XCTAssertEqual(form.noteCount, note.count + 4)
        let task = Task { await form.submit(fake.client) { _ in false } }
        await flush()
        XCTAssertTrue(form.busy)
        XCTAssertFalse(form.canSubmit, "locked while submitting")
        let againTask = Task { await form.submit(fake.client) { _ in false } }
        await flush()
        XCTAssertEqual(c.frames("report").count, 1, "a second tap while busy sends nothing")
        XCTAssertEqual(
            c.frames("report").first?.data,
            ["targetType": "message", "convId": "c2c:alice:bob", "msgIds": ["m1"], "reason": "abuse", "note": .string(note)])
        // Every frame gets its ack, so a broken guard fails here instead of waiting for ever.
        for f in c.frames("report") {
            c.receive(["id": .string(f.id ?? ""), "cmd": "ack", "data": ["reportId": "rp_1"]])
        }
        let again = await againTask.value
        XCTAssertEqual(again, .ignored)
        let outcome = await task.value
        XCTAssertEqual(outcome, .done(askBlock: "bob"))
        XCTAssertFalse(form.busy)
    }

    /// frontend-chat 79: a user already blocked is not asked about; a group message and a group never are; no note, no field.
    func testIssue79NoBlockQuestionWhenBlockedOrGroup() async {
        let fake = await online()
        let c = fake.transport.current
        let user = ReportForm(ReportRequest(target: .user("bob"), askBlock: "bob"))
        user.reason = .spam
        let t1 = Task { await user.submit(fake.client) { $0 == "bob" } }
        await flush()
        XCTAssertEqual(c.last("report")?.data, ["targetType": "user", "userId": "bob", "reason": "spam"])
        c.ack("report", ["reportId": "rp_2"])
        let o1 = await t1.value
        XCTAssertEqual(o1, .done(askBlock: nil))
        for request in [ReportRequest(target: .group("g1")), ReportRequest.message(msg("m9", conv: "group:g1", from: "carol"))!] {
            let form = ReportForm(request)
            form.reason = .other
            let t = Task { await form.submit(fake.client) { _ in false } }
            await flush()
            c.ack("report", ["reportId": "rp_3"])
            let o = await t.value
            XCTAssertEqual(o, .done(askBlock: nil))
        }
    }

    /// frontend-chat 83: 4040, 4030, 4292 toast and close; 5000, 4290 and a timeout keep the reason and the note for a manual
    /// resubmit, which sends one new frame; nothing is retried by itself.
    func testIssue83FailuresCloseOrKeepNoAutomaticRetry() async {
        let fake = await online()
        let c = fake.transport.current
        for (code, text, close) in [
            (4040, "无法举报该内容", true), (4030, "举报功能暂不可用", true), (4292, "今天的举报次数已用完", true),
            (5000, "服务异常，请稍后重试", false), (4290, "操作太频繁，请稍后再试", false),
        ] {
            let form = ReportForm(ReportRequest.message(msg("m1"))!)
            form.reason = .porn
            form.editNote(note)
            let before = c.frames("report").count
            let t = Task { await form.submit(fake.client) { _ in false } }
            await flush()
            c.ackError("report", code, msg: note)
            let o = await t.value
            XCTAssertEqual(o, .failed(text: text, close: close), "\(code)")
            XCTAssertEqual(form.reason, .porn, "kept")
            XCTAssertEqual(form.note, note, "kept")
            XCTAssertTrue(form.canSubmit)
            XCTAssertEqual(c.frames("report").count, before + 1, "\(code)")
        }
        // Nothing goes out again by itself (short of the 30-second heartbeat, which the fake does not answer).
        let sent = c.frames("report").count
        fake.clock.advance(9_000)
        await flush()
        XCTAssertEqual(c.frames("report").count, sent, "not retried")
        // A timeout keeps the form; the manual resubmit is one more frame and can succeed.
        let form = ReportForm(ReportRequest.message(msg("m1"))!)
        form.reason = .fraud
        let before = c.frames("report").count
        let t = Task { await form.submit(fake.client) { _ in false } }
        await flush()
        fake.clock.advance(10_001)
        await flush()
        let timedOut = await t.value
        XCTAssertEqual(timedOut, .failed(text: "网络异常，请稍后重试", close: false))
        XCTAssertEqual(c.frames("report").count, before + 1)
        XCTAssertEqual(form.reason, .fraud, "kept")
        let t2 = Task { await form.submit(fake.client) { _ in false } }
        await flush()
        XCTAssertEqual(c.frames("report").count, before + 2, "the manual resubmit")
        c.ack("report", ["reportId": "rp_4"])
        let o2 = await t2.value
        XCTAssertEqual(o2, .done(askBlock: "bob"))
    }
}
