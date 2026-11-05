import TiantingIM
import TiantingIMTesting
import XCTest

@testable import TiantingAppKit

/// F-UI-44 and F-PUSH-12 against the SDK with a fake transport; UserDefaults is a throwaway suite.
@MainActor
final class NoticeStoreTests: XCTestCase {
    private let me = "alice"
    private var key: String { noticeSeenKey(me) }
    private var prefs: UIPrefs!
    private var suite: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = UserDefaults(suiteName: "tt.notice.\(UUID().uuidString)")!
        prefs = UIPrefs(defaults: suite)
    }

    private func start(limits: PushLimits = PushLimits()) async -> (NoticeStore, Fake) {
        let fake = Fake(limits: limits)
        let store = NoticeStore(client: fake.client, userId: me, prefs: prefs)
        store.attach()
        await flush()
        fake.client.connect(token: "t")
        let c = fake.transport.current
        c.open()
        c.ack("auth", ["userId": .string(me), "serverTime": 1000])
        await flush()
        return (store, fake)
    }

    private func item(
        _ id: String, seq: Int64? = nil, ts: Int64 = 2000, text: JSONValue = "内容", type: String = "notice"
    ) -> JSONValue {
        var o: [String: JSONValue] = [
            "pushId": .string(id), "type": .string(type), "data": ["text": text], "ts": .int(ts), "target": "user",
        ]
        if let seq { o["pushSeq"] = .int(seq) }
        return .object(o)
    }

    /// A first round with nothing in it: sets the baseline when there is none, and lets live frames follow.
    private func emptyRound(_ fake: Fake, latest: Int64 = 0) async {
        await round(fake, [], latest: latest)
    }

    private func round(_ fake: Fake, _ items: [JSONValue], latest: Int64) async {
        fake.transport.current.ack("pushSync", ["pushes": .array(items), "hasMore": false, "latestSeq": .int(latest)])
        await flush()
    }

    private func live(_ fake: Fake, _ f: JSONValue) async {
        fake.transport.current.receive(["cmd": "push", "data": f])
        await flush()
    }

    // MARK: Banner and list

    func testLiveNoticeHasBannerListAndCount() async {
        // AC-UI-44-1, AC-PUSH-12 rule 2
        let (s, fake) = await start()
        await emptyRound(fake)
        await live(fake, item("p1", seq: 1, text: "今晚 22 点维护"))
        XCTAssertEqual(s.banner?.text, "系统通知：今晚 22 点维护")
        XCTAssertEqual(s.list.map(\.text), ["今晚 22 点维护"])
        XCTAssertEqual(s.unseen, 1)
    }

    func testBannerIsFirst50CodePointsListHasAll() async {
        let (s, fake) = await start()
        await emptyRound(fake)
        let text = String(repeating: "😀", count: 60)
        await live(fake, item("p1", seq: 1, text: .string(text)))
        XCTAssertEqual(s.banner?.text, "系统通知：" + String(repeating: "😀", count: 50))
        XCTAssertEqual(s.list.first?.text, text)
    }

    func testBannerGoesAwayAndANewOneRestartsTheTimer() async throws {
        let (s, fake) = await start()
        s.bannerDuration = .milliseconds(300)
        await emptyRound(fake)
        await live(fake, item("p1", seq: 1))
        try await Task.sleep(for: .milliseconds(200))
        await live(fake, item("p2", seq: 2, text: "第二条"))
        XCTAssertEqual(s.banner?.text, "系统通知：第二条")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(s.banner, "the second notice restarted the timer")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(s.banner)
    }

    func testDefaultBannerDurationIs5Seconds() async {
        let (s, _) = await start()
        XCTAssertEqual(s.bannerDuration, .seconds(5))
    }

    func testDismissBanner() async {
        let (s, fake) = await start()
        await emptyRound(fake)
        await live(fake, item("p1", seq: 1))
        s.dismissBanner()
        XCTAssertNil(s.banner)
    }

    func testReplayedHasNoBannerButIsInTheList() async {
        // AC-PUSH-12-1
        let (s, fake) = await start()
        await round(fake, [item("p1", seq: 1, ts: 500)], latest: 1)
        XCTAssertNil(s.banner)
        XCTAssertEqual(s.list.map(\.pushId), ["p1"])
    }

    func testOtherTypesAreIgnored() async {
        // AC-UI-44-2
        let (s, fake) = await start()
        await emptyRound(fake)
        await live(fake, item("p1", seq: 1, type: "promo"))
        XCTAssertNil(s.banner)
        XCTAssertEqual(s.list.count, 0)
        XCTAssertEqual(s.unseen, 0)
    }

    func testNoticeWithoutStringTextIsIgnored() async {
        let (s, fake) = await start()
        await emptyRound(fake)
        await live(fake, item("p1", seq: 1, text: 42))
        XCTAssertEqual(s.list.count, 0)
        XCTAssertEqual(s.unseen, 0)
    }

    func testOrderedByTsThenSeq() async {
        // AC-PUSH-12-2
        let (s, fake) = await start()
        await emptyRound(fake)
        await live(fake, item("live", seq: 1, ts: 2000))
        fake.transport.current.receive(["cmd": "push", "data": item("old", ts: 100)])
        fake.transport.current.receive(["cmd": "push", "data": item("new", ts: 3000)])
        fake.transport.current.receive(["cmd": "push", "data": item("same-a", seq: 2, ts: 2500)])
        fake.transport.current.receive(["cmd": "push", "data": item("same-b", seq: 3, ts: 2500)])
        await flush()
        XCTAssertEqual(s.list.map(\.pushId), ["new", "same-b", "same-a", "live", "old"])
    }

    func testAtMost100NewestAndTheRestStillCount() async {
        // Rule 1
        let (s, fake) = await start()
        prefs.set(key, "0")
        let items = (1...120).map { (n: Int) in item("p\(n)", seq: Int64(n), ts: Int64(100 + n)) }
        await round(fake, items, latest: 120)
        XCTAssertEqual(s.list.count, 100)
        XCTAssertEqual(s.list.first?.pushId, "p120")
        XCTAssertEqual(s.list.last?.pushId, "p21")
        XCTAssertEqual(s.unseen, 120)
    }

    func testSamePushIdOnlyOnce() async {
        // The SDK is at-least-once: a repeat that fell out of its dedupe window reaches the app and must not double up.
        var limits = PushLimits()
        limits.seenMax = 1
        let (s, fake) = await start(limits: limits)
        await emptyRound(fake)
        for id in ["p1", "p2", "p1"] { await live(fake, item(id, ts: 2000)) }
        XCTAssertEqual(s.list.map(\.pushId).sorted(), ["p1", "p2"])
        XCTAssertEqual(s.unseen, 2)
    }

    // MARK: Unseen and lastSeenSeq

    func testReplayAboveLastSeenCountsOpeningClears() async {
        // AC-PUSH-12-3
        prefs.set(key, "40")
        let (s, fake) = await start()
        await round(fake, [item("a", seq: 39, ts: 500), item("b", seq: 41, ts: 500), item("c", seq: 42, ts: 500)], latest: 42)
        XCTAssertEqual(s.unseen, 2)
        s.enterPage()
        XCTAssertEqual(s.unseen, 0)
        XCTAssertEqual(prefs.get(key), "42")
    }

    func testNoBaselineThisRoundNotCountedLaterRoundIs() async {
        // AC-PUSH-12-5
        let (s, fake) = await start()
        let c = fake.transport.current
        await round(fake, [item("a", seq: 1, ts: 500), item("b", seq: 2, ts: 500), item("d", seq: 3, ts: 500)], latest: 3)
        XCTAssertEqual(s.unseen, 0)
        XCTAssertEqual(prefs.get(key), "3")
        c.drop(1006)
        fake.clock.advance(1000)
        let c2 = fake.transport.current
        c2.open()
        c2.ack("auth", ["userId": .string(me), "serverTime": 1000])
        await flush()
        await round(fake, [item("e", seq: 4, ts: 500)], latest: 4)
        XCTAssertEqual(s.unseen, 1)
    }

    func testSequenceGoesBackAfterRestore() async {
        // AC-PUSH-12-8
        prefs.set(key, "100")
        let (s, fake) = await start()
        await round(fake, [], latest: 55)
        XCTAssertEqual(prefs.get(key), "55")
        fake.transport.current.receive(["cmd": "push", "data": item("x", seq: 56, ts: 500)])
        await flush()
        XCTAssertEqual(s.unseen, 1)
    }

    func testReplayWithoutSeqNotCountedLiveWithoutSeqCounted() async {
        // Rule 3, rule 4
        prefs.set(key, "5")
        let (s, fake) = await start()
        await emptyRound(fake, latest: 5)
        await live(fake, item("old", ts: 500))
        XCTAssertEqual(s.unseen, 0)
        await live(fake, item("all", ts: 2000))
        XCTAssertEqual(s.unseen, 1)
        s.enterPage()
        XCTAssertEqual(prefs.get(key), "5", "a frame without pushSeq does not move lastSeenSeq")
    }

    func testStayingOnThePageDoesNotCount() async {
        // AC-PUSH-12-11
        let (s, fake) = await start()
        await emptyRound(fake)
        s.enterPage()
        await live(fake, item("p1", seq: 1))
        XCTAssertEqual(s.list.count, 1)
        XCTAssertEqual(s.unseen, 0)
        XCTAssertEqual(prefs.get(key), "1")
        s.leavePage()
        XCTAssertEqual(s.unseen, 0)
        await live(fake, item("p2", seq: 2))
        XCTAssertEqual(s.unseen, 1, "counts again after leaving")
    }

    func testNoticesOtherThanNoticeTypeDoNotMoveLastSeen() async {
        // Rule 4: "received" only means type=notice.
        let (s, fake) = await start()
        await emptyRound(fake)
        await live(fake, item("promo", seq: 1, type: "promo"))
        s.enterPage()
        XCTAssertEqual(prefs.get(key), "0")
    }

    func testNotANumberCountsAsNoLastSeen() async {
        prefs.set(key, "12x")
        let (s, fake) = await start()
        await round(fake, [item("a", seq: 1, ts: 500)], latest: 1)
        XCTAssertEqual(s.unseen, 0)
        XCTAssertEqual(prefs.get(key), "1")
    }

    func testRaiseNeverLowers() async {
        // Rule 5: normal updates take the max.
        prefs.set(key, "9")
        let (s, fake) = await start()
        await emptyRound(fake, latest: 9)
        await live(fake, item("p1", seq: 3, ts: 500))
        s.enterPage()
        XCTAssertEqual(prefs.get(key), "9")
    }

    func testPrefsHoldOnlyAPlainNumber() async {
        // AC-PUSH-12-10, NF-UI-13
        let (s, fake) = await start()
        await emptyRound(fake)
        await live(fake, item("p1", seq: 1, text: "ZXQ-PUSH-通知文本"))
        s.enterPage()
        let dump = suite.dictionaryRepresentation().filter { $0.key.hasPrefix("ui.") }
        XCTAssertEqual(Set(dump.keys), [key])
        XCTAssertEqual(dump[key] as? String, "1")
    }

    func testDetachStopsReceiving() async {
        let (s, fake) = await start()
        await emptyRound(fake)
        s.detach()
        await live(fake, item("p1", seq: 1))
        XCTAssertEqual(s.list.count, 0)
    }

    // MARK: AppModel

    private func model() -> (AppModel, Fake) {
        let fake = Fake()
        let m = AppModel(
            config: AppConfig(server: URL(string: "http://localhost:1"), demoLogin: true),
            sessions: MemorySessionStore(),
            theme: ThemeController(prefs: prefs),
            prefs: prefs,
            makeClient: { _ in fake.client })
        return (m, fake)
    }

    private func logIn(_ m: AppModel, _ fake: Fake) async {
        m.login(Session(userId: me, token: "tok"))
        let c = fake.transport.current
        c.open()
        c.ack("auth", ["userId": .string(me), "serverTime": 1000])
        await flush()
    }

    func testAppSubscribesBeforeConnecting() async {
        let (m, fake) = model()
        await logIn(m, fake)
        XCTAssertEqual(fake.transport.current.frames("pushSync").count, 1, "the first auth already catches up")
        XCTAssertNotNil(m.notices)
    }

    func testLogoutDeletesTheKeyAndKeepsOtherPrefs() async {
        // AC-PUSH-12-6
        let (m, fake) = model()
        prefs.set(ThemeController.key, "dark")
        await logIn(m, fake)
        await round(fake, [], latest: 3)
        XCTAssertEqual(prefs.get(key), "3")
        m.logout()
        XCTAssertNil(prefs.get(key))
        XCTAssertEqual(prefs.get(ThemeController.key), "dark")
        XCTAssertNil(m.notices)
    }

    func testKickKeepsTheKey() async {
        // AC-PUSH-12-6: the kicked dialog's button.
        let (m, fake) = model()
        await logIn(m, fake)
        await round(fake, [], latest: 3)
        fake.transport.current.receive(["cmd": "event", "data": ["type": "kicked", "reason": "kickedByOtherDevice"]])
        fake.transport.current.drop(4009)
        await flush()
        XCTAssertNotNil(m.fatal)
        m.logout(keepNoticeSeen: true)
        XCTAssertEqual(prefs.get(key), "3")
        XCTAssertNil(m.session)
    }

    func testBannerTapOpensTheNoticesPage() async {
        let (m, fake) = model()
        await logIn(m, fake)
        await round(fake, [], latest: 0)
        m.push(.settings)
        fake.transport.current.receive(["cmd": "push", "data": item("p1", seq: 1)])
        await flush()
        XCTAssertNotNil(m.notices?.banner)
        m.openNotices()
        XCTAssertNil(m.notices?.banner)
        XCTAssertEqual(m.tab, .me)
        XCTAssertEqual(m.path, [.notices])
    }

    func testDeepLink() {
        XCTAssertEqual(parseDeepLink(URL(string: "tianting://me/notices")!), Destination(tab: .me, path: [.notices]))
    }
}
