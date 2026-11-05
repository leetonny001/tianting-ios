import TiantingIM
import XCTest

/// Navigation, login, deep links, theme, Dynamic Type, screenshots.
final class AppE2ETests: E2ECase {
    func testLoginValidation() async throws {
        launch()
        try await see("login-submit")
        XCTAssertFalse(el("login-submit").isEnabled)  // AC-UI-03-1
        try await type("   ", into: "login-username")
        XCTAssertFalse(el("login-submit").isEnabled)
        try await clearAndType("a b", into: "login-username")
        try await tap("login-submit")
        try await see("login-error")
        XCTAssertEqual(label("login-error"), "账号格式不正确")  // AC-AUTH-04-4
        try await clearAndType(uid("a"), into: "login-username")
        try await type(String(repeating: "昵", count: 33), into: "login-nickname")
        try await see("login-nickname-error")  // AC-UI-03-8
        XCTAssertEqual(label("login-nickname-error"), "昵称最多 32 个字")
        XCTAssertFalse(el("login-submit").isEnabled)
    }

    func testNicknameTabsAndSessionLifecycle() async throws {
        let me = uid("zhangsan")
        launch()
        try await login(me, nickname: "张三")
        // AC-UI-01-1
        XCTAssertTrue(el("tab-chats").isSelected)
        try await tap("tab-me")
        XCTAssertTrue(el("tab-me").isSelected)
        XCTAssertFalse(el("tab-chats").isSelected)
        // AC-UI-03-7, AC-UI-15-2
        try await see("me-name")
        try await until("nickname") { self.label("me-name") == "张三" }
        // AC-UI-15-1: copy.
        try await tap("copy-button")
        try await see("toast")
        XCTAssertEqual(label("toast"), "已复制")
        // AC-UI-01-6: no tab bar on second-level pages.
        try await tap("me-settings")
        try await gone(el("tab-me"))
        try await see("about")
        XCTAssertTrue(label("app-version").contains("0.1.0"))
        try await back()

        // The token survives a restart (Keychain) and the login is restored.
        app.terminate()
        launch(reset: false)
        try await see("tab-chats")
        XCTAssertFalse(el("login-submit").exists)

        // AC-UI-16-3 (3.6 table): after logout, a restart lands on login: the Keychain has no token.
        try await logout()
        app.terminate()
        launch(reset: false)
        try await see("login-submit")
        try await sleep(1000)
        XCTAssertFalse(el("tab-chats").exists)
    }

    func testDeepLinkBeforeAndAfterLogin() async throws {
        // AC-UI-01-3 (3.6 table): cold start with a deep link: login first, then the conversation.
        let (me, bob) = (uid("a"), uid("b"))
        try await importUsers([me, bob])
        launch()
        try await see("login-submit")
        app.open(URL(string: "tianting://chat/\(c2c(me, bob).replacingOccurrences(of: ":", with: "%3A"))")!)
        try await see("login-submit")
        try await type(me, into: "login-username")
        try await tap("login-submit")
        try await see("chat-title")
        XCTAssertEqual(label("chat-title"), bob)
        try await see(composer)

        // AC-UI-01-7 (3.6 table): unknown routes go to /chats.
        for link in ["tianting://evil.com/x", "tianting://not-a-route", "tianting://login", "tianting://chat"] {
            openLink(link)
            try await see("tab-chats")
            XCTAssertTrue(el("tab-chats").isSelected, link)
            openLink("tianting://me/settings")
            try await see("about")
        }
        openLink("tianting://me/settings/appearance")
        try await see("appearance-dark")
    }

    func testAppearanceFollowsSystemAndManual() async throws {
        try await setSystemAppearance("light")
        launch()
        try await login(uid("a"))
        let lightBg = (0xF2, 0xF3, 0xF7)
        let darkBg = (0x11, 0x13, 0x18)
        func background() -> (Int, Int, Int) {
            // A point in the empty area of the "me" page, between the settings row and the tab bar.
            let f = app.windows.firstMatch.frame
            let p = pixel(atX: f.midX, y: f.maxY - 180)
            return (p.r, p.g, p.b)
        }
        // Screenshots go through color management, so allow a small difference.
        func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
            abs(a.0 - b.0) <= 4 && abs(a.1 - b.1) <= 4 && abs(a.2 - b.2) <= 4
        }
        try await tap("tab-me")
        try await see("me-settings")
        try await sleep(500)
        XCTAssertTrue(near(background(), lightBg), "\(background())")

        // Default: follows the system live. `simctl ui` has no effect on the iOS 27 simulator runtime, not even on system
        // apps, so this part only runs on earlier runtimes.
        if #unavailable(iOS 27) {
            try await setSystemAppearance("dark")
            try await until("system dark") { near(background(), darkBg) }
            try await setSystemAppearance("light")
            try await until("system light") { near(background(), lightBg) }
        }

        // Manual dark beats the system and stays after logout and restart (AC-UI-16-5, AC-UI-22-5).
        try await tap("me-settings")
        try await tap("settings-appearance")
        try await tap("appearance-dark")
        try await back()
        try await back()
        try await see("me-settings")
        try await until("manual dark") { near(background(), darkBg) }
        app.terminate()
        launch(reset: false)
        try await see("tab-me")
        try await tap("tab-me")
        try await until("dark after restart") { near(background(), darkBg) }
        try await logout()
        capture("login-dark-after-logout")
        XCTAssertFalse(el("tab-me").exists)

        // Manual light beats a dark system.
        try await login(uid("b"))
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("settings-appearance")
        try await tap("appearance-light")
        if #unavailable(iOS 27) { try await setSystemAppearance("dark") }
        try await back()
        try await back()
        try await see("me-settings")
        try await until("manual light") { near(background(), lightBg) }
        try await setSystemAppearance("light")
    }

    func testDynamicTypeAccessibility3MainActionsUsable() async throws {
        // PRD-ui 3.5 rule 3: accessibility3 (UIKit's AccessibilityXL), buttons not cut off.
        let (me, bob) = (uid("a"), uid("b"))
        _ = try await peer(bob)
        try await importUsers([me])
        try await makeFriends(me, bob)
        let longText = String(repeating: "很长的消息内容不能被截断。", count: 12)
        launch(args: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        try await see("login-submit")
        capture("ax3-login")
        assertUsable("login-username")
        try await login(me)
        capture("ax3-chats")
        assertUsable("tab-me")
        try await startChat(with: bob)
        try await focus(composer)
        composer.typeText(longText)
        try await sleep(300)
        assertUsable("send-button")
        try await sleep(300)
        capture("ax3-composer")
        try await tap("send-button")
        try await sent(longText)
        let m = message(longText)
        XCTAssertEqual(m.label, longText, "message text is whole")
        capture("ax3-chat")
        app.swipeDown(velocity: .slow)
        try await tap("chat-more")
        try await see("info-sub")
        try await back()
        try await back()
        try await tap("tab-contacts")
        try await see(el("friend-row", labelContains: bob))
        capture("ax3-contacts")
        el("friend-row", labelContains: bob).tap()
        try await see("user-chat")
        assertUsable("user-chat")
        capture("ax3-user")
        try await back()
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("logout")
        try await see("logout-dialog")
        assertUsable("dialog-ok")
        assertUsable("dialog-cancel")
        capture("ax3-logout-dialog")
    }

    func testNoHorizontalOverflow() async throws {
        // AC-UI-02-5 (3.6 table): on the device under test nothing extends past the window. Run on iPhone SE for 375pt.
        let (me, bob) = (uid("a"), uid("b"))
        let longName = String(repeating: "很长的名字", count: 6)
        _ = try await peer(bob, nickname: longName)
        try await importUsers([me])
        try await makeFriends(me, bob)
        try await launchAndLogin(me)
        let width = app.windows.firstMatch.frame.width
        func check(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
            for id in ids {
                let f = el(id).frame
                XCTAssertLessThanOrEqual(f.maxX, width + 0.5, id, file: file, line: line)
                XCTAssertGreaterThanOrEqual(f.minX, -0.5, id, file: file, line: line)
            }
        }
        try await startChat(with: bob)
        try await send(String(repeating: "x", count: 300))
        try await sent(String(repeating: "x", count: 300))
        check(["message", "composer-input", "send-button", "chat-title", "chat-more"])
        // AC-UI-07-3: a bubble stays within 70% of the list.
        XCTAssertLessThanOrEqual(el("message").frame.width, width * 0.7 + 1)
        // AC-UI-07-1: 12 + 40 + 8 from the edge.
        XCTAssertEqual(el("message").frame.maxX, width - 60, accuracy: 1.5)
        try await back()
        check(["conv-item", "tab-chats", "tab-contacts", "tab-me"])
        try await tap("tab-contacts")
        try await see("friend-row")
        check(["friend-row", "entry-requests", "entry-groups"])
        el("friend-row").tap()
        try await see("user-name")
        check(["user-name", "user-id", "user-chat"])
        try await back()
        try await tap("entry-requests")
        try await see("requests-empty")
        check(["requests-empty"])
        try await back()
        try await tap("contacts-add")
        try await see("search-input")
        check(["search-input"])
    }

    func testScreenshots() async throws {
        // Saved for reading by eye: light and dark, all main pages.
        let (me, bob, carol) = (uid("me"), uid("bob"), uid("carol"))
        let peerBob = try await peer(bob, nickname: "博文")
        let peerCarol = try await peer(carol, nickname: "张小卡")
        try await importUsers([me], nicknames: [me: "我自己"])
        try await makeFriends(me, bob, remarkA: "老板")
        try await makeFriends(me, carol)
        let g = try await hostedGroup(name: "周末球局", members: [me, bob, carol], owner: me)
        launch()
        try await login(me, nickname: "我自己")

        _ = try peerBob.send(c2c(me, bob), "明天几点开始？")
        _ = try peerCarol.send(g.convId, "这周六下午去踢球吗")
        _ = try peerBob.send(g.convId, "我可以")
        try await peerCarol.block(me)
        let secret = "将被删除的消息"
        _ = try peerBob.send(g.convId, secret)
        var msgId: String?
        try await until("acked") {
            msgId = peerBob.messages(g.convId).last { $0.body.text == secret }?.msgId
            return msgId != nil
        }
        try await signed("POST", "/admin/messages/delete", ["convId": g.convId, "msgIds": [msgId!], "reason": "e2e"])
        try await see(conv("老板"))

        for theme in ["light", "dark"] {
            if theme == "dark" {
                try await tap("tab-me")
                try await tap("me-settings")
                try await tap("settings-appearance")
                try await tap("appearance-dark")
                capture("dark-appearance")
                try await back()
                capture("dark-settings")
                try await back()
                try await tap("tab-chats")
            }
            capture("\(theme)-chats")
            conv("周末球局").tap()
            try await see(composer)
            try await sleep(500)
            if theme == "light" {
                try await send("收到，周六见")
                try await sent("收到，周六见")
            }
            capture("\(theme)-group-chat")
            try await tap("emoji-button")
            try await see("emoji-panel")
            capture("\(theme)-emoji")
            try await tap("emoji-button")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            try await see(conv("老板"))
            conv("老板").tap()
            try await see(composer)
            try await sleep(300)
            capture("\(theme)-single-chat")
            try await back()
            // Mute bar and removed state.
            try await signed(
                "POST", "/admin/mute", ["scope": "user", "userId": me, "durationSeconds": 600, "reason": "e2e"])
            conv("周末球局").tap()
            try await see("composer-disabled")
            try await sleep(300)
            capture("\(theme)-muted")
            try await signed("POST", "/admin/unmute", ["scope": "user", "userId": me, "reason": "e2e"])
            try await tap("chat-more")
            try await see("member-grid")
            capture("\(theme)-group-settings")
            try await back()
            try await back()
            try await tap("tab-contacts")
            try await see("friend-row")
            capture("\(theme)-contacts")
            el("friend-row", labelContains: "老板").tap()
            try await see("user-name")
            capture("\(theme)-user")
            try await back()
            try await tap("entry-requests")
            try await see("requests")
            capture("\(theme)-requests")
            try await back()
            try await tap("contacts-add")
            try await see("search-input")
            capture("\(theme)-add-friend")
            try await back()
            try await tap("tab-me")
            try await see("me-name")
            capture("\(theme)-me")
            try await tap("me-settings")
            try await see("logout")
            capture("\(theme)-settings")
            try await tap("logout")
            try await see("logout-dialog")
            capture("\(theme)-logout-dialog")
            try await tap("dialog-cancel")
            try await back()
            try await tap("tab-chats")
        }
    }
}
