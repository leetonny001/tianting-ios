import TiantingIM
import XCTest

/// System notices against a real server (IM_PUSH_ENABLED=1): PRD-ui F-UI-44, PRD-live F-PUSH-12, AC-PUSH-03-16 end to end.
final class NoticesE2ETests: E2ECase {
    @discardableResult
    private func pushTo(_ userId: String, _ text: String, type: String = "notice") async throws -> String {
        let pushId = UUID().uuidString
        try await signed(
            "POST", "/admin/push",
            ["target": "user", "userIds": [userId], "type": type, "data": ["text": text], "pushId": pushId])
        return pushId
    }

    /// Logged in with the first `convs` back: `auth` is done, so T0 is set and later pushes count as live.
    private func launchReady(_ me: String) async throws {
        try await importUsers([me])
        try await launchAndLogin(me)
        try await see("chats-empty")
    }

    private func openMe() async throws {
        try await tap("tab-me")
        try await see("me-notices")
    }

    private var banner: XCUIElement { el("notice-banner") }
    private var count: XCUIElement { el("me-notices-count") }
    private var items: XCUIElementQuery { all("notice-item") }

    func testLiveNoticeBannerListCountAndBannerTap() async throws {
        // AC-UI-44-1, AC-ADM-50-1
        let me = uid("n")
        try await launchReady(me)
        try await openMe()
        XCTAssertFalse(count.exists)
        try await pushTo(me, "今晚 22 点维护")
        try await see(banner, timeout: 3)
        XCTAssertEqual(label("notice-banner"), "系统通知：今晚 22 点维护")
        try await see(count)
        XCTAssertEqual(label("me-notices-count"), "1")
        capture("notice-banner")
        try await gone(banner, timeout: 6)  // 5 seconds.

        try await pushTo(me, "第二条")
        try await see(banner, timeout: 3)
        try await until("count 2") { self.label("me-notices-count") == "2" }
        banner.tap()
        try await see("notice-item")
        try await until("two items") { self.items.count == 2 }
        XCTAssertTrue(items.element(boundBy: 0).label.contains("第二条"))
        XCTAssertTrue(items.element(boundBy: 1).label.contains("今晚 22 点维护"))
        XCTAssertTrue(el("notices-footer").exists)
        capture("notices-page")
        try await back()
        try await see("me-notices")
        XCTAssertFalse(count.exists)
    }

    func testOtherTypesAndPlainText() async throws {
        // AC-UI-44-2, AC-UI-44-3's native form, NF-UI-12
        let me = uid("n")
        try await launchReady(me)
        try await pushTo(me, "ZXQ-PUSH-PROMO", type: "promo")
        try await staysGone(banner)
        try await openMe()
        XCTAssertFalse(count.exists)

        let raw = "**粗** [链接](https://a.b) <img src=x>"
        try await pushTo(me, raw)
        try await see(banner, timeout: 3)
        XCTAssertEqual(label("notice-banner"), "系统通知：\(raw)")
        banner.tap()
        try await see("notice-item")
        XCTAssertEqual(items.count, 1, "promo is not listed")
        XCTAssertTrue(items.element(boundBy: 0).label.contains(raw), items.element(boundBy: 0).label)
    }

    func testStayingOnThePageDoesNotCount() async throws {
        // AC-PUSH-12-11
        let me = uid("n")
        try await launchReady(me)
        try await openMe()
        try await tap("me-notices")
        try await see("notices-empty")
        try await pushTo(me, "页内收到")
        try await see("notice-item", timeout: 3)
        try await gone(banner, timeout: 6)
        try await back()
        try await see("me-notices")
        try await staysGone(count)
    }

    func testRestartShowsOnlyThisRunAndCursorDoesNotReplay() async throws {
        // AC-PUSH-12-9, AC-PUSH-03-16
        let me = uid("n")
        try await launchReady(me)
        try await openMe()
        try await pushTo(me, "重启前的通知")
        try await see(banner, timeout: 3)
        try await tap("me-notices")  // lastSeenSeq = 1.
        try await see("notice-item")
        try await back()
        app.terminate()

        // Two while the app is not running.
        try await pushTo(me, "离线一 ZXQ-PUSH-OFF")
        try await pushTo(me, "离线二 ZXQ-PUSH-TWO")
        try await sleep(50)
        launch(reset: false)
        try await see("tab-chats")
        try await openMe()
        try await see(count)
        try await until("count 2") { self.label("me-notices-count") == "2" }
        try await staysGone(banner)
        try await tap("me-notices")
        try await see("notice-item")
        XCTAssertEqual(items.count, 2, "only what arrived since this launch")
        XCTAssertTrue(items.element(boundBy: 0).label.contains("离线二"))
        XCTAssertFalse(staticText(containing: "重启前的通知").exists)
        try await see("notices-footer")
        XCTAssertEqual(label("notices-footer"), "只显示本次打开以来收到的通知")
        capture("notices-after-restart")
        try await back()
        try await see("me-notices")
        XCTAssertFalse(count.exists)
        app.terminate()

        // The cursor is on disk: nothing comes back, the list is empty, nothing is counted.
        launch(reset: false)
        try await see("tab-chats")
        try await openMe()
        try await staysGone(count)
        try await tap("me-notices")
        try await see("notices-empty")
        XCTAssertEqual(items.count, 0)
        try await see("notices-footer")
    }

    func testLogoutDropsTheBaselineAndKeepsTheCursor() async throws {
        // AC-PUSH-12-6, AC-PUSH-03-16: logging out deletes the key, so the next round is not counted, and the cursor
        // stays, so only the new one comes back.
        let me = uid("n")
        try await launchReady(me)
        try await openMe()
        try await pushTo(me, "退出前的通知")
        try await see(banner, timeout: 3)
        try await tap("me-notices")
        try await see("notice-item")
        try await back()
        try await gone(banner, timeout: 6)
        try await logout()

        try await pushTo(me, "退出期间的通知")
        try await login(me)
        try await openMe()
        try await staysGone(count)
        XCTAssertFalse(banner.exists)
        try await tap("me-notices")
        try await see("notice-item")
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.element(boundBy: 0).label.contains("退出期间的通知"), "the old one is not replayed")
    }

    func testKickKeepsTheBaseline() async throws {
        // AC-PUSH-12-6, AC-PUSH-03-16: after a ban the key is still there, so a push during it counts when logging in again.
        let me = uid("n")
        try await launchReady(me)
        try await openMe()
        try await pushTo(me, "封禁前")
        try await see(banner, timeout: 3)
        try await tap("me-notices")
        try await see("notice-item")
        try await back()
        try await gone(banner, timeout: 6)

        try await signed("POST", "/admin/users/\(me)/ban", ["durationSeconds": 86_400, "reason": "e2e"])
        try await see("kicked-dialog", timeout: 3)
        try await pushTo(me, "封禁期间")
        try await tap("kicked-ok")
        try await see("login-submit")
        try await signed("POST", "/admin/users/\(me)/unban", ["reason": "e2e"])

        try await login(me)
        try await openMe()
        try await see(count)
        try await until("count 1") { self.label("me-notices-count") == "1" }
        try await staysGone(banner)
        try await tap("me-notices")
        try await see("notice-item")
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.element(boundBy: 0).label.contains("封禁期间"))
    }

    func testBroadcastBannerAndNoReplayForOfflineUsers() async throws {
        // AC-ADM-50-3, AC-PUSH-04-1
        let me = uid("n")
        try await launchReady(me)
        try await openMe()
        let text = "全员 ZXQ-PUSH-\(UUID().uuidString.prefix(8))"
        try await signed(
            "POST", "/admin/push", ["target": "all", "type": "notice", "data": ["text": text], "pushId": UUID().uuidString])
        try await see(banner, timeout: 3)
        XCTAssertEqual(label("notice-banner"), "系统通知：\(text)")
        try await see(count)
        XCTAssertEqual(label("me-notices-count"), "1")
        app.terminate()

        // A broadcast has no pushSeq: nothing to catch up, and an offline user never sees it.
        let other = uid("n")
        try await launchReady(other)
        try await openMe()
        try await tap("me-notices")
        try await see("notices-empty")
    }
}
