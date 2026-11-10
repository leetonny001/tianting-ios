import TiantingIM
import TiantingIMTesting
import XCTest

@testable import TiantingAppKit

/// FE-685 (PRD-chat C5): the list's pin, notifications off and delete rules on iOS, and the app layer against the SDK with
/// a fake transport. Same cases as tianting-web's c5.test.tsx and tianting-android's C5 tests.
@MainActor
final class C5Tests: XCTestCase {
    private let me = "alice"

    private func conv(
        _ id: String = "c2c:alice:bob", unread: Int64 = 0, mention: Int64? = nil, pinned: Bool = false,
        notifyOff: Bool = false, last: Bool = true
    ) -> Conversation {
        var o: [String: Any] = [
            "convId": id, "type": id.hasPrefix("group:") ? "group" : "c2c", "name": "n", "maxSeq": 9, "readSeq": 9 - unread,
            "minSeq": 1, "unread": unread, "updatedAt": 1,
        ]
        if last { o["lastMsg"] = ["msgId": "m9", "from": "bob", "type": "text", "text": "最后一条", "ts": 1] }
        if let mention { o["mentionUnread"] = mention }
        if pinned {
            o["pinned"] = true
            o["pinnedAt"] = 5
        }
        if notifyOff { o["notifyOff"] = true }
        let data = try! JSONSerialization.data(withJSONObject: o)
        return try! JSONDecoder().decode(Conversation.self, from: data)
    }

    private func last(_ text: String, seq: Int64 = 9) -> JSONValue {
        ["msgId": .string("m\(seq)"), "from": "bob", "type": "text", "text": .string(text), "ts": 1]
    }

    // MARK: Pure rules

    /// TC-CVS-02-03: notifications off with unread 5: a dot, "[5 条]" and the summary; a draft wins over it, a mention over
    /// both (one prefix only, frontend-chat 61); N as it is above 99.
    func testTC_CVS_02_03_dotCountPrefixAndPriority() {
        let off = conv(unread: 5, notifyOff: true)
        XCTAssertEqual(summaryPrefix(off, hasDraft: false), .unread(5))
        XCTAssertEqual(unreadPrefixText(5), "[5 条]")
        XCTAssertEqual(unreadPrefixText(150), "[150 条]", "a summary, not a badge: no 99+")
        XCTAssertEqual(convBadge(off), .dot)
        XCTAssertEqual(summaryPrefix(off, hasDraft: true), .draft)
        let mentioned = conv("group:g1", unread: 5, mention: 1, notifyOff: true)
        XCTAssertEqual(summaryPrefix(mentioned, hasDraft: true), .mention)
        XCTAssertEqual(convBadge(mentioned), .dot, "a mention is still a dot")
        XCTAssertEqual(summaryPrefix(conv(unread: 5), hasDraft: false), .none, "normal conversations have no [N 条]")
        XCTAssertEqual(convBadge(conv(unread: 120)), .count("99+"))
        XCTAssertEqual(convBadge(conv(unread: 0, notifyOff: true)), .none)
        XCTAssertEqual(summaryPrefix(conv(unread: 0, notifyOff: true), hasDraft: false), .none)
    }

    /// AC-CVS-02-3 for VoiceOver: the row reads the count, "免打扰", and no "未读 5" (the number is not at the avatar).
    func testTC_CVS_02_03_rowReadsNotifyOffAndCount() {
        let off = conv(unread: 5, notifyOff: true)
        let text = convRowAccessibilityText(
            name: "乙", conv: off, prefix: summaryPrefix(off, hasDraft: false), summary: "最后一条", draft: nil)
        XCTAssertEqual(text, "乙，[5 条] 最后一条，免打扰")
        let pinned = conv(unread: 2, pinned: true)
        XCTAssertEqual(
            convRowAccessibilityText(name: "乙", conv: pinned, prefix: .none, summary: "最后一条", draft: nil),
            "乙，已置顶，最后一条，未读 2")
        let mentioned = conv("group:g1", unread: 5, mention: 1, notifyOff: true)
        XCTAssertEqual(
            convRowAccessibilityText(name: "群", conv: mentioned, prefix: .mention, summary: "乙: 开会", draft: nil),
            "群，[有人@我] 乙: 开会，免打扰，有新消息")
    }

    /// TC-CVS-01-06: three items whose words follow the state; none with the switch off (P-46 ②).
    func testTC_CVS_01_06_menuItemsFollowStateAndSwitch() {
        XCTAssertEqual(convMenuItems(conv(), enabled: true).map(\.title), ["置顶", "免打扰", "删除"])
        XCTAssertEqual(
            convMenuItems(conv(pinned: true, notifyOff: true), enabled: true).map(\.title), ["取消置顶", "取消免打扰", "删除"])
        XCTAssertEqual(convMenuItems(conv(pinned: true), enabled: false), [])
    }

    /// frontend-chat 67: the tab's name carries the badge's number.
    func testTabNameCarriesTheBadgeNumber() {
        XCTAssertEqual(tabAccessibilityLabel("消息", .chats, badge: 5), "消息，5 条未读")
        XCTAssertEqual(tabAccessibilityLabel("消息", .chats, badge: 120), "消息，99+ 条未读")
        XCTAssertEqual(tabAccessibilityLabel("消息", .chats, badge: 0), "消息")
        XCTAssertEqual(tabAccessibilityLabel("通讯录", .contacts, badge: 2), "通讯录，2 个新的朋友")
    }

    func testCachedConfigConvSettingsOldCacheIsOff() throws {
        let old = try JSONDecoder().decode(CachedConfig.self, from: Data(#"{"files":true,"msgActions":true}"#.utf8))
        XCTAssertNil(old.convSettings)
        let json = #"{"registerMode":"open","demoLogin":true,"features":{"files":true,"convSettings":true},"limits":{"usernameMinLen":3,"usernameMaxLen":20,"passwordMinLen":8,"passwordMaxLen":64,"nicknameMaxLen":20,"deviceNameMaxLen":40}}"#
        XCTAssertEqual(CachedConfig(try JSONDecoder().decode(AccountConfig.self, from: Data(json.utf8))).convSettings, true)
        func model(_ cached: String?) -> AppModel {
            let prefs = UIPrefs(defaults: UserDefaults(suiteName: "tt.c5.cfg.\(UUID().uuidString)")!)
            if let cached { prefs.set("ui.config", cached) }
            return AppModel(
                config: AppConfig(server: URL(string: "http://localhost:1"), demoLogin: true), sessions: MemorySessionStore(),
                theme: ThemeController(prefs: prefs), prefs: prefs, makeClient: { _, _ in Fake().client },
                makeAccount: { _, s in fakeAccount(store: s, clock: FakeClock()) })
        }
        XCTAssertFalse(model(nil).convSettingsEnabled)
        XCTAssertFalse(model(#"{"files":true,"msgActions":true}"#).convSettingsEnabled, "a cache from before C5: off")
        XCTAssertTrue(model(#"{"files":true,"convSettings":true}"#).convSettingsEnabled)
    }

    // MARK: App layer with the SDK (fake transport)

    private func loggedIn(convs: [JSONValue]) async -> (AppModel, Fake) {
        let fake = Fake()
        let prefs = UIPrefs(defaults: UserDefaults(suiteName: "tt.c5.\(UUID().uuidString)")!)
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

    /// TC-CVS-02-02: normal unread 2 and 3, notifications off 5: the badge's number is 5; notifications back on, 10.
    func testTC_CVS_02_02_totalUnreadSkipsNotifyOff() async {
        let (m, fake) = await loggedIn(convs: [
            convFrame("c2c:alice:bob", maxSeq: 2, unread: 2, lastMsg: last("a", seq: 2)),
            convFrame("c2c:alice:carol", maxSeq: 3, unread: 3, lastMsg: last("b", seq: 3)),
            convFrame("group:g1", maxSeq: 5, unread: 5, lastMsg: last("c", seq: 5), notifyOff: true),
        ])
        let store = m.store!
        XCTAssertEqual(store.totalUnread, 5)
        let g = store.conversation("group:g1")!
        let task = Task { await m.toggleConvNotifyOff(g) }
        await flush()
        XCTAssertEqual(store.totalUnread, 10, "optimistic")
        let c = fake.transport.current
        XCTAssertEqual(c.last("convSet")?.data, ["convId": "group:g1", "notifyOff": false])
        c.ack("convSet", ["conv": convFrame("group:g1", maxSeq: 5, unread: 5, lastMsg: last("c", seq: 5))])
        await task.value
        XCTAssertEqual(store.totalUnread, 10)
        XCTAssertNil(m.hub.toast)
    }

    /// TC-CVS-02-05: notifications off with 5 unread, one mentioning me, plus a normal 2: 3.
    func testTC_CVS_02_05_mentionsCountInTheTotal() async {
        let (m, _) = await loggedIn(convs: [
            convFrame("c2c:alice:bob", maxSeq: 2, unread: 2, lastMsg: last("a", seq: 2)),
            convFrame("group:g1", maxSeq: 5, unread: 5, lastMsg: last("c", seq: 5), notifyOff: true, mentionUnread: 1),
        ])
        XCTAssertEqual(m.store!.totalUnread, 3)
    }

    /// 4220 rolls the pin back and says "最多置顶 20 个会话"; nothing is sent again by itself (frontend-chat 56).
    func testPin4220RollsBackWithCopyNoRetry() async {
        let (m, fake) = await loggedIn(convs: [convFrame("c2c:alice:bob", maxSeq: 1, lastMsg: last("a", seq: 1))])
        let store = m.store!
        let task = Task { await m.toggleConvPinned(store.conversation("c2c:alice:bob")!) }
        await flush()
        XCTAssertEqual(store.conversation("c2c:alice:bob")?.isPinned, true, "optimistic")
        let c = fake.transport.current
        XCTAssertEqual(c.last("convSet")?.data, ["convId": "c2c:alice:bob", "pinned": true])
        c.ackError("convSet", 4220)
        await task.value
        XCTAssertEqual(store.conversation("c2c:alice:bob")?.isPinned, false)
        XCTAssertEqual(m.hub.toast?.text, "最多置顶 20 个会话")
        fake.clock.advance(60_000)
        await flush()
        XCTAssertEqual(c.frames("convSet").count, 1)
    }

    /// 4290 on either command: "操作过于频繁".
    func testRateLimitCopyForSetAndDelete() async {
        let (m, fake) = await loggedIn(convs: [convFrame("c2c:alice:bob", maxSeq: 1, lastMsg: last("a", seq: 1))])
        let c = fake.transport.current
        let set = Task { await m.toggleConvNotifyOff(m.store!.conversation("c2c:alice:bob")!) }
        await flush()
        c.ackError("convSet", 4290)
        await set.value
        XCTAssertEqual(m.hub.toast?.text, "操作过于频繁")
        XCTAssertEqual(m.store!.conversation("c2c:alice:bob")?.isNotifyOff, false)
        m.hub.dismissToastForTest()
        let del = Task { await m.deleteConv("c2c:alice:bob") }
        await flush()
        c.ackError("convDelete", 4290)
        await del.value
        XCTAssertEqual(m.hub.toast?.text, "操作过于频繁")
        XCTAssertNotNil(m.store!.conversation("c2c:alice:bob"), "back in the list")
    }

    /// TC-CVS-03-08 (app part): "删除" asks first and sends nothing until confirmed; confirmed, the conversation leaves and
    /// its draft goes; a failure brings both back.
    func testTC_CVS_03_08_confirmThenDeleteDropsTheDraftFailureKeepsIt() async {
        let (m, fake) = await loggedIn(convs: [
            convFrame("c2c:alice:bob", maxSeq: 4, lastMsg: last("a", seq: 4)),
            convFrame("c2c:alice:carol", maxSeq: 2, lastMsg: last("b", seq: 2)),
        ])
        let c = fake.transport.current
        m.drafts.put("c2c:alice:bob", "草稿内容")
        m.drafts.put("c2c:alice:carol", "另一个草稿")
        m.askDeleteConv("c2c:alice:bob")
        XCTAssertEqual(m.hub.dialog?.id, "conv-delete-dialog")
        await flush()
        XCTAssertTrue(c.frames("convDelete").isEmpty, "nothing before the confirmation")
        m.hub.dismissDialog()  // "取消"
        XCTAssertEqual(m.drafts.text("c2c:alice:bob"), "草稿内容")
        XCTAssertNotNil(m.store!.conversation("c2c:alice:bob"))

        let failed = Task { await m.deleteConv("c2c:alice:carol") }
        await flush()
        XCTAssertNil(m.store!.conversation("c2c:alice:carol"), "optimistic")
        c.ackError("convDelete", 5000)
        await failed.value
        XCTAssertNotNil(m.store!.conversation("c2c:alice:carol"))
        XCTAssertEqual(m.drafts.text("c2c:alice:carol"), "另一个草稿")
        XCTAssertEqual(m.hub.toast?.text, "服务异常，请稍后重试")

        let ok = Task { await m.deleteConv("c2c:alice:bob") }
        await flush()
        XCTAssertEqual(c.last("convDelete")?.data, ["convId": "c2c:alice:bob", "upToSeq": 4])
        c.ack("convDelete", ["clearedSeq": 4])
        await ok.value
        await flush()
        XCTAssertNil(m.store!.conversation("c2c:alice:bob"))
        XCTAssertNil(m.drafts.draft("c2c:alice:bob"))
        XCTAssertEqual(m.drafts.text("c2c:alice:carol"), "另一个草稿", "only that conversation's draft")
    }

    /// TC-CVS-04-05 (app part, frontend-chat 55): another device deletes: the draft here goes too, an open confirmation for
    /// it closes, and the chat page's input is told to empty.
    func testTC_CVS_04_05_otherDeviceDeleteDropsDraftAndClosesConfirmation() async {
        let (m, fake) = await loggedIn(convs: [convFrame("c2c:alice:bob", maxSeq: 4, lastMsg: last("a", seq: 4))])
        m.drafts.put("c2c:alice:bob", "草稿内容")
        m.askDeleteConv("c2c:alice:bob")
        let before = m.store!.deletedTicks["c2c:alice:bob"] ?? 0
        fake.transport.current.receive([
            "cmd": "event", "data": ["type": "convDeleted", "convId": "c2c:alice:bob", "clearedSeq": 4],
        ])
        await flush()
        XCTAssertNil(m.store!.conversation("c2c:alice:bob"))
        XCTAssertNil(m.drafts.draft("c2c:alice:bob"))
        XCTAssertNil(m.hub.dialog)
        XCTAssertEqual(m.store!.deletedTicks["c2c:alice:bob"], before + 1)
    }

    /// TC-CVS-04-01 (app part): another device's settings show at once: pinned first, notifications off.
    func testTC_CVS_04_01_settingsEventReorders() async {
        let (m, fake) = await loggedIn(convs: [
            convFrame("c2c:alice:bob", maxSeq: 1, lastMsg: last("a", seq: 1), updatedAt: 2),
            convFrame("c2c:alice:carol", maxSeq: 1, lastMsg: last("b", seq: 1), updatedAt: 1),
        ])
        XCTAssertEqual(m.store!.convs.map(\.convId), ["c2c:alice:bob", "c2c:alice:carol"])
        fake.transport.current.receive([
            "cmd": "event",
            "data": ["type": "convSettingsChanged", "convId": "c2c:alice:carol", "pinned": true, "pinnedAt": 9, "notifyOff": true],
        ])
        await flush()
        XCTAssertEqual(m.store!.convs.map(\.convId), ["c2c:alice:carol", "c2c:alice:bob"])
        XCTAssertEqual(m.store!.convs.first?.isNotifyOff, true)
    }

    /// frontend-chat 66: a group probed in with no message is "done", which blocks nothing.
    func testEmptyGroupProbeDoneBlocksNothing() {
        XCTAssertNil(chatBlock(snapshot: nil, probe: .done))
    }
}
