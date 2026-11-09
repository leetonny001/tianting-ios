import Foundation
import Network
import CryptoKit
import XCTest

/// A scriptable account server in the test process: `/v1/*` over HTTP and `/ws` over a hand-made WebSocket, on one loopback
/// port. One simulator shares the host's network, so "the network is gone" is this server dropping connections.
final class FakeAccountServer: @unchecked Sendable {
    enum Reply {
        case json(Int, [String: Any])
        case text(Int, String, String)
        case hang
        case drop
    }

    struct Request {
        let method: String
        let path: String
        let body: [String: Any]
    }

    private let queue = DispatchQueue(label: "tt.fake-account")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sockets: [FakeSocket] = []
    private var routes: [String: [Reply]] = [:]
    private var _requests: [Request] = []
    private var _timeline: [String] = []
    private var _authTokens: [String] = []
    private var _closeCodes: [Int] = []
    private var genCounter: Int64 = 1

    /// Accept and hang up at once: requests fail as on a lost network.
    var blackhole: Bool {
        get { locked { _blackhole } }
        set {
            locked { _blackhole = newValue }
            guard newValue else { return }
            // Open connections die with the network too: URLSession would otherwise keep using one.
            queue.sync {
                for s in sockets { s.connection.cancel() }
                sockets = []
            }
        }
    }
    private var _blackhole = false
    var demoLogin: Bool { get { locked { _demo } } set { locked { _demo = newValue } } }
    private var _demo = false
    var registerMode: String { get { locked { _mode } } set { locked { _mode = newValue } } }
    private var _mode = "invite"
    var privacy: (version: String, url: String?)? { get { locked { _privacy } } set { locked { _privacy = newValue } } }
    private var _privacy: (version: String, url: String?)?
    /// What every issued access token's expiry is, relative to now. Default 24 hours.
    var accessLifeMs: Int64 { get { locked { _life } } set { locked { _life = newValue } } }
    private var _life: Int64 = 86_400_000
    /// access expiry == absolute expiry (RS5-11).
    var atAbsoluteLimit: Bool { get { locked { _absolute } } set { locked { _absolute = newValue } } }
    private var _absolute = false
    var convs: [[String: Any]] { get { locked { _convs } } set { locked { _convs = newValue } } }
    private var _convs: [[String: Any]] = []
    var authAckExtra: [String: Any] { get { locked { _ackExtra } } set { locked { _ackExtra = newValue } } }
    private var _ackExtra: [String: Any] = [:]

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    private(set) var port: UInt16 = 0
    var url: String { "http://localhost:\(port)" }

    func start() throws {
        let params = NWParameters.tcp
        let l = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = l.port?.rawValue else { throw E2EError.failed("listener") }
        port = p
        listener = l
    }

    func stop() {
        listener?.cancel()
        queue.sync {
            for s in sockets { s.connection.cancel() }
            sockets = []
        }
    }

    // MARK: Script

    /// Queues replies for a path; when they run out, the default answer applies.
    func script(_ path: String, _ replies: Reply...) {
        locked { routes[path, default: []] += replies }
    }

    var requests: [Request] { locked { _requests } }
    func scriptedCount(_ path: String) -> Int { locked { routes[path]?.count ?? 0 } }
    func requests(_ path: String) -> [Request] { requests.filter { $0.path == path } }
    /// Paths and "auth" in arrival order.
    var timeline: [String] { locked { _timeline } }
    var authTokens: [String] { locked { _authTokens } }
    /// The close codes clients sent.
    var closeCodes: [Int] { locked { _closeCodes } }
    var openSockets: Int { queue.sync { sockets.filter { $0.isWebSocket }.count } }

    /// A token with the claims the SDK reads.
    static func token(sid: String, gen: Int64) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return b64(#"{"alg":"HS256"}"#) + "." + b64(#"{"sid":"\#(sid)","gen":\#(gen)}"#) + ".sig"
    }

    func auth(user: String = "alice", sid: String = "s1", code: String? = nil, codeGen: Int64? = nil) -> [String: Any] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let (gen, life, absolute): (Int64, Int64, Bool) = locked {
            genCounter += 1
            return (genCounter, _life, _absolute)
        }
        let access = now + life
        var o: [String: Any] = [
            "userId": user, "accessToken": Self.token(sid: sid, gen: gen), "accessExpiresAt": access,
            "refreshToken": "k1.\(sid).\(gen).n.m", "refreshExpiresAt": access + 86_400_000,
            "absoluteExpiresAt": absolute ? access : access + 86_400_000 * 365,
        ]
        if let code { o["recoveryCode"] = code }
        if let codeGen { o["recoveryCodeGen"] = codeGen }
        return o
    }

    func error(_ status: Int, _ code: Int, reason: String? = nil, details: [String: Any]? = nil) -> Reply {
        var o: [String: Any] = ["code": code, "msg": "fake msg never shown"]
        if let reason { o["reason"] = reason }
        if let details { o["details"] = details }
        return .json(status, o)
    }

    func nextReply(_ request: Request) -> Reply {
        let scripted: Reply? = locked {
            guard var q = routes[request.path], !q.isEmpty else { return nil }
            let r = q.removeFirst()
            routes[request.path] = q
            return r
        }
        if let scripted { return scripted }
        switch request.path {
        case "/v1/config":
            var o: [String: Any] = [
                "registerMode": registerMode, "demoLogin": demoLogin, "features": ["files": false],
                "limits": [
                    "usernameMinLen": 4, "usernameMaxLen": 32, "passwordMinLen": 8, "passwordMaxLen": 128, "nicknameMaxLen": 32,
                    "deviceNameMaxLen": 64,
                ],
            ]
            if let p = privacy {
                var n: [String: Any] = ["version": p.version]
                if let u = p.url { n["url"] = u }
                o["privacyNotice"] = n
            }
            return .json(200, o)
        case "/v1/account/login", "/v1/account/token/refresh":
            return .json(200, auth())
        case "/v1/account/register", "/v1/account/recover":
            return .json(200, auth(code: "CODE-AAAA-\(requests.count)", codeGen: 1))
        case "/v1/account/events":
            return .json(200, ["events": [], "otherSessions": ["count": 0]])
        case "/notice":
            return .text(200, "text/html; charset=utf-8", "<html><body><h1>隐私说明内容</h1></body></html>")
        default:
            return .json(200, [:])
        }
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        if blackhole {
            c.cancel()
            return
        }
        let s = FakeSocket(connection: c, server: self)
        sockets.append(s)
        s.read()
    }

    fileprivate func record(_ r: Request) {
        locked {
            _requests.append(r)
            _timeline.append(r.path)
        }
    }

    fileprivate func recordAuth(_ token: String) {
        locked {
            _authTokens.append(token)
            _timeline.append("auth")
        }
    }

    fileprivate func recordClose(_ code: Int) {
        locked {
            _closeCodes.append(code)
            _timeline.append("close\(code)")
        }
    }

    fileprivate func forget(_ s: FakeSocket) {
        sockets.removeAll { $0 === s }
    }

    /// Sends a frame to every WebSocket, optionally followed by a close.
    func broadcast(_ frame: [String: Any], thenClose code: UInt16? = nil) {
        queue.async { [self] in
            for s in sockets where s.isWebSocket {
                s.send(frame)
                if let code { s.close(code) }
            }
        }
    }

    func kick(_ reason: String, code: UInt16, recoverBefore: Int64? = nil) {
        var data: [String: Any] = ["type": "kicked", "reason": reason]
        if let recoverBefore { data["recoverBefore"] = recoverBefore }
        broadcast(["cmd": "event", "data": data], thenClose: code)
    }
}

private final class FakeSocket {
    let connection: NWConnection
    private weak var server: FakeAccountServer?
    private var buffer = Data()
    private(set) var isWebSocket = false
    private var closing = false

    init(connection: NWConnection, server: FakeAccountServer) {
        self.connection = connection
        self.server = server
    }

    func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if self.isWebSocket { self.parseFrames() } else { self.parseHTTP() }
            if done || error != nil {
                self.server?.forget(self)
                self.connection.cancel()
                return
            }
            self.read()
        }
    }

    private func parseHTTP() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.endIndex >= end.upperBound + length else { return }
        let bodyData = Data(buffer[end.upperBound..<(end.upperBound + length)])
        buffer = Data(buffer[(end.upperBound + length)...])  // A copy: its indices start at 0 again.
        let path = String(first[1].split(separator: "?")[0])
        if headers["upgrade"]?.lowercased() == "websocket" {
            upgrade(key: headers["sec-websocket-key"] ?? "")
            return
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        let request = FakeAccountServer.Request(method: String(first[0]), path: path, body: body)
        server?.record(request)
        guard let reply = server?.nextReply(request) else { return }
        switch reply {
        case .hang:
            break
        case .drop:
            connection.cancel()
        case .json(let status, let o):
            respond(status, "application/json", (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
        case .text(let status, let type, let text):
            respond(status, type, Data(text.utf8))
        }
    }

    private func respond(_ status: Int, _ type: String, _ body: Data) {
        var out = Data("HTTP/1.1 \(status) X\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n".utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in })
    }

    private func upgrade(key: String) {
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head =
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        isWebSocket = true
        parseFrames()
    }

    private func parseFrames() {
        while buffer.count >= 2 {
            let b = [UInt8](buffer.prefix(14))
            let opcode = b[0] & 0x0f
            var len = Int(b[1] & 0x7f)
            var offset = 2
            if len == 126 {
                guard b.count >= 4 else { return }
                len = Int(b[2]) << 8 | Int(b[3])
                offset = 4
            } else if len == 127 {
                guard b.count >= 10 else { return }
                len = 0
                for i in 2..<10 { len = len << 8 | Int(b[i]) }
                offset = 10
            }
            let masked = b[1] & 0x80 != 0
            let total = offset + (masked ? 4 : 0) + len
            guard buffer.count >= total else { return }
            let all = [UInt8](buffer.prefix(total))
            buffer = Data(buffer.dropFirst(total))
            var payload = Array(all[(offset + (masked ? 4 : 0))...])
            if masked {
                let m = Array(all[offset..<(offset + 4)])
                for i in payload.indices { payload[i] ^= m[i % 4] }
            }
            handle(opcode: opcode, payload: payload)
        }
    }

    private func handle(opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x1:
            guard let o = (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any] else { return }
            handleText(o)
        case 0x8:
            let code = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : 1005
            if closing {  // The client's answer to our close: the handshake is done.
                hangUp()
                return
            }
            server?.recordClose(code)
            frame(opcode: 0x8, payload: payload)
            hangUp()
        case 0x9:
            frame(opcode: 0xA, payload: payload)
        default:
            break
        }
    }

    private func handleText(_ o: [String: Any]) {
        if closing { return }  // Nothing may follow a close frame.
        let cmd = o["cmd"] as? String ?? ""
        let id = o["id"] as? String
        let data = o["data"] as? [String: Any] ?? [:]
        switch cmd {
        case "ping":
            send(["cmd": "pong"])
        case "auth":
            server?.recordAuth(data["token"] as? String ?? "")
            var ack: [String: Any] = ["userId": "alice", "serverTime": Int64(Date().timeIntervalSince1970 * 1000)]
            for (k, v) in server?.authAckExtra ?? [:] { ack[k] = v }
            send(["id": id ?? "", "cmd": "ack", "data": ack])
        case "convs":
            send(["id": id ?? "", "cmd": "ack", "data": ["convs": server?.convs ?? [], "truncated": false]])
        default:
            send(["id": id ?? "", "cmd": "ack", "data": [:]])
        }
    }

    func send(_ o: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
        frame(opcode: 0x1, payload: [UInt8](data))
    }

    /// Starts the closing handshake and waits for the answer, as the real server's library does: hanging up at once can lose
    /// the close code on the client.
    func close(_ code: UInt16) {
        closing = true
        frame(opcode: 0x8, payload: [UInt8(code >> 8), UInt8(code & 0xff)])
    }

    private func hangUp() {
        let c = connection
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        isWebSocket = false
        server?.forget(self)
    }

    private func frame(opcode: UInt8, payload: [UInt8]) {
        var out: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            out += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
        } else {
            out.append(127)
            for i in (0..<8).reversed() { out.append(UInt8((payload.count >> (8 * i)) & 0xff)) }
        }
        connection.send(content: Data(out + payload), completion: .contentProcessed { _ in })
    }
}

/// A TCP proxy in front of the real server, for "the network is gone" and "the response is late" (TC-ACC-04-06, TC-ACC-03-20).
final class TCPProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tt.proxy")
    private let target: NWEndpoint.Port
    private var listener: NWListener?
    private var pairs: [(NWConnection, NWConnection)] = []
    private let lock = NSLock()
    private var _down = false
    private var _holdResponses = false
    private var _holdHTTP = false
    private var _seenRefresh: [String] = []
    private var held: [(NWConnection, Data)] = []
    private(set) var port: UInt16 = 0
    var url: String { "http://localhost:\(port)" }

    init(targetPort: UInt16) {
        target = NWEndpoint.Port(rawValue: targetPort)!
    }

    /// New connections are hung up on, and open ones are cut.
    var down: Bool {
        get { lock.withLock { _down } }
        set {
            lock.withLock { _down = newValue }
            if newValue { cutAll() }
        }
    }

    /// Requests go through, responses do not come back.
    var holdResponses: Bool {
        get { lock.withLock { _holdResponses } }
        set { lock.withLock { _holdResponses = newValue } }
    }

    func start() throws {
        let l = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = l.port?.rawValue else { throw E2EError.failed("proxy") }
        port = p
        listener = l
    }

    func stop() {
        listener?.cancel()
        cutAll()
    }

    private func cutAll() {
        queue.sync {
            for (a, b) in pairs {
                a.cancel()
                b.cancel()
            }
            pairs = []
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        if down {
            c.cancel()
            return
        }
        let up = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
        up.start(queue: queue)
        pairs.append((c, up))
        pump(from: c, to: up, isResponse: false)
        pump(from: up, to: c, isResponse: true)
    }

    /// Plain-HTTP responses wait until `releaseHeld()`; a connection that switched to WebSocket keeps flowing, the way a
    /// late HTTP answer reaches the app after the server's kick.
    var holdHTTPResponses: Bool {
        get { lock.withLock { _holdHTTP } }
        set { lock.withLock { _holdHTTP = newValue } }
    }

    func releaseHeld() {
        holdHTTPResponses = false
        queue.async {
            for (to, data) in self.held { to.send(content: data, completion: .contentProcessed { _ in }) }
            self.held = []
        }
    }

    /// The `refreshToken` values seen in responses, oldest first: the "stolen" token of the attack tests. Test memory only.
    var seenRefreshTokens: [String] { lock.withLock { _seenRefresh } }

    private func note(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), text.contains("\"refreshToken\":\"") else { return }
        for part in text.components(separatedBy: "\"refreshToken\":\"").dropFirst() {
            if let end = part.firstIndex(of: "\"") {
                let token = String(part[..<end])
                lock.withLock { _seenRefresh.append(token) }
            }
        }
    }

    /// What came back, in order: `kicked:<reason>` from WebSocket frames, `status:<status>` and `http:<code>` (from error
    /// bodies) of plain HTTP answers. For tests that must say which path ended a session (AC-ACC-03-8). No token values are kept.
    var events: [String] { lock.withLock { _events } }
    /// WebSocket connections the server accepted (101) through this proxy: a reconnect adds one.
    var upgrades: Int { lock.withLock { _upgrades } }
    private var _upgrades = 0
    private var _events: [String] = []

    /// `req:<method> <path>` for plain HTTP requests, without the query string.
    private func noteRequest(_ data: Data) {
        guard data.count > 4, let end = data.firstIndex(of: 0x0d) else { return }
        let parts = String(decoding: data[data.startIndex..<end], as: UTF8.self).split(separator: " ")
        guard parts.count >= 2, ["GET", "POST", "PUT", "DELETE", "PATCH"].contains(String(parts[0])) else { return }
        let path = parts[1].split(separator: "?").first.map(String.init) ?? ""
        lock.withLock { _events.append("req:\(parts[0]) \(path)") }
    }

    private func noteEvents(_ data: Data, socket: Bool) {
        if !socket, data.starts(with: Data("HTTP/1.1 ".utf8)), data.count >= 12 {
            let status = String(decoding: data[data.startIndex + 9..<data.startIndex + 12], as: UTF8.self)
            lock.withLock { _events.append("status:" + status) }
        }
        // Lossy: WebSocket frame headers are not UTF-8, the JSON after them is.
        let text = String(decoding: data, as: UTF8.self)
        let pattern = socket ? #""type":"kicked","reason":"([A-Za-z]+)""# : #""code":([0-9]{4})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let found = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).map { (socket ? "kicked:" : "http:") + text[$0] }
        }
        if !found.isEmpty { lock.withLock { _events += found } }
    }

    private func pump(from: NWConnection, to: NWConnection, isResponse: Bool, upgraded: Bool = false) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var isSocket = upgraded
            if let data, !data.isEmpty, !(isResponse && self.holdResponses) {
                if isResponse, !isSocket, data.starts(with: Data("HTTP/1.1 101".utf8)) {
                    isSocket = true
                    self.lock.withLock {
                        self._upgrades += 1
                        self._events.append("status:101")
                    }
                }
                if isResponse, !isSocket { self.note(data) }
                if isResponse { self.noteEvents(data, socket: isSocket) }
                if !isResponse, !isSocket { self.noteRequest(data) }
                if isResponse, !isSocket, self.holdHTTPResponses {
                    self.held.append((to, data))
                } else {
                    to.send(content: data, completion: .contentProcessed { _ in })
                }
            }
            if done || error != nil {
                from.cancel()
                to.cancel()
                return
            }
            self.pump(from: from, to: to, isResponse: isResponse, upgraded: isSocket)
        }
    }
}
