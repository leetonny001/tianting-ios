import TiantingIM
import XCTest

/// FE-669 with images and files: recalled while shown full screen, recalled while downloading, quoting an image and a
/// file. The real im-server and scripts/fake_s3.py (its GET can be slowed down).
@MainActor
final class C4FilesE2ETests: FilesCase {
    /// TC-RCL-03-08: the peer recalls the image shown full screen: the viewer closes, "该消息已被撤回" shows, the bubble turns
    /// into the recall line (AC-RCL-03-8).
    func testTC_RCL_03_08_viewerClosesWhenThePeerRecallsTheImage() async throws {
        let me = uid("va"), you = uid("vb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        let m = try await peerSendsImage(peer, conv, original: jpeg(800, 600, color: (20, 60, 200)), width: 800, height: 600)
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await until("loaded", timeout: 15) { self.value(self.imageBubbles.firstMatch).hasSuffix("loaded") }
        imageBubbles.firstMatch.tap()
        try await see("viewer-image", timeout: 15)
        try await peer.recall(conv, m.msgId!)
        try await gone(el("viewer-image"), timeout: 5)
        try await see(el("toast", labelContains: "该消息已被撤回"), timeout: 3)
        try await see(el("msg-recalled", labelContains: "对方撤回了一条消息"), timeout: 3)
        XCTAssertFalse(imageBubbles.firstMatch.exists)
    }

    /// TC-RCL-03-12: a 20 MB file downloading slowly is recalled: the download stops, "该消息已被撤回" shows, no "下载失败",
    /// and neither the SDK's cache nor URLSession's temporary files keep a partial file (AC-RCL-03-12).
    func testTC_RCL_03_12_downloadAbortedWhenRecalledNoPartialFile() async throws {
        let me = uid("xa"), you = uid("xb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        let data = Data((0..<(20 << 20)).map { UInt8(($0 * 7) & 0xFF) })
        let m = try await peerSendsFile(peer, conv, data, name: "大文件ZXQ-RCL-3.bin", mime: "application/octet-stream")
        try await launchFiles(me)
        try await tap(self.conv(you))
        // Earlier cases of this run may have left cached files of other messages: compare with what is there now.
        try await until("probe") { self.probeInt("cache") >= 0 && self.probeInt("part") >= 0 }
        let cacheBefore = probeInt("cache")
        let partBefore = probeInt("part")
        let urlSessionBefore = probeInt("cfdl")
        try await s3ctl("get_chunk_ms=100")
        try await tap(el("file-download"))
        try await tap("dialog-ok")
        try await see("file-downloading", timeout: 15)
        try await until("bytes are arriving", timeout: 20) { self.probeInt("part") + self.probeInt("cfdl") > partBefore + urlSessionBefore }
        try await peer.recall(conv, m.msgId!)
        try await see(el("toast", labelContains: "该消息已被撤回"), timeout: 5)
        try await see(el("msg-recalled", labelContains: "对方撤回了一条消息"), timeout: 5)
        try await s3ctl("reset=1")
        var last = ""
        let clean = Date().addingTimeInterval(15)
        while !(probeInt("part") == partBefore && probeInt("cache") == cacheBefore) {
            last = "part \(partBefore)->\(probeInt("part")) cache \(cacheBefore)->\(probeInt("cache"))"
            if Date() > clean {
                XCTFail("partial file left: \(last)")
                throw E2EError.failed("partial file")
            }
            try await sleep(200)
        }
        // No temporary file of URLSession's own either: sdk-swift streams into its `.part-` (frontend-chat issue 52).
        try await sleep(2000)
        XCTAssertEqual(probeInt("cfdl"), urlSessionBefore, "URLSession temporary file")
        XCTAssertFalse(el("file-download-failed").exists)
        try await staysGone(el("file-download-failed"))
    }

    /// TC-QUO-01-05 step 3 (and the client side of AC-QUO-01-7): quoting an image sends "[图片]", a file "[文件] {name}";
    /// sent images and files have the menu (AC-QUO-01-5).
    func testTC_QUO_01_05_quoteImageAndFileSummaries() async throws {
        let me = uid("ia"), you = uid("ib")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        try await peerSendsImage(peer, conv, original: jpeg(400, 300, color: (200, 60, 20)), width: 400, height: 300)
        try await peerSendsFile(peer, conv, Data("%PDF-1.4 x".utf8), name: "报告.pdf", mime: "application/pdf")
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await until("loaded", timeout: 15) { self.value(self.imageBubbles.firstMatch).hasSuffix("loaded") }
        try await see(fileBubbles.firstMatch)
        func quoteAndSend(_ bubble: XCUIElement, _ reply: String) async throws {
            try await longPress(bubble)
            let shown = try await menuShown()
            XCTAssertTrue(shown.contains("引用"))
            try await tapMenuItem("引用")
            try await see("quote-bar")
            try await send(reply)
            try await until("peer got \(reply)") { peer.messages(conv).contains { $0.body.text == reply } }
        }
        try await quoteAndSend(imageBubbles.firstMatch, "回图片")
        XCTAssertEqual(peer.messages(conv).first { $0.body.text == "回图片" }!.body.quote?.text, "[图片]")
        try await quoteAndSend(fileBubbles.firstMatch, "回文件")
        XCTAssertEqual(peer.messages(conv).first { $0.body.text == "回文件" }!.body.quote?.text, "[文件] 报告.pdf")
        try await see(el("msg-quote", labelContains: "[图片]"), timeout: 10)
        try await see(el("msg-quote", labelContains: "[文件] 报告.pdf"), timeout: 10)
    }
}
