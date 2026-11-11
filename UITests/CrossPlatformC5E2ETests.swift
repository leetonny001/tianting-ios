import Foundation
import TiantingIM
import XCTest

/// FE-686: C5 across H5, Android and iOS against one im-server (pin, notifications off and delete in sync). One user's two
/// devices are on two platforms, online at the same time: D1 (`testXP5_d1`) acts through its UI, D2 (`testXP5_d2`) watches
/// through its UI; `TT_E2E_XP_FROM` is the other platform. They keep in step through the coordinating script's signal board
/// (`TT_E2E_XP_COORD`: POST/GET /s/{dir}/{name}, a GET waits up to t ms).
///
/// The shared contract (tianting-web's xp-c5.spec.ts and tianting-android's CrossPlatformC5E2e copy this):
/// - Run id R; direction dir = {D1}2{D2} (for example h52ios), one user per direction U = xp{R}{dir}, nickname the userId;
///   peers pa, pb, pc = xp{R}pa, xp{R}pb, xp{R}pc. The script puts in, in this order: pa says "XP5-g-{dir}" in group G =
///   xp{R}g{dir} "C5群-{dir}" (pa and U); pc says "ZXQ-XP5-c-{dir}" to U (conversation C); pb says "ZXQ-XP5-b-{dir}" (B);
///   pa says "XP5-a1-{dir}" and "XP5-a2-{dir}" (A, 2 unread). The first order is A, B, C, G.
/// - D2: (1) log in; the list is A, B, C, G with A at 2 unread; open C (see its text), open B and write the draft
///   "XP5草稿-{dir}", back to the list (B shows [草稿]); post d2-ready. (2) On pin: within 2 seconds A is on top and pinned
///   (AC-CVS-04-1); post d2-pin. (3) On mute: within 2 seconds A is muted (the icon, a dot, no number); post d2-mute. (4) On
///   del: within 2 seconds B leaves the list (AC-CVS-04-5); post d2-del. (5) Once d1-del and d2-del are both in, the script
///   has pb say "XP5-b-new-{dir}": B is back with 1 unread, the summary is the new message with no [草稿]; on d1-back (opening it syncs the read to D1) opening it shows
///   only that one and an empty input (AC-CVS-03-2, issue 55); post d2-back. (6) Go offline (H5 cuts the WebSocket, Android
///   airplane mode, iOS cuts the relay); post d2-offline. (7) On offline-done: while offline C is still there; once back,
///   the order, pins and mutes are what D1 posted (G, A, B; G and A pinned; A muted), C is not in the list and opening C
///   shows no message (AC-CVS-04-2); post d2-done.
/// - D1: (1) log in, wait for d2-ready. (2) Long press (H5: right click) A; with the menu up post pin, then tap "置顶"; wait
///   for d2-pin. (3) The same with mute and "免打扰"; wait for d2-mute. (4) Long press B, "删除"; with the dialog up post
///   del, then confirm; once B is gone post d1-del. (5) B is back with 1 unread; post d1-back, wait for d2-offline. (6) Pin G, delete C;
///   once the list is G, A, B post offline-done with its own order, pinned and muted (as a/b/c/g); wait for d2-done.
/// - "2 seconds" count from when D2 gets the signal; D1 posts before it taps, so D1's tap and UI count too.
/// - Proof that D2 can fail: the script's --fake-sender {dir} has no D1 and posts pin itself after d2-ready; D2 must fail at (2).
/// iOS also checks the app's data directory: C's text is gone from disk after (7). Without `TT_E2E_XP` these tests skip.
/// Local results on the simulator.
@MainActor
final class CrossPlatformC5E2ETests: E2ECase {
    static let me = "ios"

    var run: String { Self.env("TT_E2E_XP") ?? "" }
    var with: String { Self.env("TT_E2E_XP_FROM") ?? "" }
    var coord: String { Self.env("TT_E2E_XP_COORD") ?? "" }
    var dir = ""
    var u: String { "xp\(run)\(dir)" }
    var names: [String: String] {
        ["a": "xp\(run)pa", "b": "xp\(run)pb", "c": "xp\(run)pc", "g": "C5群-\(dir)"]
    }
    private var relay: TCPProxy?

    override func setUp() async throws {
        try await super.setUp()
        guard !run.isEmpty, !coord.isEmpty, ["h5", "android"].contains(with) else {
            throw XCTSkip("the cross-platform tests need TT_E2E_XP, TT_E2E_XP_COORD and TT_E2E_XP_FROM from the coordinating script")
        }
    }

    override func tearDown() async throws {
        relay?.stop()
        relay = nil
        try await super.tearDown()
    }

    // MARK: Signal board

    private func post(_ name: String, _ body: [String: String] = [:]) async throws {
        var req = URLRequest(url: URL(string: "\(coord)/s/\(dir)/\(name)")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, res) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((res as? HTTPURLResponse)?.statusCode, 200, "signal \(name)")
    }

    /// Waits for a signal; returns when it was seen here and what it carried.
    private func wait(_ name: String, ms: Int = 180_000) async throws -> (seen: Date, body: [String: String]) {
        var req = URLRequest(url: URL(string: "\(coord)/s/\(dir)/\(name)?t=\(ms)")!)
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

    /// True within 2 seconds of t0.
    private func within2s(_ t0: Date, _ what: String, _ condition: () -> Bool) async throws {
        while !condition() {
            if Date().timeIntervalSince(t0) >= 2 {
                XCTFail("not within 2 seconds: \(what)")
                throw E2EError.failed(what)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        print("TT-E2E-XP5 \(dir) \(what) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
    }

    // MARK: The list

    func row(_ k: String) -> XCUIElement { listRow(names[k]!) }
    /// The rows' labels from one snapshot of the tree. Binding the rows one by one by index races with a row leaving the
    /// list (C goes when the relay comes back) and fails the test on "no matches for element at index 3"; a snapshot that
    /// cannot be taken reads as an empty list, so the caller's `until` just looks again.
    func labels() -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier == "conv-item" { out.append(s.label) }
            s.children.forEach(walk)
        }
        walk(root)
        return out
    }
    func key(_ label: String) -> String {
        names.first { label.hasPrefix($0.value + "，") }?.key ?? "?"
    }
    func keys() -> String { labels().map(key).joined(separator: ",") }
    func pinned(_ k: String) -> Bool { row(k).exists && row(k).label.contains("，已置顶，") }
    func muted(_ k: String) -> Bool { row(k).exists && row(k).label.hasSuffix("，免打扰") }
    func state() -> [String: String] {
        let ls = labels()
        let ks = ls.map(key)
        return [
            "order": ks.joined(separator: ","),
            "pinned": zip(ks, ls).filter { $0.1.contains("，已置顶，") }.map(\.0).joined(separator: ","),
            "muted": zip(ks, ls).filter { $0.1.hasSuffix("，免打扰") }.map(\.0).joined(separator: ","),
        ]
    }

    /// Long press a row; with the menu up, optionally post a signal, then tap an item (delete also confirms).
    private func menu(_ k: String, _ title: String, signal: String? = nil) async throws {
        let shown = try await convMenu(row(k))
        XCTAssertTrue(shown.contains(title), "menu has \(title): \(shown)")
        if title == "删除" {
            try await tapMenuItem("删除")
            try await see("conv-delete-dialog")
            if let signal { try await post(signal) }
            try await tap("dialog-ok")
        } else {
            if let signal { try await post(signal) }
            try await tapMenuItem(title)
        }
    }

    // MARK: D1

    func testXP5_d1() async throws {
        dir = "ios2\(with)"
        launch()
        try await login(u)
        try await until("first list", timeout: 30) { self.keys() == "a,b,c,g" }
        _ = try await wait("d2-ready", ms: 300_000)
        // (2) Pin A.
        try await menu("a", "置顶", signal: "pin")
        try await until("A pinned here") { self.pinned("a") }
        _ = try await wait("d2-pin")
        // (3) Mute A.
        try await settle()
        try await menu("a", "免打扰", signal: "mute")
        try await until("A muted here") { self.muted("a") }
        _ = try await wait("d2-mute")
        // (4) Delete B.
        try await settle()
        try await menu("b", "删除", signal: "del")
        try await gone(row("b"), timeout: 3)
        try await sleep(1000)  // still gone after the ack
        XCTAssertFalse(row("b").exists)
        try await post("d1-del")
        // (5) pb says one more: B is back with 1 unread.
        try await see(row("b"), timeout: 30)
        // The summary and the unread count can land in two updates: wait for both, then check the count is exactly 1.
        try await until("B back with the new message and 1 unread") {
            let l = self.row("b").label
            return l.contains("XP5-b-new-\(self.dir)") && l.hasSuffix("，未读 1")
        }
        XCTAssertTrue(row("b").label.hasSuffix("，未读 1"), row("b").label)
        try await post("d1-back")
        _ = try await wait("d2-offline", ms: 300_000)
        // (6) While D2 is offline: pin G, delete C.
        try await menu("g", "置顶")
        try await until("G pinned here") { self.pinned("g") }
        try await settle()
        try await menu("c", "删除")
        try await until("G, A, B", timeout: 5) { self.keys() == "g,a,b" }
        try await sleep(1000)
        let mine = state()
        XCTAssertEqual(mine, ["order": "g,a,b", "pinned": "g,a", "muted": "a"])
        try await post("offline-done", mine)
        _ = try await wait("d2-done", ms: 300_000)
    }

    // MARK: D2

    func testXP5_d2() async throws {
        dir = "\(with)2ios"
        let r = TCPProxy(targetPort: try XCTUnwrap(URLComponents(string: http)?.port.map(UInt16.init)))
        try r.start()
        relay = r
        launch(env: ["TIANTING_SERVER": r.url, "TT_TEST_STATE": "1", "TT_TEST_SCAN": "ZXQ-XP5-c-\(dir)"])
        try await login(u)
        // (1) The first state; open C, write a draft in B.
        try await until("first list", timeout: 30) { self.keys() == "a,b,c,g" }
        XCTAssertTrue(row("a").label.hasSuffix("，未读 2"), row("a").label)
        try await tapElement(row("c"))
        try await see(message("ZXQ-XP5-c-\(dir)"), timeout: 15)
        try await until("C on disk (control)", timeout: 15) { self.probe("scan") > 0 }
        try await back()
        try await tapElement(row("b"))
        try await see(message("ZXQ-XP5-b-\(dir)"), timeout: 15)
        try await typeInComposer("XP5草稿-\(dir)")
        try await back()
        try await until("draft in the list") { self.row("b").label.contains("[草稿] XP5草稿-\(self.dir)") }
        try await until("first order after the draft") { self.keys() == "a,b,c,g" }
        XCTAssertEqual(state(), ["order": "a,b,c,g", "pinned": "", "muted": ""])
        try await post("d2-ready")
        // (2) Pinned.
        var t0 = try await wait("pin").seen
        try await within2s(t0, "A on top and pinned") { self.keys().hasPrefix("a,") && self.pinned("a") }
        try await post("d2-pin")
        // (3) Muted: the icon, a dot, no number.
        t0 = try await wait("mute").seen
        try await within2s(t0, "A muted") {
            self.muted("a") && self.row("a").label.contains("[2 条] XP5-a2-\(self.dir)") && !self.row("a").label.contains("未读")
        }
        try await post("d2-mute")
        // (4) Deleted.
        t0 = try await wait("del").seen
        try await within2s(t0, "B left the list") { !self.row("b").exists }
        try await post("d2-del")
        // (5) Back with only the new message, no draft.
        try await see(row("b"), timeout: 30)
        // The summary and the unread count can land in two updates: wait for both, then check the count is exactly 1.
        try await until("B back with the new message and 1 unread") {
            let l = self.row("b").label
            return l.contains("XP5-b-new-\(self.dir)") && l.hasSuffix("，未读 1")
        }
        XCTAssertTrue(row("b").label.hasSuffix("，未读 1"), row("b").label)
        XCTAssertFalse(row("b").label.contains("[草稿]"), "the draft went with the deletion")
        _ = try await wait("d1-back")  // Opening it syncs the read to D1: let D1 see its "1 unread" first.
        try await tapElement(row("b"))
        try await see(message("XP5-b-new-\(dir)"))
        app.swipeDown()
        try await sleep(1500)
        XCTAssertEqual(all("message").count, 1, "only the new message")
        XCTAssertFalse(message("ZXQ-XP5-b-\(dir)").exists)
        XCTAssertEqual(composerText(), "")
        try await back()
        try await post("d2-back")
        // (6) Offline.
        r.down = true
        try await see("conn-banner", timeout: 15)
        try await post("d2-offline")
        // (7) After D1's changes: the old list while offline, D1's list once back.
        let done = try await wait("offline-done", ms: 300_000).body
        XCTAssertTrue(row("c").exists, "C is still here while offline")
        r.down = false
        try await until("as on D1", timeout: 20) { self.state() == done }
        XCTAssertEqual(done, ["order": "g,a,b", "pinned": "g,a", "muted": "a"])
        try await until("C purged from disk", timeout: 20) { self.probe("scan") == 0 }
        try await startChat(with: "xp\(run)pc")
        try await sleep(1000)
        XCTAssertEqual(all("message").count, 0, "C has no message")
        XCTAssertFalse(message("ZXQ-XP5-c-\(dir)").exists)
        try await post("d2-done")
    }
}
