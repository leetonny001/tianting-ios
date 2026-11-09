import CoreGraphics
import Foundation
import ImageIO
import TiantingIM
import UniformTypeIdentifiers
import XCTest

@testable import TiantingAppKit

/// FE-637, FE-638: the pure helpers and ImageIO processing (unit level; the pages are in UITests/FilesE2ETests).
final class MediaTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    /// Left half `left`, right half `right` (RGB 0...255).
    private func halves(_ w: Int, _ h: Int, left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8), alpha: UInt8 = 255)
        -> CGImage
    {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = x < w / 2 ? left : right
                let i = (y * w + x) * 4
                px[i] = c.0
                px[i + 1] = c.1
                px[i + 2] = c.2
                px[i + 3] = alpha
            }
        }
        let info = alpha == 255 ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        return ctx.makeImage()!
    }

    private func write(_ image: CGImage, _ type: UTType, _ name: String, props: [CFString: Any] = [:]) -> URL {
        let url = dir.appendingPathComponent(name)
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        return url
    }

    /// A JPEG with GPS, a camera model and Orientation=6 (AC-FILE-02-4): stored 40 × 20, left red, right blue.
    private func exifJpeg() -> URL {
        write(
            halves(40, 20, left: (255, 0, 0), right: (0, 0, 255)), .jpeg, "exif.jpg",
            props: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "ZXQ-CAMERA", kCGImagePropertyTIFFOrientation: 6],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 31.23, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 121.47, kCGImagePropertyGPSLongitudeRef: "E",
                ],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "ZXQ-EXIF"],
            ])
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var d = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: CGFloat(-x), y: CGFloat(-(image.height - 1 - y)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(d[0]), Int(d[1]), Int(d[2]))
    }

    private func decode(_ url: URL) -> CGImage {
        let s = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateImageAtIndex(s, 0, nil)!
    }

    private func props(_ url: URL) -> [CFString: Any] {
        let s = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
    }

    private func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Sniffing

    func testSniffReadsTypesSizesAlphaAndOrientation() throws {
        let jpeg = sniffImage(try Data(contentsOf: exifJpeg()))
        XCTAssertEqual(jpeg?.kind, .jpeg)
        XCTAssertEqual(jpeg?.width, 40)
        XCTAssertEqual(jpeg?.height, 20)
        XCTAssertEqual(jpeg?.orientation, 6)
        let png = sniffImage(try Data(contentsOf: write(halves(30, 10, left: (1, 2, 3), right: (4, 5, 6), alpha: 128), .png, "a.png")))
        XCTAssertEqual(png, ImageHead(kind: .png, width: 30, height: 10, alpha: true))
        let gif = sniffImage(try Data(contentsOf: write(halves(8, 6, left: (1, 2, 3), right: (4, 5, 6)), .gif, "a.gif")))
        XCTAssertEqual(gif?.kind, .gif)
        XCTAssertEqual(gif?.width, 8)
        XCTAssertNil(sniffImage(Data("<html>".utf8)))
        var heic = Data([0, 0, 0, 24])
        heic.append(Data("ftypheic".utf8))
        XCTAssertEqual(sniffImage(heic)?.kind, .heic)
        var webp = Data("RIFF".utf8)
        webp.append(Data([0, 0, 0, 0]))
        webp.append(Data("WEBPVP8X".utf8))
        webp.append(Data([0, 0, 0, 0, 0x10, 0, 0, 0, 99, 0, 0, 49, 0, 0]))
        XCTAssertEqual(sniffImage(webp), ImageHead(kind: .webp, width: 100, height: 50, alpha: true))
    }

    func testPixelLimit() {
        XCTAssertTrue(withinPixelLimit(8000, 5000))
        XCTAssertFalse(withinPixelLimit(8000, 5001))
        XCTAssertFalse(withinPixelLimit(nil, 10))
        XCTAssertFalse(withinPixelLimit(0, 10))
    }

    // MARK: Texts and helpers

    func testSizesNamesAndOpenWhitelist() {
        XCTAssertEqual(formatSize(512), "512 B")
        XCTAssertEqual(formatSize(1536), "1.5 KB")
        XCTAssertEqual(formatSize(5 << 20), "5 MB")
        XCTAssertEqual(formatSize(150 << 20), "150 MB")
        XCTAssertEqual(extensionOf("a.PDF"), "pdf")
        XCTAssertEqual(extensionOf("noext"), "")
        // AC-FILE-03-9: pdf can open; .xyz only saves; the type and the extension must agree.
        XCTAssertTrue(canOpen(mime: "application/pdf", name: "报告.pdf"))
        XCTAssertFalse(canOpen(mime: "application/octet-stream", name: "a.xyz"))
        XCTAssertFalse(canOpen(mime: "application/pdf", name: "a.exe"))
        XCTAssertTrue(canOpen(mime: "text/plain", name: "a.txt"))
        XCTAssertEqual(fileTypeLabel("a.zip"), "ZIP")
        XCTAssertEqual(fileTypeLabel("a.xyz"), "FILE")
        XCTAssertTrue(looksLikeImage(mime: nil, name: "a.HEIC"))
        XCTAssertFalse(looksLikeImage(mime: "application/pdf", name: "a.pdf"))
    }

    // AC-FILE-02-6: the reserved size is known before loading.
    func testDisplaySizeKeepsRatioWithinTheBox() {
        XCTAssertEqual(displaySize(4000, 3000), CGSize(width: 200, height: 150))
        XCTAssertEqual(displaySize(100, 50), CGSize(width: 100, height: 50))
        XCTAssertEqual(displaySize(10000, 10), CGSize(width: 200, height: 40))
        XCTAssertEqual(displaySize(nil, nil), CGSize(width: 160, height: 120))
    }

    private func failed(_ type: MessageType, _ error: SendFailure, reason: String? = nil, fileId: String = "") -> Message {
        var body = MsgBody()
        if type == .image { body.image = ImageBody(fileId: fileId) } else { body.file = FileBody(fileId: fileId, name: "a.pdf") }
        var m = message("c", status: .failed, type: type)
        m.body = body
        m.error = error
        m.errorReason = reason
        return m
    }

    // AC-FILE-01-12, 01-17, 02-13, F-FILE-07 rule 4: the PRD's texts; the network text is the same as H5 and Android (D12).
    func testFailureTexts() {
        XCTAssertEqual(attachmentErrorText(failed(.image, .code(4292))), "今天的上传额度已用完")
        XCTAssertEqual(attachmentErrorText(failed(.file, .code(4290), reason: "uploadPendingLimit")), "上传任务太多，请稍后再试")
        XCTAssertEqual(attachmentErrorText(failed(.image, .process)), "无法处理这张图片，请用文件方式发送")
        XCTAssertEqual(attachmentErrorText(failed(.file, .storage)), "存储空间不足")
        XCTAssertEqual(attachmentErrorText(failed(.image, .sourceMissing)), "原文件已不可用，请重新选择")
        XCTAssertEqual(attachmentErrorText(failed(.image, .network)), "图片上传失败，请检查网络后重发")
        XCTAssertEqual(attachmentErrorText(failed(.file, .interrupted)), "文件上传失败，请检查网络后重发")
        XCTAssertEqual(attachmentErrorText(failed(.file, .code(4139))), "文件过大，最大 100 MB")
        XCTAssertEqual(attachmentErrorText(failed(.image, .code(4150))), "不支持发送这种文件")
        // Uploaded already: the code came from `send`.
        XCTAssertEqual(attachmentErrorText(failed(.image, .code(4036), fileId: "F1")), errorText(4036, cmd: "send"))
        XCTAssertTrue(attachmentDeleteOnly(failed(.image, .sourceMissing)))
        XCTAssertFalse(attachmentDeleteOnly(failed(.image, .network)))
        XCTAssertEqual(attachmentStatusText(.uploading, percent: 42), "上传中 42%")
        XCTAssertEqual(attachmentStatusText(.processing, percent: nil), "处理中…")
        XCTAssertEqual(attachmentStatusText(.queued, percent: nil), "等待发送")
        XCTAssertNil(attachmentStatusText(.sent, percent: nil))
    }

    // AC-FILE-02-8, 03-8: "[图片]", "[文件]", never the file name.
    func testSummaries() {
        let img = conversation(.c2c, last: LastMsg(msgId: "m", from: "bob", type: "image", text: "", ts: 1))
        XCTAssertEqual(conversationSummary(img, me: "alice") { $0 }, "[图片]")
        let file = conversation(.group, last: LastMsg(msgId: "m", from: "bob", type: "file", text: "", ts: 1))
        XCTAssertEqual(conversationSummary(file, me: "alice") { _ in "Bob" }, "Bob: [文件]")
        let other = conversation(.c2c, last: LastMsg(msgId: "m", from: "bob", type: "custom", text: "", ts: 1))
        XCTAssertEqual(conversationSummary(other, me: "alice") { $0 }, "[暂不支持的消息]")
    }

    // MARK: Processing (F-FILE-02 rules 2 to 4)

    // AC-FILE-02-4: upright by EXIF orientation, then no EXIF, GPS or camera model in the original or the thumbnail.
    func testExifOrientationAppliedThenEverythingStripped() throws {
        let src = exifJpeg()
        let out = try ImageProcessing.process(src, outDir: dir.appendingPathComponent("out"))
        XCTAssertEqual(out.original.mime, "image/jpeg")
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 40)
        for f in [out.original.file, out.thumb.file] {
            let p = props(f)
            XCTAssertNil(p[kCGImagePropertyGPSDictionary], "no GPS")
            XCTAssertNil((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel], "no model")
            XCTAssertNil((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
            XCTAssertEqual((p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
            let bytes = try Data(contentsOf: f)
            XCTAssertNil(bytes.range(of: Data("Exif".utf8)), "no APP1 Exif segment")
            XCTAssertNil(bytes.range(of: Data("ZXQ".utf8)))
            let img = decode(f)
            XCTAssertEqual(img.width, 20)
            XCTAssertEqual(img.height, 40)
            let top = pixel(img, 10, 5)
            let bottom = pixel(img, 10, 34)
            XCTAssertGreaterThan(top.0, 180, "top is red: \(top)")
            XCTAssertGreaterThan(bottom.2, 180, "bottom is blue: \(bottom)")
        }
    }

    func testLongSideShrinksTo4096AndThumbWithinLimits() throws {
        let big = write(halves(5000, 2500, left: (10, 200, 30), right: (200, 10, 30)), .png, "big.png")
        let out = try ImageProcessing.process(big, outDir: dir)
        XCTAssertEqual(out.width, 4096)
        XCTAssertEqual(out.height, 2048)
        XCTAssertEqual(out.original.mime, "image/jpeg", "opaque png becomes jpeg")
        let t = decode(out.thumb.file)
        XCTAssertEqual(max(t.width, t.height), 480)
        XCTAssertLessThanOrEqual(size(out.thumb.file), thumbMaxBytes)
        XCTAssertLessThanOrEqual(size(out.original.file), imageMaxBytes)
    }

    func testTransparentPngStaysPng() throws {
        let src = write(halves(60, 40, left: (255, 0, 0), right: (0, 255, 0), alpha: 100), .png, "t.png")
        let out = try ImageProcessing.process(src, outDir: dir)
        XCTAssertEqual(out.original.mime, "image/png")
        XCTAssertEqual(out.thumb.mime, "image/png")
        // ImageIO's own eXIf chunk is dropped too; the file still decodes with its transparency.
        for f in [out.original.file, out.thumb.file] {
            XCTAssertNil(try Data(contentsOf: f).range(of: Data("eXIf".utf8)))
            XCTAssertEqual(decode(f).width, f == out.original.file ? 60 : 60)
            XCTAssertNotEqual(decode(f).alphaInfo, .none)
        }
    }

    // F-FILE-02 rule 4: a GIF is uploaded byte for byte; its first frame makes the thumbnail.
    func testGifIsNotEncodedAgain() throws {
        let src = write(halves(64, 32, left: (255, 0, 0), right: (0, 0, 255)), .gif, "a.gif")
        let out = try ImageProcessing.process(src, outDir: dir)
        XCTAssertEqual(out.original.mime, "image/gif")
        XCTAssertEqual(try Data(contentsOf: out.original.file), try Data(contentsOf: src))
        XCTAssertEqual(out.width, 64)
        XCTAssertNotEqual(out.thumb.mime, "image/gif")
    }

    // AC-FILE-02-13 (first half): a file that only claims to be an image fails with the process error.
    func testUndecodableFails() throws {
        let fake = dir.appendingPathComponent("fake.jpg")
        try Data("not an image at all".utf8).write(to: fake)
        XCTAssertThrowsError(try ImageProcessing.process(fake, outDir: dir)) { XCTAssertEqual(($0 as? ImageProcessError)?.why, "unknown") }
        // A JPEG start and nothing behind it.
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0]).write(to: broken)
        XCTAssertThrowsError(try ImageProcessing.process(broken, outDir: dir))
    }

    /// A PNG header claiming 8000 × 8000 (64 million pixels), no pixel data behind it.
    private func bombHeader() throws -> URL {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        d.append(Data("IHDR".utf8))
        d.append(Data([0, 0, 0x1F, 0x40, 0, 0, 0x1F, 0x40, 8, 2, 0, 0, 0, 0, 0, 0, 0]))
        let u = dir.appendingPathComponent("bomb.png")
        try d.write(to: u)
        return u
    }

    // F-FILE-02 rule 3, AC-FILE-02-12: over the pixel limit never reaches the decoder, sending or showing.
    func testPixelBombIsRefusedBeforeDecoding() throws {
        let bomb = try bombHeader()
        XCTAssertThrowsError(try ImageProcessing.process(bomb, outDir: dir)) {
            XCTAssertEqual(($0 as? ImageProcessError)?.why, "tooManyPixels")
        }
        XCTAssertNil(ImageProcessing.displayImage(bomb, maxLong: 480))
        let ok = write(halves(40, 20, left: (1, 1, 1), right: (2, 2, 2)), .jpeg, "ok.jpg")
        XCTAssertNotNil(ImageProcessing.displayImage(ok, maxLong: 480))
    }

    // AC-ACC-06-6: 512 × 512 JPEG from a square of the upright image.
    func testAvatarIs512Square() throws {
        let img = halves(900, 600, left: (255, 0, 0), right: (0, 0, 255))
        let out = try ImageProcessing.avatar(img, x: 450, y: 0, side: 600, out: dir.appendingPathComponent("av.jpg"))
        let d = decode(out)
        XCTAssertEqual(d.width, 512)
        XCTAssertEqual(d.height, 512)
        XCTAssertGreaterThan(pixel(d, 256, 256).2, 180, "the right half was taken")
        XCTAssertLessThanOrEqual(size(out), avatarMaxBytes)
        XCTAssertEqual(sniffImage(try Data(contentsOf: out))?.kind, .jpeg)
    }

    // AC-FILE-02-13 (second half): a photo-like source over 20 MiB is fine after processing.
    func testOver20MiBSourceSucceedsAfterProcessing() throws {
        let w = 6000, h = 4000
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 7
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_103_515_245 &+ 12345
                let n = Int(seed >> 28)
                let i = (y * w + x) * 4
                px[i] = UInt8((x * 255 / w + n) & 0xFF)
                px[i + 1] = UInt8((y * 255 / h + n) & 0xFF)
                px[i + 2] = UInt8(((x + y) * 255 / (w + h)) & 0xFF)
                px[i + 3] = 255
            }
        }
        let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let src = write(ctx.makeImage()!, .png, "huge.png")
        XCTAssertGreaterThan(size(src), imageMaxBytes, "the source is over 20 MiB")
        let out = try ImageProcessing.process(src, outDir: dir)
        XCTAssertLessThanOrEqual(size(out.original.file), imageMaxBytes)
        XCTAssertEqual(out.width, 4096)
    }
}
