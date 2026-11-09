import CryptoKit
import Foundation
import ImageIO
import TiantingIM
import UIKit
import UniformTypeIdentifiers
import XCTest

/// Images and files against the real im-server (IM_FILES_ENABLED=1) and scripts/fake_s3.py (FE-637, FE-638). The system
/// pickers cannot be driven by a UI test: the app takes "picked" files from `TT_TEST_PICK_DIR`, a host directory the test
/// writes (debug builds only, like Android's `pickForTest`).
@MainActor
class FilesCase: E2ECase {
    private(set) var pickDir: URL!
    private var scratch: [URL] = []

    var s3: String { Self.env("TT_E2E_S3") ?? "" }

    override func setUp() async throws {
        try await super.setUp()
        guard let control = Self.env("TT_E2E_CONTROL"), Self.env("TT_E2E_S3") != nil else {
            throw XCTSkip("needs scripts/run-e2e.sh with the fake S3")
        }
        pickDir = URL(fileURLWithPath: control).deletingLastPathComponent().appendingPathComponent("pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pickDir, withIntermediateDirectories: true)
        _ = try await s3ctl("reset=1")
    }

    override func tearDown() async throws {
        _ = try? await s3ctl("reset=1")
        if let pickDir { try? FileManager.default.removeItem(at: pickDir) }
        for d in scratch { try? FileManager.default.removeItem(at: d) }
        scratch = []
        try await super.tearDown()
    }

    // MARK: App

    func launchFiles(_ me: String, reset: Bool = true, env: [String: String] = [:]) async throws {
        var e = ["TT_TEST_PICK_DIR": pickDir.path, "TT_TEST_STATE": "1"]
        for (k, v) in env { e[k] = v }
        launch(reset: reset, env: e)
        if reset { try await login(me) } else { try await see("tab-chats") }
    }

    /// What the next "图片" / "文件" tap picks: the files in name order.
    func willPick(_ files: [(String, Data)]) throws {
        for n in (try? FileManager.default.contentsOfDirectory(atPath: pickDir.path)) ?? [] {
            try? FileManager.default.removeItem(at: pickDir.appendingPathComponent(n))
        }
        for (name, data) in files { try data.write(to: pickDir.appendingPathComponent(name)) }
    }

    func clearPicks() throws { try willPick([]) }

    func pickImages(_ files: [(String, Data)]) async throws {
        try willPick(files)
        try await openPlus()
        try await tap("attach-image")
    }

    func pickFiles(_ files: [(String, Data)]) async throws {
        try willPick(files)
        try await openPlus()
        try await tap("attach-file")
    }

    func openPlus() async throws {
        if !el("attach-panel").exists { try await tap("attach-button") }
        try await see("attach-panel")
    }

    func tap(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await until("hittable \(e)", file: file, line: line) { e.exists && e.isHittable }
        e.tap()
    }

    /// An element inside the i-th file bubble.
    func inBubble(_ i: Int, _ id: String) -> XCUIElement {
        fileBubbles.element(boundBy: i).descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func state() -> String { el("test-state").value as? String ?? "" }

    /// `att=N` in the debug probe: files in the SDK's sandbox.
    func sandboxCount() -> Int { probeInt("att") }

    func probeInt(_ key: String) -> Int {
        let s = state()
        guard let r = s.range(of: "\(key)=") else { return -1 }
        return Int(s[r.upperBound...].prefix { $0.isNumber }) ?? -1
    }

    func lastDownloadSHA() -> String {
        let s = state()
        guard let r = s.range(of: "dl=") else { return "" }
        return String(s[r.upperBound...].prefix { $0.isHexDigit })
    }

    var imageBubbles: XCUIElementQuery { all("image-bubble") }
    var fileBubbles: XCUIElementQuery { all("file-bubble") }

    /// Never reads a missing element: in an async test that failure can hang the runner (seen with `.label`).
    func value(_ e: XCUIElement) -> String { e.exists ? (e.value as? String ?? "") : "" }

    /// The list row of `name` whose label also has `text` (the summary).
    func convRow(_ name: String, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'conv-item' AND label CONTAINS %@ AND label CONTAINS %@", name, text)
        ).firstMatch
    }

    // MARK: Peers with files

    /// A peer that can send images and files (demo token, StaticTokenAuth).
    func filesPeer(_ userId: String) async throws -> IMClient {
        try await importUsers([userId])
        let token = try await userToken(userId)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-peer-\(UUID().uuidString)")
        scratch.append(dir)
        var options = IMClientOptions(url: http.replacingOccurrences(of: "http://", with: "ws://") + "/ws")
        options.platform = .web
        options.systemEvents = false
        options.pushCursorStore = nil
        options.attachmentDirectory = dir.appendingPathComponent("att")
        options.fileCacheDirectory = dir.appendingPathComponent("cache")
        options.files = FileClient(auth: StaticTokenAuth(baseUrl: http, token: token))
        let client = IMClient(options: options)
        client.connect(token: token)
        peerList.append(client)
        try await until("\(userId) connected") { client.state == .connected && client.userId == userId }
        return client
    }

    private var peerList: [IMClient] = []

    override func tearDownWithError() throws {
        for p in peerList { p.destroy() }
        peerList = []
        try super.tearDownWithError()
    }

    func userToken(_ userId: String) async throws -> String {
        try await admin("POST", "/admin/users/token", ["userId": userId])["token"] as! String
    }

    func tmpFile(_ data: Data, _ name: String = "f") throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tt-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        scratch.append(d)
        let u = d.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    /// The peer sends an image: `original` bytes as given (the server reads its size from the header), a small real
    /// thumbnail.
    @discardableResult
    func peerSendsImage(
        _ peer: IMClient, _ conv: String, original: Data, width: Int, height: Int, mime: String = "image/jpeg",
        thumb: Data? = nil
    ) async throws -> Message {
        let before = peer.messages(conv).count
        let t = thumb ?? jpeg(min(480, width), max(1, min(480, width) * height / max(1, width)), color: (90, 120, 200))
        try peer.sendImage(
            conv,
            ProcessedImage(
                original: LocalUpload(file: try tmpFile(original), mime: mime), thumb: LocalUpload(file: try tmpFile(t), mime: "image/jpeg"),
                width: width, height: height))
        return try await sentBy(peer, conv, after: before)
    }

    @discardableResult
    func peerSendsFile(_ peer: IMClient, _ conv: String, _ data: Data, name: String, mime: String) async throws -> Message {
        let before = peer.messages(conv).count
        try peer.sendFile(conv, FileInput(file: try tmpFile(data), name: name, mime: mime))
        return try await sentBy(peer, conv, after: before)
    }

    private func sentBy(_ peer: IMClient, _ conv: String, after: Int) async throws -> Message {
        var got: Message?
        try await until("peer's attachment sent", timeout: 30) {
            let list = peer.messages(conv)
            guard list.count > after, let m = list.last, m.isAttachment else { return false }
            if m.status == .failed { return true }
            got = m.status == .sent ? m : nil
            return got != nil
        }
        return try XCTUnwrap(got, "peer's attachment failed: \(String(describing: peer.messages(conv).last?.error))")
    }

    func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: Fake S3 (scripts/fake_s3.py)

    @discardableResult
    func s3ctl(_ query: String) async throws -> [String: Any] {
        try await getJSON(s3 + "/__ctl?" + query) as? [String: Any] ?? [:]
    }

    func s3stats() async throws -> (puts: Int, gets: [String: Int]) {
        let o = try await getJSON(s3 + "/__stats") as? [String: Any] ?? [:]
        return (o["puts"] as? Int ?? 0, o["gets"] as? [String: Int] ?? [:])
    }

    func s3list(_ prefix: String, bucket: String = "chat") async throws -> [[String: Any]] {
        let p = prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prefix
        return try await getJSON(s3 + "/__list?bucket=\(bucket)&prefix=\(p)") as? [[String: Any]] ?? []
    }

    /// Replaces an object directly (not presigned): a test double for what was stored (AC-FILE-02-12).
    func s3replace(key: String, _ data: Data, bucket: String = "chat") async throws {
        var req = URLRequest(url: URL(string: "\(s3)/\(bucket)/\(key)")!)
        req.httpMethod = "PUT"
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
    }

    private func getJSON(_ url: String) async throws -> Any {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// `/v1/*` as the app's user, from the test (AC-FILE-01-12, 01-17).
    func api(_ method: String, _ path: String, token: String, _ body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: http + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let o = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, o)
    }

    // MARK: Images

    /// A real JPEG of one color (ImageIO).
    func jpeg(_ w: Int, _ h: Int, color: (UInt8, UInt8, UInt8), props: [CFString: Any] = [:]) -> Data {
        encode(solid(w, h, color), .jpeg, props: props)
    }

    func png(_ w: Int, _ h: Int, color: (UInt8, UInt8, UInt8)) -> Data { encode(solid(w, h, color), .png) }

    func gif(_ w: Int, _ h: Int) -> Data { encode(solid(w, h, (200, 50, 50)), .gif) }

    /// A JPEG with only an SOF0 segment: the server reads its size without decoding (a big "original" that is cheap).
    func headerJpeg(_ w: Int, _ h: Int, _ size: Int = 4000) -> Data {
        var b = [UInt8](repeating: 0, count: size)
        let head: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(h >> 8), UInt8(h & 255), UInt8(w >> 8), UInt8(w & 255), 3,
            1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
        ]
        for (i, x) in head.enumerated() { b[i] = x }
        for i in head.count..<(size - 2) { b[i] = UInt8((i * 31) & 0xFF) }
        b[size - 2] = 0xFF
        b[size - 1] = 0xD9
        return Data(b)
    }

    func solid(_ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8)) -> CGImage {
        halves(w, h, left: c, right: c)
    }

    func halves(_ w: Int, _ h: Int, left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8)) -> CGImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = x < w / 2 ? left : right
                let i = (y * w + x) * 4
                px[i] = c.0
                px[i + 1] = c.1
                px[i + 2] = c.2
            }
        }
        let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    func encode(_ image: CGImage, _ type: UTType, props: [CFString: Any] = [:]) -> Data {
        let d = NSMutableData()
        let dest = CGImageDestinationCreateWithData(d, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return d as Data
    }

    func decode(_ d: Data) -> CGImage? {
        guard let s = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    func properties(_ d: Data) -> [CFString: Any] {
        guard let s = CGImageSourceCreateWithData(d as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
    }

    func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var d = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: CGFloat(-x), y: CGFloat(-(image.height - 1 - y)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(d[0]), Int(d[1]), Int(d[2]))
    }
}
