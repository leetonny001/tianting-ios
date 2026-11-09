import ImageIO
import TiantingIM
import XCTest

/// FE-637 (pick, process, send, sandbox, avatar) and FE-638 (show, download, open, save) against the real im-server and
/// the fake S3 (scripts/run-e2e.sh). Local results on the simulator; CI does not run these.
final class FilesE2ETests: FilesCase {
    // MARK: Sending (FE-637)

    /// TC-FILE-02-01 (iOS both ways), TC-FILE-02-08: the app sends a JPEG, the peer gets the same size and type; the
    /// peer's image shows its thumbnail first and opens the original; the list says "[图片]".
    func testTC_FILE_02_01_imageBothWaysThumbThenOriginal() async throws {
        let me = uid("fa"), you = uid("fb")
        let peer = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        let conv = c2c(me, you)
        try await pickImages([("a.jpg", jpeg(1600, 1200, color: (200, 80, 40)))])
        let mine = imageBubbles.firstMatch
        try await until("my image sent", timeout: 20) { self.value(mine).hasPrefix("已发送") }
        var got: Message?
        try await until("peer receives", timeout: 10) {
            got = peer.messages(conv).first { $0.type == .image }
            return got != nil
        }
        XCTAssertEqual(got?.body.image?.width, 1600)
        XCTAssertEqual(got?.body.image?.height, 1200)
        XCTAssertEqual(got?.body.image?.mime, "image/jpeg")
        let original = try await peer.download(fileId: try XCTUnwrap(got?.body.image?.fileId), variant: .original)
        XCTAssertEqual(try Data(contentsOf: original).count, Int(got?.body.image?.size ?? -1))

        try await s3ctl("reset=1")
        let sent = try await peerSendsImage(peer, conv, original: jpeg(1200, 900, color: (30, 160, 60)), width: 1200, height: 900)
        try await until("two image bubbles") { self.imageBubbles.count == 2 }
        let theirs = imageBubbles.element(boundBy: 1)
        try await until("thumbnail loaded", timeout: 15) { self.value(theirs).hasSuffix("loaded") }
        let stats = try await s3stats()
        XCTAssertEqual(stats.gets["original"] ?? 0, 0, "no original before opening it")
        theirs.tap()
        try await see("viewer-image", timeout: 15)
        let got1 = try await s3stats().gets["original"] ?? 0
        XCTAssertGreaterThanOrEqual(got1, 1)
        try await tap("viewer-close")
        try await back()
        try await see(convRow(you, containing: "[图片]"))
        XCTAssertEqual(sent.body.image?.width, 1200)
    }

    /// TC-FILE-02-04: GPS, camera model and Orientation=6 are gone from the stored original and thumbnail, which are upright
    /// (40 × 20 left red right blue becomes 20 × 40 top red bottom blue). No exiftool here (H18, I-issue).
    func testTC_FILE_02_04_exifAndGpsStrippedOrientationApplied() async throws {
        let me = uid("ea"), you = uid("eb")
        let peer = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        let src = encode(
            halves(40, 20, left: (255, 0, 0), right: (0, 0, 255)), .jpeg,
            props: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "ZXQ-CAMERA", kCGImagePropertyTIFFOrientation: 6],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 31.23, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 121.47, kCGImagePropertyGPSLongitudeRef: "E",
                ],
            ])
        XCTAssertNotNil(properties(src)[kCGImagePropertyGPSDictionary], "the source carries GPS")
        try await pickImages([("gps.jpg", src)])
        let conv = c2c(me, you)
        var got: Message?
        try await until("peer receives", timeout: 20) {
            got = peer.messages(conv).first { $0.type == .image }
            return got != nil
        }
        let fileId = try XCTUnwrap(got?.body.image?.fileId)
        XCTAssertEqual(got?.body.image?.width, 20)
        XCTAssertEqual(got?.body.image?.height, 40)
        for v in [FileVariant.original, .thumb] {
            let d = try Data(contentsOf: try await peer.download(fileId: fileId, variant: v))
            let p = properties(d)
            XCTAssertNil(p[kCGImagePropertyGPSDictionary], "\(v): no GPS")
            XCTAssertNil(p[kCGImagePropertyExifDictionary], "\(v): no Exif")
            XCTAssertNil((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel], "\(v): no model")
            XCTAssertNil(d.range(of: Data("Exif".utf8)), "\(v): no APP1 Exif")
            XCTAssertNil(d.range(of: Data("ZXQ-CAMERA".utf8)))
            let img = try XCTUnwrap(decode(d))
            XCTAssertEqual(img.width, 20)
            XCTAssertEqual(img.height, 40)
            XCTAssertGreaterThan(rgb(img, 10, 5).0, 180, "\(v): top is red")
            XCTAssertGreaterThan(rgb(img, 10, 34).2, 180, "\(v): bottom is blue")
        }
    }

    /// TC-FILE-02-05: cancelling while uploading removes the message, no `send` (sentinel: a text after it is all the peer
    /// gets).
    func testTC_FILE_02_05_cancelWhileUploading() async throws {
        let me = uid("ca"), you = uid("cb")
        let peer = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        try await s3ctl("put_delay_ms=6000")
        try await pickImages([("a.jpg", jpeg(300, 200, color: (10, 10, 200)))])
        try await see(el("attach-status", labelContains: "上传中"), timeout: 15)
        try await tap("attach-cancel")
        try await gone(imageBubbles.firstMatch)
        try await s3ctl("put_delay_ms=0")
        try await send("ZXQ-after-cancel")
        try await sent("ZXQ-after-cancel")
        let conv = c2c(me, you)
        try await until("peer gets the text") { peer.messages(conv).contains { $0.body.text == "ZXQ-after-cancel" } }
        XCTAssertFalse(peer.messages(conv).contains { $0.type == .image }, "the cancelled image was never sent")
        try await staysGone(imageBubbles.firstMatch)
    }

    /// TC-FILE-02-13: a file that only claims to be an image fails with the process text; a photo over 20 MiB is sent
    /// (the limit counts after processing).
    func testTC_FILE_02_13_undecodableFailsHugeSourceSucceeds() async throws {
        let me = uid("ha"), you = uid("hb")
        let peer = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        try await pickImages([("fake.jpg", Data("ZXQ not an image".utf8))])
        try await see(el("attach-error", labelContains: "无法处理这张图片，请用文件方式发送"), timeout: 15)
        // A photo-like 6000 × 4000 PNG over 20 MiB.
        let w = 6000, h = 4000
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt32 = 3
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_103_515_245 &+ 12345
                let n = Int(seed >> 28)
                let i = (y * w + x) * 4
                px[i] = UInt8((x * 255 / w + n) & 0xFF)
                px[i + 1] = UInt8((y * 255 / h + n) & 0xFF)
                px[i + 2] = UInt8(((x + y) * 255 / (w + h)) & 0xFF)
            }
        }
        let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let huge = encode(ctx.makeImage()!, .png)
        XCTAssertGreaterThan(huge.count, 20 << 20)
        try await pickImages([("huge.png", huge)])
        let conv = c2c(me, you)
        var got: Message?
        try await until("peer receives the big photo", timeout: 60) {
            got = peer.messages(conv).first { $0.type == .image }
            return got != nil
        }
        XCTAssertLessThanOrEqual(got?.body.image?.size ?? .max, 20 << 20)
        XCTAssertEqual(got?.body.image?.width, 4096)
    }

    /// TC-FILE-03-01 (iOS both ways, group), TC-FILE-05-03: the app sends a pdf, members get it with the same SHA-256; a
    /// member's file downloads in the app with the source prompt the first time only, same SHA-256.
    func testTC_FILE_03_01_pdfInGroupBothWaysSourcePromptOnce() async throws {
        let me = uid("pa"), you = uid("pb")
        let peer = try await filesPeer(you)
        let g = try await hostedGroup(name: "文件群", members: [me, you])
        try await launchFiles(me)
        try await tap(self.conv("文件群"))
        var pdf = Data("%PDF-1.7\n".utf8)
        pdf.append(Data((0..<(5 << 20)).map { UInt8(($0 * 7) & 0xFF) }))
        try await pickFiles([("ZXQ-FILE-报告.pdf", pdf)])
        XCTAssertFalse(el("keep-info-dialog").exists, "a pdf is not an image: no prompt")
        var got: Message?
        try await until("member receives", timeout: 30) {
            got = peer.messages(g.convId).first { $0.type == .file }
            return got != nil
        }
        XCTAssertEqual(got?.body.file?.name, "ZXQ-FILE-报告.pdf")
        XCTAssertEqual(got?.body.file?.mime, "application/pdf")
        let f = try await peer.download(fileId: try XCTUnwrap(got?.body.file?.fileId), variant: .original)
        XCTAssertEqual(sha(try Data(contentsOf: f)), sha(pdf))
        try await until("my sandbox copy deleted after sending") { self.sandboxCount() == 0 }

        var zip = Data("PK\u{3}\u{4}".utf8)
        zip.append(Data((0..<300_000).map { UInt8(($0 * 13) & 0xFF) }))
        try await peerSendsFile(peer, g.convId, zip, name: "资料.zip", mime: "application/zip")
        try await until("two file bubbles") { self.fileBubbles.count == 2 }
        try await tap(inBubble(1, "file-download"))
        try await see("source-dialog")
        XCTAssertEqual(label("dialog-text"), "文件来自其他用户，请确认来源可信")
        try await tap("dialog-ok")
        try await see(inBubble(1, "file-save"), timeout: 15)
        try await until("download hash") { self.lastDownloadSHA() == self.sha(zip) }
        // The second file from someone else in the same conversation: no prompt.
        try await peerSendsFile(peer, g.convId, zip + Data([1]), name: "资料2.zip", mime: "application/zip")
        try await until("three file bubbles") { self.fileBubbles.count == 3 }
        try await tap(inBubble(2, "file-download"))
        try await staysGone(el("source-dialog"))
        try await until("second download hash", timeout: 15) { self.lastDownloadSHA() == self.sha(zip + Data([1])) }
    }

    /// TC-FILE-03-06: images picked through "文件" ask first; cancel sends nothing, confirm sends a file message with the
    /// original bytes (metadata kept).
    func testTC_FILE_03_06_imageAsFileAsksFirst() async throws {
        let me = uid("ka"), you = uid("kb")
        let peer = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        let src = jpeg(64, 48, color: (1, 2, 3), props: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "ZXQ-KEEP"]])
        try await pickFiles([("photo.jpg", src)])
        try await see("keep-info-dialog")
        XCTAssertEqual(label("dialog-text"), "文件会保留原始信息（可能包含位置）")
        try await tap("dialog-cancel")
        try await staysGone(fileBubbles.firstMatch)
        try await pickFiles([("photo.jpg", src)])
        try await see("keep-info-dialog")
        try await tap("dialog-ok")
        let conv = c2c(me, you)
        var got: Message?
        try await until("peer receives a file", timeout: 20) {
            got = peer.messages(conv).first { $0.type == .file }
            return got != nil
        }
        let f = try await peer.download(fileId: try XCTUnwrap(got?.body.file?.fileId), variant: .original)
        XCTAssertEqual(sha(try Data(contentsOf: f)), sha(src), "a file is not encoded again")
    }

    /// TC-FILE-01-12: 4292 marks the image failed with "今天的上传额度已用完" and is not retried. The day's declared bytes
    /// are used up by the test first (F-FILE-01 rule 6a: four times the daily quota, AC-FILE-01-29).
    func testTC_FILE_01_12_quotaExceeded() async throws {
        let me = uid("qa"), you = uid("qb")
        _ = try await filesPeer(you)
        try await importUsers([me])
        let token = try await userToken(me)
        // Declare 100 MiB at a time, then halve the size at each 4292, until even 512 bytes are refused.
        var hit = false
        var size = 100 << 20
        for _ in 0..<400 where size >= 512 {
            let (status, o) = try await api(
                "POST", "/v1/files/uploads", token: token,
                ["kind": "file", "name": "x.bin", "size": size, "mime": "application/octet-stream"])
            if status == 429, o["code"] as? Int == 4292 {
                hit = true
                size /= 2
                continue
            }
            XCTAssertEqual(status, 200, "\(o)")
            if let id = o["fileId"] as? String { _ = try await api("DELETE", "/v1/files/uploads/\(id)", token: token) }
        }
        XCTAssertTrue(hit, "the declared bytes reached 4292")
        try await launchFiles(me)
        try await startChat(with: you)
        try await pickImages([("a.jpg", jpeg(100, 100, color: (5, 5, 5)))])
        let err = el("attach-error", labelContains: "今天的上传额度已用完")
        try await see(err, timeout: 15)
        let puts = try await s3stats().puts
        try await sleep(2500)
        XCTAssertTrue(err.exists, "still failed: no automatic retry")
        let got2 = try await s3stats().puts
        XCTAssertEqual(got2, puts)
        XCTAssertTrue(value(imageBubbles.firstMatch).hasPrefix("发送失败"))
    }

    /// TC-FILE-01-17: uploadPendingLimit fails with "上传任务太多，请稍后再试", no retry; a cancel sends DELETE, which frees
    /// the slot at once.
    func testTC_FILE_01_17_pendingLimitAndCancelSendsDelete() async throws {
        let me = uid("la"), you = uid("lb")
        _ = try await filesPeer(you)
        try await importUsers([me])
        let token = try await userToken(me)
        func ask() async throws -> (Int, [String: Any]) {
            try await api("POST", "/v1/files/uploads", token: token, ["kind": "file", "name": "x.bin", "size": 10, "mime": "application/octet-stream"])
        }
        var mine: [String] = []
        for _ in 0..<19 {
            let (s, o) = try await ask()
            XCTAssertEqual(s, 200, "\(o)")
            mine.append(o["fileId"] as? String ?? "")
        }
        try await launchFiles(me)
        try await startChat(with: you)
        // The app's upload is the 20th pending one, held in its PUT.
        try await s3ctl("put_delay_ms=8000")
        try await pickFiles([("a.txt", Data("ZXQ pending".utf8))])
        try await see(el("attach-status", labelContains: "上传中"), timeout: 15)
        let (full, o) = try await ask()
        XCTAssertEqual(full, 429)
        XCTAssertEqual(o["reason"] as? String, "uploadPendingLimit")
        try await tap("attach-cancel")
        try await gone(fileBubbles.firstMatch)
        try await until("the slot is free after the app's DELETE") {
            _ = self
            return true
        }
        var freed = false
        for _ in 0..<20 where !freed {
            let (s, _) = try await ask()
            freed = s == 200
            if !freed { try await sleep(200) }
        }
        XCTAssertTrue(freed, "DELETE freed the pending slot")
        try await s3ctl("put_delay_ms=0")
        // Now 20 pending again: the app's next file fails with the PRD's text and stays failed.
        try await pickFiles([("b.txt", Data("ZXQ pending 2".utf8))])
        let err = el("attach-error", labelContains: "上传任务太多，请稍后再试")
        try await see(err, timeout: 15)
        try await sleep(2500)
        XCTAssertTrue(err.exists)
        for id in mine { _ = try await api("DELETE", "/v1/files/uploads/\(id)", token: token) }
    }

    /// TC-FILE-07-04: three images picked in order, text typed while the first uploads: the text is sent first, the
    /// images follow in pick order with increasing seq.
    func testTC_FILE_07_04_textPassesUploadsImagesKeepOrder() async throws {
        let me = uid("oa"), you = uid("ob")
        let peer = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        try await s3ctl("put_delay_ms=1500")
        try await pickImages([
            ("1.jpg", jpeg(31, 20, color: (1, 1, 1))), ("2.jpg", jpeg(41, 20, color: (2, 2, 2))), ("3.jpg", jpeg(51, 20, color: (3, 3, 3))),
        ])
        try await send("ZXQ-text-first")
        try await sent("ZXQ-text-first")
        let conv = c2c(me, you)
        try await until("peer has four", timeout: 40) { peer.messages(conv).count >= 4 }
        let list = peer.messages(conv)
        XCTAssertEqual(list.first?.body.text, "ZXQ-text-first", "text passed the uploading images")
        XCTAssertEqual(list.dropFirst().map { $0.body.image?.width }, [31, 41, 51], "pick order")
        let seqs = list.compactMap(\.seq)
        XCTAssertEqual(seqs, seqs.sorted())
    }

    /// TC-FILE-07-05, 07-06: the upload fails (the fake S3 drops the PUT; a simulator cannot lose its network), the
    /// picked source is deleted, the resend uses the sandbox copy and succeeds once; the copy is deleted after sending.
    func testTC_FILE_07_05_07_06_failedUploadResendsFromSandbox() async throws {
        let me = uid("sa"), you = uid("sb")
        let peer = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        try await s3ctl("fail_puts=100")
        try await pickImages([("a.jpg", jpeg(200, 100, color: (9, 99, 199)))])
        try await see(el("attach-error", labelContains: "图片上传失败，请检查网络后重发"), timeout: 30)
        XCTAssertEqual(sandboxCount(), 2, "original and thumbnail in the sandbox")
        try clearPicks()  // The "album" original is gone.
        try await s3ctl("fail_puts=0")
        try await tap("failed-icon")
        try await tap("dialog-ok")
        try await until("sent", timeout: 20) { self.value(self.imageBubbles.firstMatch).hasPrefix("已发送") }
        let conv = c2c(me, you)
        try await until("peer has it") { peer.messages(conv).contains { $0.type == .image } }
        try await sleep(1500)
        XCTAssertEqual(peer.messages(conv).filter { $0.type == .image }.count, 1, "only once")
        try await until("sandbox copy deleted") { self.sandboxCount() == 0 }
    }

    /// TC-FILE-07-07: five failed uploads of the same image leave no stored object (the quota is only charged by a
    /// complete, F-FILE-01 rule 6; inferred like H19, the client has no quota endpoint).
    func testTC_FILE_07_07_fiveFailuresNoFinalObject() async throws {
        let me = uid("wa"), you = uid("wb")
        _ = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        let before = try await s3list("final/").count
        try await s3ctl("fail_puts=100")
        try await pickImages([("a.jpg", jpeg(120, 80, color: (7, 7, 7)))])
        let err = el("attach-error")
        try await see(err, timeout: 30)
        for _ in 1..<5 {
            try await tap("failed-icon")
            try await tap("dialog-ok")
            try await until("failed again", timeout: 30) { self.value(self.imageBubbles.firstMatch).hasPrefix("发送失败") && err.exists }
            try await sleep(300)
        }
        let got3 = try await s3stats().puts
        XCTAssertEqual(got3, 5, "five PUT attempts")
        let got4 = try await s3list("final/").count
        XCTAssertEqual(got4, before, "no final object: nothing completed")
    }

    /// TC-FILE-07-09: failed uploads keep their sandbox copies; logging out deletes them.
    func testTC_FILE_07_09_logoutClearsSandbox() async throws {
        let me = uid("za"), you = uid("zb")
        _ = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        try await s3ctl("fail_puts=100")
        try await pickFiles([("1.txt", Data("ZXQ 1".utf8)), ("2.txt", Data("ZXQ 2".utf8)), ("3.txt", Data("ZXQ 3".utf8))])
        try await until("three failed", timeout: 40) { self.all("attach-error").count == 3 }
        XCTAssertEqual(sandboxCount(), 3)
        try await back()
        try await logout()
        try await until("sandbox emptied") { self.sandboxCount() == 0 }
    }

    /// F-FILE-07 rule 6, H16: more than nine at once sends none.
    func testMoreThanNinePickedSendsNone() async throws {
        let me = uid("na"), you = uid("nb")
        _ = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        try await pickFiles((0..<10).map { ("\($0).txt", Data("ZXQ \($0)".utf8)) })
        try await see(el("toast", labelContains: "一次最多选择 9 个"))
        try await staysGone(fileBubbles.firstMatch)
    }

    /// TC-FILE-07-01: killed while uploading → failed after the restart, no automatic upload; the resend uploads from the
    /// start and the peer gets exactly one.
    func testTC_FILE_07_01_killedWhileUploadingThenResend() async throws {
        let me = uid("ua"), you = uid("ub")
        let peer = try await filesPeer(you)
        try await launchFiles(me)
        try await startChat(with: you)
        try await s3ctl("put_delay_ms=20000")
        try await pickImages([("a.jpg", jpeg(320, 240, color: (100, 0, 100)))])
        try await see(el("attach-status", labelContains: "上传中"), timeout: 15)
        try await sleep(500)
        app.terminate()
        try await s3ctl("put_delay_ms=0")
        let putsBefore = try await s3stats().puts
        try await launchFiles(me, reset: false)
        // Nothing reached the server yet, so the list has no row: open the chat again.
        try await startChat(with: you)
        let bubble = imageBubbles.firstMatch
        try await until("failed after the restart") { self.value(bubble).hasPrefix("发送失败") }
        try await sleep(2000)
        let got5 = try await s3stats().puts
        XCTAssertEqual(got5, putsBefore, "no automatic upload")
        try await tap("failed-icon")
        try await tap("dialog-ok")
        try await until("sent", timeout: 20) { self.value(bubble).hasPrefix("已发送") }
        let got6 = try await s3stats().puts
        XCTAssertEqual(got6, putsBefore + 2, "uploaded again from the start (original and thumbnail)")
        let conv = c2c(me, you)
        try await until("peer has it") { peer.messages(conv).contains { $0.type == .image } }
        try await sleep(1500)
        XCTAssertEqual(peer.messages(conv).filter { $0.type == .image }.count, 1)
    }

    /// TC-ACC-06-06: "我" → avatar → crop → 512 × 512 JPEG uploaded as kind=avatar → PATCH profile; shown at once. The SDK
    /// fetches the new address (H13); the test public address is http, so the app shows the uploaded file (AC-UI-21-5).
    func testTC_ACC_06_06_avatarCroppedUploadedShown() async throws {
        let user = uid("av"), password = "correct-horse-7"
        let expires = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
        let inv = try await signed("POST", "/admin/invites", ["count": 1, "maxUses": 1, "expiresAt": expires, "note": "ios-e2e"])
        let code = try XCTUnwrap((inv["invites"] as? [[String: Any]])?.first?["code"] as? String)
        var o = AccountClientOptions(baseUrl: http)
        o.platform = .android
        o.systemEvents = false
        let device = AccountClient(options: o)
        let r = try await device.register(username: user, password: password, nickname: nil, inviteCode: code)
        try await device.ackRecoveryCode(gen: try XCTUnwrap(r.recoveryCodeGen))
        launch(env: ["TT_TEST_PICK_DIR": pickDir.path, "TT_TEST_STATE": "1"])
        try await see("login-use-account")
        try await tap("login-use-account")
        try await type(user, into: "account-username")
        try await type(password, into: "account-password")
        if !el("account-submit").isHittable { app.swipeUp() }
        try await tap("account-submit")
        try await see("tab-chats", timeout: 15)
        try await tap("tab-me")
        try willPick([("face.png", png(900, 600, color: (40, 180, 90)))])
        try await tap("me-avatar")
        try await see("avatar-crop", timeout: 10)
        try await tap("avatar-save")
        try await see(el("toast", labelContains: "头像已更新"), timeout: 20)
        try await gone(el("avatar-crop"))
        // The stored avatar is a 512 × 512 JPEG in the public bucket.
        let objects = try await s3list("", bucket: "avatars")
        XCTAssertEqual(objects.count, 1, "one public avatar object")
        let key = try XCTUnwrap(objects.first?["key"] as? String)
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(s3)/__raw?bucket=avatars&key=\(key)")!)
        // The server's own profile: users.avatar is the public address of that object (the profile is visible to the
        // account itself; the test asks as the user with an admin-issued token).
        let selfView = try await profileAsSelf(user)
        XCTAssertEqual(selfView?.avatar, "\(s3)/avatars/\(key)")
        let img = try XCTUnwrap(decode(data))
        XCTAssertEqual(img.width, 512)
        XCTAssertEqual(img.height, 512)
        XCTAssertGreaterThan(rgb(img, 256, 256).1, 150, "the picked picture")
        capture("tc-acc-06-06-avatar")
    }

    private func profileAsSelf(_ user: String) async throws -> UserProfile? {
        let token = try await userToken(user)
        var options = IMClientOptions(url: http.replacingOccurrences(of: "http://", with: "ws://") + "/ws")
        options.platform = .web
        options.systemEvents = false
        options.pushCursorStore = nil
        let c = IMClient(options: options)
        defer { c.destroy() }
        c.connect(token: token)
        try await until("self connected") { c.state == .connected }
        return await c.getUsers([user]).first
    }

    // MARK: Showing (FE-638)

    /// TC-FILE-02-06: the 4000 × 3000 image reserves its size before loading; the next message moves ≤ 1 pt.
    func testTC_FILE_02_06_placeholderKeepsTheNextMessageInPlace() async throws {
        let me = uid("ra"), you = uid("rb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        // A noisy thumbnail over 16 KiB: the fake S3 waits after each 16 KiB, so it arrives late enough to measure before.
        var px = [UInt8](repeating: 255, count: 480 * 360 * 4)
        for i in 0..<px.count where i % 4 != 3 { px[i] = UInt8((i &* 2_654_435_761) >> 24 & 0xFF) }
        let ctx = CGContext(
            data: &px, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 480 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let thumb = encode(ctx.makeImage()!, .jpeg)
        XCTAssertGreaterThan(thumb.count, 20_000)
        try await peerSendsImage(peer, conv, original: headerJpeg(4000, 3000), width: 4000, height: 3000, thumb: thumb)
        try peer.send(conv, "ZXQ-next")
        try await until("peer sent text") { peer.messages(conv).last?.status == .sent }
        try await launchFiles(me)
        try await s3ctl("get_chunk_ms=500")
        try await tap(self.conv(you))
        let next = message("ZXQ-next")
        let bubble = imageBubbles.firstMatch
        try await see(next)
        try await until("loading") { self.value(bubble).hasSuffix("loading") }
        let before = next.frame.minY
        XCTAssertEqual(bubble.frame.width, 200, accuracy: 1)
        XCTAssertEqual(bubble.frame.height, 150, accuracy: 1)
        try await until("loaded", timeout: 20) { self.value(bubble).hasSuffix("loaded") }
        try await sleep(300)
        XCTAssertLessThanOrEqual(abs(next.frame.minY - before), 1, "the next message moved")
    }

    /// TC-FILE-02-07, TC-FILE-03-04, TC-FILE-02-08, TC-FILE-03-08: a hostile name is plain text; a 200-character name is
    /// truncated in the middle inside the screen; summaries are "[图片]" and "[文件]" without the name.
    func testTC_FILE_02_07_03_04_namesPlainTruncatedSummaries() async throws {
        let me = uid("xa"), you = uid("xb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        try await peerSendsImage(peer, conv, original: jpeg(300, 200, color: (5, 5, 50)), width: 300, height: 200)
        try await launchFiles(me)
        try await see(convRow(you, containing: "[图片]"))
        let hostile = "<img src=x onerror=alert(1)>.txt"
        try await peerSendsFile(peer, conv, Data("ZXQ".utf8), name: hostile, mime: "text/plain")
        // 200 characters; ASCII, since the server takes at most 255 bytes after cleaning (F-FILE-01 rule 7).
        let long = String(repeating: "a", count: 196) + ".pdf"
        try await peerSendsFile(peer, conv, Data("%PDF-1.4 ZXQ".utf8), name: long, mime: "application/pdf")
        try await see(convRow(you, containing: "[文件]"))
        XCTAssertFalse(convRow(you, containing: "aaaa").exists, "no file name in the summary")
        try await tap(self.conv(you))
        try await until("two files") { self.fileBubbles.count == 2 }
        XCTAssertTrue(fileBubbles.element(boundBy: 0).label.hasPrefix("文件 \(hostile)，"), "plain text: \(fileBubbles.element(boundBy: 0).label)")
        let w = app.windows.firstMatch.frame
        let longBubble = fileBubbles.element(boundBy: 1)
        XCTAssertLessThanOrEqual(longBubble.frame.maxX, w.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(longBubble.frame.minX, 0)
        XCTAssertTrue(longBubble.label.contains(long), "the full name for VoiceOver; the text is truncated")
        XCTAssertLessThan(longBubble.frame.height, 110, "the name stays on one line")
        capture("tc-file-03-04-long-name")
    }

    /// TC-FILE-02-09: 40 images in the history: only the thumbnails near the viewport are fetched, no originals.
    func testTC_FILE_02_09_lazyThumbnailsOnly() async throws {
        let me = uid("ya"), you = uid("yb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        // Many messages to someone who has not answered hit the stranger limit (4137) once an earlier test lowered it.
        try await makeFriends(me, you)
        let conv = c2c(me, you)
        for i in 0..<40 {
            try await peerSendsImage(peer, conv, original: jpeg(60 + i, 40, color: (UInt8(i), 9, 9)), width: 60 + i, height: 40)
        }
        try await s3ctl("reset=1")
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await until("some thumbnails loaded", timeout: 15) { self.imageBubbles.count > 0 && self.probeInt("img") > 0 }
        try await sleep(2000)
        let gets = try await s3stats().gets
        XCTAssertEqual(gets["original"] ?? 0, 0, "no originals")
        XCTAssertGreaterThan(gets["thumb"] ?? 0, 0)
        XCTAssertLessThan(gets["thumb"] ?? 0, 40, "only near the viewport: \(gets)")
    }

    /// TC-FILE-02-12: a stored thumbnail whose header claims more than 40 million pixels shows the placeholder; nothing
    /// crashes and other messages still work.
    func testTC_FILE_02_12_pixelBombThumbShowsPlaceholder() async throws {
        let me = uid("ba"), you = uid("bb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        let thumb = jpeg(120, 90, color: (1, 200, 1))
        let m = try await peerSendsImage(peer, conv, original: jpeg(400, 300, color: (1, 200, 1)), width: 400, height: 300, thumb: thumb)
        let fileId = try XCTUnwrap(m.body.image?.fileId)
        let thumbs = try await s3list("final/\(fileId)/").filter { ($0["key"] as? String)?.hasSuffix("/thumb") == true }
        let key = try XCTUnwrap(thumbs.first?["key"] as? String)
        // An 8000 × 8000 PNG header (64 million pixels) and nothing behind it.
        var bomb = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        bomb.append(Data("IHDR".utf8))
        bomb.append(Data([0, 0, 0x1F, 0x40, 0, 0, 0x1F, 0x40, 8, 2, 0, 0, 0, 0, 0, 0, 0]))
        try await s3replace(key: key, bomb)
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await see("image-undecodable", timeout: 15)
        XCTAssertTrue(value(imageBubbles.firstMatch).hasSuffix("undecodable"))
        try await send("ZXQ-still-fine")
        try await sent("ZXQ-still-fine")
    }

    /// TC-FILE-02-14 (iOS): a GIF shows its first frame and the "GIF" mark.
    func testTC_FILE_02_14_gifFirstFrameAndMark() async throws {
        let me = uid("ga"), you = uid("gb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        try await peerSendsImage(peer, conv, original: gif(80, 60), width: 80, height: 60, mime: "image/gif")
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await see("image-gif", timeout: 10)
        try await until("loaded", timeout: 15) { self.value(self.imageBubbles.firstMatch).hasSuffix("loaded") }
    }

    /// TC-FILE-03-05 (iOS): the download breaks halfway (the fake S3 cuts the GET; a simulator shares the Mac's network):
    /// failure and retry; the retry starts over with a new URL.
    func testTC_FILE_03_05_downloadCutThenRetry() async throws {
        let me = uid("da"), you = uid("db")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        let data = Data((0..<(1 << 20)).map { UInt8(($0 * 11) & 0xFF) })
        try await peerSendsFile(peer, conv, data, name: "big.bin", mime: "application/octet-stream")
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await s3ctl("get_chunk_ms=100")
        try await tap(el("file-download"))
        try await tap("dialog-ok")
        try await see("file-downloading", timeout: 10)
        try await s3ctl("cut_gets=1")
        try await see("file-download-failed", timeout: 20)
        try await s3ctl("reset=1")
        try await tap("file-download-failed")
        try await see("file-save", timeout: 20)
        try await until("hash") { self.lastDownloadSHA() == self.sha(data) }
        let got7 = try await s3stats().gets["original"] ?? 0
        XCTAssertEqual(got7, 1, "after the reset: one fresh GET")
    }

    /// TC-FILE-03-09 (iOS): a pdf has "打开" and "保存", a .xyz only "保存".
    func testTC_FILE_03_09_openOnlyForTheWhitelist() async throws {
        let me = uid("wa"), you = uid("wb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        try await peerSendsFile(peer, conv, Data("%PDF-1.4\n%ZXQ\n".utf8), name: "a.pdf", mime: "application/pdf")
        try await peerSendsFile(peer, conv, Data("ZXQ xyz".utf8), name: "a.xyz", mime: "application/octet-stream")
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await until("two files") { self.fileBubbles.count == 2 }
        try await tap(el("file-download"))
        try await tap("dialog-ok")
        try await until("first downloaded", timeout: 15) { self.all("file-save").count == 1 }
        try await tap(el("file-download"))
        try await until("second downloaded", timeout: 15) { self.all("file-save").count == 2 }
        XCTAssertEqual(all("file-open").count, 1, "only the pdf opens")
        let pdf = fileBubbles.element(boundBy: 0)
        XCTAssertTrue(pdf.descendants(matching: .any).matching(identifier: "file-open").firstMatch.exists)
        let xyz = fileBubbles.element(boundBy: 1)
        XCTAssertFalse(xyz.descendants(matching: .any).matching(identifier: "file-open").firstMatch.exists)
        XCTAssertTrue(xyz.descendants(matching: .any).matching(identifier: "file-save").firstMatch.exists)
        // "打开" is Quick Look; "保存" the share sheet.
        pdf.descendants(matching: .any).matching(identifier: "file-open").firstMatch.tap()
        try await until("Quick Look", timeout: 10) { self.app.navigationBars.count > 0 && !self.el("chat-title").isHittable }
        capture("tc-file-03-09-quicklook")
    }

    /// TC-FILE-04-10: 200 images from the peer; scrolling through all of them gives no 4290, each thumbnail downloads at
    /// most once, and opening the chat again needs no download.
    func testTC_FILE_04_10_twoHundredImagesNo4290AndCache() async throws {
        let me = uid("ia"), you = uid("ib")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        // Many messages to someone who has not answered hit the stranger limit (4137) once an earlier test lowered it.
        try await makeFriends(me, you)
        let conv = c2c(me, you)
        let thumb = jpeg(48, 32, color: (20, 20, 160))
        for i in 0..<200 {
            try await peerSendsImage(peer, conv, original: headerJpeg(300 + i, 200, 2000), width: 300 + i, height: 200, thumb: thumb)
            try await sleep(60)  // Messages: 20 per second per user.
        }
        try await s3ctl("reset=1")
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await see(imageBubbles.firstMatch, timeout: 10)
        let list = el("message-list")
        let end = el("history-state", labelContains: "没有更多了")
        let retry = el("history-state", labelContains: "加载失败")
        var retries = 0
        for _ in 0..<200 {
            if end.exists { break }
            if retry.exists {
                retries += 1
                retry.tap()
            }
            list.swipeDown(velocity: .fast)
            try await sleep(150)
        }
        XCTAssertTrue(end.exists, "scrolled to the first message")
        XCTAssertEqual(retries, 0, "history pages loaded without failures")
        for _ in 0..<40 { list.swipeUp(velocity: .fast) }
        XCTAssertFalse(el("toast", labelContains: "频繁").exists)
        let first = try await s3stats().gets["thumb"] ?? 0
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThanOrEqual(first, 200, "each thumbnail at most once")
        try await back()
        try await tap(self.conv(you))
        try await see(imageBubbles.firstMatch)
        try await sleep(2000)
        let got8 = try await s3stats().gets["thumb"] ?? 0
        XCTAssertEqual(got8, first, "cached: no new download")
    }

    /// F-FILE-02 rule 9, 13.4: saving the original to Photos; refused permission shows "没有相册权限" with Settings.
    func testImageSaveToPhotosAndRefusedPermission() async throws {
        let me = uid("ma"), you = uid("mb")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        try await peerSendsImage(peer, conv, original: jpeg(300, 200, color: (200, 200, 10)), width: 300, height: 200)
        app.resetAuthorizationStatus(for: .photos)
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await until("loaded", timeout: 15) { self.value(self.imageBubbles.firstMatch).hasSuffix("loaded") }
        imageBubbles.firstMatch.tap()
        try await see("viewer-save", timeout: 15)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try await tap("viewer-save")
        let isDeny = NSPredicate(format: "label BEGINSWITH 'Don' OR label == '不允许'")
        let inSpringboard = springboard.descendants(matching: .button).matching(isDeny).firstMatch
        let inApp = app.descendants(matching: .button).matching(isDeny).firstMatch
        try await until("permission alert", timeout: 15) { inSpringboard.exists || inApp.exists }
        let deny = inSpringboard.exists ? inSpringboard : inApp
        capture("photos-permission-alert")
        // "Don't Allow" (the system speaks English: the tests launch with en-US).
        deny.tap()
        try await see("gallery-denied", timeout: 10)
        XCTAssertTrue(el("gallery-settings").exists)
        capture("photos-permission-denied")
        try await tap("dialog-cancel")
        try await tap("viewer-close")
    }

    // MARK: Accessibility (AC-CHAT-90-8, 90-9)

    /// The new bubbles, the "+" panel, the viewer and the dialogs have names; system audit for descriptions; light and dark
    /// screenshots.
    func testTC_CHAT_90_08_filesPagesNamedLightAndDark() async throws {
        let me = uid("ya11y"), you = uid("yb11y")
        try await importUsers([me])
        let peer = try await filesPeer(you)
        let conv = c2c(me, you)
        try await peerSendsImage(peer, conv, original: jpeg(300, 200, color: (10, 120, 200)), width: 300, height: 200)
        try await peerSendsFile(peer, conv, Data("%PDF-1.4 ZXQ".utf8), name: "说明.pdf", mime: "application/pdf")
        try await launchFiles(me)
        try await tap(self.conv(you))
        try await until("loaded", timeout: 15) { self.value(self.imageBubbles.firstMatch).hasSuffix("loaded") }
        XCTAssertEqual(imageBubbles.firstMatch.label, "图片")
        XCTAssertTrue(fileBubbles.firstMatch.label.hasPrefix("文件 说明.pdf，"), fileBubbles.firstMatch.label)
        XCTAssertEqual(el("attach-button").label, "发送图片或文件")
        try await openPlus()
        XCTAssertEqual(el("attach-image").label, "图片")
        XCTAssertEqual(el("attach-file").label, "文件")
        try audit()
        for mode in ["light", "dark"] {
            try await setSystemAppearance(mode)
            try await sleep(600)
            capture("tc-chat-90-08-files-\(mode)")
        }
        imageBubbles.firstMatch.tap()
        try await see("viewer-image", timeout: 15)
        XCTAssertEqual(el("viewer-close").label, "关闭")
        try audit()
        capture("tc-chat-90-08-viewer-dark")
        try await setSystemAppearance("light")
        try await tap("viewer-close")
    }

    /// The system audit; each issue is printed with its element so a failure says what to fix.
    private func audit() throws {
        try app.performAccessibilityAudit(for: [.sufficientElementDescription]) { issue in
            print("A11Y-ISSUE \(issue.compactDescription): \(issue.element?.debugDescription.prefix(200) ?? "-")")
            return false
        }
    }
}
