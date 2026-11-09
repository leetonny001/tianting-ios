import Foundation
import TiantingIM
import XCTest

/// FE-640: AC-FILE-02-1 and AC-FILE-03-1 across H5, Android and iOS against one im-server and one fake S3. The three
/// platforms cannot run at the same time, so each first sends through its own UI (`testXP1_send`), and later receives through
/// its own UI (`testXP2_receive`): the receiver loads the messages, downloads them and checks the bytes.
///
/// The shared contract (the same-named tests in tianting-web and tianting-android copy this):
/// - Run id R (`TT_E2E_XP`). Users `xp{R}h5`, `xp{R}android`, `xp{R}ios`; group `xp{R}g` named "跨端群" with all three
///   (the coordinating script creates the users and the group).
/// - Each platform sends the other two a 1600 × 1200 solid JPEG in the one-to-one chat: h5 (200,40,40),
///   android (40,160,60), ios (40,60,200).
/// - Each platform sends the group the file `跨端-{platform}.pdf`: "%PDF-1.7\n" plus N bytes, byte i = (i × 31 + seed) & 0xFF,
///   N = 1048576 + seed, seed h5 1, android 2, ios 3. The receiver computes the expected SHA-256 itself.
/// Receiving (`TT_E2E_XP_FROM`, default the other two): the sender's image shows its thumbnail and opens the original; the
/// original downloaded by sdk-swift (the test runner logged in as the same user) has `size` bytes, decodes to 1600 × 1200 in
/// the sender's colour, and the thumbnail's long side is ≤ 480. In the group, the sender's file has the right name, size and
/// type, and the app's own download (tapped in the UI) has the expected SHA-256. Without `TT_E2E_XP` these tests skip.
/// Local results on the simulator.
final class CrossPlatformE2ETests: FilesCase {
    static let me = "ios"
    static let platforms = ["h5", "android", "ios"]
    static let colors: [String: (Int, Int, Int)] = ["h5": (200, 40, 40), "android": (40, 160, 60), "ios": (40, 60, 200)]
    static let seeds = ["h5": 1, "android": 2, "ios": 3]
    static let width = 1600, height = 1200

    var run: String { Self.env("TT_E2E_XP") ?? "" }
    func user(_ p: String) -> String { "xp\(run)\(p)" }
    var me: String { user(Self.me) }
    var group: String { "group:xp\(run)g" }

    static func fileName(_ p: String) -> String { "跨端-\(p).pdf" }
    static func fileBytes(_ p: String) -> Data {
        let seed = seeds[p]!
        var d = Data("%PDF-1.7\n".utf8)
        d.append(Data((0..<(1_048_576 + seed)).map { UInt8(($0 * 31 + seed) & 0xFF) }))
        return d
    }

    override func setUp() async throws {
        try await super.setUp()
        guard !run.isEmpty else { throw XCTSkip("the cross-platform tests need TT_E2E_XP from the coordinating script") }
    }

    private func jpegFor(_ p: String) -> Data {
        let c = Self.colors[p]!
        return jpeg(Self.width, Self.height, color: (UInt8(c.0), UInt8(c.1), UInt8(c.2)))
    }

    private func allImagesLoaded() -> Bool {
        let n = imageBubbles.count
        if n == 0 { return false }
        for i in 0..<n where !value(imageBubbles.element(boundBy: i)).hasSuffix("loaded") { return false }
        return true
    }

    private func assertColor(_ want: (Int, Int, Int), _ got: (Int, Int, Int), _ what: String) {
        XCTAssertTrue(
            abs(want.0 - got.0) <= 40 && abs(want.1 - got.1) <= 40 && abs(want.2 - got.2) <= 40,
            "\(what): want \(want), got \(got)")
    }

    /// Polls with async work in between (`until` takes a synchronous condition).
    private func poll(_ what: String, timeout: TimeInterval = 30, _ body: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if try await body() { return }
            if Date() > end {
                XCTFail("timed out: \(what)")
                throw CancellationError()
            }
            try await sleep(200)
        }
    }

    /// The first message of `type` from `sender` in `conv` that the server has (loads history first).
    private func serverMessage(_ client: IMClient, _ conv: String, _ type: MessageType, from sender: String) async -> Message? {
        _ = try? await client.loadHistory(conv)
        let list: [Message] = client.messages(conv)
        for m in list where m.type == type && m.from == sender && m.seq != nil { return m }
        return nil
    }

    func testXP1_send() async throws {
        try await launchFiles(me)
        for p in Self.platforms where p != Self.me {
            try await startChat(with: user(p))
            let before = imageBubbles.count
            try await pickImages([("xp-ios-to-\(p).jpg", jpegFor(Self.me))])
            try await until("image bubble") { self.imageBubbles.count == before + 1 }
            let mine = imageBubbles.element(boundBy: before)
            try await until("image to \(p) sent", timeout: 30) { self.value(mine).hasPrefix("已发送") }
            try await back()
        }
        try await tap(conv("跨端群"))
        try await pickFiles([(Self.fileName(Self.me), Self.fileBytes(Self.me))])
        try await until("file bubble") { self.fileBubbles.count >= 1 }
        // Checked from the server's side with a second client (sdk-swift) logged in as the same user.
        let check = try await filesPeer(me)
        var sent: Message?
        try await poll("group file sent") {
            sent = await self.serverMessage(check, self.group, .file, from: self.me)
            return sent != nil
        }
        XCTAssertEqual(sent?.body.file?.name, Self.fileName(Self.me))
        XCTAssertEqual(sent?.body.file?.size, Int64(Self.fileBytes(Self.me).count))
        for p in Self.platforms where p != Self.me {
            let c = c2c(me, user(p))
            var img: Message?
            try await poll("image to \(p) on the server", timeout: 15) {
                img = await self.serverMessage(check, c, .image, from: self.me)
                return img != nil
            }
            XCTAssertEqual(img?.body.image?.width, Self.width)
            XCTAssertEqual(img?.body.image?.height, Self.height)
            XCTAssertEqual(img?.body.image?.mime, "image/jpeg")
        }
    }

    func testXP2_receive() async throws {
        // run-e2e.sh passes an empty value when it is not set: empty means the other two.
        let given = Self.env("TT_E2E_XP_FROM") ?? ""
        let from = (given.isEmpty ? Self.platforms.filter { $0 != Self.me }.joined(separator: ",") : given)
            .split(separator: ",").map(String.init)
        XCTAssertFalse(from.isEmpty)
        let check = try await filesPeer(me)  // sdk-swift in the runner, the same user as the app
        try await launchFiles(me)
        for p in from {
            let c = c2c(me, user(p))
            var got: Message?
            let sender = user(p)
            try await poll("image from \(p)") {
                got = await self.serverMessage(check, c, .image, from: sender)
                return got != nil
            }
            let img = try XCTUnwrap(got?.body.image)
            XCTAssertEqual(img.width, Self.width, "\(p) width")
            XCTAssertEqual(img.height, Self.height, "\(p) height")
            XCTAssertEqual(img.mime, "image/jpeg", "\(p) mime")
            // UI: every image in this chat shows its thumbnail; each opens the original.
            try await tap(conv(user(p)))
            try await until("image bubbles loaded", timeout: 20) { self.allImagesLoaded() }
            for i in 0..<imageBubbles.count {
                imageBubbles.element(boundBy: i).tap()
                try await see("viewer-image", timeout: 15)
                try await tap("viewer-close")
            }
            try await back()
            // Bytes through sdk-swift.
            let original = try Data(contentsOf: try await check.download(fileId: img.fileId, variant: .original))
            XCTAssertEqual(original.count, Int(img.size ?? -1), "\(p) original size")
            let o = try XCTUnwrap(decode(original))
            XCTAssertEqual(o.width, Self.width)
            XCTAssertEqual(o.height, Self.height)
            assertColor(Self.colors[p]!, rgb(o, Self.width / 2, Self.height / 2), "\(p) original colour")
            let thumb = try Data(contentsOf: try await check.download(fileId: img.fileId, variant: .thumb))
            let t = try XCTUnwrap(decode(thumb))
            XCTAssertLessThanOrEqual(max(t.width, t.height), 480, "\(p) thumbnail long side")
            assertColor(Self.colors[p]!, rgb(t, t.width / 2, t.height / 2), "\(p) thumbnail colour")
        }
        // The group: the senders' files, downloaded in the app's UI.
        var files: [Message] = []
        let senders = Set(from.map { user($0) })
        try await poll("files in the group") {
            _ = try? await check.loadHistory(self.group)
            let list: [Message] = check.messages(self.group)
            files = list.filter { (m: Message) -> Bool in m.type == .file && m.seq != nil }
            let have = Set(files.map { (m: Message) -> String in m.from })
            return senders.isSubset(of: have)
        }
        try await tap(conv("跨端群"))
        try await until("file bubbles") { self.fileBubbles.count == files.count }
        var prompted = false
        for p in from {
            let sender = user(p)
            let m = try XCTUnwrap(files.first { (x: Message) -> Bool in x.from == sender })
            let f = try XCTUnwrap(m.body.file)
            XCTAssertEqual(f.name, Self.fileName(p))
            XCTAssertEqual(f.size, Int64(Self.fileBytes(p).count))
            XCTAssertEqual(f.mime, "application/pdf")
            let i = try XCTUnwrap(files.firstIndex { (x: Message) -> Bool in x.msgId == m.msgId })
            try await tap(inBubble(i, "file-download"))
            if !prompted {
                try await see("source-dialog")
                try await tap("dialog-ok")
                prompted = true
            }
            let want = sha(Self.fileBytes(p))
            try await until("\(p) file downloaded in the app", timeout: 30) { self.lastDownloadSHA() == want }
        }
    }
}
