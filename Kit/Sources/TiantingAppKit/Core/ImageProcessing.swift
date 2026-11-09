import CoreGraphics
import Foundation
import ImageIO
import TiantingIM
import UniformTypeIdentifiers

/// Processing failed: the page says "无法处理这张图片，请用文件方式发送" (F-FILE-02 rule 2). `why` is a category only, never
/// a file name.
public struct ImageProcessError: Error, Equatable {
    public let why: String
}

private let headBytes = 256 * 1024
private let qualities: [CGFloat] = [0.9, 0.8, 0.7, 0.55, 0.4]

/// Image processing before sending (PRD-chat F-FILE-02 rules 2 to 4, F-ACC-06 rule 3), with ImageIO. The image is turned
/// upright by its EXIF orientation and encoded again from pixels only, so the output has no EXIF or GPS; a long side over
/// 4096 shrinks; the thumbnail has a long side of 480 and at most 512 KiB; a GIF is not encoded again (only its first frame
/// makes the thumbnail). The header's width and height are checked against the pixel limit before decoding (rule 3). HEIC
/// becomes JPEG; transparent PNG and WebP become PNG (ImageIO cannot write WebP). The SDK only takes the result (R-CF-24).
public enum ImageProcessing {
    /// The first bytes of a file, without decoding.
    public static func readHead(_ url: URL) -> ImageHead? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: headBytes) else { return nil }
        return sniffImage(d)
    }

    /// Processes one image to send. The results go into `outDir`; the SDK copies them into its sandbox.
    public static func process(_ src: URL, outDir: URL) throws -> ProcessedImage {
        guard let head = readHead(src) else { throw ImageProcessError(why: "unknown") }
        if head.width != nil, !withinPixelLimit(head.width, head.height) { throw ImageProcessError(why: "tooManyPixels") }
        guard let source = CGImageSourceCreateWithURL(src as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else { throw ImageProcessError(why: "decode") }
        // HEIC has no parsed header: ImageIO's properties are checked instead, still before decoding.
        let size = pixelSize(source)
        guard withinPixelLimit(size?.width, size?.height) else {
            throw ImageProcessError(why: size == nil ? "decode" : "tooManyPixels")
        }
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            throw ImageProcessError(why: "storage")
        }
        let id = UUID().uuidString
        if head.kind == .gif {
            // Not encoded again (rule 4): uploaded as is, the first frame makes the thumbnail.
            let bytes = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? 0
            if bytes > imageMaxBytes { throw ImageProcessError(why: "tooLarge") }
            let original = outDir.appendingPathComponent("\(id)-o.gif")
            do {
                try FileManager.default.copyItem(at: src, to: original)
            } catch {
                throw ImageProcessError(why: "storage")
            }
            let first = try upright(source, maxLong: thumbLongSide * 2)
            guard let thumb = encodeUnder(first, long: thumbLongSide, alpha: hasAlpha(first), maxBytes: thumbMaxBytes,
                shrink: true, base: outDir.appendingPathComponent("\(id)-t"))
            else { throw ImageProcessError(why: "thumb") }
            return ProcessedImage(
                original: LocalUpload(file: original, mime: "image/gif"), thumb: thumb.upload,
                width: head.width ?? first.width, height: head.height ?? first.height)
        }
        let image = try upright(source, maxLong: originalLongSide)
        // Transparent PNG and WebP keep their transparency (PNG out); the rest is JPEG (rule 2's matrix).
        let alpha = head.alpha && hasAlpha(image)
        guard let main = encodeUnder(image, long: originalLongSide, alpha: alpha, maxBytes: imageMaxBytes, shrink: false,
            base: outDir.appendingPathComponent("\(id)-o"))
        else { throw ImageProcessError(why: "tooLarge") }
        guard let thumb = encodeUnder(image, long: thumbLongSide, alpha: alpha, maxBytes: thumbMaxBytes, shrink: true,
            base: outDir.appendingPathComponent("\(id)-t"))
        else { throw ImageProcessError(why: "thumb") }
        return ProcessedImage(original: main.upload, thumb: thumb.upload, width: main.width, height: main.height)
    }

    /// The width and height ImageIO reads from the header, upright (orientations 5 to 8 swap them).
    static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(o) ? (h, w) : (w, h)
    }

    /// Decodes upright (EXIF orientation applied), long side at most `maxLong` (only shrinking). ImageIO subsamples while
    /// decoding, so a big photo never decodes at full size.
    public static func upright(_ source: CGImageSource, maxLong: Int) throws -> CGImage {
        guard let size = pixelSize(source), withinPixelLimit(size.width, size.height) else {
            throw ImageProcessError(why: "tooManyPixels")
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxLong, max(size.width, size.height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            throw ImageProcessError(why: "decode")
        }
        return image
    }

    public static func upright(_ url: URL, maxLong: Int) throws -> CGImage {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(s) > 0
        else { throw ImageProcessError(why: "decode") }
        return try upright(s, maxLong: maxLong)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// The avatar (F-ACC-06 rule 3): a square (x, y, side) of the upright image, scaled to 512 × 512, JPEG ≤ 2 MiB.
    public static func avatar(_ image: CGImage, x: Int, y: Int, side: Int, out: URL) throws -> URL {
        let s = max(1, min(side, min(image.width, image.height)))
        let cx = min(max(0, x), image.width - s)
        let cy = min(max(0, y), image.height - s)
        guard let square = image.cropping(to: CGRect(x: cx, y: cy, width: s, height: s)),
            let scaled = scale(square, width: avatarSide, height: avatarSide, alpha: false)
        else { throw ImageProcessError(why: "decode") }
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        for q in qualities {
            guard write(scaled, to: out, type: .jpeg, quality: q) else { throw ImageProcessError(why: "storage") }
            if let n = fileSize(out), n <= avatarMaxBytes { return out }
        }
        return out
    }

    private struct Encoded {
        let upload: LocalUpload
        let width: Int
        let height: Int
    }

    /// Encodes within `maxBytes`: lower quality first, then (`shrink`, the thumbnail) a smaller size. nil when impossible.
    private static func encodeUnder(
        _ image: CGImage, long: Int, alpha: Bool, maxBytes: Int64, shrink: Bool, base: URL
    ) -> Encoded? {
        let type: UTType = alpha ? .png : .jpeg
        let mime = alpha ? "image/png" : "image/jpeg"
        let out = base.appendingPathExtension(alpha ? "png" : "jpg")
        var side = long
        while side >= 120 {
            let s = min(1, Double(side) / Double(max(image.width, image.height)))
            let w = max(1, Int((Double(image.width) * s).rounded()))
            let h = max(1, Int((Double(image.height) * s).rounded()))
            guard let scaled = s < 1 ? scale(image, width: w, height: h, alpha: alpha) : image else { return nil }
            for q in alpha ? [1] : qualities {
                guard write(scaled, to: out, type: type, quality: q) else { return nil }
                if let n = fileSize(out), n <= maxBytes {
                    return Encoded(upload: LocalUpload(file: out, mime: mime), width: scaled.width, height: scaled.height)
                }
            }
            if !shrink { break }
            side = Int((Double(side) * 0.75).rounded())
        }
        try? FileManager.default.removeItem(at: out)
        return nil
    }

    static func scale(_ image: CGImage, width: Int, height: Int, alpha: Bool) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Writes pixels only. ImageIO still adds a small Exif block of its own (pixel dimensions, color space) and, for
    /// JPEG, an APP13 segment; null dictionaries in the options produce a broken file, so the metadata is dropped from the
    /// encoded bytes instead. No EXIF, GPS, TIFF or orientation in the output.
    static func write(_ image: CGImage, to url: URL, type: UTType, quality: CGFloat) -> Bool {
        try? FileManager.default.removeItem(at: url)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return false }
        let opts: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        let out = type == .png ? stripPngMetadata(data as Data) : stripJpegMetadata(data as Data)
        return (try? out.write(to: url)) != nil
    }

    /// Drops APP1 (Exif, XMP), APP3 to APP13, APP15 and comments before the scan; keeps JFIF (APP0), ICC (APP2), Adobe
    /// (APP14) and every coding segment. The scan data is copied as it is.
    static func stripJpegMetadata(_ d: Data) -> Data {
        let b = [UInt8](d)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return d }
        var out = Data([0xFF, 0xD8])
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xDA { break }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let end = i + 2 + len
            guard end <= b.count else { return d }
            let drop = marker == 0xE1 || (0xE3...0xED).contains(marker) || marker == 0xEF || marker == 0xFE
            if !drop { out.append(contentsOf: b[i..<end]) }
            i = end
        }
        out.append(contentsOf: b[i...])
        return out
    }

    /// Keeps the chunks needed to show the image; drops eXIf, tEXt, iTXt, zTXt, tIME and anything unknown. Whole chunks
    /// go, so the CRCs of the rest stay valid.
    static func stripPngMetadata(_ d: Data) -> Data {
        let keep: Set<String> = ["IHDR", "PLTE", "tRNS", "sRGB", "gAMA", "cHRM", "iCCP", "sBIT", "IDAT", "IEND"]
        let b = [UInt8](d)
        guard b.count > 8 else { return d }
        var out = Data(b[0..<8])
        var i = 8
        while i + 12 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let end = i + 12 + len
            guard len >= 0, end <= b.count else { return d }
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            if keep.contains(type) { out.append(contentsOf: b[i..<end]) }
            i = end
        }
        return out
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Decodes a downloaded image for display, after checking its header against the pixel limit (AC-FILE-02-12). nil:
    /// not an image, over the limit, or the decoder failed ("图片无法显示"). GIF gives its first frame.
    public static func displayImage(_ url: URL, maxLong: Int) -> CGImage? {
        guard let head = readHead(url) else { return nil }
        if head.width != nil, !withinPixelLimit(head.width, head.height) { return nil }
        return try? upright(url, maxLong: maxLong)
    }
}
