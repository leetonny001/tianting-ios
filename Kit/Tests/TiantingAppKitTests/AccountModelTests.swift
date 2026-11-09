import TiantingIM
import TiantingIMTesting
import XCTest

@testable import TiantingAppKit

private func b64(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// A token with the claims the SDK reads.
private func accessToken(sid: String, gen: Int64) -> String {
    b64(#"{"alg":"HS256"}"#) + "." + b64(#"{"sid":"\#(sid)","gen":\#(gen)}"#) + ".sig"
}

private func authBody(
    user: String = "alice", sid: String = "s1", gen: Int64 = 1, code: String? = nil, codeGen: Int64? = nil, access: Int64
) -> JSONValue {
    var o: [String: JSONValue] = [
        "userId": .string(user), "accessToken": .string(accessToken(sid: sid, gen: gen)), "accessExpiresAt": .int(access),
        "refreshToken": .string("k.\(sid).\(gen).n.m"), "refreshExpiresAt": .int(access + 86_400_000 * 90),
        "absoluteExpiresAt": .int(access + 86_400_000 * 365),
    ]
    if let code { o["recoveryCode"] = .string(code) }
    if let codeGen { o["recoveryCodeGen"] = .int(codeGen) }
    return .object(o)
}

private func configBody(demo: Bool = false, mode: String = "invite", privacy: JSONValue? = nil) -> JSONValue {
    var o: [String: JSONValue] = [
        "registerMode": .string(mode), "demoLogin": .bool(demo), "features": ["files": false],
        "limits": [
            "usernameMinLen": 4, "usernameMaxLen": 32, "passwordMinLen": 8, "passwordMaxLen": 128, "nicknameMaxLen": 32,
            "deviceNameMaxLen": 64,
        ],
    ]
    if let privacy { o["privacyNotice"] = privacy }
    return .object(o)
}

/// The app's account flows against the real `AccountClient` and `IMClient`, with fake HTTP, WebSocket and clock.
@MainActor
final class AccountModelTests: XCTestCase {
    let store = MemorySessionStore()
    let http = FakeHttp()
    let fake = Fake()
    lazy var prefs = UIPrefs(defaults: UserDefaults(suiteName: "tt.account.\(UUID().uuidString)")!)
    lazy var m = AppModel(
        config: AppConfig(server: URL(string: "http://im.test"), demoLogin: false),
        sessions: store,
        theme: ThemeController(prefs: prefs),
        prefs: prefs,
        makeClient: { [fake] _, _ in fake.client },
        makeAccount: { [http, fake] _, s in fakeAccount(store: s, clock: fake.clock, http: http) })

    private var dayLater: Int64 { fake.clock.now() + 86_400_000 }

    private func answer(_ path: String, _ body: JSONValue) async {
        await flush()
        http.last(path).respond(200, body)
        await flush()
    }

    private func register(code: String = "CODE-1", gen: Int64 = 1) async throws {
        _ = m
        async let done: Void = m.accountRegister(username: "alice", password: "pw123456", nickname: nil, inviteCode: "inv")
        await answer("/v1/account/register", authBody(code: code, codeGen: gen, access: dayLater))
        try await done
    }

    private func confirmed() async throws {
        try await register()
        async let done: Void = m.confirmRecovery()
        await answer("/v1/account/recovery-code/ack", [:])
        try await done
    }

    private func connectFake() async {
        let c = fake.transport.current
        c.open()
        await flush()
        c.ack("auth", ["userId": "alice", "serverTime": .int(fake.clock.now())])
        await flush()
    }

    // MARK: Recovery code

    func testTC_ACC_05_06_tokenStaysOutOfTheStoreUntilConfirmed() async throws {
        try await register()
        XCTAssertNil(store.saved, "no token on disk before 我已保存")
        XCTAssertEqual(store.saves.count, 0)
        XCTAssertEqual(m.recovery, RecoveryPrompt(code: "CODE-1", gen: 1))
        XCTAssertNil(m.store, "the list cannot be reached (AC-ACC-01-12)")
        XCTAssertEqual(fake.transport.connections.count, 0)
        XCTAssertNotNil(m.account.session, "the token is in memory")

        async let done: Void = m.confirmRecovery()
        await answer("/v1/account/recovery-code/ack", [:])
        try await done
        XCTAssertEqual(http.last("/v1/account/recovery-code/ack").json["gen"]?.intValue, 1)
        XCTAssertEqual(store.saved?.mode, .account)
        XCTAssertNil(m.recovery)
        XCTAssertNotNil(m.store)
        XCTAssertEqual(fake.transport.connections.count, 1)
    }

    func testTC_ACC_05_14_staleCodeEndsTheSessionWithTheDialog() async throws {
        try await register()
        async let done: Void = m.confirmRecovery()
        await flush()
        http.last("/v1/account/recovery-code/ack").respondError(400, 4000, reason: "recoveryCodeStale")
        await flush()
        do {
            try await done
            XCTFail("throws")
        } catch {}
        XCTAssertNil(m.recovery)
        XCTAssertEqual(fatalText(try XCTUnwrap(m.fatal)), "恢复码已更新，请重新登录查看")
        XCTAssertNil(store.saved)
        m.acknowledgeFatal()
        XCTAssertNil(m.fatal)
        XCTAssertNil(m.store)
    }

    func testTC_ACC_05_18_unackedAfterLoginForcesTheSavePageWithoutACode() async throws {
        try await confirmed()
        fake.transport.current.open()
        await flush()
        fake.transport.current.ack(
            "auth", ["userId": "alice", "serverTime": .int(fake.clock.now()), "recoveryCodeUnacked": true])
        await flush()
        XCTAssertEqual(m.recovery, RecoveryPrompt(), "no code: asks for the password")
        async let regen: Void = m.requestRecoveryCode(password: "pw123456")
        await answer("/v1/account/recovery-code", ["recoveryCode": "CODE-2", "recoveryCodeGen": 2])
        try await regen
        XCTAssertEqual(m.recovery, RecoveryPrompt(code: "CODE-2", gen: 2))
        async let done: Void = m.confirmRecovery()
        await answer("/v1/account/recovery-code/ack", [:])
        try await done
        XCTAssertNil(m.recovery)
        XCTAssertNotNil(m.store, "the same login goes on")
    }

    func testTC_ACC_05_18_passwordChangeClearsTheStoreUntilConfirmed() async throws {
        try await confirmed()
        await connectFake()
        XCTAssertNotNil(store.saved)
        async let change: Void = m.changePassword(old: "pw123456", new: "pw654321")
        await answer("/v1/account/password", authBody(sid: "s2", code: "CODE-2", codeGen: 2, access: dayLater))
        try await change
        XCTAssertNil(store.saved, "killed on the save page: back to login, not the old revoked value")
        XCTAssertEqual(m.recovery, RecoveryPrompt(code: "CODE-2", gen: 2))
        async let done: Void = m.confirmRecovery()
        await answer("/v1/account/recovery-code/ack", [:])
        try await done
        XCTAssertEqual(store.saved?.refreshToken, "k.s2.1.n.m")
    }

    // MARK: Fatal copy

    func testTC_ACC_04_05_fatalCopyBranches() {
        let at: Int64 = 1_900_000_000_000
        let date = "你的账号凭证有变化。如果不是你本人操作，请在 \(sessionDate(at)) 前用恢复码找回"
        for r in ["passwordChanged", "sessionRevoked", "accountDeleted"] {
            XCTAssertEqual(fatalText(.kicked(reason: r, code: 4012, until: nil, recoverBefore: at)), date, r)
            XCTAssertEqual(fatalText(.kicked(reason: r, code: 4012, until: nil, recoverBefore: nil)), "账号已被下线", r)
        }
        XCTAssertEqual(fatalText(.kicked(reason: "suspended", code: 4012, until: .permanent, recoverBefore: at)), "账号已被封禁")
        XCTAssertEqual(
            fatalText(.session(SessionEnd(action: .login, dialog: .credentialAnomaly))),
            "检测到登录凭证异常，这台设备已下线。如果不是你本人操作，请尽快改密码")
        XCTAssertEqual(
            fatalText(.session(SessionEnd(action: .login, dialog: .recoverBefore, recoverBefore: at))), date)
        XCTAssertEqual(fatalText(.session(SessionEnd(action: .login, dialog: .sessionExpired))), "登录已失效，请重新登录")
        XCTAssertEqual(fatalText(.session(SessionEnd(action: .login, dialog: .supersededExceeded))), "登录已失效，请重新登录")
        XCTAssertEqual(fatalText(.session(SessionEnd(action: .login, dialog: .accountOffline))), "账号已被下线")
        XCTAssertEqual(fatalText(.session(SessionEnd(action: .banNotice))), "账号已被封禁")
        XCTAssertEqual(fatalText(.session(SessionEnd(action: .login))), "登录已失效，请重新登录")
        XCTAssertFalse(fatalNeedsDialog(.session(SessionEnd(action: .login))), "K7: nothing to say")
        XCTAssertTrue(fatalNeedsDialog(.session(SessionEnd(action: .login, dialog: .sessionExpired))))
        XCTAssertTrue(fatalNeedsDialog(.session(SessionEnd(action: .banNotice))))
        XCTAssertTrue(fatalNeedsDialog(.closed(code: 4010, reason: "")))
    }

    func testTC_ACC_04_05_kickWithDeadlineDoesNotReconnectAndClearsOnOk() async throws {
        try await confirmed()
        await connectFake()
        let at: Int64 = 1_900_000_000_000
        fake.transport.current.receive([
            "cmd": "event", "data": ["type": "kicked", "reason": "passwordChanged", "recoverBefore": .int(at)],
        ])
        fake.transport.current.drop(4012)
        await flush()
        XCTAssertEqual(m.fatal, .kicked(reason: "passwordChanged", code: 4012, until: nil, recoverBefore: at))
        XCTAssertTrue(fatalText(try XCTUnwrap(m.fatal)).contains(sessionDate(at)))
        XCTAssertNil(store.saved, "the SDK cleared the token")
        let before = fake.transport.connections.count
        fake.clock.advance(60_000)
        XCTAssertEqual(fake.transport.connections.count, before)
        m.acknowledgeFatal()
        await m.logoutFinished()
        XCTAssertNil(m.session)
        XCTAssertEqual(http.to("/v1/account/logout").count, 0, "the session is already gone")
    }

    func testTC_ACC_03_26_replayEndsWithTheDialog() async throws {
        store.saved = AccountSession(
            mode: .account, userId: "alice", accessToken: accessToken(sid: "s1", gen: 1), accessExpiresAt: fake.clock.now() - 1,
            refreshToken: "k.s1.1.n.m", refreshExpiresAt: dayLater, absoluteExpiresAt: dayLater * 2)
        await m.restore()
        await flush()
        http.last("/v1/account/token/refresh").respondError(401, 4019, reason: "replayDetected")
        await flush()
        XCTAssertEqual(fatalText(try XCTUnwrap(m.fatal)), "检测到登录凭证异常，这台设备已下线。如果不是你本人操作，请尽快改密码")
        XCTAssertNil(store.saved)
    }

    // MARK: Cold start

    func testTC_ACC_03_07_expiredAccessRefreshesBeforeAuth() async throws {
        store.saved = AccountSession(
            mode: .account, userId: "alice", accessToken: accessToken(sid: "s1", gen: 1), accessExpiresAt: fake.clock.now() - 1,
            refreshToken: "k.s1.1.n.m", refreshExpiresAt: dayLater, absoluteExpiresAt: dayLater * 2)
        await m.restore()
        await flush()
        XCTAssertNotNil(m.store, "the list shows, no login page")
        XCTAssertNil(m.fatal)
        XCTAssertEqual(http.to("/v1/account/token/refresh").count, 1)
        XCTAssertEqual(fake.transport.connections.count, 0, "no dial before the token is fresh")
        http.last("/v1/account/token/refresh").respond(200, authBody(gen: 2, access: dayLater))
        await flush()
        fake.transport.current.open()
        await flush()
        XCTAssertEqual(fake.transport.current.last("auth")?.data?["token"]?.stringValue, accessToken(sid: "s1", gen: 2))
        XCTAssertEqual(store.saved?.accessToken, accessToken(sid: "s1", gen: 2))
    }

    func testK7_noSessionNoConnection() async {
        await m.restore()
        await flush()
        XCTAssertFalse(m.booting)
        XCTAssertNil(m.store)
        XCTAssertNil(m.fatal)
        XCTAssertEqual(fake.transport.connections.count, 0)
        XCTAssertEqual(m.loginId, 0, "no login was started: the SDK's fatal would hide a connect here")
    }

    func testTC_ACC_03_18_oldShapeIsADemoSession() async throws {
        let old = Data(#"{"userId":"alice","token":"legacy"}"#.utf8)
        store.saved = try JSONDecoder().decode(AccountSession.self, from: old)
        await m.restore()
        await flush()
        XCTAssertEqual(m.session, SessionInfo(userId: "alice", mode: .demo))
        XCTAssertEqual(http.calls.filter { $0.path != "/v1/config" }.count, 0, "nothing to refresh")
        fake.transport.current.open()
        await flush()
        XCTAssertEqual(fake.transport.current.last("auth")?.data?["token"]?.stringValue, "legacy")
    }

    // MARK: Logout

    func testTC_ACC_04_06_logoutDoesNotWaitAndKeepsThePendingRecord() async throws {
        try await confirmed()
        await connectFake()
        m.logout()
        // The page is back at login before anything else happened (K2).
        XCTAssertNil(m.session)
        XCTAssertNil(m.store)
        await flush()
        let call = http.last("/v1/account/logout")
        XCTAssertFalse(call.settled, "the network hangs")
        XCTAssertNil(store.saved, "the token left the store before the request")
        XCTAssertEqual(store.pendingLogouts.count, 1)
        XCTAssertEqual(store.pendingLogouts.first?.sid, "s1")
        XCTAssertNil(fake.transport.current.closedWith, "logout first, then 1000")
        call.fail("offline")
        await m.logoutFinished()
        XCTAssertEqual(store.pendingLogouts.count, 1, "it stays for when the network is back")
        XCTAssertEqual(fake.transport.current.closedWith?.code, 1000)
        // A clear keeps it: only the session goes.
        try await store.clear()
        XCTAssertEqual(store.pendingLogouts.count, 1)
        m.account.networkOnline()
        await flush()
        let retry = http.last("/v1/account/logout")
        XCTAssertFalse(retry === call)
        XCTAssertEqual(retry.json["refreshToken"]?.stringValue, "k.s1.1.n.m")
        retry.respond(200, [:])
        await flush()
        XCTAssertEqual(store.pendingLogouts.count, 0)
    }

    func testA1_loginWorksAtOnceWhileALogoutIsInFlight() async throws {
        try await confirmed()
        await connectFake()
        let oldConnection = fake.transport.current
        m.logout()
        await flush()
        let logoutCall = http.last("/v1/account/logout")
        async let again: Void = m.accountLogin(username: "alice", password: "pw123456")
        await flush()
        XCTAssertEqual(http.to("/v1/account/login").count, 1, "the login does not wait for the logout's answer")
        XCTAssertEqual(oldConnection.closedWith?.code, 1000, "the old client is gone before the new session starts")
        await answer("/v1/account/login", authBody(sid: "s9", access: dayLater))
        try await again
        await flush()
        XCTAssertEqual(m.session?.userId, "alice")
        let saved = store.saved?.accessToken
        XCTAssertNotNil(saved)
        XCTAssertEqual(m.account.session?.accessToken, saved)
        let store1 = m.store
        logoutCall.respond(200, [:])
        await m.logoutFinished()
        await flush()
        XCTAssertEqual(m.session?.userId, "alice")
        XCTAssertTrue(m.store === store1)
        XCTAssertEqual(m.account.session?.accessToken, saved)
        XCTAssertEqual(store.saved?.accessToken, saved)
        XCTAssertNil(m.fatal)
        XCTAssertEqual(store.pendingLogouts.count, 0)
    }

    func testA1_demoLoginWorksAtOnceWhileALogoutIsInFlight() async throws {
        try await confirmed()
        await connectFake()
        m.logout()
        await flush()
        let logoutCall = http.last("/v1/account/logout")
        await m.login(AccountSession(mode: .demo, userId: "alice", accessToken: "demo-token", accessExpiresAt: dayLater))
        XCTAssertEqual(m.session?.mode, .demo)
        logoutCall.respond(200, [:])
        await m.logoutFinished()
        await flush()
        XCTAssertEqual(m.session?.mode, .demo)
        XCTAssertEqual(m.account.session?.accessToken, "demo-token")
        XCTAssertEqual(store.saved?.accessToken, "demo-token")
    }

    func testA2_privacyConfirmationIsPerAccountAndOldKeysGo() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "a2-\(UUID().uuidString)"))
        let p = UIPrefs(defaults: defaults)
        p.set("ui.noticeVersion.alice", "v1")
        p.set("ui.theme", "dark")
        p.removeAll(prefix: "ui.noticeVersion.")
        XCTAssertNil(p.get("ui.noticeVersion.alice"))
        XCTAssertEqual(p.get("ui.theme"), "dark")
    }

    // MARK: Configuration

    private func config(_ body: JSONValue) async throws -> AccountConfig {
        async let load: Void = m.loadLoginConfig()
        await answer("/v1/config", body)
        await load
        guard case .loaded(let c) = m.loginConfig else { throw E2E.notLoaded }
        return c
    }

    private enum E2E: Error { case notLoaded }

    func testTC_ACC_07_07_bothSwitchesHaveToBeOn() async throws {
        let on = try await config(configBody(demo: true))
        XCTAssertFalse(loginEntry(on, buildDemoLogin: false).showDemo, "build off, server on")
        XCTAssertTrue(loginEntry(on, buildDemoLogin: true).showDemo)
        let off = try await config(configBody(demo: false))
        XCTAssertFalse(loginEntry(off, buildDemoLogin: true).showDemo, "build on, server off")
        XCTAssertFalse(loginEntry(off, buildDemoLogin: false).showDemo)
    }

    func testTC_ACC_07_05_registerEntryFollowsTheMode() async throws {
        let invite = loginEntry(try await config(configBody(mode: "invite")), buildDemoLogin: false)
        XCTAssertTrue(invite.showRegister)
        XCTAssertTrue(invite.askInviteCode)
        let open = loginEntry(try await config(configBody(mode: "open")), buildDemoLogin: false)
        XCTAssertTrue(open.showRegister)
        XCTAssertFalse(open.askInviteCode)
        let closed = loginEntry(try await config(configBody(mode: "closed")), buildDemoLogin: false)
        XCTAssertFalse(closed.showRegister)
        let unknown = loginEntry(try await config(configBody(mode: "future")), buildDemoLogin: false)
        XCTAssertFalse(unknown.showRegister, "does not guess")
    }

    func testTC_ACC_07_09_configFailureGuessesNothingAndRetryRecovers() async throws {
        async let load: Void = m.loadLoginConfig()
        await flush()
        XCTAssertEqual(m.loginConfig, .loading)
        http.last("/v1/config").fail("offline")
        await flush()
        await load
        XCTAssertEqual(m.loginConfig, .failed)
        // Even with a value from an earlier run: the login page does not use it (F-ACC-07, 异常).
        _ = try await config(configBody(mode: "closed"))
        async let again: Void = m.loadLoginConfig()
        await flush()
        XCTAssertEqual(m.loginConfig, .loading, "a retry starts over")
        http.last("/v1/config").respond(503, text: "<html>")
        await flush()
        await again
        XCTAssertEqual(m.loginConfig, .failed)
        XCTAssertNotNil(m.cachedConfig, "kept for a logged-in user")
    }

    func testTC_ACC_10_01_noticeEntriesFollowTheConfiguration() async throws {
        _ = try await config(configBody(privacy: ["version": "v1", "url": "https://example.test/notice"]))
        XCTAssertEqual(m.noticeURL?.absoluteString, "https://example.test/notice")
        _ = try await config(configBody(privacy: ["version": "v1", "url": "javascript:alert(1)"]))
        XCTAssertNil(m.noticeURL, "only http(s)")
        _ = try await config(configBody())
        XCTAssertNil(m.noticeURL, "empty configuration: hidden")
    }

    func testTC_ACC_10_03_updatedNoticeAsksOnce() async throws {
        _ = try await config(configBody(privacy: ["version": "v1", "url": "https://example.test/n"]))
        try await register()
        async let ack: Void = m.confirmRecovery()
        await answer("/v1/account/recovery-code/ack", [:])
        try await ack
        XCTAssertNil(m.hub.dialog, "registering agreed to v1")
        m.logout()
        await flush()
        http.last("/v1/account/logout").respond(200, [:])
        await m.logoutFinished()

        _ = try await config(configBody(privacy: ["version": "v2", "url": "https://example.test/n"]))
        async let login: Void = m.accountLogin(username: "alice", password: "pw123456")
        await answer("/v1/account/login", authBody(sid: "s3", access: dayLater))
        try await login
        await flush()
        XCTAssertEqual(m.hub.dialog?.id, "privacy-update-dialog")
        XCTAssertEqual(prefs.get(privacyAckKey("alice")), "v1", "only a confirmation records it")
        XCTAssertFalse(privacyAckKey("alice").contains("alice"), "the key stays after logout")
        XCTAssertNotEqual(privacyAckKey("alice"), privacyAckKey("bob"))
    }

    // MARK: Security notice and nickname

    func testTC_ACC_02_13_securityNoticeShowsAToast() async throws {
        try await confirmed()
        await connectFake()
        fake.transport.current.ack("convs", ["convs": [], "truncated": false])
        await flush()
        fake.transport.current.receive([
            "cmd": "event", "data": ["type": "securityNotice", "kind": "newDeviceLogin", "at": 1, "platform": "android"],
        ])
        await flush()
        XCTAssertEqual(m.hub.toast?.text, "你的账号在新设备登录")
    }

    // AC-ACC-03-25, AC-ACC-03-45, F-ACC-05 rule 5.
    func testSecurityNoticeOtherKindsToastUnknownIsSilent() async throws {
        try await confirmed()
        await connectFake()
        fake.transport.current.ack("convs", ["convs": [], "truncated": false])
        await flush()
        fake.transport.current.receive([
            "cmd": "event", "data": ["type": "securityNotice", "kind": "futureKind", "at": 1, "platform": "android"],
        ])
        await flush()
        XCTAssertNil(m.hub.toast)
        for (kind, text) in [
            ("recoveryCodeRegenerated", "你的恢复码已重新生成"), ("refreshReplay", "检测到你的账号登录凭证异常"),
            ("refreshRateLimited", "你的账号登录凭证刷新过于频繁"), ("newIpPrefix", "你的账号正在新的网络使用"),
            ("passwordChanged", "你的账号密码已被修改"), ("passwordRecovered", "你的账号已通过恢复码重设密码"),
        ] {
            fake.transport.current.receive([
                "cmd": "event", "data": ["type": "securityNotice", "kind": .string(kind), "at": 1, "platform": "android"],
            ])
            await flush()
            XCTAssertEqual(m.hub.toast?.text, text)
        }
        XCTAssertNil(securityNoticeText("futureKind"))
    }

    func testTC_ACC_06_05_nicknameShowsAtOnce() async throws {
        try await confirmed()
        await connectFake()
        let before = m.store!.profileVersion
        async let done: Void = m.account.updateProfile(nickname: "小明")
        await answer("/v1/account/profile", [:])
        try await done
        await flush()
        XCTAssertGreaterThan(m.store!.profileVersion, before)
        XCTAssertEqual(m.store!.profile("alice")?.nickname, "小明")
    }

    // MARK: Copy

    func testTC_ACC_01_18_registerErrors() {
        func text(_ code: Int, _ status: Int = 400, reason: String? = nil) -> String {
            accountFailure(AccountError(status: status, code: code, reason: reason), page: .register).text
        }
        XCTAssertEqual(text(4004), "用户名格式不正确")
        XCTAssertEqual(text(4000, reason: "passwordWeak"), "密码太简单")
        XCTAssertEqual(text(4030, 403, reason: "inviteInvalid"), "邀请码无效")
        XCTAssertEqual(text(4290, 429), "操作太频繁，请稍后再试")
        XCTAssertEqual(text(5030, 503), "服务暂不可用")
        XCTAssertEqual(accountFailure(AccountNetworkError.network, page: .register).text, "网络异常，请稍后重试")
        XCTAssertEqual(accountFailure(AccountNetworkError.timeout, page: .register).text, "网络异常，请稍后重试")
    }

    func testTC_ACC_01_13_takenNameGoesUnderTheField() {
        let f = accountFailure(AccountError(status: 409, code: 4095), page: .register)
        XCTAssertEqual(f.text, "这个用户名不能使用")
        XCTAssertTrue(f.onUsername)
        XCTAssertFalse(f.clearPassword)
    }

    func testTC_ACC_02_08_wrongPasswordClearsTheField() {
        let f = accountFailure(AccountError(status: 401, code: 4018), page: .login)
        XCTAssertEqual(f.text, "用户名或密码错误")
        XCTAssertTrue(f.clearPassword)
        XCTAssertFalse(f.onUsername)
    }

    func testTC_ACC_02_09_lockShowsMinutesRoundedUp() {
        func locked(_ s: Int64) -> String {
            accountFailure(AccountError(status: 429, code: 4294, details: ["retryAfterSeconds": .int(s)]), page: .login).text
        }
        XCTAssertEqual(locked(600), "尝试次数过多，请 10 分钟后再试")
        XCTAssertEqual(locked(601), "尝试次数过多，请 11 分钟后再试")
        XCTAssertEqual(locked(1), "尝试次数过多，请 1 分钟后再试")
    }

    func testTC_ACC_05_09_deletionPending() {
        let f = accountFailure(
            AccountError(status: 403, code: 4030, reason: "accountDeletionPending", details: ["deleteAt": .int(1_900_000_000_000)]),
            page: .login)
        XCTAssertEqual(f.deleteAt, 1_900_000_000_000)
        XCTAssertEqual(deletionPendingText(deleteAt: f.deleteAt), "账号正在注销，\(sessionDate(1_900_000_000_000))后不可恢复，是否撤销？")
    }

    func testAccountEventCopyCoversTheServersKinds() {
        for k in [
            "newDeviceLogin", "passwordChanged", "passwordRecovered", "loggedOutOthers", "recoveryCodeRegenerated",
            "deletionRequested", "deletionCanceled", "refreshReplay", "refreshRateLimited", "newIpPrefix",
        ] {
            XCTAssertNotEqual(accountEventText(k), "账号活动", k)
        }
        XCTAssertEqual(accountEventText("future"), "账号活动")
    }
}

/// The real Keychain: only on a simulator or device with Keychain access in the test host.
@MainActor
final class KeychainSessionStoreTests: XCTestCase {
    private var store: KeychainSessionStore!

    override func setUp() async throws {
        store = KeychainSessionStore(service: "com.tianting.im.test.\(UUID().uuidString)")
        do {
            try await store.savePendingLogouts([PendingLogout(sid: "probe", refreshToken: "probe")])
            try await store.savePendingLogouts([])
        } catch let e as KeychainError where e.status == errSecMissingEntitlement {
            throw XCTSkip("no Keychain in this test host; the UI tests read the real one through test-state")
        }
    }

    override func tearDown() async throws {
        store.wipe()
    }

    private let session = AccountSession(
        mode: .account, userId: "alice", accessToken: "a", accessExpiresAt: 5, refreshToken: "r", refreshExpiresAt: 6,
        absoluteExpiresAt: 7)

    func testSaveLoadOverwrite() async throws {
        var loaded = try await store.load()
        XCTAssertNil(loaded)
        XCTAssertTrue(store.isEmpty)
        try await store.save(session)
        loaded = try await store.load()
        XCTAssertEqual(loaded, session)
        var next = session
        next.accessToken = "b"
        try await store.save(next)
        loaded = try await store.load()
        XCTAssertEqual(loaded?.accessToken, "b")
    }

    func testTC_ACC_04_06_clearKeepsThePendingLogouts() async throws {
        try await store.save(session)
        try await store.savePendingLogouts([PendingLogout(sid: "s1", refreshToken: "r1")])
        try await store.clear()
        let loaded = try await store.load()
        XCTAssertNil(loaded)
        XCTAssertTrue(store.isEmpty)
        let pending = try await store.loadPendingLogouts()
        XCTAssertEqual(pending, [PendingLogout(sid: "s1", refreshToken: "r1")])
        XCTAssertEqual(store.pendingCount, 1)
        try await store.savePendingLogouts([])
        let none = try await store.loadPendingLogouts()
        XCTAssertEqual(none, [])
    }

    func testTC_ACC_03_18_oldItemReadsAsDemo() async throws {
        store.seedLegacySession(userId: "alice", token: "legacy")
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.mode, .demo)
        XCTAssertEqual(loaded?.userId, "alice")
        XCTAssertEqual(loaded?.accessToken, "legacy")
        XCTAssertNil(loaded?.refreshToken)
    }

    func testAccessibilityIsThisDeviceOnly() async throws {
        try await store.save(session)
        var next = session
        next.accessToken = "b"
        try await store.save(next)  // Also after an update.
        let attrs = try XCTUnwrap(rawAttributes())
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    private func rawAttributes() -> [String: Any]? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Mirror(reflecting: store!).children.first { $0.label == "service" }?.value as Any,
            kSecAttrAccount as String: "session",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? [String: Any]
    }
}

/// `SystemEventsMonitor` on iOS: the SDK's own tests run on macOS, where its UIKit half is not compiled.
@MainActor
final class SystemEventsOnIOSTests: XCTestCase {
    func testPendingLogoutGoesOutOnTheFirstPathUpdateAndOnBecomingActive() async throws {
        let http = FakeHttp()
        let store = MemorySessionStore()
        store.pendingLogouts = [PendingLogout(sid: "s1", refreshToken: "r1")]
        var options = AccountClientOptions(baseUrl: "http://im.test")
        options.store = store
        options.http = http
        options.random = { 0.5 }
        let account = AccountClient(options: options)  // systemEvents stays on.
        // No start(), no direct call: only the monitor can send this.
        var deadline = Date().addingTimeInterval(5)
        while http.to("/v1/account/logout").isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(http.to("/v1/account/logout").count, 1, "NWPathMonitor's first update reaches networkOnline()")
        http.last("/v1/account/logout").fail("offline")
        try await Task.sleep(for: .milliseconds(50))

        // Back in the foreground. `didBecomeActive` also calls online(); a failed record stays and goes out again.
        http.calls.forEach { if !$0.settled { $0.fail("offline") } }
        let before = http.to("/v1/account/logout").count
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        deadline = Date().addingTimeInterval(5)
        while http.to("/v1/account/logout").count == before, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(http.to("/v1/account/logout").count, before)
        withExtendedLifetime(account) {}
    }
}
