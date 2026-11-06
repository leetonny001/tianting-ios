import TiantingIM
import XCTest

/// Account flows against the real im-server (`scripts/e2e-server.sh`: invite mode, refresh keys, IM_TEST_DISABLE_AUTH_LOCK=1).
/// The second device is a real `AccountClient` + `IMClient` in the test process.
final class AccountE2ETests: E2ECase {
    private let password = "correct-horse-7"
    private var devices: [AccountClient] = []
    private var proxy: TCPProxy?
    private var clockMoved = false

    override func tearDown() async throws {
        for d in devices { _ = d }
        devices = []
        proxy?.stop()
        proxy = nil
        if clockMoved {
            try? await admin("POST", "/admin/test/clock", ["nowMs": NSNull()])
            clockMoved = false
        }
        try await super.tearDown()
    }

    private func invite(maxUses: Int = 1) async throws -> String {
        let expires = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
        let r = try await signed(
            "POST", "/admin/invites", ["count": 1, "maxUses": maxUses, "expiresAt": expires, "note": "ios-e2e"])
        let list = r["invites"] as? [[String: Any]]
        return try XCTUnwrap(list?.first?["code"] as? String)
    }

    private func device(platform: Platform = .android) -> AccountClient {
        var options = AccountClientOptions(baseUrl: http)
        options.platform = platform
        options.systemEvents = false
        let c = AccountClient(options: options)
        devices.append(c)
        return c
    }

    private func start(reset: Bool = true, server: String? = nil) {
        launch(reset: reset, env: ["TT_TEST_STATE": "1", "TIANTING_SERVER": server ?? http])
    }

    private func state() -> String { el("test-state").value as? String ?? "" }

    private func stateIs(_ session: Int, _ pending: Int) async throws {
        try await until("state session=\(session) pending=\(pending), was \(state())") {
            self.state().hasPrefix("session=\(session) pending=\(pending)")
        }
    }

    private func submit(_ id: String) async throws {
        if !el(id).isHittable { app.swipeUp() }
        try await tap(id)
    }

    private func openAccountForm() async throws {
        try await see("login-use-account")  // The e2e server has demo login on.
        try await tap("login-use-account")
        try await see("account-username")
    }

    /// Registers through the app and confirms. Returns the code it showed.
    @discardableResult
    private func registerInApp(_ user: String, inviteCode: String? = nil) async throws -> String {
        let code: String
        if let inviteCode { code = inviteCode } else { code = try await invite() }
        try await openAccountForm()
        try await tap("account-register")
        try await see("register-username")
        try await type(user, into: "register-username")
        try await type(password, into: "register-password")
        try await type(code, into: "register-invite")
        try await submit("register-submit")
        try await see("recovery-code", timeout: 15)
        let shown = label("recovery-code")
        try await stateIs(0, 0)
        try await tap("recovery-confirm")
        try await see("tab-chats", timeout: 15)
        try await stateIs(1, 0)
        return shown
    }

    private func logInInApp(_ user: String, _ pw: String) async throws {
        try await openAccountForm()
        try await type(user, into: "account-username")
        try await type(pw, into: "account-password")
        try await submit("account-submit")
    }

    private func toSecurity() async throws {
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("settings-security")
        try await see("security-password")
    }

    private func waitForConnection(_ user: String) async throws {
        // Sends a message to itself is not possible; the "我" page shows the profile only after connecting.
        try await sleep(800)
    }

    // MARK: Register, confirm, logout, login

    func testTC_ACC_01_12_registerConfirmLogoutLogin() async throws {
        let me = uid("alice")
        start()
        let code = try await registerInApp(me)
        XCTAssertGreaterThan(code.count, 16)
        // A cold start stays logged in.
        app.terminate()
        start(reset: false)
        try await see("tab-chats")
        try await stateIs(1, 0)
        // Logout reaches the server: the session is gone, nothing pending.
        try await logout()
        try await stateIs(0, 0)
        try await tap("login-use-account")
        try await type(me, into: "account-username")
        try await type("wrong-password", into: "account-password")
        try await submit("account-submit")
        try await see("account-error")
        XCTAssertEqual(label("account-error"), "用户名或密码错误")  // TC-ACC-02-08 against the real server.
        XCTAssertEqual(el("account-username").value as? String, me)
        try await type(password, into: "account-password")
        try await submit("account-submit")
        try await see("tab-chats", timeout: 15)
        try await stateIs(1, 0)
    }

    func testTC_ACC_01_13_takenNameFromTheRealServer() async throws {
        let me = uid("alice")
        let inviteCode = try await invite(maxUses: 2)
        _ = try await device().register(username: me, password: password, inviteCode: inviteCode)
        start()
        try await openAccountForm()
        try await tap("account-register")
        try await see("register-username")
        try await type(me, into: "register-username")
        try await type(password, into: "register-password")
        try await type(inviteCode, into: "register-invite")
        try await submit("register-submit")
        try await see("register-username-error", timeout: 15)
        XCTAssertEqual(label("register-username-error"), "这个用户名不能使用")
    }

    func testTC_ACC_09_01_inviteUsedUp() async throws {
        let code = try await invite(maxUses: 2)
        _ = try await device().register(username: uid("first"), password: password, inviteCode: code)
        start()
        try await registerInApp(uid("second"), inviteCode: code)
        try await logout()
        try await tap("login-use-account")
        try await tap("account-register")
        try await type(uid("third"), into: "register-username")
        try await type(password, into: "register-password")
        try await type(code, into: "register-invite")
        try await submit("register-submit")
        try await see("register-error", timeout: 15)
        XCTAssertEqual(label("register-error"), "邀请码无效")
    }

    // MARK: Devices

    func testTC_ACC_02_13_newDeviceLoginReachesTheAppAndTheList() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        try await waitForConnection(me)
        _ = try await device().login(username: me, password: password)
        try await see("toast", timeout: 2)
        XCTAssertEqual(label("toast"), "你的账号在新设备登录")
        try await toSecurity()
        try await see("security-event")
        XCTAssertNotNil(all("security-event").allElementsBoundByIndex.first { $0.label.contains("新设备登录") && $0.label.contains("Android") })
        XCTAssertTrue(label("security-other-sessions").contains("其他 1 台设备"), label("security-other-sessions"))
    }

    func testTC_ACC_04_05_otherDeviceChangesPassword() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        try await waitForConnection(me)
        let d2 = device()
        _ = try await d2.login(username: me, password: password)
        let r = try await d2.changePassword(oldPassword: password, newPassword: "new-password-8")
        XCTAssertNotNil(r.recoveryCode)
        // F-ACC-03 rule 6a: the old code stays valid for 7 days.
        try await see("kicked-text", timeout: 5)
        XCTAssertTrue(label("kicked-text").hasPrefix("你的账号凭证有变化。如果不是你本人操作，请在 "), label("kicked-text"))
        XCTAssertTrue(label("kicked-text").hasSuffix(" 前用恢复码找回"), label("kicked-text"))
        try await stateIs(0, 0)
        try await tap("kicked-ok")
        // The old password no longer works, the new one does and shows the unconfirmed newest code.
        try await logInInApp(me, password)
        try await see("account-error", timeout: 15)
        XCTAssertEqual(label("account-error"), "用户名或密码错误")
        try await type("new-password-8", into: "account-password")
        try await submit("account-submit")
        try await see("recovery-code", timeout: 15)
    }

    func testTC_ACC_03_34_offlineWhilePasswordChanged() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        app.terminate()
        let d2 = device()
        _ = try await d2.login(username: me, password: password)
        _ = try await d2.changePassword(oldPassword: password, newPassword: "new-password-8")
        // Access still valid: `auth` gets kicked/passwordChanged with the date.
        start(reset: false)
        try await see("kicked-text", timeout: 10)
        XCTAssertTrue(label("kicked-text").contains("前用恢复码找回"), label("kicked-text"))
        try await tap("kicked-ok")
        try await see("login-use-account")
    }

    func testTC_ACC_04_09_logoutOthers() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        let d2 = device()
        _ = try await d2.login(username: me, password: password)
        var options = IMClientOptions(url: http.replacingOccurrences(of: "http://", with: "ws://") + "/ws")
        options.platform = .android
        options.systemEvents = false
        options.pushCursorStore = nil
        let im = IMClient(options: options)
        var kicked: FatalReason?
        let sub = im.on { if case .fatal(let r) = $0 { kicked = r } }
        im.connect(tokenProvider: d2.tokenProvider)
        try await until("d2 connected") { im.state == .connected }

        try await toSecurity()
        try await tap("security-logout-others")
        try await type("wrong-password", into: "security-current")
        try await submit("security-submit")
        try await see("security-error", timeout: 15)
        XCTAssertEqual(label("security-error"), "密码错误")
        XCTAssertNil(kicked)

        try await type(password, into: "security-current")
        try await submit("security-submit")
        try await see("toast", timeout: 15)
        XCTAssertEqual(label("toast"), "已退出其他设备")
        try await until("d2 kicked") { kicked != nil }
        if case .kicked(let reason, let code, _, _)? = kicked {
            XCTAssertEqual(reason, "sessionRevoked")
            XCTAssertEqual(code, 4012)
        } else {
            XCTFail("\(String(describing: kicked))")
        }
        XCTAssertFalse(el("conn-banner").exists)
        XCTAssertFalse(el("kicked-dialog").exists)
        // The password did not change.
        _ = try await device().login(username: me, password: password)
        im.destroy()
        withExtendedLifetime(sub) {}
    }

    // MARK: Recovery

    func testTC_ACC_05_04_recoverWithTheCode() async throws {
        let me = uid("alice")
        start()
        let code = try await registerInApp(me)
        try await logout()
        try await tap("login-use-account")
        try await tap("account-forgot")
        try await see("recover-username")
        try await type(me, into: "recover-username")
        try await type("not-the-code", into: "recover-code")
        try await type("new-password-8", into: "recover-password")
        try await submit("recover-submit")
        try await see("recover-error", timeout: 15)
        XCTAssertEqual(label("recover-error"), "用户名或恢复码错误")
        try await clearAndType(code, into: "recover-code")
        try await submit("recover-submit")
        try await see("recovery-code", timeout: 15)
        XCTAssertNotEqual(label("recovery-code"), code)
        try await stateIs(0, 0)
        try await tap("recovery-confirm")
        try await see("tab-chats", timeout: 15)
    }

    func testTC_ACC_05_06_killOnSavePageThenLoginShowsANewCode() async throws {
        let me = uid("alice")
        let inviteCode = try await invite()
        _ = try await device().register(username: me, password: password, inviteCode: inviteCode)  // Never confirmed.
        start()
        try await logInInApp(me, password)
        try await see("recovery-code", timeout: 15)
        let first = label("recovery-code")
        try await stateIs(0, 0)
        app.terminate()
        start(reset: false)
        try await see("login-use-account")
        try await stateIs(0, 0)
        try await logInInApp(me, password)
        try await see("recovery-code", timeout: 15)
        XCTAssertNotEqual(label("recovery-code"), first)
    }

    func testTC_ACC_05_18_scene1_unackedForcesTheSavePage() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        app.terminate()
        // Another session regenerates and never confirms: as if the `recovery-code` response was lost.
        let d2 = device()
        _ = try await d2.login(username: me, password: password)
        _ = try await d2.regenerateRecoveryCode(password: password)
        start(reset: false)
        try await see("recovery-needs-password", timeout: 10)
        XCTAssertFalse(el("tab-chats").exists)
        try await type(password, into: "recovery-password")
        try await tap("recovery-regenerate")
        try await see("recovery-code", timeout: 15)
        try await tap("recovery-confirm")
        try await see("tab-chats", timeout: 15)
        app.terminate()
        start(reset: false)
        try await see("tab-chats")
        try await sleep(2000)
        XCTAssertFalse(el("recovery-page").exists, "confirmed: not again")
    }

    func testTC_ACC_05_18_scene2_killAfterPasswordChange() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        try await toSecurity()
        try await tap("security-password")
        try await type(password, into: "security-current")
        try await type("new-password-8", into: "security-new")
        try await submit("security-submit")
        try await see("recovery-code", timeout: 15)
        try await stateIs(0, 0)
        app.terminate()
        start(reset: false)
        try await see("login-use-account")
        try await stateIs(0, 0)
        try await logInInApp(me, "new-password-8")
        try await see("recovery-code", timeout: 15)
        try await stateIs(0, 0)
        try await tap("recovery-confirm")
        try await see("tab-chats", timeout: 15)
    }

    // MARK: Session

    func testTC_ACC_03_08_forcedOffWhileAway() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        app.terminate()
        try await admin("POST", "/admin/users/\(me)/force-logout", [:])
        start(reset: false)
        try await see("kicked-text", timeout: 10)
        XCTAssertEqual(label("kicked-text"), "账号已被下线", "access still valid: kicked first; no deadline without an old code")
        try await tap("kicked-ok")
        try await see("login-use-account")
        try await stateIs(0, 0)
    }

    func testTC_ACC_03_18_oldKeychainItemWithARealToken() async throws {
        let me = uid("legacy")
        try await importUsers([me])
        let issued = try await admin("POST", "/admin/users/token", ["userId": me])
        let token = try XCTUnwrap(issued["token"] as? String)
        launch(reset: true, env: ["TT_TEST_LEGACY_SESSION": "\(me):\(token)", "TT_TEST_STATE": "1"])
        try await see("tab-chats")
        try await tap("tab-me")
        try await until("my id") { self.el("me-id").exists && self.label("me-id").contains(me) }
        try await tap("me-settings")
        try await see("about")
        XCTAssertFalse(el("settings-security").exists)
    }

    /// TC-ACC-04-06 against the real server: only the proxy between the app and the server goes down.
    func testTC_ACC_04_06_offlineLogoutRevokesOnceBackOnline() async throws {
        let me = uid("alice")
        let p = TCPProxy(targetPort: try XCTUnwrap(URLComponents(string: http)?.port.map(UInt16.init)))
        try p.start()
        proxy = p
        start(server: p.url)
        try await registerInApp(me)
        let d2 = device()
        _ = try await d2.login(username: me, password: password)
        p.down = true
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("logout")
        try await tap("dialog-ok")
        try await see("login-config-error", timeout: 5)
        try await stateIs(0, 1)
        var events = try await d2.listEvents()
        XCTAssertEqual(events.otherSessions.count, 1, "the server has not heard")

        p.down = false
        XCUIDevice.shared.press(.home)
        try await sleep(800)
        app.activate()
        try await stateIs(0, 0)
        events = try await d2.listEvents()
        XCTAssertEqual(events.otherSessions.count, 0, "logout reached the server and revoked the sid")
    }

    /// TC-ACC-03-20 against the real server, with the server's clock moved 5 minutes: the first refresh's response never
    /// arrives and the app is killed.
    func testTC_ACC_03_20_oldRefreshStillWorksAfterALostResponse() async throws {
        let me = uid("alice")
        let p = TCPProxy(targetPort: try XCTUnwrap(URLComponents(string: http)?.port.map(UInt16.init)))
        try p.start()
        proxy = p
        start(server: p.url)
        try await registerInApp(me)
        try await waitForConnection(me)
        // A refresh: the server rejects a superseded generation only after promotion, so drive it with 4011 from force of
        // a second refresh token is not possible here. `tokenExpired` needs an expired access: move the clock by 25 hours.
        clockMoved = true
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        p.holdResponses = true
        try await admin("POST", "/admin/test/clock", ["nowMs": now + 25 * 3_600_000])
        app.terminate()
        start(reset: false, server: p.url)  // `auth` with the expired token: 4011, then a refresh whose answer is held.
        try await sleep(3000)
        app.terminate()
        p.holdResponses = false
        try await admin("POST", "/admin/test/clock", ["nowMs": now + 25 * 3_600_000 + 5 * 60_000])
        start(reset: false, server: p.url)
        try await see("tab-chats", timeout: 10)
        try await sleep(3000)
        XCTAssertFalse(el("kicked-dialog").exists, "no replay, no login page")
        XCTAssertFalse(el("login-use-account").exists)
        try await stateIs(1, 0)
    }

    func testTC_ACC_06_05_nicknameShowsAtOnce() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        try await tap("tab-me")
        try await see("me-edit-nickname")
        try await tap("me-edit-nickname")
        try await see("nickname-input")
        try await clearAndType("小明同学", into: "nickname-input")
        try await tap("nickname-submit")
        try await see("me-name")
        try await until("my new nickname") { self.label("me-name") == "小明同学" }
        // Another account sees it from the server (its 10-minute cache is the SDK's, in the SDK's tests).
        let bob = uid("bob")
        let other = try await peer(bob)
        try await makeFriends(me, bob)  // A stranger cannot read a profile (F-SOC-10).
        let users = await other.getUsers([me])
        XCTAssertEqual(users.first?.nickname, "小明同学")
    }

    func testTC_ACC_08_06_deleteThenCancelFromLogin() async throws {
        let me = uid("alice")
        start()
        try await registerInApp(me)
        try await toSecurity()
        try await tap("security-delete")
        try await see("delete-dialog")
        XCTAssertEqual(label("dialog-text"), "7 天后不可恢复，用户名不能再使用，已发的消息会保留")
        try await tap("dialog-ok")
        try await type("wrong-password", into: "security-current")
        try await submit("security-submit")
        try await see("security-error", timeout: 15)
        XCTAssertEqual(label("security-error"), "密码错误")
        try await type(password, into: "security-current")
        try await submit("security-submit")
        try await see("login-use-account", timeout: 15)
        try await stateIs(0, 0)
        try await logInInApp(me, password)
        try await see("delete-pending-dialog", timeout: 15)
        XCTAssertTrue(label("dialog-text").hasPrefix("账号正在注销，"))
        try await tap("dialog-ok")
        try await see("tab-chats", timeout: 15)
    }

    func testTC_ACC_07_08_accountHasSecurityDemoDoesNot() async throws {
        start()
        try await see("login-username")
        try await type(uid("demo"), into: "login-username")
        try await tap("login-submit")
        try await see("tab-chats")
        try await tap("tab-me")
        try await tap("me-settings")
        try await see("about")
        XCTAssertFalse(el("settings-security").exists)
    }
}
