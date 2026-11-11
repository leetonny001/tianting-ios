import XCTest

/// FE-698: the C6 cross-platform cases (reports and 4510; H5, Android and iOS on one im-server, the admin site on the same
/// server). The shared contract (tianting-web e2e/xp-c6.spec.ts, tianting-android CrossPlatformC6E2e and tianting-admin
/// e2e/xp-c6.spec.ts carry the same text, in Chinese):
/// - Run R; platforms P = h5, android, ios. One direction per reporting platform X (X is also the signals' namespace): the
///   reporter rX = xp{R}r{X}, the reported user vX = xp{R}v{X} (nickname = userId); vX is signed in on the other two
///   platforms at once (the receivers Y and Z: two devices of one user). Also o = xp{R}o (talks and recalls in the group),
///   s = xp{R}s (the sentinel), group G = xp{R}g "C6群-{R}" (o, rh5, randroid, rios), and the marker word W = zxqword{R}
///   (added to the list by the test, not a real word). The script seeds: vX says "XP6-v-{X}" to rX; o says "XP6-M-{R}" in G,
///   then "XP6-R-{X}" for h5, android, ios in that order; it waits until W applies.
/// - Receiver (vX on Y): (1) Sign in; rX's row says "XP6-v-{X}" with 1 unread; stay on the list; post ready-{Y}, wait for the
///   other receiver's ready (its sign-in sends this device a new-device notice, which must land before recording), start
///   recording what comes down (H5: WebSocket frames, Android: SDK events, iOS: frames on the relay), post armed-{Y}.
///   (2) On reported (t0) the script has s send the sentinel "XP6-s1-{X}" to vX: the sentinel is in the list within 2 seconds;
///   at t0 + 2 s everything recorded is about the sentinel's conversation only (AC-MOD-03-1, F-MOD-03 rule 7: the reported
///   user gets no frame at all) and rX's row is unchanged; post s1-ok-{Y} and record afresh. (3) On blocked (t0): sentinel
///   "XP6-s2-{X}", the same checks; then open rX's conversation: only "XP6-v-{X}", nothing with W (AC-MOD-02-1, client
///   side); post obs-done-{Y}.
/// - Reporter (rX on X): (1) Sign in, open vX's conversation with "XP6-v-{X}"; wait for both receivers' armed. (2) The
///   message menu's "举报", 辱骂骚扰, submit: "已提交，感谢你的反馈" and the block question (cancel); post reported. (3) Wait for
///   both s1-ok; send "XP6 含 {W}": failed, "消息包含不当内容，无法发送", the input empties; post blocked. (4) Wait for both
///   obs-done; open G with "XP6-M-{R}" and "XP6-R-{X}", wait 2 s so the read gets reported, post g-seen; the script has o
///   recall "XP6-R-{X}" and posts recalled (with the msgId); the last recall line's "举报", 其他, submit, no block question
///   (AC-MOD-03-11); "XP6-M-{R}"'s menu "举报", 垃圾广告, submit (AC-MOD-04-1: one report from each platform); post r-done.
/// - Last part (namespace final, all three online): each signs in as rX, opens G with "XP6-M-{R}", posts f-ready-{X}; the
///   admin site (a moderator) sees "XP6-M-{R}"'s row with "3 次", grants and reads the evidence (watermark), deletes the
///   message and posts deleting right before the last click; on deleting (t0) every platform loses "XP6-M-{R}" and shows
///   "该消息已被删除", then posts f-done-{X} (with ms); the admin resolves the report.
/// - Proof the receivers can fail: --fake X:report (no reporter; the script, as rX, sends vX one message and posts reported)
///   must fail them at (2); --fake X:block (the script really reports, then as rX sends a plain message and posts blocked)
///   must fail them at (3).
/// TT_E2E_XP (run), TT_E2E_XP_COORD (signals), TT_E2E_XP_FROM (the reporting platform X, for the receiver). Tests:
/// testXP6_reporter, testXP6_observer, testXP6_final. Without TT_E2E_XP these tests skip. Local results on the simulator.
@MainActor
final class CrossPlatformC6E2ETests: E2ECase {
    static let me = "ios"
    static let platforms = ["h5", "android", "ios"]

    var run: String { Self.env("TT_E2E_XP") ?? "" }
    var from: String { Self.env("TT_E2E_XP_FROM") ?? "" }
    var coord: String { Self.env("TT_E2E_XP_COORD") ?? "" }
    var ns = ""
    func r(_ x: String) -> String { "xp\(run)r\(x)" }
    func v(_ x: String) -> String { "xp\(run)v\(x)" }
    var s: String { "xp\(run)s" }
    var groupName: String { "C6群-\(run)" }
    var word: String { "zxqword\(run)" }
    func others(_ x: String) -> [String] { Self.platforms.filter { $0 != x } }
    private var relay: TCPProxy?

    override func setUp() async throws {
        try await super.setUp()
        guard !run.isEmpty, !coord.isEmpty else {
            throw XCTSkip("the cross-platform tests need TT_E2E_XP and TT_E2E_XP_COORD from the coordinating script")
        }
    }

    override func tearDown() async throws {
        relay?.stop()
        relay = nil
        try await super.tearDown()
    }

    // MARK: Signal board

    private func post(_ name: String, _ body: [String: String] = [:]) async throws {
        var req = URLRequest(url: URL(string: "\(coord)/s/\(ns)/\(name)")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, res) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((res as? HTTPURLResponse)?.statusCode, 200, "signal \(name)")
    }

    private func wait(_ name: String, ms: Int = 300_000) async throws -> (seen: Date, body: [String: String]) {
        var req = URLRequest(url: URL(string: "\(coord)/s/\(ns)/\(name)?t=\(ms)")!)
        req.timeoutInterval = TimeInterval(ms / 1000 + 10)
        let (data, res) = try await URLSession.shared.data(for: req)
        let code = (res as? HTTPURLResponse)?.statusCode
        guard code == 200 else {
            XCTFail("waiting for signal \(name): \(code ?? 0)")
            throw E2EError.failed("signal \(name)")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (Date(), obj?["body"] as? [String: String] ?? [:])
    }

    private func log(_ what: String, _ t0: Date) {
        print("TT-E2E-XP6 \(ns) \(Self.me) \(what) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
    }

    // MARK: Pages

    private func submit(_ reason: String) async throws {
        try await see("report-sheet")
        XCTAssertEqual(label("report-hint"), "所选内容将提交给平台审核")
        try await pickReason(reason)
        try await tap("report-submit")
        try await toast("已提交，感谢你的反馈")
        try await gone(el("report-sheet"))
    }

    // MARK: Reporter

    func testXP6_reporter() async throws {
        ns = Self.me
        launch()
        try await login(r(ns))
        let vRow = listRow(v(ns))
        try await see(vRow, timeout: 30)
        try await until("vX's row", timeout: 15) { vRow.label.contains("XP6-v-\(self.ns)") }
        try await tapElement(vRow)
        try await see(message("XP6-v-\(ns)"), timeout: 15)
        for y in others(ns) { _ = try await wait("armed-\(y)", ms: 600_000) }
        // (2) Report the c2c message.
        let menu = try await c6Menu(message("XP6-v-\(ns)"))
        XCTAssertTrue(menu.contains("举报"), "\(menu)")
        try await tapMenuItem("举报")
        try await submit("abuse")
        try await see("report-block-dialog")
        XCTAssertTrue(label("dialog-text").hasPrefix("要把对方加入黑名单吗？"), label("dialog-text"))
        try await tap("dialog-cancel")
        try await gone(el("report-block-dialog"))
        try await post("reported")
        // (3) 4510.
        for y in others(ns) { _ = try await wait("s1-ok-\(y)") }
        let text = "XP6 含 \(word)"
        try await typeInComposer(text)
        try await tapSend()
        try await toast("消息包含不当内容，无法发送")
        XCTAssertEqual(composerText(), "", "the input empties")
        let m = message(text)
        try await until("failed") { (m.value as? String) == "发送失败" }
        try await post("blocked")
        // (4) The recalled group message and AC-MOD-04-1's target.
        for y in others(ns) { _ = try await wait("obs-done-\(y)") }
        try await back()
        let gRow = listRow(groupName)
        try await see(gRow, timeout: 15)
        try await tapElement(gRow)
        try await see(message("XP6-M-\(run)"), timeout: 15)
        try await see(message("XP6-R-\(ns)"), timeout: 15)
        try await sleep(2000)  // reads are reported at most once a second; the server checks readSeq
        try await post("g-seen")
        _ = try await wait("recalled", ms: 60_000)
        try await gone(message("XP6-R-\(ns)"), timeout: 10)
        try await until("the recall line's 举报", timeout: 10) { self.all("recall-report").count >= 1 }
        let lines = all("recall-report")
        try await tapElement(lines.element(boundBy: lines.count - 1))
        try await submit("other")
        try await staysGone(el("report-block-dialog"))
        let gm = try await c6Menu(message("XP6-M-\(run)"))
        XCTAssertTrue(gm.contains("举报"), "\(gm)")
        try await tapMenuItem("举报")
        try await submit("spam")
        try await staysGone(el("report-block-dialog"))
        try await post("r-done")
    }

    // MARK: Receiver

    func testXP6_observer() async throws {
        guard ["h5", "android"].contains(from) else { throw XCTSkip("TT_E2E_XP_FROM is the reporting platform (h5 or android)") }
        ns = from
        let relay = TCPProxy(targetPort: try XCTUnwrap(URLComponents(string: http)?.port.map(UInt16.init)))
        try relay.start()
        self.relay = relay
        let rc = c2c(r(ns), v(ns))
        let sc = c2c(s, v(ns))
        launch(env: ["TIANTING_SERVER": relay.url])
        try await login(v(ns))
        let rRow = listRow(r(ns))
        try await see(rRow, timeout: 30)
        try await until("rX's row", timeout: 15) { rRow.label.contains("XP6-v-\(self.ns)") && !rRow.label.contains("未读") }
        try await post("ready-\(Self.me)")
        for y in others(ns) where y != Self.me { _ = try await wait("ready-\(y)", ms: 600_000) }
        try await sleep(1500)  // the other device's new-device notice lands before recording
        var mark = relay.socketFrames.count
        try await post("armed-\(Self.me)")
        let sRow = listRow(s)
        /// From t0 to t0 + 2 s: the sentinel shows, every frame that came down is about its conversation, rX's row is as it was.
        func window(_ t0: Date, _ sentinel: String, _ step: String) async throws {
            while !(sRow.exists && sRow.label.contains(sentinel)) {
                if Date().timeIntervalSince(t0) >= 2 {
                    XCTFail("\(step): no sentinel within 2 seconds")
                    throw E2EError.failed(step)
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            log("\(step) sentinel", t0)
            let left = 2 - Date().timeIntervalSince(t0)
            if left > 0 { try await Task.sleep(for: .milliseconds(Int(left * 1000))) }
            let got = relay.socketFrames.dropFirst(mark).map { $0.text }.filter { !$0.contains("\"id\":") }
            let stray = got.filter { !$0.contains(sc) }.count
            XCTAssertEqual(stray, 0, "\(step): the reported user got frames besides the sentinel's (\(stray) of \(got.count))")
            XCTAssertTrue(got.contains { $0.contains(sentinel) }, "\(step): the sentinel's frame")
            XCTAssertTrue(rRow.label.contains("XP6-v-\(ns)") && !rRow.label.contains("未读"), rRow.label)
            if stray > 0 { throw E2EError.failed(step) }
            mark = relay.socketFrames.count
        }
        // (2)
        var t0 = try await wait("reported").seen
        try await window(t0, "XP6-s1-\(ns)", "after the report")
        try await post("s1-ok-\(Self.me)")
        // (3)
        t0 = try await wait("blocked").seen
        try await window(t0, "XP6-s2-\(ns)", "after the 4510")
        try await tapElement(rRow)
        try await see(message("XP6-v-\(ns)"), timeout: 15)
        try await sleep(1000)
        XCTAssertEqual(all("message").count, 1, "only XP6-v")
        XCTAssertFalse(message(word).exists)
        _ = rc
        try await post("obs-done-\(Self.me)")
    }

    // MARK: Last part

    func testXP6_final() async throws {
        ns = "final"
        launch()
        try await login(r(Self.me))
        let gRow = listRow(groupName)
        try await see(gRow, timeout: 30)
        try await tapElement(gRow)
        try await see(message("XP6-M-\(run)"), timeout: 15)
        try await post("f-ready-\(Self.me)")
        let t0 = try await wait("deleting", ms: 900_000).seen
        try await gone(message("XP6-M-\(run)"), timeout: 10)
        try await see("msg-deleted", timeout: 10)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        log("deleted", t0)
        XCTAssertEqual(label("msg-deleted"), "该消息已被删除")
        try await post("f-done-\(Self.me)", ["ms": String(ms)])
    }
}
