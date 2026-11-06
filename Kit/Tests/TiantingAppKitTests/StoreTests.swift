import TiantingIM
import TiantingIMTesting
import XCTest

@testable import TiantingAppKit

/// The app's state layer against the SDK with a fake transport.
@MainActor
final class StoreTests: XCTestCase {
    private func model(store: AccountSessionStore? = nil) -> (AppModel, Fake) {
        let sessions = store ?? MemorySessionStore()
        let fake = Fake()
        let config = AppConfig(server: URL(string: "http://localhost:1"), demoLogin: true)
        let prefs = UIPrefs(defaults: UserDefaults(suiteName: "tt.store.\(UUID().uuidString)")!)
        let m = AppModel(
            config: config, sessions: sessions, theme: ThemeController(prefs: prefs), makeClient: { _ in fake.client },
            makeAccount: { _, s in fakeAccount(store: s, clock: fake.clock) })
        return (m, fake)
    }

    private func loggedIn(convs: [JSONValue] = []) async -> (AppModel, Fake, MemorySessionStore) {
        let sessions = MemorySessionStore()
        let (m, fake) = model(store: sessions)
        await m.login(demoSession("alice", "tok"))
        let c = fake.transport.current
        c.open()
        c.ack("auth", ["userId": "alice", "serverTime": .int(fake.clock.now())])
        await flush()
        XCTAssertFalse(m.store!.convsLoaded, "no skeleton flash before convs (AC-UI-20-1)")
        c.ack("convs", ["convs": .array(convs), "truncated": false])
        await flush()
        return (m, fake, sessions)
    }

    func testConvsLoadedAndTruncated() async {
        let (m, fake, _) = await loggedIn()
        let store = m.store!
        XCTAssertTrue(store.convsLoaded)
        XCTAssertFalse(store.truncated)
        fake.transport.current.receive([
            "cmd": "event", "data": ["type": "convAdded", "conv": convFrame("group:g1", name: "群", memberCount: 3)],
        ])
        await flush()
        XCTAssertEqual(store.conversation("group:g1")?.memberCount, 3)
    }

    func testLoginStoresAndLogoutClears() async {
        // AC-UI-16-3, AC-UI-18-3
        let (m, fake, sessions) = await loggedIn()
        XCTAssertEqual(sessions.saved?.accessToken, "tok")
        XCTAssertEqual(sessions.saved?.mode, .demo)
        m.drafts.put("c", "x")
        m.push(.settings)
        m.logout()
        XCTAssertNil(m.session)
        XCTAssertNil(m.store)
        XCTAssertEqual(m.path, [])
        XCTAssertNil(m.drafts.draft("c"))  // AC-UI-24-4
        await m.logoutFinished()
        XCTAssertNil(sessions.saved)
        XCTAssertEqual(fake.transport.current.closedWith?.code, 1000)
    }

    func testFatalKeepsPageUntilOk() async {
        // AC-UI-18-2, AC-UI-43-3: no reconnect, page stays.
        let (m, fake, sessions) = await loggedIn()
        m.push(.settings)
        fake.transport.current.receive(["cmd": "event", "data": ["type": "kicked", "reason": "suspended", "until": nil]])
        fake.transport.current.drop(4012)
        await flush()
        XCTAssertEqual(m.fatal, .kicked(reason: "suspended", code: 4012, until: .permanent))
        XCTAssertEqual(fatalText(m.fatal!), "账号已被封禁")
        XCTAssertEqual(m.path, [.settings], "stays on the current page")
        let before = fake.transport.connections.count
        fake.clock.advance(60_000)
        XCTAssertEqual(fake.transport.connections.count, before, "does not reconnect")
        m.acknowledgeFatal()
        XCTAssertNil(m.fatal)
        await m.logoutFinished()
        XCTAssertNil(sessions.saved)
    }

    func testSendFailureToastsOnceExceptSilentCodes() async {
        // AC-UI-08-3, AC-UI-08-5, AC-UI-31-1, F-UI-41 rule 5
        let (m, fake, _) = await loggedIn()
        let store = m.store!
        let conv = "c2c:alice:bob"
        func sendAndFail(_ code: Int) async {
            _ = try? store.client.send(conv, "x")
            await flush()
            fake.transport.current.ackError("send", code)
            await flush()
        }
        await sendAndFail(4290)
        XCTAssertEqual(m.hub.toast?.text, "发送太频繁，请稍后再试")
        let first = m.hub.toast?.id
        m.hub.dismissToastForTest()
        await sendAndFail(4035)
        XCTAssertNil(m.hub.toast, "tips, not toasts")
        XCTAssertEqual(store.sendTips[conv]?.values.first, 4035)
        await sendAndFail(4036)
        XCTAssertNil(m.hub.toast)
        await sendAndFail(4137)
        XCTAssertNil(m.hub.toast)
        await sendAndFail(4031)
        XCTAssertNil(m.hub.toast, "the bar says it")
        await sendAndFail(4042)
        XCTAssertEqual(m.hub.toast?.text, "用户不存在")
        XCTAssertNotEqual(m.hub.toast?.id, first)
    }

    func testTimeoutNoToast() async {
        // AC-UI-08-3
        let (m, fake, _) = await loggedIn()
        _ = try? m.store!.client.send("c2c:alice:bob", "x")
        await flush()
        fake.clock.advance(10_001)
        await flush()
        XCTAssertEqual(m.store!.messages("c2c:alice:bob").last?.status, .failed)
        XCTAssertNil(m.hub.toast)
    }

    func testPendingCountAndRemoveFailed() async {
        // AC-UI-16-2, AC-UI-09-5
        let (m, fake, _) = await loggedIn()
        let store = m.store!
        let conv = "c2c:alice:bob"
        _ = try? store.client.send(conv, "x")
        await flush()
        fake.transport.current.ackError("send", 4042)
        await flush()
        XCTAssertEqual(store.pendingCount, 1)
        let id = store.messages(conv).last!.clientMsgId
        store.client.removeFailed(conv, id)
        await flush()
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertTrue(store.messages(conv).isEmpty)
    }

    func testRetryKeepsClientMsgId() async {
        // AC-UI-08-2, AC-UI-09-4
        let (m, fake, _) = await loggedIn()
        let store = m.store!
        let conv = "c2c:alice:bob"
        _ = try? store.client.send(conv, "x")
        await flush()
        let c = fake.transport.current
        let original = c.last("send")?.data?["clientMsgId"]?.stringValue
        c.ackError("send", 4290)
        await flush()
        store.client.retry(conv, store.messages(conv).last!.clientMsgId)
        await flush()
        XCTAssertEqual(c.frames("send").count, 2)
        XCTAssertEqual(c.last("send")?.data?["clientMsgId"]?.stringValue, original)
    }

    func testRemovedSnapshotAndBackIn() async {
        // AC-UI-33-4, AC-UI-33-11, AC-UI-33-12
        let (m, fake, _) = await loggedIn(convs: [convFrame("group:g1", name: "群")])
        let store = m.store!
        XCTAssertNil(store.snapshot("group:g1"))
        let v = store.snapshotVersion
        fake.transport.current.receive([
            "cmd": "event", "data": ["type": "convRemoved", "convId": "group:g1", "reason": "dissolved"],
        ])
        await flush()
        XCTAssertGreaterThan(store.snapshotVersion, v)
        XCTAssertEqual(store.snapshot("group:g1")?.name, "群")
        XCTAssertEqual(chatBlock(snapshot: store.snapshot("group:g1"), probe: .idle)?.bar, "群聊已解散")
        XCTAssertNil(store.conversation("group:g1"))
        fake.transport.current.receive([
            "cmd": "event", "data": ["type": "convAdded", "conv": convFrame("group:g1", name: "群")],
        ])
        await flush()
        XCTAssertNil(store.snapshot("group:g1"))
        XCTAssertNotNil(store.conversation("group:g1"))
    }

    func testUnknownGroupErrorsReachThePage() async {
        // AC-UI-33-10: a sync goes out and the error comes back.
        let (m, fake, _) = await loggedIn()
        let store = m.store!
        let task = Task { () -> Int? in
            do {
                _ = try await store.client.loadHistory("group:g1")
                return nil
            } catch {
                return (error as? IMError)?.code
            }
        }
        await flush()
        let c = fake.transport.current
        XCTAssertEqual(c.last("sync")?.data?["beforeSeq"]?.intValue, 9_007_199_254_740_991)
        c.ackError("sync", 4033)
        let code = await task.value
        XCTAssertEqual(code, 4033)
    }

    func testMuteVersionBumpsAndExpiry() async {
        // AC-UI-41-1, AC-UI-41-4, AC-UI-41-5
        let (m, fake, _) = await loggedIn()
        let store = m.store!
        let v = store.muteVersion
        let until = fake.clock.now() + 60_000
        fake.transport.current.receive([
            "cmd": "event", "data": ["type": "muted", "scope": "user", "mutedUntil": .int(until)],
        ])
        await flush()
        XCTAssertGreaterThan(store.muteVersion, v)
        XCTAssertEqual(store.mute("c2c:alice:bob")?.mutedUntil, .at(until))
        fake.clock.advance(60_001)
        await flush()
        XCTAssertNil(store.mute("c2c:alice:bob"), "local expiry without an unmuted event")
    }

    func testGroupAllMuteBarText() async {
        // AC-UI-41-6 (TC-UI-41-07), F-ADM-42
        for (role, barred) in [("member", true), ("owner", false), ("admin", false)] {
            let (m, fake, _) = await loggedIn(convs: [convFrame("group:g1", name: "群", myRole: role)])
            let store = m.store!
            let v = store.muteVersion
            fake.transport.current.receive([
                "cmd": "event", "data": ["type": "muted", "scope": "groupAll", "groupId": "g1", "mutedUntil": nil],
            ])
            await flush()
            XCTAssertGreaterThan(store.muteVersion, v, role)
            if barred {
                XCTAssertEqual(store.mute("group:g1").map(mutedText), "群主已开启全员禁言")
            } else {
                XCTAssertNil(store.mute("group:g1"), role)
            }
            fake.transport.current.receive([
                "cmd": "event", "data": ["type": "unmuted", "scope": "groupAll", "groupId": "g1"],
            ])
            await flush()
            XCTAssertNil(store.mute("group:g1"), role)
        }
    }

    func testGroupAllMuteFromConvsOnLogin() async {
        // AC-UI-41-6: turned on while offline.
        let (m, _, _) = await loggedIn(convs: [convFrame("group:g1", name: "群", myRole: "member", allMuted: true)])
        XCTAssertEqual(m.store!.mute("group:g1").map(mutedText), "群主已开启全员禁言")
    }

    func testDeletedMessageHasNoBody() async {
        // AC-UI-42-1
        let (m, fake, _) = await loggedIn(convs: [convFrame("group:g1", name: "群", maxSeq: 0)])
        let store = m.store!
        let c = fake.transport.current
        c.receive([
            "cmd": "msg",
            "data": [
                "msgId": "m1", "clientMsgId": "x1", "convId": "group:g1", "seq": 1, "from": "bob", "type": "text",
                "body": ["text": "ZXQ-SECRET"], "ts": .int(fake.clock.now()),
            ],
        ])
        await flush()
        XCTAssertEqual(store.messages("group:g1").first?.body.text, "ZXQ-SECRET")
        c.receive(["cmd": "event", "data": ["type": "msgDeleted", "convId": "group:g1", "msgIds": ["m1"], "seqs": [1]]])
        await flush()
        XCTAssertEqual(store.messages("group:g1").first?.deleted, true)
        XCTAssertNil(store.messages("group:g1").first?.body.text)
        let summary = conversationSummary(store.conversation("group:g1")!, me: "alice") { $0 }
        XCTAssertEqual(summary, "该消息已被删除")
    }

    func testActiveConversationDrivesReadReports() async {
        // AC-UI-06-4, AC-UI-06-7: messages count as unread once the page is not the active one.
        let conv = "group:g1"
        let (m, fake, _) = await loggedIn(convs: [convFrame(conv, name: "群")])
        let store = m.store!
        let c = fake.transport.current
        func receive(_ seq: Int64) async {
            c.receive([
                "cmd": "msg",
                "data": [
                    "msgId": .string("m\(seq)"), "clientMsgId": .string("x\(seq)"), "convId": .string(conv), "seq": .int(seq),
                    "from": "bob", "type": "text", "body": ["text": "t"], "ts": .int(fake.clock.now()),
                ],
            ])
            await flush()
        }
        store.setActive(conv)
        await receive(1)
        XCTAssertEqual(store.conversation(conv)?.unread, 0)
        store.clearActive(conv)
        await receive(2)
        XCTAssertEqual(store.conversation(conv)?.unread, 1)
        XCTAssertEqual(store.totalUnread, 1)
        // A new chat page appearing before the old one disappears keeps its own active state.
        store.setActive("group:other")
        store.clearActive(conv)
        store.setActive(conv)
        fake.clock.advance(2_000)
        await flush()
        XCTAssertEqual(c.last("read")?.data?["seq"]?.intValue, 2, "reads up to the message that came while away")
    }

    func testDeepLinkWaitsForLogin() async {
        // AC-UI-01-3
        let (m, fake) = model()
        m.handle(url: URL(string: "tianting://chat/c2c%3Aalice%3Abob")!)
        XCTAssertEqual(m.path, [])
        XCTAssertEqual(m.pendingDestination?.path, [.chat("c2c:alice:bob")])
        await m.login(demoSession("alice", "t"))
        XCTAssertEqual(m.path, [.chat("c2c:alice:bob")])
        XCTAssertNil(m.pendingDestination)
        _ = fake
        // Logged in: immediately.
        m.handle(url: URL(string: "tianting://me/settings")!)
        XCTAssertEqual(m.tab, .me)
        XCTAssertEqual(m.path, [.settings])
    }

    func testRestoreUsesStoredSession() async {
        let sessions = MemorySessionStore()
        sessions.saved = demoSession("alice", "tok")
        let (m, fake) = model(store: sessions)
        await m.restore()
        XCTAssertEqual(m.session?.userId, "alice")
        XCTAssertEqual(fake.transport.connections.count, 1)
        fake.transport.current.open()
        XCTAssertEqual(fake.transport.current.last("auth")?.data?["token"]?.stringValue, "tok")
    }

    func testToastReplacesAndExpires() async throws {
        // AC-UI-19-1
        let hub = UIHub()
        hub.toastDuration = .milliseconds(100)
        hub.show("a")
        hub.show("b")
        XCTAssertEqual(hub.toast?.text, "b")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(hub.toast)
    }

    func testLoggerTakesOnlyStaticStrings() {
        // AC-UI-90-12 by construction: this line compiles only with a literal.
        TTLog.event("test.event")
        TTLog.requestError("test.error", code: 1)
    }
}

extension UIHub {
    func dismissToastForTest() {
        clearToast()
    }
}
