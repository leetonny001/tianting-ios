import TiantingIM
import XCTest

/// Account flows against the real im-server (`scripts/e2e-server.sh`: invite mode, refresh keys, IM_TEST_DISABLE_AUTH_LOCK=1).
/// The second device is a real `AccountClient` + `IMClient` in the test process.
final class AccountE2ETests: E2ECase {
    private let password = "correct-horse-7"
    private var devices: [AccountClient] = []
    private var proxy: TCPProxy?
    private var clockMoved = false
    private var darkMode = false

    override func tearDown() async throws {
        for d in devices { _ = d }
        devices = []
        proxy?.stop()
        proxy = nil
        if darkMode {
            try? await setSystemAppearance("light")
            darkMode = false
        }
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
        let rows = try await signed("GET", "/admin/invites")["invites"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first { $0["codeLast4"] as? String == String(code.suffix(4)) }?["usedCount"] as? Int, 2)
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

    // MARK: FE-620: what only ran against the fake server, and notices with a kick. Simulator, local.

    private func setClock(_ ms: Int64) async throws {
        clockMoved = true
        try await admin("POST", "/admin/test/clock", ["nowMs": ms])
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func dateText(_ ms: Int64) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        return "请在 \(c.year!)/\(c.month!)/\(c.day!) 前用恢复码找回"
    }

    /// Whoever holds a stolen refresh token: refreshes it and promotes the result. Returns the status of the refresh.
    private func steal(_ token: String, promote: Bool = true) async throws -> Int {
        var req = URLRequest(url: URL(string: http + "/v1/account/token/refresh")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": token])
        let (data, res) = try await URLSession.shared.data(for: req)
        let status = (res as! HTTPURLResponse).statusCode
        if promote, status == 200, let access = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["accessToken"] as? String {
            var ev = URLRequest(url: URL(string: http + "/v1/account/events")!)
            ev.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (_, r2) = try await URLSession.shared.data(for: ev)
            XCTAssertEqual((r2 as! HTTPURLResponse).statusCode, 200)
        }
        return status
    }

    private func proxied() throws -> TCPProxy {
        let p = TCPProxy(targetPort: try XCTUnwrap(URLComponents(string: http)?.port.map(UInt16.init)))
        try p.start()
        proxy = p
        return p
    }

    private func saves() -> Int {
        guard let r = state().range(of: "saves=") else { return -1 }
        return Int(state()[r.upperBound...]) ?? -1
    }

    // TC-ACC-04-24, AC-ACC-04-25: sequences one to four, the date on screen on this device.
    func testTC_ACC_04_24_sequenceA_logoutOthersThenPassword() async throws {
        let me = uid("seqa")
        let t0 = nowMs()
        try await setClock(t0)
        start()
        try await registerInApp(me)
        app.terminate()
        let x = device()
        _ = try await x.login(username: me, password: password)
        _ = try await x.logoutOthers(password: password)
        _ = try await x.changePassword(oldPassword: password, newPassword: "new-password-8")
        try await setClock(t0 + 86_400_000)
        start(reset: false)
        try await see("kicked-text", timeout: 15)
        XCTAssertTrue(label("kicked-text").contains(dateText(t0 + 7 * 86_400_000)), label("kicked-text"))
        try await tap("kicked-ok")
        try await see("login-use-account")
    }

    func testTC_ACC_04_24_sequenceB_passwordThenDelete() async throws {
        let me = uid("seqb")
        let t0 = nowMs()
        try await setClock(t0)
        start()
        try await registerInApp(me)
        app.terminate()
        let x = device()
        _ = try await x.login(username: me, password: password)
        _ = try await x.changePassword(oldPassword: password, newPassword: "new-password-8")
        try await x.requestDelete(password: "new-password-8")
        try await setClock(t0 + 86_400_000)
        start(reset: false)
        try await see("kicked-text", timeout: 15)
        XCTAssertTrue(label("kicked-text").contains(dateText(t0 + 7 * 86_400_000)), label("kicked-text"))
        try await tap("kicked-ok")
        try await see("login-use-account")
    }

    func testTC_ACC_04_24_sequenceC_secondPasswordChangeDoesNotMoveTheDate() async throws {
        let me = uid("seqc")
        let t0 = nowMs()
        try await setClock(t0)
        start()
        try await registerInApp(me)
        app.terminate()
        let x = device()
        _ = try await x.login(username: me, password: password)
        _ = try await x.changePassword(oldPassword: password, newPassword: "new-password-8")
        try await setClock(t0 + 5 * 86_400_000)
        _ = try await x.changePassword(oldPassword: "new-password-8", newPassword: "new-password-9")
        try await setClock(t0 + 6 * 86_400_000)
        start(reset: false)
        try await see("kicked-text", timeout: 15)
        XCTAssertTrue(label("kicked-text").contains(dateText(t0 + 7 * 86_400_000)), label("kicked-text"))
        try await tap("kicked-ok")
        try await see("login-use-account")
    }

    func testTC_ACC_04_24_sequenceD_logoutOthersWhileOnline() async throws {
        let me = uid("seqd")
        let t0 = nowMs()
        try await setClock(t0)
        start()
        try await registerInApp(me)
        try await waitForConnection(me)
        // C1 replaced on day 0 by this device; the other device then logs the others out while this one is online.
        let x = device()
        _ = try await x.login(username: me, password: password)
        _ = try await x.regenerateRecoveryCode(password: password)
        _ = try await x.logoutOthers(password: password)
        try await see("kicked-text", timeout: 15)
        XCTAssertTrue(label("kicked-text").contains(dateText(t0 + 7 * 86_400_000)), label("kicked-text"))
        capture("sequenceD-kicked")
        try await tap("kicked-ok")
        try await see("login-use-account")
    }

    // F-ACC-02 rule 3b, F-ACC-05 rule 5, A12, A13: real server, with screenshots; the toast and the dialog together.
    func testFE620_noticesAndKickTogether() async throws {
        try await noticesAndKickTogether(suffix: "")
    }

    // Issue I10 in dark mode: the toast stays above the dialog and "确定" works.
    func testFE620_noticesAndKickTogetherDark() async throws {
        try await setSystemAppearance("dark")
        darkMode = true
        try await noticesAndKickTogether(suffix: "-dark")
    }

    private func noticesAndKickTogether(suffix: String) async throws {
        let me = uid("note")
        start()
        try await registerInApp(me)
        try await waitForConnection(me)
        let x = device()
        _ = try await x.login(username: me, password: password)
        try await see("toast", timeout: 2)
        XCTAssertEqual(label("toast"), "你的账号在新设备登录")
        capture("notice-newDeviceLogin" + suffix)
        try await gone(el("toast"), timeout: 8)
        _ = try await x.regenerateRecoveryCode(password: password)
        try await see("toast", timeout: 3)
        XCTAssertEqual(label("toast"), "你的恢复码已重新生成")
        XCTAssertFalse(el("kicked-text").exists)
        capture("notice-recoveryCodeRegenerated" + suffix)
        try await gone(el("toast"), timeout: 8)
        _ = try await x.changePassword(oldPassword: password, newPassword: "new-password-8")
        try await see("kicked-text", timeout: 5)
        // Issue I10: the notice that came just before the kick is drawn above the dialog, clear of the card.
        XCTAssertTrue(el("toast").exists, "the notice is still on screen with the dialog")
        XCTAssertEqual(all("toast").count, 1, "one toast")
        XCTAssertEqual(label("toast"), "你的账号密码已被修改")
        let toast = el("toast").frame
        let card = el("kicked-dialog").frame
        XCTAssertFalse(toast.intersects(card), "the toast \(toast) does not overlap the card \(card)")
        XCTAssertGreaterThanOrEqual(toast.minY, app.windows.firstMatch.frame.minY, "the toast is on screen")
        capture("notice-passwordChanged-with-dialog" + suffix)
        XCTAssertTrue(el("kicked-ok").isHittable, "the toast must not cover the button")
        try await tap("kicked-ok")
        try await see("login-use-account")
        capture("notice-after-dialog" + suffix)
    }

    // TC-ACC-03-13 on the real server: the refresh is saved, the app dies before using it, the restart uses it.
    func testTC_ACC_03_13_realKillAfterSaveThenNewToken() async throws {
        let me = uid("kill")
        start()
        try await registerInApp(me)
        app.terminate()
        let t = nowMs() + 25 * 3_600_000
        try await setClock(t)
        launch(reset: false, env: ["TT_TEST_STATE": "1", "TIANTING_SERVER": http, "TT_TEST_EXIT_AFTER_SAVE": "1"])
        try await until("the app exits after saving", timeout: 30) { self.app.state == .notRunning }
        try await setClock(t + 5 * 60_000)  // Past the overlap window: only the saved value is good now.
        start(reset: false)
        try await see("tab-chats", timeout: 15)
        try await sleep(2500)
        XCTAssertFalse(el("kicked-text").exists, "the new token is valid, no replay")
        try await stateIs(1, 0)
    }

    // TC-ACC-03-26: a real replay through the app.
    func testTC_ACC_03_26_realReplayDialog() async throws {
        let me = uid("rep")
        let p = try proxied()
        start(server: p.url)
        try await registerInApp(me)
        app.terminate()
        let stolen = try XCTUnwrap(p.seenRefreshTokens.last)
        let t0 = nowMs()
        try await setClock(t0 + 25 * 3_600_000)
        let status = try await steal(stolen)
        XCTAssertEqual(status, 200)
        try await setClock(t0 + 25 * 3_600_000 + 3 * 60_000)
        start(reset: false, server: p.url)
        try await see("kicked-text", timeout: 20)
        XCTAssertTrue(label("kicked-text").contains("检测到登录凭证异常"), label("kicked-text"))
        try await tap("kicked-ok")
        try await see("login-use-account")
        try await stateIs(0, 0)
    }

    // TC-ACC-03-41: one real superseded, then the window ends and the retry is a replay. Three in a row only exist on the fake server.
    func testTC_ACC_03_41_realSupersededThenReplay() async throws {
        let me = uid("sup")
        let p = try proxied()
        start(server: p.url)
        try await registerInApp(me)
        app.terminate()
        let stolen = try XCTUnwrap(p.seenRefreshTokens.last)
        let t = nowMs() + 25 * 3_600_000
        try await setClock(t)
        let status = try await steal(stolen)
        XCTAssertEqual(status, 200)
        try await setClock(t + 2 * 60_000 - 5000)  // Five seconds of the window left.
        start(reset: false, server: p.url)
        try await see("tab-chats", timeout: 10)
        try await sleep(2000)
        XCTAssertFalse(el("kicked-text").exists, "stays on this page, waits retryAfterSeconds")
        try await setClock(t + 2 * 60_000 + 1000)
        try await see("kicked-text", timeout: 20)
        XCTAssertTrue(label("kicked-text").contains("检测到登录凭证异常"), label("kicked-text"))
        try await tap("kicked-ok")
    }

    // AC-ACC-03-37, first half: the 21st issue in the hour gets 4290 from the real server; stays here.
    func testTC_ACC_03_40_real4290StaysHere() async throws {
        let me = uid("lim")
        let p = try proxied()
        start(server: p.url)
        try await registerInApp(me)
        app.terminate()
        let held = try XCTUnwrap(p.seenRefreshTokens.last)
        let t = nowMs() + 25 * 3_600_000
        try await setClock(t)
        var last = 0
        for _ in 0..<21 { last = try await steal(held, promote: false) }
        XCTAssertEqual(last, 429)
        start(reset: false, server: p.url)
        try await see("tab-chats", timeout: 10)
        try await sleep(3000)
        XCTAssertFalse(el("kicked-text").exists, "no dialog on 4290")
        try await stateIs(1, 0)
        // The next hour the retry goes through.
        let before = saves()
        try await setClock(t + 61 * 60_000)
        try await until("the backoff retry succeeds, was \(state())", timeout: 45) { self.saves() > before }
    }

    // TC-ACC-04-25 scene two on the real server: the kick comes first, the answer after 31 seconds.
    func testTC_ACC_04_25_realResponseAfter31Seconds() async throws {
        let me = uid("late")
        let p = try proxied()
        start(server: p.url)
        try await registerInApp(me)
        try await waitForConnection(me)
        try await toSecurity()
        try await tap("security-password")
        try await type(password, into: "security-current")
        try await type("new-password-8", into: "security-new")
        p.holdHTTPResponses = true
        let before = saves()
        let started = Date()
        try await submit("security-submit")
        try await see("kicked-text", timeout: 40)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 25, "the kick waits for the timeout")
        try await sleep(max(0, Int((31 - Date().timeIntervalSince(started)) * 1000)))
        p.releaseHeld()
        try await sleep(1500)
        XCTAssertEqual(saves(), before, "the late answer is dropped")
        XCTAssertTrue(el("kicked-text").exists)
        try await tap("kicked-ok")
        try await see("login-use-account")
        try await stateIs(0, 0)
    }

    // AC-ACC-03-43 (issue F2 fixed in the server): `IM_REFRESH_ABSOLUTE=40s scripts/run-e2e.sh --only AccountE2ETests/testTC_ACC_03_45_realAbsoluteLimit`; skipped on the default server.
    func testTC_ACC_03_45_realAbsoluteLimit() async throws {
        let probe = device()
        let code = try await invite()
        let probeUser = uid("absp")
        _ = try await probe.register(username: probeUser, password: password, inviteCode: code)
        let abs = try XCTUnwrap(probe.session?.absoluteExpiresAt)
        try XCTSkipIf(abs - nowMs() > 120_000, "needs IM_REFRESH_ABSOLUTE=40s")
        let me = uid("abs")
        let p = try proxied()
        start(server: p.url)
        try await registerInApp(me)
        try await until("connected", timeout: 10) { p.upgrades >= 1 }
        let first = saves()
        let sockets = p.upgrades
        XCUIDevice.shared.press(.home)
        try await sleep(1000)
        app.activate()
        try await sleep(1000)
        XCTAssertEqual(saves(), first, "no refresh at the limit")
        XCTAssertFalse(el("kicked-text").exists)
        try await sleep(5000)
        XCTAssertEqual(saves(), first, "no refresh before the limit")
        try await see("kicked-text", timeout: 60)
        XCTAssertEqual(label("kicked-text"), "登录已失效，请重新登录")
        // Past the limit too (F2 fixed on the server): nothing was refreshed and the app did not reconnect.
        try await sleep(3000)
        XCTAssertEqual(saves(), first, "no refresh after the limit either, events \(p.events)")
        XCTAssertEqual(p.upgrades, sockets, "no reconnect, events \(p.events)")
        // The server's `kicked/tokenExpired` at the limit (the JWT's `exp` is whole seconds, so up to 1 s early) no longer
        // makes the app ask (P-35 L1: the access expiry is the absolute limit, so the SDK ends the session at once).
        let asks = p.events.filter { $0 == "req:POST /v1/account/token/refresh" }.count
        XCTAssertEqual(asks, 0, "no refresh request at all, events \(p.events)")
        print("TC-ACC-03-45 events: \(p.events)")
        try await tap("kicked-ok")
        try await see("login-use-account")
        try await stateIs(0, 0)
    }

    // AC-ACC-03-10: `IM_ACCESS_TTL=6h20s scripts/run-e2e.sh --only AccountE2ETests/testTC_ACC_03_10_realTimerRefreshReconnectsQuietly`; skipped on the default server. A real timer, not [SDK clock].
    func testTC_ACC_03_10_realTimerRefreshReconnectsQuietly() async throws {
        let probe = device()
        let code = try await invite()
        let probeUser = uid("ttlp")
        _ = try await probe.register(username: probeUser, password: password, inviteCode: code)
        let access = try XCTUnwrap(probe.session?.accessExpiresAt)
        try XCTSkipIf(access - nowMs() > 7 * 3_600_000, "needs IM_ACCESS_TTL=6h20s")
        let me = uid("ttl")
        let friend = try await peer(uid("ttlpeer"))
        start()
        try await registerInApp(me)
        let first = saves()
        try await until("the timer's refresh, was \(state())", timeout: 40) { self.saves() > first }
        XCTAssertFalse(el("kicked-text").exists)
        XCTAssertFalse(el("conn-banner").exists, "no connection notice")
        try await sleep(2000)
        XCTAssertFalse(el("conn-banner").exists, "no connection notice")
        try await startChat(with: friend.userId ?? "")
        try await send("after refresh")
        try await sent("after refresh")
    }

    // TC-ACC-04-15, AC-ACC-04-16: the password change committed, the answer lost. The server kicks first; no "凭证异常".
    func testTC_ACC_04_15_realPasswordResponseLost() async throws {
        let me = uid("lost")
        let p = try proxied()
        start(server: p.url)
        try await registerInApp(me)
        try await waitForConnection(me)
        try await toSecurity()
        try await tap("security-password")
        try await type(password, into: "security-current")
        try await type("new-password-8", into: "security-new")
        p.holdHTTPResponses = true
        try await submit("security-submit")
        try await see("kicked-text", timeout: 40)
        XCTAssertTrue(label("kicked-text").contains("你的账号凭证有变化"), label("kicked-text"))
        XCTAssertFalse(label("kicked-text").contains("凭证异常"), label("kicked-text"))
        p.holdHTTPResponses = false
        try await tap("kicked-ok")
        try await see("login-use-account")
        try await logInInApp(me, "new-password-8")
        try await see("recovery-code", timeout: 15)
    }

    // TC-ACC-03-34, the other half: access expired, the refresh gets 4019 credentialsChanged and the date.
    func testTC_ACC_03_34_expiredAccessGets4019WithTheDate() async throws {
        let me = uid("exp34")
        start()
        try await registerInApp(me)
        app.terminate()
        let d2 = device()
        _ = try await d2.login(username: me, password: password)
        let changed = nowMs()
        _ = try await d2.changePassword(oldPassword: password, newPassword: "new-password-8")
        try await setClock(changed + 25 * 3_600_000)
        start(reset: false)
        try await see("kicked-text", timeout: 15)
        XCTAssertTrue(label("kicked-text").contains(dateText(changed + 7 * 86_400_000)), label("kicked-text"))
        XCTAssertFalse(label("kicked-text").contains("凭证异常"), label("kicked-text"))
        try await tap("kicked-ok")
        try await see("login-use-account")
    }

    // AC-ACC-03-12, second half (`IM_ACCESS_TTL=30s scripts/run-e2e.sh --only AccountE2ETests/testTC_ACC_03_12_expiredWhileOnlineRefreshesQuietly`,
    // skipped on the default server): connected, the access token runs out on the server's real timer, the server sends
    // `kicked/tokenExpired`, the refresh succeeds, no dialog, the app reconnects. Moving the IM clock does not do it: the
    // server's expiry timer is armed at `auth` with the remaining time and runs on the real clock.
    func testTC_ACC_03_12_expiredWhileOnlineRefreshesQuietly() async throws {
        let probe = device()
        let code = try await invite()
        _ = try await probe.register(username: uid("exp12p"), password: password, inviteCode: code)
        let access = try XCTUnwrap(probe.session?.accessExpiresAt)
        try XCTSkipIf(access - nowMs() > 120_000, "needs IM_ACCESS_TTL=30s")
        let me = uid("exp12")
        let p = try proxied()
        start(server: p.url)
        try await registerInApp(me)
        // Under 6 hours left, so the app refreshes once on its own; that token is short on arrival, so from then on only
        // the server's kick makes it refresh (the SDK's shortOnArrival). The save count is read before the kick is looked
        // for: the proxy notes the kick before passing it on, so a count read while no kick is noted is from before it.
        var beforeKick = saves()
        try await until("the server kicks tokenExpired, events \(p.events)", timeout: 75) {
            let n = self.saves()
            if p.events.contains("kicked:tokenExpired") { return true }
            beforeKick = n
            return false
        }
        try await until("a real refresh after the kick, was \(state()), events \(p.events)", timeout: 20) {
            self.saves() > beforeKick
        }
        // The order the proxy saw after the kick: the refresh, its 200, then a new WebSocket the server accepted (101).
        try await until("reconnected after the kick, events \(p.events)", timeout: 10) {
            p.events.drop { $0 != "kicked:tokenExpired" }.contains("status:101")
        }
        let afterKick = Array(p.events.drop { $0 != "kicked:tokenExpired" })
        let refresh = try XCTUnwrap(afterKick.firstIndex(of: "req:POST /v1/account/token/refresh"), "refresh after the kick: \(afterKick)")
        let reconnect = try XCTUnwrap(afterKick.firstIndex(of: "req:GET /ws"), "reconnect after the kick: \(afterKick)")
        XCTAssertLessThan(refresh, reconnect, "refresh first, then reconnect: \(afterKick)")
        XCTAssertEqual(afterKick[refresh + 1], "status:200", "the refresh succeeded: \(afterKick)")
        XCTAssertEqual(afterKick.dropFirst(reconnect + 1).first, "status:101", "the server took the new connection: \(afterKick)")
        try await sleep(2000)
        XCTAssertFalse(el("kicked-text").exists, "no dialog")
        XCTAssertFalse(el("kicked-dialog").exists, "no dialog")
        try await see("tab-chats")
        try await stateIs(1, 0)
        XCTAssertFalse(p.events.contains { $0.hasPrefix("http:") }, "no request failed: \(p.events)")
        XCTAssertFalse(p.events.contains { $0.hasPrefix("kicked:") && $0 != "kicked:tokenExpired" }, "\(p.events)")
        print("TC-ACC-03-12 events: \(p.events)")
    }

    // AC-ACC-03-8 (PRD-chat v1.2, issue I3): the refresh token is revoked; a cold start goes back to login. Which text
    // depends on the path the app actually took, and the test says which one it was: access expired here, so the refresh
    // came first and got 4019 -> "登录已失效，请重新登录"; or access still good here, so `auth` came first and the server's
    // `kicked` -> "账号已被下线". Only the server's clock moves, so this device takes the second path; the first is checked
    // on the fake server.
    func testTC_ACC_03_08_realRevokedRefreshColdStart() async throws {
        let me = uid("rev")
        let p = try proxied()
        start(server: p.url)
        try await registerInApp(me)
        app.terminate()
        try await admin("POST", "/admin/users/\(me)/force-logout", [:])
        try await setClock(nowMs() + 25 * 3_600_000)
        let before = p.events.count
        start(reset: false, server: p.url)
        try await see("kicked-text", timeout: 15)
        let seen = Array(p.events.dropFirst(before))
        // `kicked/tokenExpired` only starts a refresh, so it does not decide the path; the refresh's 4019 or a kick for the
        // revocation does.
        let first = try XCTUnwrap(
            seen.first { $0 == "http:4019" || ($0.hasPrefix("kicked:") && $0 != "kicked:tokenExpired") },
            "no 4019 and no revocation kick: \(seen)")
        if first == "http:4019" {
            XCTAssertEqual(label("kicked-text"), "登录已失效，请重新登录", "refresh path, \(seen)")
        } else {
            XCTAssertEqual(label("kicked-text"), "账号已被下线", "kick path (\(first)), \(seen)")
        }
        // Record which path this run took (the report quotes it).
        print("TC-ACC-03-08 path: \(first), events \(seen)")
        try await tap("kicked-ok")
        try await see("login-use-account")
        try await stateIs(0, 0)
    }
}
