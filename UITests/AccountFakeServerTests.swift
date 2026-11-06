import XCTest

/// The account pages' states against a scripted server (PRD-chat 13.4): the things a real server cannot be made to do on demand.
final class AccountFakeServerTests: E2ECase {
    private var fake: FakeAccountServer!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeAccountServer()
        try fake.start()
    }

    override func tearDown() async throws {
        fake.stop()
        try await super.tearDown()
    }

    private func start(reset: Bool = true, env: [String: String] = [:]) {
        var e = ["TIANTING_SERVER": fake.url, "TT_TEST_STATE": "1"]
        for (k, v) in env { e[k] = v }
        launch(reset: reset, env: e)
    }

    private func state() -> String { el("test-state").value as? String ?? "" }

    private func logOutAccount() async throws {
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("logout")
        try await tap("dialog-ok")
        try await see("account-username")
    }

    private func stateIs(_ session: Int, _ pending: Int) async throws {
        try await until("state session=\(session) pending=\(pending), was \(state())") {
            self.state().hasPrefix("session=\(session) pending=\(pending)")
        }
    }

    private func typeAccount(_ user: String = "alice", _ pw: String = "pw123456") async throws {
        try await type(user, into: "account-username")
        try await type(pw, into: "account-password")
    }

    private func submit(_ id: String) async throws {
        // On a small screen the keyboard can cover the button.
        if !el(id).isHittable { app.swipeUp() }
        try await tap(id)
    }

    /// Account login, nothing to confirm: at the list.
    private func logIn() async throws {
        try await see("account-username")
        try await typeAccount()
        try await submit("account-submit")
        try await see("tab-chats")
    }

    // MARK: Entries (F-ACC-07)

    func testTC_ACC_07_05_noDemoWithInvite() async throws {
        start()
        try await see("account-username")
        XCTAssertTrue(el("account-password").exists)
        XCTAssertFalse(el("login-username").exists)
        XCTAssertFalse(staticText(containing: "业务方").exists)
        try await tap("account-register")
        try await see("register-invite")
        XCTAssertFalse(staticText(containing: "业务方").exists)
    }

    func testTC_ACC_07_06_demoFormStays() async throws {
        fake.demoLogin = true
        start()
        try await see("login-username")
        XCTAssertTrue(el("login-nickname").exists)
        try await tap("login-use-account")
        try await see("account-username")
        try await back()
        try await see("login-username")
    }

    func testTC_ACC_07_07_bothSwitches() async throws {
        fake.demoLogin = true
        start(env: ["TT_BUILD_DEMO_LOGIN": "0"])
        try await see("account-username")
        try await staysGone(el("login-username"))
        app.terminate()
        fake.demoLogin = false
        start()
        try await see("account-username")
        try await staysGone(el("login-username"))
    }

    func testTC_ACC_07_09_closedAndConfigFailure() async throws {
        fake.registerMode = "closed"
        start()
        try await see("account-username")
        try await staysGone(el("account-register"))
        XCTAssertTrue(el("account-forgot").exists)
        app.terminate()

        fake.registerMode = "open"
        fake.blackhole = true
        start()
        try await see("login-config-error")
        XCTAssertEqual(label("login-config-error"), "网络异常，请稍后重试")
        XCTAssertTrue(el("login-config-retry").exists)
        XCTAssertFalse(el("account-username").exists, "no form when the mode is unknown")
        XCTAssertFalse(el("login-username").exists)
        fake.blackhole = false
        try await tap("login-config-retry")
        try await see("account-username")
        XCTAssertTrue(el("account-register").exists)
    }

    // MARK: Register (F-ACC-01)

    private func fillRegister() async throws {
        try await see("register-username")
        try await type("alice", into: "register-username")
        try await type("pw123456", into: "register-password")
        try await type("INV", into: "register-invite")
    }

    func testTC_ACC_01_12_savePageBlocksEverythingUntilConfirmed() async throws {
        start()
        try await see("account-register")
        try await tap("account-register")
        try await fillRegister()
        try await submit("register-submit")
        try await see("recovery-code")
        XCTAssertEqual(fake.requests("/v1/account/register").first?.body["password"] as? String, "pw123456", "the field's whole text")
        XCTAssertEqual(fake.requests("/v1/account/register").first?.body["username"] as? String, "alice")
        XCTAssertEqual(fake.requests("/v1/account/register").first?.body["inviteCode"] as? String, "INV")
        let code = label("recovery-code")
        XCTAssertTrue(code.hasPrefix("CODE-AAAA"))
        XCTAssertEqual(label("recovery-warning"), "恢复码丢失后账号无法找回")
        XCTAssertTrue(el("recovery-copy").exists)
        XCTAssertEqual(all("recovery-confirm").count, 1)
        try await stateIs(0, 0)  // TC-ACC-05-06: no token in the Keychain.

        // Copying.
        try await tap("recovery-copy")
        try await see("toast")
        XCTAssertEqual(label("toast"), "已复制")

        // The back gesture has nowhere to go: from the left edge, as a person would.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        try await sleep(600)
        XCTAssertTrue(el("recovery-code").exists, "still on the save page")
        XCTAssertFalse(el("register-username").exists)
        XCTAssertFalse(el("tab-chats").exists)
        XCTAssertFalse(el("account-username").exists)
        XCTAssertEqual(fake.requests("/v1/account/recovery-code/ack").count, 0)

        try await tap("recovery-confirm")
        try await see("tab-chats")
        XCTAssertEqual(fake.requests("/v1/account/recovery-code/ack").first?.body["gen"] as? Int, 1)
        try await stateIs(1, 0)
        XCTAssertTrue(state().contains("class=cku"), "AfterFirstUnlockThisDeviceOnly: \(state())")
        try await see("tab-me")
        XCTAssertEqual(fake.authTokens.count, 1)
    }

    /// iOS's Automatic Strong Password once covered this field and lost every key after the first. Keys tapped one by one, as
    /// a person types (not `typeText`); the field shows them all and the request carries them all.
    func testTC_ACC_01_12_passwordTypedKeyByKeyArrivesWhole() async throws {
        start()
        try await see("account-register")
        try await tap("account-register")
        try await see("register-username")
        try await type("alice", into: "register-username")
        el("register-password").tap()
        try await sleep(800)
        for ch in "pwabcdef" {
            app.keys[String(ch)].tap()
            try await sleep(150)
        }
        XCTAssertEqual(el("register-password").value as? String, "••••••••")
        capture("repro-key-by-key")
        try await type("INV", into: "register-invite")
        XCTAssertEqual(el("register-password").value as? String, "••••••••", "still there after leaving the field")
        try await submit("register-submit")
        try await see("recovery-code")
        XCTAssertEqual(fake.requests("/v1/account/register").first?.body["password"] as? String, "pwabcdef")
    }

    func testTC_ACC_01_12_copyFailureSaysSo() async throws {
        fake.script("/v1/account/login", .json(200, fake.auth(code: "CODE-1", codeGen: 3)))
        start(env: ["TT_TEST_COPY_FAIL": "1"])
        try await see("account-username")
        try await typeAccount()
        try await submit("account-submit")
        try await see("recovery-code")
        try await tap("recovery-copy")
        try await see("toast")
        XCTAssertEqual(label("toast"), "复制失败，请手动记下")
    }

    func testTC_ACC_01_13_takenNameUnderTheField() async throws {
        fake.script("/v1/account/register", fake.error(409, 4095))
        start()
        try await see("account-register")
        try await tap("account-register")
        try await fillRegister()
        try await submit("register-submit")
        try await see("register-username-error")
        XCTAssertEqual(label("register-username-error"), "这个用户名不能使用")
        XCTAssertLessThan(el("register-username").frame.maxY, el("register-username-error").frame.minY + 1, "under the field")
        XCTAssertEqual(el("register-invite").value as? String, "INV")
        XCTAssertTrue((el("register-password").value as? String ?? "").contains("•"), "password kept")
        XCTAssertFalse(el("recovery-code").exists)
    }

    func testTC_ACC_01_18_registerErrorsKeepTheInput() async throws {
        fake.script(
            "/v1/account/register", fake.error(400, 4004), fake.error(400, 4000, reason: "passwordWeak"),
            fake.error(403, 4030, reason: "inviteInvalid"), fake.error(429, 4290), fake.error(503, 5030), .drop)
        start()
        try await see("account-register")
        try await tap("account-register")
        try await fillRegister()
        for text in ["用户名格式不正确", "密码太简单", "邀请码无效", "操作太频繁，请稍后再试", "服务暂不可用", "网络异常，请稍后重试"] {
            try await submit("register-submit")
            try await until("error \(text)") { self.el("register-error").exists && self.label("register-error") == text }
            XCTAssertEqual(el("register-username").value as? String, "alice", text)
            XCTAssertEqual(el("register-invite").value as? String, "INV", text)
            XCTAssertTrue((el("register-password").value as? String ?? "").contains("•"), text)
            try await until("button back") { self.el("register-submit").isEnabled }
        }
    }

    // MARK: Login (F-ACC-02)

    func testTC_ACC_02_08_wrongPassword() async throws {
        fake.script("/v1/account/login", fake.error(401, 4018))
        start()
        try await see("account-username")
        try await typeAccount()
        try await submit("account-submit")
        try await see("account-error")
        XCTAssertEqual(label("account-error"), "用户名或密码错误")
        XCTAssertEqual(el("account-username").value as? String, "alice")
        XCTAssertFalse((el("account-password").value as? String ?? "").contains("•"), "password cleared")
    }

    func testTC_ACC_02_09_lockoutDoesNotRetry() async throws {
        fake.script("/v1/account/login", fake.error(429, 4294, details: ["retryAfterSeconds": 600]))
        start()
        try await see("account-username")
        try await typeAccount()
        try await submit("account-submit")
        try await see("account-error")
        XCTAssertEqual(label("account-error"), "尝试次数过多，请 10 分钟后再试")
        try await sleep(5000)
        XCTAssertEqual(fake.requests("/v1/account/login").count, 1)
    }

    func testF_ACC_08_deletionPendingOffersToCancel() async throws {
        fake.script(
            "/v1/account/login", fake.error(403, 4030, reason: "accountDeletionPending", details: ["deleteAt": 1_900_000_000_000]))
        start()
        try await see("account-username")
        try await typeAccount()
        try await submit("account-submit")
        try await see("delete-pending-dialog")
        XCTAssertTrue(label("dialog-text").hasPrefix("账号正在注销，"))
        XCTAssertTrue(label("dialog-text").hasSuffix("后不可恢复，是否撤销？"))
        XCTAssertFalse(fake.timeline.contains("auth"), "no token")
        try await tap("dialog-ok")
        try await see("tab-chats")
        XCTAssertEqual(fake.requests("/v1/account/delete/cancel").count, 1)
        XCTAssertEqual(fake.requests("/v1/account/login").count, 2)
    }

    // MARK: Recovery (F-ACC-05)

    func testTC_ACC_05_04_recoverShowsANewCode() async throws {
        start()
        try await see("account-forgot")
        try await tap("account-forgot")
        try await see("recover-username")
        try await type("alice", into: "recover-username")
        try await type("OLD-CODE", into: "recover-code")
        try await type("pw654321", into: "recover-password")
        try await submit("recover-submit")
        try await see("recovery-code")
        XCTAssertEqual(fake.requests("/v1/account/recover").first?.body["newPassword"] as? String, "pw654321")
        try await stateIs(0, 0)
        try await tap("recovery-confirm")
        try await see("tab-chats")
    }

    func testTC_ACC_05_09_warningOnEveryPageAndNoSupportEntry() async throws {
        start()
        try await see("account-register")
        try await tap("account-register")
        try await see("register-recovery-hint")
        XCTAssertEqual(label("register-recovery-hint"), "恢复码丢失后账号无法找回")
        XCTAssertFalse(staticText(containing: "客服").exists)
        try await back()
        try await tap("account-forgot")
        try await see("recover-recovery-hint")
        XCTAssertEqual(label("recover-recovery-hint"), "恢复码丢失后账号无法找回")
        XCTAssertFalse(staticText(containing: "客服").exists)
    }

    func testTC_ACC_05_14_staleCode() async throws {
        fake.script("/v1/account/login", .json(200, fake.auth(code: "CODE-1", codeGen: 3)))
        fake.script("/v1/account/recovery-code/ack", fake.error(400, 4000, reason: "recoveryCodeStale"))
        start()
        try await see("account-username")
        try await typeAccount()
        try await submit("account-submit")
        try await see("recovery-confirm")
        try await tap("recovery-confirm")
        try await see("kicked-text")
        XCTAssertEqual(label("kicked-text"), "恢复码已更新，请重新登录查看")
        try await tap("kicked-ok")
        try await see("account-username")
        try await stateIs(0, 0)
    }

    func testTC_ACC_05_06_killedOnTheSavePage() async throws {
        fake.script("/v1/account/login", .json(200, fake.auth(code: "CODE-1", codeGen: 3)))
        fake.script("/v1/account/login", .json(200, fake.auth(code: "CODE-2", codeGen: 4)))
        start()
        try await see("account-username")
        try await typeAccount()
        try await submit("account-submit")
        try await see("recovery-code")
        XCTAssertEqual(label("recovery-code"), "CODE-1")
        try await stateIs(0, 0)
        app.terminate()
        start(reset: false)
        try await see("account-username")
        try await stateIs(0, 0)
        try await typeAccount()
        try await submit("account-submit")
        try await see("recovery-code")
        XCTAssertEqual(label("recovery-code"), "CODE-2")
    }

    func testTC_ACC_05_18_unackedAckForcesThePage() async throws {
        start()
        try await logIn()
        app.terminate()
        fake.authAckExtra = ["recoveryCodeUnacked": true]
        fake.script("/v1/account/recovery-code", fake.error(401, 4018))
        fake.script("/v1/account/recovery-code", .json(200, ["recoveryCode": "CODE-9", "recoveryCodeGen": 9]))
        start(reset: false)
        try await see("recovery-needs-password")
        XCTAssertFalse(el("tab-chats").exists)
        try await type("wrong-pass", into: "recovery-password")
        try await tap("recovery-regenerate")
        try await see("recovery-error")
        XCTAssertEqual(label("recovery-error"), "密码错误")
        try await type("pw123456", into: "recovery-password")
        try await tap("recovery-regenerate")
        try await see("recovery-code")
        XCTAssertEqual(label("recovery-code"), "CODE-9")
        fake.authAckExtra = [:]
        try await tap("recovery-confirm")
        try await see("tab-chats")
        XCTAssertEqual(fake.requests("/v1/account/recovery-code/ack").first?.body["gen"] as? Int, 9)
    }

    func testTC_ACC_05_18_forgottenPasswordIsNotATrap() async throws {
        start()
        try await logIn()
        app.terminate()
        fake.authAckExtra = ["recoveryCodeUnacked": true]
        start(reset: false)
        try await see("recovery-needs-password")
        try await tap("recovery-logout")
        try await see("account-forgot")
        try await stateIs(0, 0)
    }

    // MARK: Session (F-ACC-03)

    func testTC_ACC_03_07_expiredAccessRefreshesFirst() async throws {
        fake.accessLifeMs = -3_600_000
        start()
        try await logIn()
        app.terminate()
        fake.accessLifeMs = 86_400_000
        let before = fake.timeline.count
        start(reset: false)
        // Never the login page or a dialog on the way.
        for _ in 0..<20 {
            XCTAssertFalse(el("account-username").exists)
            XCTAssertFalse(el("kicked-dialog").exists)
            try await sleep(100)
        }
        try await see("tab-chats")
        try await until("auth") { self.fake.timeline.dropFirst(before).contains("auth") }
        let after = Array(fake.timeline.dropFirst(before))
        let refresh = try XCTUnwrap(after.firstIndex(of: "/v1/account/token/refresh"))
        let auth = try XCTUnwrap(after.firstIndex(of: "auth"))
        XCTAssertLessThan(refresh, auth, "\(after)")
    }

    func testTC_ACC_03_08_revokedOnColdStart() async throws {
        start()
        try await logIn()
        app.terminate()
        fake.script("/v1/account/token/refresh", fake.error(401, 4019, reason: "revoked"))
        fake.accessLifeMs = 86_400_000
        // Only a token that needs refreshing reaches 4019 at start.
        start(reset: false)
        try await see("tab-chats")
        fake.kick("tokenExpired", code: 4011)
        try await see("kicked-text")
        XCTAssertEqual(label("kicked-text"), "登录已失效，请重新登录")
        try await tap("kicked-ok")
        try await see("account-username")
        try await stateIs(0, 0)
    }

    func testTC_ACC_03_10_timerRefreshesAndReconnectsQuietly() async throws {
        fake.accessLifeMs = 6 * 3_600_000 + 5_000
        start()
        try await logIn()
        try await until("first auth") { self.fake.authTokens.count == 1 }
        fake.accessLifeMs = 86_400_000
        let first = fake.authTokens[0]
        // The SDK's timer fires 6 hours before expiry.
        var bannerSeen = false
        let deadline = Date().addingTimeInterval(15)
        while fake.authTokens.count < 2, Date() < deadline {
            bannerSeen = bannerSeen || el("conn-banner").exists
            XCTAssertFalse(el("kicked-dialog").exists)
            try await sleep(100)
        }
        XCTAssertEqual(fake.authTokens.count, 2, "\(fake.timeline)")
        XCTAssertNotEqual(fake.authTokens[1], first)
        XCTAssertTrue(fake.closeCodes.contains(1000), "\(fake.timeline)")
        XCTAssertFalse(bannerSeen, "under a second: no connection hint")
        XCTAssertEqual(fake.requests("/v1/account/token/refresh").count, 1)
    }

    func testTC_ACC_03_11_offlineColdStartShowsTheCache() async throws {
        fake.convs = [[
            "convId": "c2c:alice:bob", "type": "c2c", "name": "缓存的会话", "maxSeq": 0, "readSeq": 0, "minSeq": 1, "unread": 0,
            "updatedAt": 1,
        ]]
        fake.accessLifeMs = -3_600_000
        start()
        try await logIn()
        try await see(conv("缓存的会话"))
        try await sleep(1500)  // Written to the local database.
        app.terminate()
        fake.accessLifeMs = 86_400_000
        fake.blackhole = true
        start(reset: false, env: ["TT_TEST_OFFLINE": "1"])
        try await see("tab-chats")
        try await see(conv("缓存的会话"))
        try await see("conn-banner", timeout: 15)
        XCTAssertTrue(label("conn-banner").contains("网络不可用"), label("conn-banner"))
        XCTAssertFalse(el("account-username").exists)
        XCTAssertFalse(el("kicked-dialog").exists)
        let before = fake.authTokens.count
        fake.blackhole = false
        try await until("connected with a fresh token", timeout: 40) { self.fake.authTokens.count > before }
        try await gone(el("conn-banner"), timeout: 10)
    }

    func testTC_ACC_03_12_refresh503BacksOffAndKickedRefreshReconnects() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        // Kicked with tokenExpired while the refresh answers 503 first: stays, backs off, reconnects without a dialog.
        fake.script("/v1/account/token/refresh", fake.error(503, 5030))
        fake.kick("tokenExpired", code: 4011)
        try await until("second refresh", timeout: 10) { self.fake.requests("/v1/account/token/refresh").count >= 2 }
        try await until("reconnected", timeout: 10) { self.fake.authTokens.count == 2 }
        XCTAssertFalse(el("kicked-dialog").exists)
        XCTAssertTrue(el("tab-chats").exists)
    }

    func testTC_ACC_03_13_killedAfterSaving() async throws {
        fake.accessLifeMs = -3_600_000
        start()
        try await logIn()
        app.terminate()
        fake.accessLifeMs = 86_400_000
        let refreshes = fake.requests("/v1/account/token/refresh").count
        let auths = fake.authTokens.count
        // Dies right after the refreshed session is written, before it is used.
        start(reset: false, env: ["TT_TEST_EXIT_AFTER_SAVE": "1"])
        try await until("refreshed", timeout: 10) { self.fake.requests("/v1/account/token/refresh").count == refreshes + 1 }
        try await until("app gone", timeout: 10) { self.app.state != .runningForeground }
        XCTAssertEqual(fake.authTokens.count, auths, "not used before dying: \(fake.timeline)")
        start(reset: false)
        try await see("tab-chats")
        try await until("auth") { self.fake.authTokens.count == auths + 1 }
        XCTAssertEqual(
            fake.requests("/v1/account/token/refresh").count, refreshes + 1, "the saved token is used, no second refresh")
    }

    func testTC_ACC_03_18_oldKeychainItemIsDemo() async throws {
        start(env: ["TT_TEST_LEGACY_SESSION": "alice:legacy-token"])
        try await see("tab-chats")
        try await until("auth") { self.fake.authTokens == ["legacy-token"] }
        XCTAssertEqual(fake.requests("/v1/account/token/refresh").count, 0)
        try await tap("tab-me")
        XCTAssertFalse(el("me-edit-nickname").exists)
        try await tap("me-settings")
        try await see("about")
        XCTAssertFalse(el("settings-security").exists)
    }

    func testTC_ACC_03_20_killedWithTheRefreshInFlight() async throws {
        fake.accessLifeMs = -3_600_000
        start()
        try await logIn()
        let old = try XCTUnwrap(fake.requests("/v1/account/token/refresh").last?.body["refreshToken"] as? String)
        _ = old
        app.terminate()
        // The next refresh never answers; the app dies waiting.
        fake.script("/v1/account/token/refresh", .hang)
        let before = fake.requests("/v1/account/token/refresh").count
        start(reset: false)
        try await until("sent", timeout: 10) { self.fake.requests("/v1/account/token/refresh").count == before + 1 }
        let held = fake.requests("/v1/account/token/refresh").last?.body["refreshToken"] as? String
        app.terminate()
        fake.accessLifeMs = 86_400_000
        start(reset: false)
        try await see("tab-chats")
        try await until("retried", timeout: 10) { self.fake.requests("/v1/account/token/refresh").count == before + 2 }
        XCTAssertEqual(fake.requests("/v1/account/token/refresh").last?.body["refreshToken"] as? String, held, "the same old value")
        try await until("connected") { self.fake.authTokens.count >= 1 }
        XCTAssertFalse(el("account-username").exists)
    }

    func testTC_ACC_03_26_replayDialog() async throws {
        start()
        try await logIn()
        fake.script("/v1/account/token/refresh", fake.error(401, 4019, reason: "replayDetected"))
        fake.kick("tokenExpired", code: 4011)
        try await see("kicked-text")
        XCTAssertEqual(label("kicked-text"), "检测到登录凭证异常，这台设备已下线。如果不是你本人操作，请尽快改密码")
        try await stateIs(0, 0)
        try await tap("kicked-ok")
        try await see("account-username")
    }

    func testTC_ACC_03_39_supersededThreeTimes() async throws {
        start()
        try await logIn()
        let superseded = { self.fake.error(401, 4019, reason: "superseded", details: ["retryAfterSeconds": 1]) }
        fake.script("/v1/account/token/refresh", superseded(), superseded(), superseded())
        fake.kick("tokenExpired", code: 4011)
        try await until("first", timeout: 5) { self.fake.requests("/v1/account/token/refresh").count >= 1 }
        XCTAssertFalse(el("kicked-dialog").exists, "stays on the page")
        try await see("kicked-text", timeout: 12)
        XCTAssertEqual(label("kicked-text"), "登录已失效，请重新登录")
        XCTAssertEqual(fake.requests("/v1/account/token/refresh").count, 3)
    }

    func testTC_ACC_03_43_absoluteLimitEndsWithoutRefreshing() async throws {
        fake.atAbsoluteLimit = true
        fake.accessLifeMs = 4_000
        start()
        try await logIn()
        try await see("kicked-text", timeout: 12)
        XCTAssertEqual(label("kicked-text"), "登录已失效，请重新登录")
        XCTAssertEqual(fake.requests("/v1/account/token/refresh").count, 0)
    }

    // MARK: Kicks and logout (F-ACC-04)

    func testTC_ACC_04_05_kickShowsTheDeadline() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        let at: Int64 = 1_900_000_000_000
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy/M/d"
        let date = f.string(from: Date(timeIntervalSince1970: TimeInterval(at) / 1000))
        fake.kick("passwordChanged", code: 4012, recoverBefore: at)
        try await see("kicked-text")
        XCTAssertEqual(label("kicked-text"), "你的账号凭证有变化。如果不是你本人操作，请在 \(date) 前用恢复码找回")
        try await sleep(5000)
        XCTAssertEqual(fake.authTokens.count, 1, "no reconnect")
        try await stateIs(0, 0)
        try await tap("kicked-ok")
        try await see("account-username")
        try await stateIs(0, 0)
    }

    func testTC_ACC_04_05_kickWithoutDeadline() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        fake.kick("passwordChanged", code: 4012)
        try await see("kicked-text")
        XCTAssertEqual(label("kicked-text"), "账号已被下线")
    }

    /// Offline logout: back at login at once, only the pending record left; goes out when back in the foreground (the real
    /// notification through the SDK's SystemEventsMonitor) and on a cold start.
    func testTC_ACC_04_06_offlineLogoutSendsLaterFromForeground() async throws {
        start()
        try await logIn()
        try await stateIs(1, 0)
        fake.blackhole = true
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("logout")
        try await tap("dialog-ok")
        // Back at login at once. With no network `GET /v1/config` fails too, so the page offers a retry and guesses nothing.
        try await see("login-config-error")
        try await stateIs(0, 1)
        XCTAssertEqual(fake.requests("/v1/account/logout").count, 0)

        // Network back; the app goes to the background and returns.
        fake.blackhole = false
        XCUIDevice.shared.press(.home)
        try await until("background") { self.app.state != .runningForeground }
        try await sleep(500)
        let before = fake.requests("/v1/account/logout").count
        app.activate()
        try await until("logout sent", timeout: 10) { self.fake.requests("/v1/account/logout").count > before }
        XCTAssertNotNil(fake.requests("/v1/account/logout").last?.body["refreshToken"])
        try await stateIs(0, 0)
    }

    func testTC_ACC_04_06_offlineLogoutSendsLaterFromColdStart() async throws {
        start()
        try await logIn()
        fake.blackhole = true
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("logout")
        try await tap("dialog-ok")
        try await see("login-config-error")
        try await stateIs(0, 1)
        app.terminate()
        fake.blackhole = false
        start(reset: false)
        try await see("account-username")
        try await until("logout sent", timeout: 10) { self.fake.requests("/v1/account/logout").count >= 1 }
        try await stateIs(0, 0)
        XCTAssertFalse(el("tab-chats").exists)
    }

    /// K2: the page does not wait for a hanging logout.
    func testK2_hangingLogoutDoesNotHoldThePage() async throws {
        start()
        try await logIn()
        fake.script("/v1/account/logout", .hang)
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("logout")
        let tapped = Date()
        try await tap("dialog-ok")
        try await see("account-username")
        XCTAssertLessThan(Date().timeIntervalSince(tapped), 5, "far from the SDK's 30 seconds")
        try await stateIs(0, 1)
    }

    /// A1: logging in does not wait for a hanging logout, and that logout ending (here the SDK's 30 seconds) leaves the new
    /// session alone; the old sid's record still goes out.
    func testA1_loginAtOnceWhileALogoutHangs() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        fake.script("/v1/account/logout", .hang)
        try await logOutAccount()
        try await stateIs(0, 1)
        fake.script("/v1/account/login", .json(200, fake.auth(sid: "s2")))  // A new sid, as the real server gives.
        try await typeAccount()
        let tapped = Date()
        try await submit("account-submit")
        try await see("tab-chats")
        XCTAssertLessThan(Date().timeIntervalSince(tapped), 8, "far from the SDK's 30 seconds")
        XCTAssertEqual(fake.requests("/v1/account/login").count, 2)
        try await until("auth with the new token") { self.fake.authTokens.count == 2 }
        // A login sends pending records: the old sid goes out again while the first request still hangs.
        try await until("record sent") { self.fake.requests("/v1/account/logout").count >= 2 }
        try await stateIs(1, 0)
        // Past the SDK's 30 seconds for the first request: its end changes nothing.
        try await sleep(32_000)
        try await stateIs(1, 0)
        XCTAssertTrue(el("tab-chats").exists)
        XCTAssertFalse(el("account-username").exists)
        XCTAssertFalse(el("kicked-text").exists)
    }

    /// D1's password change committed, the response was lost, and the next refresh says so: the deadline, not the anomaly.
    func testTC_ACC_04_16_credentialsChangedIsNotAnAnomaly() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        let at: Int64 = 1_900_000_000_000
        fake.script("/v1/account/token/refresh", fake.error(401, 4019, reason: "credentialsChanged", details: ["recoverBefore": at]))
        fake.kick("tokenExpired", code: 4011)
        do { try await see("kicked-text") } catch {
            print("E2E-TIMELINE \(fake.timeline) closes=\(fake.closeCodes)")
            throw error
        }
        XCTAssertTrue(label("kicked-text").hasPrefix("你的账号凭证有变化。"), label("kicked-text"))
        XCTAssertFalse(label("kicked-text").contains("异常"))
        try await tap("kicked-ok")
        try await see("account-username")
    }

    func testTC_ACC_04_27_passwordChangeHoldsTheKick() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("settings-security")
        try await tap("security-password")
        try await type("pw123456", into: "security-current")
        try await type("pw654321", into: "security-new")

        // The server kicks before it answers: no dialog, the answer changes the sid (AC-ACC-04-27, last case).
        fake.script("/v1/account/password", .hang)
        try await submit("security-submit")
        try await until("sent") { self.fake.requests("/v1/account/password").count == 1 }
        fake.kick("passwordChanged", code: 4012)
        try await sleep(1000)
        XCTAssertFalse(el("kicked-dialog").exists, "held while the request is in flight")
        // 30 seconds without an answer: the failure shows, then the held kick applies (the first case).
        try await see("kicked-dialog", timeout: 40)
        XCTAssertEqual(label("kicked-text"), "账号已被下线")
    }

    func testTC_ACC_04_27_answerFirstReconnectsAndShowsTheNewCode() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("settings-security")
        try await tap("security-password")
        try await type("pw123456", into: "security-current")
        try await type("pw654321", into: "security-new")
        fake.script("/v1/account/password", .json(200, fake.auth(sid: "s2", code: "CODE-NEW", codeGen: 2)))
        try await submit("security-submit")
        try await see("recovery-code")
        XCTAssertEqual(label("recovery-code"), "CODE-NEW")
        XCTAssertEqual(fake.requests("/v1/account/password").first?.body["newPassword"] as? String, "pw654321")
        XCTAssertEqual(fake.requests("/v1/account/password").first?.body["oldPassword"] as? String, "pw123456")
        try await stateIs(0, 0)  // TC-ACC-05-18: the old token left the store, the new one is not there yet.
        try await until("reconnected with the new sid") { self.fake.authTokens.count == 2 }
        XCTAssertFalse(el("kicked-dialog").exists)
        try await tap("recovery-confirm")
        try await see("security-password")  // Back where the change was made, one page up.
        try await stateIs(1, 0)
        XCTAssertFalse(el("account-username").exists)
    }

    // MARK: Security pages

    func testTC_ACC_07_08_demoHasNoSecurityEntryAccountHas() async throws {
        fake.demoLogin = true
        fake.script("/demo/login", .json(200, ["userId": "alice", "token": "demo-token"]))
        start()
        try await see("login-username")
        try await type("alice", into: "login-username")
        try await tap("login-submit")
        try await see("tab-chats")
        try await tap("tab-me")
        XCTAssertFalse(el("me-edit-nickname").exists)
        try await tap("me-settings")
        try await see("about")
        XCTAssertFalse(el("settings-security").exists)
        app.terminate()

        fake.demoLogin = false
        start()
        try await logIn()
        try await tap("tab-me")
        XCTAssertTrue(el("me-edit-nickname").exists)
        try await tap("me-settings")
        try await see("settings-security")
    }

    func testTC_ACC_08_06_deleteConfirmAndWrongPassword() async throws {
        fake.script("/v1/account/delete", fake.error(401, 4018))
        start()
        try await logIn()
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("settings-security")
        try await tap("security-delete")
        try await see("delete-dialog")
        XCTAssertEqual(label("dialog-text"), "7 天后不可恢复，用户名不能再使用，已发的消息会保留")
        try await tap("dialog-ok")
        try await type("wrong-pass", into: "security-current")
        try await submit("security-submit")
        try await see("security-error")
        XCTAssertEqual(label("security-error"), "密码错误")
        XCTAssertTrue(el("security-current").exists, "stays on the page")
        XCTAssertFalse(el("account-username").exists)
        try await stateIs(1, 0)
    }

    func testSecurityPageListsEventsAndFailsSoftly() async throws {
        fake.script(
            "/v1/account/events", .text(502, "text/html", "<html>"),
            .json(
                200,
                [
                    "events": [["kind": "newDeviceLogin", "at": 1_800_000_000_000, "platform": "android"]],
                    "otherSessions": ["count": 2, "lastActiveAt": 1_800_000_000_000],
                ]))
        start()
        try await logIn()
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("settings-security")
        try await see("security-events-error")
        try await tap("security-events-retry")
        try await see("security-event")
        XCTAssertTrue(label("security-event").contains("新设备登录"))
        XCTAssertTrue(label("security-event").contains("Android"))
        XCTAssertTrue(label("security-other-sessions").contains("其他 2 台设备"))
    }

    // MARK: Notices and privacy

    func testTC_ACC_02_13_securityNoticeToast() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        try await sleep(500)
        fake.broadcast(["cmd": "event", "data": ["type": "securityNotice", "kind": "newDeviceLogin", "at": 1, "platform": "android"]])
        try await see("toast", timeout: 2)
        XCTAssertEqual(label("toast"), "你的账号在新设备登录")
    }

    /// AC-ACC-03-25, AC-ACC-03-45, F-ACC-05 rule 5. The wording of these three waits for confirmation (issue table).
    func testSecurityNoticeOtherKindsToast() async throws {
        start()
        try await logIn()
        try await until("auth") { self.fake.authTokens.count == 1 }
        try await sleep(500)
        fake.broadcast(["cmd": "event", "data": ["type": "securityNotice", "kind": "futureKind", "at": 1, "platform": "android"]])
        try await staysGone(el("toast"))
        fake.broadcast(["cmd": "event", "data": ["type": "securityNotice", "kind": "refreshReplay", "at": 1, "platform": "android"]])
        try await see("toast", timeout: 2)
        XCTAssertEqual(label("toast"), "检测到你的账号登录凭证异常")
    }

    func testTC_ACC_10_01_privacyEntriesOpenAndFailSoftly() async throws {
        fake.privacy = (version: "v1", url: "\(fake.url)/notice")
        start()
        try await see("login-privacy")
        try await tap("login-privacy")
        try await see(staticText(containing: "隐私说明内容"), timeout: 10)
        try await back()
        try await tap("account-register")
        try await see("register-privacy")
        fake.script("/notice", .text(500, "text/plain", "x"))
        try await tap("register-privacy")
        try await see("privacy-error", timeout: 10)
        XCTAssertEqual(label("privacy-error"), "暂时打不开，请稍后重试")
        try await back()
        try await back()
        try await see("account-submit")  // It blocks nothing.
        try await logIn()
        try await tap("privacy-update-ok")  // This device has no record of the version (see 实现时发现的问题).
        try await tap("tab-me")
        try await tap("me-settings")
        try await see("about-privacy")
        try await tap("about-privacy")
        try await see(staticText(containing: "隐私说明内容"), timeout: 10)
    }

    func testTC_ACC_10_01_noConfigurationHidesTheEntries() async throws {
        start()
        try await see("account-username")
        try await staysGone(el("login-privacy"))
        try await tap("account-register")
        try await see("register-username")
        XCTAssertFalse(el("register-privacy").exists)
    }

    func testTC_ACC_10_03_updatedNoticeAsksOnce() async throws {
        fake.privacy = (version: "v1", url: "\(fake.url)/notice")
        start()
        try await see("account-register")
        try await tap("account-register")
        try await fillRegister()
        try await submit("register-submit")
        try await tap("recovery-confirm")
        try await see("tab-chats")
        try await staysGone(el("privacy-update-dialog"))
        app.terminate()

        fake.privacy = (version: "v2", url: "\(fake.url)/notice")
        start(reset: false)
        try await see("tab-chats")
        try await staysGone(el("privacy-update-dialog"))  // A login asks, a cold start does not.
        try await logOutAccount()
        try await typeAccount()
        try await submit("account-submit")
        try await see("privacy-update-dialog")
        XCTAssertEqual(label("privacy-update-text"), "隐私说明已更新")
        try await tap("privacy-update-ok")
        try await gone(el("privacy-update-dialog"))
        XCTAssertTrue(el("tab-chats").exists, "agreeing or not, the app works")
        try await logOutAccount()
        try await typeAccount()
        try await submit("account-submit")
        try await see("tab-chats")
        try await staysGone(el("privacy-update-dialog"))
    }

    // MARK: Look

    /// TC-CHAT-90-08: the system's audit for elements without a description, the native `button-name`.
    func testTC_CHAT_90_08_accessibilityAudit() async throws {
        fake.script("/v1/account/register", .json(200, fake.auth(code: "RTVX-KQ7M-2NPD-8WHC", codeGen: 1)))
        start()
        try await see("account-username")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        try await tap("account-register")
        try await see("register-username")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        try await fillRegister()
        try await submit("register-submit")
        try await see("recovery-code")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        try await tap("recovery-confirm")
        try await see("tab-chats")
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("settings-security")
        try await see("security-password")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        try await tap("security-password")
        try await see("security-current")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
    }

    /// The walkthrough for people: light and dark, every account page. Also checks they exist under Dynamic Type.
    func testTC_CHAT_90_08_screenshots() async throws {
        fake.privacy = (version: "v1", url: "\(fake.url)/notice")
        let events: FakeAccountServer.Reply = .json(
            200,
            [
                "events": [
                    ["kind": "newDeviceLogin", "at": 1_800_000_000_000, "platform": "android"],
                    ["kind": "passwordChanged", "at": 1_799_000_000_000, "platform": "ios"],
                ],
                "otherSessions": ["count": 1, "lastActiveAt": 1_800_000_000_000],
            ])
        for mode in ["light", "dark"] {
            fake.script("/v1/account/events", events)
            try await setSystemAppearance(mode)
            start()
            try await see("account-username")
            capture("account-login-\(mode)")
            try await tap("account-register")
            try await see("register-username")
            capture("account-register-\(mode)")
            fake.script("/v1/account/register", fake.error(409, 4095))
            try await fillRegister()
            try await submit("register-submit")
            try await see("register-username-error")
            capture("account-register-error-\(mode)")
            try await back()
            try await tap("account-forgot")
            try await see("recover-username")
            capture("account-forgot-\(mode)")
            try await back()
            try await tap("account-register")
            try await fillRegister()
            fake.script("/v1/account/register", .json(200, fake.auth(code: "RTVX-KQ7M-2NPD-8WHC-4FYB-JZ3G", codeGen: 1)))
            try await submit("register-submit")
            try await see("recovery-code")
            capture("account-recovery-\(mode)")
            try await tap("recovery-confirm")
            try await see("tab-chats")
            try await tap("tab-me")
            try await see("me-edit-nickname")
            capture("account-me-\(mode)")
            try await tap("me-settings")
            try await see("settings-security")
            capture("account-settings-\(mode)")
            try await tap("settings-security")
            try await see("security-password")
            try await sleep(500)
            capture("account-security-\(mode)")
            try await tap("security-password")
            try await see("security-current")
            capture("account-change-password-\(mode)")
            try await back()
            try await tap("security-delete")
            try await see("delete-dialog")
            capture("account-delete-dialog-\(mode)")
            app.terminate()
        }
        try await setSystemAppearance("light")
    }
}
