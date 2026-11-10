import TiantingIM
import TiantingIMTesting
import XCTest

@testable import TiantingAppKit

/// FE-669, FE-670 (PRD-chat C4): the pure rules of recall, quote and @ on iOS, and the app layer against the SDK with a fake
/// transport. Same cases as tianting-android's C4Test and tianting-web's c4.test.tsx / mentions.test.ts.
@MainActor
final class C4Tests: XCTestCase {
    private let me = "alice"

    private func msg(
        _ id: String, from: String = "bob", type: MessageType = .text, status: MessageStatus = .sent, text: String? = "t",
        deleted: Bool? = nil, recalled: Bool? = nil, recalledBy: String? = nil, mentions: [String: Any]? = nil,
        convId: String = "group:g1", seq: Int64 = 1
    ) -> Message {
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let mentions { body["mentions"] = mentions }
        if type == .file { body["file"] = ["fileId": "f1", "name": "报告.pdf", "size": 10, "mime": "application/pdf"] }
        if type == .image { body["image"] = ["fileId": "i1", "width": 10, "height": 10, "mime": "image/jpeg", "size": 10] }
        var o: [String: Any] = [
            "clientMsgId": id, "msgId": id, "seq": seq, "convId": convId, "from": from, "type": type.rawValue, "body": body,
            "ts": 0, "status": status.rawValue,
        ]
        if let deleted { o["deleted"] = deleted }
        if let recalled { o["recalled"] = recalled }
        if let recalledBy { o["recalledBy"] = recalledBy }
        let data = try! JSONSerialization.data(withJSONObject: o)
        return try! JSONDecoder().decode(Message.self, from: data)
    }

    // MARK: Mentions model (FE-670)

    private func type(_ s: EditState, _ ch: String, canMention: Bool = true) -> EditResult {
        let next = insertText(ch, into: s.text, range: NSRange(location: s.selStart, length: s.selEnd - s.selStart))
        return applyEdit(
            s, text: next.text, selStart: next.caret.location, selEnd: next.caret.location, composing: false,
            canMention: canMention)
    }

    private func backspace(_ s: EditState) -> EditResult {
        let ns = s.text as NSString
        let at = s.selStart
        let next = ns.replacingCharacters(in: NSRange(location: at - 1, length: 1), with: "")
        return applyEdit(s, text: next, selStart: at - 1, selEnd: at - 1, composing: false, canMention: true)
    }

    private func picked(_ text: String, name: String = "小王", userId: String = "u2") -> EditState {
        var s = EditState(text: text)
        let r = type(s, "@")
        XCTAssertNotNil(r.trigger)
        s = r.state
        let m = insertMention(s.text, s.ranges, at: r.trigger!, name: name, userId: userId)
        return EditState(text: m.text, selStart: m.caret, ranges: m.ranges)
    }

    func testTC_MEN_01_08_triggerOnlyAtLineStartOrAfterSpaceNotForEmailOrPaste() {
        // a@b.com does not open; a line-start ＠ opens; pasting "@u2" (one multi-character insert) does not.
        var s = EditState.empty
        for ch in "a@b.com".map(String.init) {
            let r = type(s, ch)
            XCTAssertNil(r.trigger, "no picker inside an email")
            s = r.state
        }
        XCTAssertEqual(type(.empty, "＠").trigger, 0, "full-width at the line start")
        XCTAssertEqual(type(EditState(text: "你好 "), "@").trigger, 3, "after a space")
        XCTAssertEqual(type(EditState(text: "第一行\n"), "@").trigger, 4, "after a newline")
        let pasted = applyEdit(.empty, text: "@u2", selStart: 3, selEnd: 3, composing: false, canMention: true)
        XCTAssertNil(pasted.trigger)
        XCTAssertNil(mentionsToSend(pasted.state.text, pasted.state.ranges), "pasted text makes no mentions")
    }

    func testTC_MEN_01_06_noPickerInSingleChatOrWithTheSwitchOff() {
        XCTAssertNil(type(.empty, "@", canMention: false).trigger)
        XCTAssertEqual(type(.empty, "@", canMention: false).state.text, "@", "@ stays as a plain character")
    }

    func testTC_MEN_01_07_insertsNicknameRangeAndSendsUserId() {
        let s = picked("你好 ", name: "小王", userId: "u2")
        XCTAssertEqual(s.text, "你好 @小王 ")
        XCTAssertEqual(s.ranges, [MentionRange(start: 3, len: 4, userId: "u2")])
        XCTAssertEqual(mentionsToSend(s.text, s.ranges), Mentions(userIds: ["u2"], all: false))
        let all = insertMention("@", [], at: 0, name: "所有人", userId: nil)
        XCTAssertEqual(all.text, "@所有人 ")
        XCTAssertEqual(mentionsToSend(all.text, all.ranges), Mentions(userIds: [], all: true))
    }

    func testTC_MEN_01_05_deletingTheInsertedTextDropsTheMention() {
        let s = picked("")
        // Delete one character in the middle of "@小王 " (a selection delete, not the caret-after backspace).
        let r = applyEdit(
            EditState(text: s.text, selStart: 1, selEnd: 2, ranges: s.ranges), text: "@王 ", selStart: 1, selEnd: 1,
            composing: false, canMention: true)
        XCTAssertEqual(r.state.ranges, [])
        XCTAssertNil(mentionsToSend(r.state.text, r.state.ranges))
        // Replacing everything drops it too.
        let all = applyEdit(s, text: "删掉了", selStart: 3, selEnd: 3, composing: false, canMention: true)
        XCTAssertNil(mentionsToSend(all.state.text, all.state.ranges))
    }

    func testTC_MEN_01_12_oneBackspaceRemovesTheWholeMention() {
        let s = picked("你好 ")
        let r = backspace(s)
        XCTAssertEqual(r.state.text, "你好 ")
        XCTAssertEqual(r.state.selStart, 3)
        XCTAssertEqual(r.state.ranges, [])
        // A backspace elsewhere is one character.
        let typed = type(s, "啊").state
        XCTAssertEqual(backspace(typed).state.text, "你好 @小王 ")
        XCTAssertEqual(backspace(typed).state.ranges.count, 1)
    }

    func testTC_MEN_01_12_caretNeverRestsInsideAMention() {
        let s = picked("")  // "@小王 ", range 0..<4
        let inside = applyEdit(
            EditState(text: s.text, selStart: 0, ranges: s.ranges), text: s.text, selStart: 2, selEnd: 2, composing: false,
            canMention: true)
        XCTAssertEqual(inside.state.selStart, 4, "tapped in: to the end")
        let fromBehind = applyEdit(
            EditState(text: s.text, selStart: 4, ranges: s.ranges), text: s.text, selStart: 3, selEnd: 3, composing: false,
            canMention: true)
        XCTAssertEqual(fromBehind.state.selStart, 0, "moving left into it: to the start")
        XCTAssertEqual(clampCaret(4, s.ranges), 4)
    }

    func testTC_MEN_01_09_compositionChangesNothingUntilCommitted() {
        // Automated part of the manual case: marked text containing @ neither opens the picker nor moves ranges.
        let s = picked("")  // "@小王 "
        let composing = applyEdit(s, text: "@小王 n@", selStart: 7, selEnd: 7, composing: true, canMention: true)
        XCTAssertNil(composing.trigger)
        XCTAssertEqual(composing.state.ranges, s.ranges)
        XCTAssertEqual(composing.state.composeBase, "@小王 ")
        // Backspace inside the composition (the IME edits its own marked text) is no mention backspace.
        let still = applyEdit(composing.state, text: "@小王 n", selStart: 6, selEnd: 6, composing: true, canMention: true)
        XCTAssertEqual(still.state.ranges, s.ranges)
        // Committed "你@": compared once with the text before the composition; two characters, so no picker.
        let committed = applyEdit(still.state, text: "@小王 你@", selStart: 7, selEnd: 7, composing: false, canMention: true)
        XCTAssertNil(committed.trigger)
        XCTAssertEqual(committed.state.ranges, s.ranges, "the range in front is untouched")
        XCTAssertNil(committed.state.composeBase)
        XCTAssertEqual(mentionsToSend(committed.state.text, committed.state.ranges)?.userIds, ["u2"])
        // After it, a typed @ after a space works again.
        XCTAssertNotNil(type(type(committed.state, " ").state, "@").trigger)
    }

    func testRangesMoveWithEditsBeforeThemAndDedupe() {
        let s = picked("")
        let r = applyEdit(
            EditState(text: s.text, selStart: 0, ranges: s.ranges), text: "嗨" + s.text, selStart: 1, selEnd: 1,
            composing: false, canMention: true)
        XCTAssertEqual(r.state.ranges.first?.start, 1)
        let twice = [MentionRange(start: 0, len: 4, userId: "u2"), MentionRange(start: 4, len: 4, userId: "u2")]
        XCTAssertEqual(mentionsToSend("@小王 @小王 ", twice)?.userIds, ["u2"])
        let emoji = insertText("😀", into: s.text, range: NSRange(location: 0, length: 0))
        let moved = applyEdit(
            EditState(text: s.text, selStart: 0, ranges: s.ranges), text: emoji.text, selStart: 2, selEnd: 2,
            composing: false, canMention: false)
        XCTAssertEqual(moved.state.ranges.first?.start, 2, "UTF-16 offsets: an emoji is two units")
        // A range whose text no longer starts with @ (a stale draft) sends nothing.
        XCTAssertNil(mentionsToSend("你好啊", [MentionRange(start: 0, len: 2, userId: "u2")]))
        XCTAssertNil(mentionsToSend("@", [MentionRange(start: 0, len: 4, userId: "u2")]), "past the end")
    }

    func testTC_MEN_01_10_draftsKeepTextMentionsAndQuote() {
        let d = DraftStore()
        let s = picked("收到 ")
        d.put("group:g1", Draft(text: s.text, mentions: s.ranges, quote: "m1"))
        XCTAssertEqual(d.draft("group:g1"), Draft(text: "收到 @小王 ", mentions: s.ranges, quote: "m1"))
        XCTAssertEqual(d.text("group:g1"), "收到 @小王 ")
        d.put("c", Draft(text: " ", quote: "m2"))
        XCTAssertNotNil(d.draft("c"), "a quote alone is a draft")
        XCTAssertNil(d.text("c"), "but no [草稿] text")
        d.put("c", Draft(text: " "))
        XCTAssertNil(d.draft("c"))
    }

    func testTC_MEN_03_05_mentionPrefixBeatsDraft() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "convId": "group:g1", "type": "group", "name": "n", "maxSeq": 2, "readSeq": 0, "minSeq": 1, "unread": 2,
            "updatedAt": 1, "mentionUnread": 1, "firstMentionSeq": 2,
        ])
        let mentioned = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(summaryPrefix(mentioned, hasDraft: true), .mention)
        let plain = conversation(.group, last: nil)
        XCTAssertEqual(summaryPrefix(plain, hasDraft: true), .draft)
        XCTAssertEqual(summaryPrefix(plain, hasDraft: false), SummaryPrefix.none)
    }

    func testTC_MEN_01_01_mentionedBubbleIsMineOnly() {
        XCTAssertTrue(mentionsMe(msg("m", mentions: ["userIds": ["alice"]]), me: me))
        XCTAssertTrue(mentionsMe(msg("m", mentions: ["all": true]), me: me))
        XCTAssertFalse(mentionsMe(msg("m", mentions: ["userIds": ["u3"]]), me: me))
        XCTAssertFalse(mentionsMe(msg("m", from: "alice", mentions: ["all": true]), me: me), "my own")
        XCTAssertFalse(mentionsMe(msg("m"), me: me))
    }

    // MARK: Menu, recall copy (FE-669)

    func testTC_UI_09_01_switchOffCopyOnlyOnBySdkActions() {
        let text = msg("m1")
        XCTAssertEqual(menuItems(text, actionsOn: false) { [.copy, .quote, .recall] }, [.copy])
        XCTAssertEqual(menuItems(msg("i", type: .image), actionsOn: false) { [.quote] }, [], "image: no menu when off")
        XCTAssertEqual(menuItems(text, actionsOn: true) { [.copy, .quote, .recall] }, [.copy, .quote, .recall])
        XCTAssertEqual(menuItems(msg("i", type: .image), actionsOn: true) { [.quote] }, [.quote])
        let failed = msg("f", status: .failed)
        XCTAssertEqual(menuItems(failed, actionsOn: false) { [] }, [.copy, .retry, .delete])
        XCTAssertEqual(menuItems(failed, actionsOn: true, canRetry: false) { [.copy] }, [.copy, .delete])
    }

    func testTC_RCL_03_10_recalledAndDeletedLinesHaveNoMenu() {
        let recalled = msg("m", text: nil, deleted: true, recalled: true)
        XCTAssertEqual(menuItems(recalled, actionsOn: true) { [.copy] }, [])
        XCTAssertEqual(menuItems(msg("m", text: nil, deleted: true), actionsOn: false) { [] }, [])
        XCTAssertEqual(menuItems(msg("t", type: .tip, text: nil), actionsOn: true) { [.copy] }, [])
        // The c2c copy both ways (F-RCL-02 rule 1a row 1).
        let c2c = "c2c:alice:bob"
        let mine = recallNotice(convId: c2c, message: msg("x", from: me, deleted: true, recalled: true, convId: c2c), me: me)!
        XCTAssertEqual(recallText(mine) { $0 }, "你撤回了一条消息")
        let theirs = recallNotice(convId: c2c, message: msg("y", from: "bob", deleted: true, recalled: true, convId: c2c), me: me)!
        XCTAssertEqual(recallText(theirs) { $0 }, "对方撤回了一条消息")
        XCTAssertNil(recallNotice(convId: c2c, message: msg("z", deleted: true, convId: c2c), me: me), "a console deletion")
    }

    func testTC_RCL_03_06_TC_RCL_02_04_listSummaryUsesTheRecallTable() throws {
        func conv(_ last: [String: Any], type: String = "group") throws -> Conversation {
            let data = try JSONSerialization.data(withJSONObject: [
                "convId": type == "group" ? "group:g1" : "c2c:alice:bob", "type": type, "name": "n", "maxSeq": 1,
                "readSeq": 1, "minSeq": 1, "unread": 0, "updatedAt": 1, "lastMsg": last,
            ])
            return try JSONDecoder().decode(Conversation.self, from: data)
        }
        let names = ["u1": "爱丽丝", "a": "管理甲", "m": "成员丙"]
        let name = { (u: String) in names[u] ?? u }
        let own: [String: Any] = ["msgId": "m", "from": "u1", "type": "text", "ts": 1, "deleted": true, "recalled": true, "recalledBy": "u1"]
        XCTAssertEqual(conversationSummary(try conv(own), me: "u1", senderName: name), "你撤回了一条消息")
        XCTAssertEqual(conversationSummary(try conv(own), me: "n", senderName: name), "爱丽丝撤回了一条消息")
        var byAdmin = own
        byAdmin["from"] = "m"
        byAdmin["recalledBy"] = "a"
        XCTAssertEqual(conversationSummary(try conv(byAdmin), me: "a", senderName: name), "你撤回了 成员丙 的一条消息")
        XCTAssertEqual(conversationSummary(try conv(byAdmin), me: "m", senderName: name), "管理甲撤回了你的一条消息")
        XCTAssertEqual(conversationSummary(try conv(byAdmin), me: "n", senderName: name), "管理甲撤回了一条成员消息")
        let deleted: [String: Any] = ["msgId": "m", "from": "m", "type": "text", "ts": 1, "deleted": true]
        XCTAssertEqual(conversationSummary(try conv(deleted), me: "n", senderName: name), "该消息已被删除")
    }

    func testTC_RCL_01_08_TC_RCL_02_05_recallErrorCopy() {
        func err(_ code: Int, window: Int64? = nil) -> IMError {
            IMError(code: code, details: window.map { ["windowSeconds": .int($0)] })
        }
        XCTAssertEqual(recallErrorText(err(4097, window: 120)), "发送时间超过 2 分钟，无法撤回")
        XCTAssertEqual(recallErrorText(err(4097, window: 604_800)), "发送时间超过 7 天，无法撤回")
        XCTAssertEqual(recallErrorText(err(4097)), "发送时间超过 2 分钟，无法撤回")
        XCTAssertEqual(recallErrorText(err(4030)), "你没有权限撤回这条消息")
        XCTAssertEqual(recallErrorText(err(4044)), "消息不存在或已过期")
        XCTAssertEqual(recallErrorText(IMConnectionError.timeout(cmd: "recall")), "服务异常，请稍后重试", "issue 37")
        XCTAssertEqual(errorText(4293, cmd: "send"), "@所有人次数已用完")
    }

    // MARK: Quote (FE-669)

    func testTC_QUO_01_05_TC_QUO_02_05_quoteBarAndBlockArePlainTextInFourStates() {
        let html = "<img src=x onerror=alert(1)><b>粗</b>"
        let name = { (u: String) in u == "bob" ? "乙" : u }
        XCTAssertEqual(quoteBarText(msg("m", text: html), senderName: name), "乙: \(html)")
        XCTAssertEqual(quoteBarText(msg("i", type: .image, text: nil), senderName: name), "乙: [图片]")
        XCTAssertEqual(quoteBarText(msg("f", type: .file, text: nil), senderName: name), "乙: [文件] 报告.pdf")
        XCTAssertEqual(quoteBarText(msg("r", text: nil, deleted: true, recalled: true), senderName: name), "引用内容已被撤回")
        XCTAssertEqual(quoteBarText(msg("d", text: nil, deleted: true), senderName: name), "引用内容已被删除")
        XCTAssertEqual(quoteBarText(nil, senderName: name), "引用内容不可用")
        XCTAssertEqual(quoteBlockText(QuoteView(msgId: "m", from: "bob", type: .text, state: .normal, text: html), senderName: name), "乙: \(html)")
        XCTAssertEqual(quoteBlockText(QuoteView(msgId: "m", state: .recalled), senderName: name), "引用内容已被撤回")
        XCTAssertEqual(quoteBlockText(QuoteView(msgId: "m", state: .deleted), senderName: name), "引用内容已被删除")
        XCTAssertEqual(quoteBlockText(QuoteView(msgId: "m", type: .file, state: .expired), senderName: name), "[文件] 已过期")
        XCTAssertEqual(quoteBlockText(QuoteView(msgId: "m", state: "later"), senderName: name), "引用内容不可用")
    }

    func testTC_QUO_02_03_jumpPlanWithin200TooEarlyBeyondMissingInside() {
        let loaded = Array(Int64(501)...550)
        XCTAssertEqual(jumpPlan(520, loaded: loaded, limit: quoteJumpMax), .here)
        XCTAssertEqual(jumpPlan(401, loaded: loaded, limit: quoteJumpMax), .load(100))
        XCTAssertEqual(jumpPlan(301, loaded: loaded, limit: quoteJumpMax), .load(200))
        XCTAssertEqual(jumpPlan(1, loaded: loaded, limit: quoteJumpMax), .tooEarly)
        XCTAssertEqual(jumpPlan(nil, loaded: loaded, limit: quoteJumpMax), .missing)
        XCTAssertEqual(jumpPlan(560, loaded: loaded, limit: quoteJumpMax), .missing)
        XCTAssertEqual(jumpPlan(1, loaded: loaded, limit: .max), .load(200), "有人@我 pages until there (issue 40)")
    }

    // MARK: App layer with the SDK (fake transport)

    private func loggedIn(convs: [JSONValue], msgActions: Bool = true) async -> (AppModel, Fake) {
        let fake = Fake()
        let prefs = UIPrefs(defaults: UserDefaults(suiteName: "tt.c4.\(UUID().uuidString)")!)
        let m = AppModel(
            config: AppConfig(server: URL(string: "http://localhost:1"), demoLogin: true), sessions: MemorySessionStore(),
            theme: ThemeController(prefs: prefs), prefs: prefs, makeClient: { _, _ in fake.client },
            makeAccount: { _, s in fakeAccount(store: s, clock: fake.clock) })
        await m.login(demoSession(me, "tok"))
        let c = fake.transport.current
        c.open()
        c.ack("auth", ["userId": .string(me), "serverTime": .int(fake.clock.now())])
        await flush()
        c.ack("convs", ["convs": .array(convs), "truncated": false])
        await flush()
        return (m, fake)
    }

    func testTC_RCL_01_01_recallEventGivesTheRecallLineAndSummary() async {
        let (m, fake) = await loggedIn(convs: [convFrame("c2c:alice:bob", maxSeq: 0)])
        let store = m.store!
        let c = fake.transport.current
        c.receive([
            "cmd": "msg",
            "data": [
                "msgId": "m1", "clientMsgId": "x1", "convId": "c2c:alice:bob", "seq": 1, "from": "bob", "type": "text",
                "body": ["text": "ZXQ-RCL-2"], "ts": .int(fake.clock.now()),
            ],
        ])
        await flush()
        c.receive([
            "cmd": "event",
            "data": [
                "type": "msgDeleted", "convId": "c2c:alice:bob", "msgIds": ["m1"], "seqs": [1],
                "recalled": ["by": "bob", "at": .int(fake.clock.now())],
            ],
        ])
        await flush()
        let row = store.messages("c2c:alice:bob").first!
        XCTAssertEqual(row.deleted, true)
        XCTAssertNil(row.body.text)
        let n = recallNotice(convId: "c2c:alice:bob", message: row, me: me)!
        XCTAssertEqual(recallText(n) { $0 }, "对方撤回了一条消息")
        XCTAssertEqual(conversationSummary(store.conversation("c2c:alice:bob")!, me: me) { $0 }, "对方撤回了一条消息")
        XCTAssertEqual(menuItems(row, actionsOn: true) { store.client.messageActions(row) }, [])
    }

    func testTC_MEN_02_05_4293ToastsOnceAndFails() async {
        let (m, fake) = await loggedIn(convs: [convFrame("group:g1", maxSeq: 0, myRole: "owner")])
        let store = m.store!
        let c = fake.transport.current
        _ = try? store.client.send("group:g1", "@所有人 开会", mentions: Mentions(all: true))
        await flush()
        XCTAssertEqual(c.last("send")?.data?.objectValue?["body"]?.objectValue?["mentions"], ["all": true])
        c.ackError("send", 4293)
        await flush()
        XCTAssertEqual(m.hub.toast?.text, "@所有人次数已用完")
        XCTAssertEqual(store.messages("group:g1").last?.status, .failed)
        let sends = c.frames("send").count
        fake.clock.advance(60_000)
        await flush()
        XCTAssertEqual(c.frames("send").count, sends, "never sent again by itself")
    }

    func testTC_RCL_03_12_downloadAbortedClearsStateAndTellsOnlyForRecall() async {
        let (m, _) = await loggedIn(convs: [])
        let media = m.media!
        XCTAssertFalse(media.downloadAborted("f1"), "nothing running: no toast")
        media.startDownload("f1")
        XCTAssertEqual(media.downloads["f1"], .running(0, nil))
        m.store!.onDownloadAborted?("f1", true)
        XCTAssertNil(media.downloads["f1"])
        XCTAssertEqual(m.hub.toast?.text, "该消息已被撤回")
        m.hub.dismissToastForTest()
        media.startDownload("f2")
        m.store!.onDownloadAborted?("f2", false)
        XCTAssertNil(media.downloads["f2"])
        XCTAssertNil(m.hub.toast, "a deletion or expiry: the bubble says it (issue 46)")
    }

    func testTC_UI_09_01_switchFromTheCachedConfigOldCacheIsOff() {
        func model(_ cached: String?) -> AppModel {
            let prefs = UIPrefs(defaults: UserDefaults(suiteName: "tt.c4.cfg.\(UUID().uuidString)")!)
            if let cached { prefs.set("ui.config", cached) }
            return AppModel(
                config: AppConfig(server: URL(string: "http://localhost:1"), demoLogin: true), sessions: MemorySessionStore(),
                theme: ThemeController(prefs: prefs), prefs: prefs, makeClient: { _, _ in Fake().client },
                makeAccount: { _, s in fakeAccount(store: s, clock: FakeClock()) })
        }
        XCTAssertFalse(model(#"{"files":true}"#).msgActionsEnabled, "a cache from before C4: off")
        XCTAssertFalse(model(nil).msgActionsEnabled)
        XCTAssertFalse(model(#"{"files":true,"msgActions":false}"#).msgActionsEnabled)
        XCTAssertTrue(model(#"{"files":true,"msgActions":true}"#).msgActionsEnabled)
    }

    func testMsgActionsSwitchFromConfigAndOldCache() throws {
        let old = try JSONDecoder().decode(CachedConfig.self, from: Data(#"{"files":true}"#.utf8))
        XCTAssertNil(old.msgActions, "an older cache: off")
        let json = #"{"registerMode":"open","demoLogin":true,"features":{"files":true,"msgActions":true},"limits":{"usernameMinLen":3,"usernameMaxLen":20,"passwordMinLen":8,"passwordMaxLen":64,"nicknameMaxLen":20,"deviceNameMaxLen":40}}"#
        let on = CachedConfig(try JSONDecoder().decode(AccountConfig.self, from: Data(json.utf8)))
        XCTAssertEqual(on.msgActions, true)
        let legacy = json.replacingOccurrences(of: #","msgActions":true"#, with: "")
        XCTAssertNil(CachedConfig(try JSONDecoder().decode(AccountConfig.self, from: Data(legacy.utf8))).msgActions)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
