import CryptoKit
import TiantingIM
import UIKit
import XCTest

/// End-to-end base: the app under test on the simulator against a real im-server that scripts/run-e2e.sh starts. The second
/// account is a real `IMClient` in the test runner: one simulator cannot run two copies of the app.
///
/// Waits poll with `Task.sleep`, never `waitForExistence`: tests are async on the main actor, and a blocking wait would stop
/// the peer client from running.
@MainActor
class E2ECase: XCTestCase {
    let app = XCUIApplication()
    private(set) var peers: [IMClient] = []
    private var modeChanged = false

    static func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }
    var http: String { Self.env("TT_E2E_HTTP") ?? "" }
    var adminBase: String { Self.env("TT_E2E_ADMIN") ?? "" }

    override func setUp() async throws {
        try await super.setUp()
        guard Self.env("TT_E2E_HTTP") != nil else {
            throw XCTSkip("needs a server: run scripts/run-e2e.sh")
        }
    }

    override func tearDown() async throws {
        for p in peers { p.destroy() }
        peers = []
        if modeChanged {
            try? await signed("PATCH", "/admin/settings/social", ["mode": "open"])
            modeChanged = false
        }
        app.terminate()
        try await super.tearDown()
    }

    // MARK: Ids

    private static var seq = 0
    func uid(_ base: String) -> String {
        Self.seq += 1
        return base + String(Int64(Date().timeIntervalSince1970 * 1000) % 100_000_000, radix: 36) + String(Self.seq)
    }

    func c2c(_ a: String, _ b: String) -> String { c2cConvId(a, b) }

    // MARK: Admin API (protocol/ADMIN.md)

    @discardableResult
    func admin(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: adminBase + path)!)
        req.httpMethod = method
        req.setValue(Self.env("TT_E2E_ADMIN_KEY"), forHTTPHeaderField: "X-Admin-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await perform(req, "\(method) \(path)")
    }

    @discardableResult
    func signed(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let raw = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let toSign = [method, path, timestamp, nonce, hash, "e2e", "", ""].joined(separator: "\n")
        let secret = Self.env("TT_E2E_SECRET") ?? ""
        let mac = HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        var req = URLRequest(url: URL(string: adminBase + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.env("TT_E2E_CALLER"), forHTTPHeaderField: "X-IM-Caller")
        req.setValue(timestamp, forHTTPHeaderField: "X-IM-Timestamp")
        req.setValue(nonce, forHTTPHeaderField: "X-IM-Nonce")
        req.setValue("e2e", forHTTPHeaderField: "X-IM-Operator")
        req.setValue(base64url(Data(mac)), forHTTPHeaderField: "X-IM-Signature")
        if !raw.isEmpty { req.httpBody = raw }
        return try await perform(req, "\(method) \(path)")
    }

    private func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func perform(_ req: URLRequest, _ what: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            XCTFail("\(what): \(status) \(String(decoding: data, as: UTF8.self))")
            throw E2EError.failed(what)
        }
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private var imported = Set<String>()

    /// Importing again would clear a nickname, so each user is imported once.
    func importUsers(_ users: [String], nicknames: [String: String] = [:]) async throws {
        let users = users.filter { imported.insert($0).inserted }
        if users.isEmpty { return }
        let list: [[String: Any]] = users.map { u in
            var o: [String: Any] = ["userId": u]
            if let n = nicknames[u] { o["nickname"] = n }
            return o
        }
        try await admin("POST", "/admin/users/import", ["users": list])
    }

    @discardableResult
    func hostedGroup(name: String, members: [String], owner: String? = nil) async throws -> (groupId: String, convId: String) {
        let g = uid("g")
        try await importUsers(members)
        var body: [String: Any] = ["groupId": g, "name": name, "members": members]
        if let owner { body["owner"] = owner }
        if owner != nil {
            try await signed("POST", "/admin/groups", body)
        } else {
            try await admin("POST", "/admin/groups", body)
        }
        return (g, "group:\(g)")
    }

    func makeFriends(_ a: String, _ b: String, remarkA: String? = nil) async throws {
        var pair: [String: Any] = ["a": a, "b": b]
        if let remarkA { pair["remarkA"] = remarkA }
        try await signed("POST", "/admin/friends/import", ["pairs": [pair]])
    }

    func setFriendsMode() async throws {
        modeChanged = true
        try await signed("PATCH", "/admin/settings/social", ["mode": "friends"])
    }

    /// A second account: a real client connected to the same server.
    func peer(_ userId: String, nickname: String? = nil) async throws -> IMClient {
        try await importUsers([userId], nicknames: nickname.map { [userId: $0] } ?? [:])
        let token = try await admin("POST", "/admin/users/token", ["userId": userId])["token"] as! String
        var options = IMClientOptions(url: http.replacingOccurrences(of: "http://", with: "ws://") + "/ws")
        options.platform = .web
        options.systemEvents = false
        options.pushCursorStore = nil
        let client = IMClient(options: options)
        client.connect(token: token)
        peers.append(client)
        try await until("\(userId) connected") { client.state == .connected && client.userId == userId }
        return client
    }

    // MARK: Waiting

    func until(
        _ what: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.lifetime = .keepAlways
                add(shot)
                print("E2E-TREE-BEGIN\n\(app.debugDescription)\nE2E-TREE-END")
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                throw E2EError.failed(what)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func sleep(_ ms: Int) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    /// A negative check holds for 2 seconds (PRD-ui 2.1).
    func staysGone(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            XCTAssertFalse(element.exists, file: file, line: line)
            try await sleep(200)
        }
    }

    // MARK: Elements

    func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func all(_ id: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: id)
    }

    func el(_ id: String, labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", id, text)).firstMatch
    }

    func staticText(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func message(_ text: String) -> XCUIElement { el("message", labelContains: text) }
    func conv(_ name: String) -> XCUIElement { el("conv-item", labelContains: name) }
    var composer: XCUIElement { app.textViews["composer-input"] }

    func see(_ element: XCUIElement, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await until("\(element)", timeout: timeout, file: file, line: line) { element.exists }
    }

    func see(_ id: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await see(el(id), timeout: timeout, file: file, line: line)
    }

    func gone(_ element: XCUIElement, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await until("gone: \(element)", timeout: timeout, file: file, line: line) { !element.exists }
    }

    func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let e = el(id)
        try await until("hittable \(id)", file: file, line: line) { e.exists && e.isHittable }
        e.tap()
    }

    /// XCUITest sometimes loses a tap right after keyboard input (not seen with direct touches on the simulator). Taps again
    /// until the expected result shows, and logs each loss so it stays visible.
    func tap(_ id: String, until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for attempt in 0..<4 {
            try await tap(id, file: file, line: line)
            for _ in 0..<15 {
                if done() { return }
                try await sleep(100)
            }
            print("E2E-LOST-TAP \(id) attempt \(attempt)")
        }
        XCTFail("tap on \(id) had no effect", file: file, line: line)
        throw E2EError.failed(id)
    }

    /// Switches the simulator's appearance: scripts/run-e2e.sh watches for this file on the host (the test runner can write
    /// host paths; `XCUIDevice.appearance` has no effect here).
    func setSystemAppearance(_ value: String) async throws {
        guard let dir = Self.env("TT_E2E_CONTROL") else { throw XCTSkip("needs scripts/run-e2e.sh") }
        let request = URL(fileURLWithPath: dir).appendingPathComponent("appearance")
        try value.write(to: request, atomically: true, encoding: .utf8)
        try await until("appearance switched") { !FileManager.default.fileExists(atPath: request.path) }
    }

    func tapMenuItem(_ title: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let e = app.buttons[title].firstMatch
        try await until("menu item \(title)", file: file, line: line) { e.exists }
        try await sleep(400)  // The menu is still animating; a tap now can be lost.
        e.tap()
    }

    func type(_ text: String, into id: String) async throws {
        let e = el(id)
        try await until("field \(id)") { e.exists && e.isHittable }
        try await focus(e)
        e.typeText(text)
        try await sleep(300)
    }

    /// Tapping a field that already has focus opens the edit menu, and the next tap only closes that menu.
    func focus(_ e: XCUIElement) async throws {
        if (e.value(forKey: "hasKeyboardFocus") as? Bool) != true { e.tap() }
        try await until("keyboard focus") { (e.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        try await sleep(400)  // Keys sent while the keyboard animates in, and taps right after typing, get lost.
    }

    /// Replaces a field's text.
    func clearAndType(_ text: String, into id: String) async throws {
        let e = el(id)
        try await until("field \(id)") { e.exists && e.isHittable }
        try await focus(e)
        // A tap can put the caret anywhere in the text: go to its end first.
        if let value = e.value as? String, !value.isEmpty {
            if e.elementType == .textView {
                e.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.2)).tap()
                try await sleep(300)
            }
            e.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        e.typeText(text)
        try await sleep(300)
    }

    func back() async throws {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        try await until("back button") { b.exists && b.isHittable }
        b.tap()
    }

    /// A link to the running app. `app.open` would relaunch it, with the launch environment that resets its state.
    func openLink(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
    }

    /// The text of a label element.
    func label(_ id: String) -> String { el(id).label }

    // MARK: App

    func launch(reset: Bool = true, args: [String] = [], env: [String: String] = [:]) {
        app.launchEnvironment = ["TIANTING_SERVER": http]
        if reset { app.launchEnvironment["TT_RESET_STATE"] = "1" }
        for (k, v) in env { app.launchEnvironment[k] = v }
        // A plain English keyboard: on a Chinese one, typed Latin letters become pinyin composition and candidates. The
        // app's own strings do not depend on the system language.
        app.launchArguments =
            ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US", "-AppleKeyboards", "(en_US@sw=QWERTY;hw=Automatic)"] + args
        app.launch()
    }

    func login(_ userId: String, nickname: String? = nil) async throws {
        try await see("login-username")
        try await type(userId, into: "login-username")
        if let nickname { try await type(nickname, into: "login-nickname") }
        // On a small screen with large text the keyboard covers the button; the keyboard's "go" key does the same.
        if el("login-submit").isHittable {
            try await tap("login-submit")
        } else {
            el(nickname == nil ? "login-username" : "login-nickname").typeText("\n")
        }
        try await see("tab-chats")
    }

    func launchAndLogin(_ userId: String, nickname: String? = nil) async throws {
        launch()
        try await login(userId, nickname: nickname)
    }

    func startChat(with userId: String) async throws {
        try await tap("plus-button")
        try await tapMenuItem("发起单聊")
        try await type(userId, into: "start-chat-input")
        try await tap("start-chat-submit")
        try await see("chat-title")
    }

    func send(_ text: String) async throws {
        try await see(composer)
        try await focus(composer)
        composer.typeText(text)
        try await sleep(300)
        try await tap("send-button") { (self.composer.value as? String ?? "").isEmpty }
    }

    func sent(_ text: String) async throws {
        let m = message(text)
        try await see(m)
        try await until("sent \(text)") { (m.value as? String) == "已发送" }
    }

    func logout() async throws {
        try await tap("tab-me")
        try await tap("me-settings")
        try await tap("logout")
        try await tap("dialog-ok")
        try await see("login-submit")
    }

    /// Asserts the element is inside the screen and can be tapped.
    func assertUsable(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let e = el(id)
        XCTAssertTrue(e.exists, "\(id) exists", file: file, line: line)
        XCTAssertTrue(e.isHittable, "\(id) hittable", file: file, line: line)
        let f = e.frame
        let w = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(f.minX, 0, "\(id) left edge", file: file, line: line)
        XCTAssertLessThanOrEqual(f.maxX, w.maxX + 0.5, "\(id) right edge", file: file, line: line)
        XCTAssertLessThanOrEqual(f.maxY, w.maxY + 0.5, "\(id) bottom edge", file: file, line: line)
    }

    /// Saves a screenshot next to the run's results (`TT_E2E_SCREENSHOTS`) and attaches it.
    func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = Self.env("TT_E2E_SCREENSHOTS") {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// The color (0...255) of one screen point of a screenshot.
    func pixel(atX x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int) {
        let image = XCUIScreen.main.screenshot().image
        guard let cg = image.cgImage else { return (0, 0, 0) }
        var data = [UInt8](repeating: 0, count: 4)
        let scale = image.scale
        let ctx = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: -x * scale, y: -(CGFloat(cg.height) - y * scale))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}

enum E2EError: Error {
    case failed(String)
}

func two(_ n: Int) -> String { String(format: "%02d", n) }

func monthDay(_ ms: Int64) -> String {
    let d = Calendar.current.dateComponents(
        [.month, .day, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    return "\(two(d.month!))-\(two(d.day!)) \(two(d.hour!)):\(two(d.minute!))"
}

func dateTime(_ ms: Int64) -> String {
    let y = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    return "\(y)-\(monthDay(ms))"
}
