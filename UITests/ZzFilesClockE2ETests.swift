import TiantingIM
import XCTest

/// File cases that move the server's IM clock (`/admin/test/clock`). Named to run last: a moved clock touches every
/// session on the server; the clock goes back at the end of each test.
final class ZzFilesClockE2ETests: FilesCase {
    private var clockMoved = false

    override func tearDown() async throws {
        if clockMoved {
            try? await admin("POST", "/admin/test/clock", ["nowMs": NSNull()])
            clockMoved = false
        }
        try await super.tearDown()
    }

    private func moveClock(hours: Double) async throws {
        clockMoved = true
        try await admin("POST", "/admin/test/clock", ["nowMs": Int64((Date().timeIntervalSince1970 + hours * 3600) * 1000)])
        try await admin("POST", "/admin/test/jobs/file_purge/run")
        try await admin("POST", "/admin/test/clock", ["nowMs": NSNull()])
        clockMoved = false
    }

    /// TC-FILE-07-10 (iOS, PRD-chat v1.4, P-37 ①): two images completed but not sent (the peer blocked me: 4036), purged
    /// after 25 hours. With the sandbox copy the resend uploads again and is delivered (the server answers 4048 or 4096);
    /// without it: "原文件已不可用，请重新选择", delete only.
    func testTC_FILE_07_10_purgedUploadResendsFromSandboxOrSaysSourceMissing() async throws {
        let me = uid("pa"), you = uid("pb")
        let peer = try await filesPeer(you)
        try await importUsers([me])
        try await peer.block(me)
        try await launchFiles(me)
        try await startChat(with: you)
        try await pickImages([("a.jpg", jpeg(210, 100, color: (200, 0, 0))), ("b.jpg", jpeg(220, 100, color: (0, 200, 0)))])
        try await until("both refused", timeout: 30) {
            self.imageBubbles.count == 2 && (0..<2).allSatisfy { self.value(self.imageBubbles.element(boundBy: $0)).hasPrefix("发送失败") }
        }
        let putsBefore = try await s3stats().puts
        XCTAssertEqual(putsBefore, 4, "both uploaded (original and thumbnail)")
        try await moveClock(hours: 25)
        try await peer.unblock(me)
        // A: the sandbox copy is there.
        try await tap("failed-icon")  // The first failed one: A.
        try await tap("dialog-ok")
        let conv = c2c(me, you)
        try await until("A delivered after uploading again", timeout: 30) {
            peer.messages(conv).contains { $0.type == .image && $0.body.image?.width == 210 }
        }
        let got1 = try await s3stats().puts
        XCTAssertEqual(got1, putsBefore + 2, "uploaded again from the start")
        // B: restart without the sandbox copies.
        app.terminate()
        try await launchFiles(me, reset: false, env: ["TT_TEST_DROP_SANDBOX": "1"])
        try await tap(self.conv(you))
        try await see("failed-icon")
        try await tap("failed-icon")
        try await tap("dialog-ok")
        try await see(el("attach-error", labelContains: "原文件已不可用，请重新选择"), timeout: 20)
        let got2 = try await s3stats().puts
        XCTAssertEqual(got2, putsBefore + 2, "nothing to upload")
        // Delete only.
        try await tap("failed-icon")
        try await see("delete-dialog")
        try await tap("dialog-ok")
        try await until("B removed") { self.imageBubbles.count == 1 }
        XCTAssertFalse(peer.messages(conv).contains { $0.body.image?.width == 220 })
    }

    /// TC-FILE-06-06: an image and a file past the 180-day retention show "图片已过期" and "文件已过期" and fetch nothing.
    func testTC_FILE_06_06_expiredImageAndFile() async throws {
        let me = uid("xa"), you = uid("xb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        try await peerSendsImage(peer, conv, original: jpeg(300, 200, color: (9, 9, 9)), width: 300, height: 200)
        try await peerSendsFile(peer, conv, Data("ZXQ old".utf8), name: "旧文件.txt", mime: "text/plain")
        try await moveClock(hours: 181 * 24)
        try await s3ctl("reset=1")
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await see("image-expired", timeout: 15)
        try await see("file-expired")
        XCTAssertTrue(value(imageBubbles.firstMatch).hasSuffix("expired"))
        XCTAssertFalse(el("file-download").exists, "no download for an expired file")
        try await sleep(1500)
        let gets = try await s3stats().gets
        XCTAssertEqual(gets.values.reduce(0, +), 0, "nothing fetched: \(gets)")
    }
}
