import Foundation
import TiantingIM

// Images and files, the pure part (PRD-chat section 6): type sniffing, header width and height, the pixel limit, texts,
// sizes, file names. No decoding and no network, so the unit tests call them directly. Same semantics as tianting-web's
// src/lib/media.ts and tianting-android's core/Media.kt.

/// Pixel limit before decoding (F-FILE-02 rule 3, not calibrated).
public let maxPixels: Int64 = 40_000_000
/// How many can be picked at once (F-FILE-07 rule 6, not calibrated).
public let maxPick = 9
/// The processed original (IM_IMAGE_MAX_BYTES, 20 MiB; F-FILE-02 rule 2 counts after processing).
public let imageMaxBytes: Int64 = 20 << 20
/// The thumbnail (F-FILE-02 rule 3).
public let thumbMaxBytes: Int64 = 512 << 10
public let fileMaxBytes: Int64 = 100 << 20
public let avatarMaxBytes: Int64 = 2 << 20
/// Long side of the original (F-FILE-02 rule 4), of the thumbnail (rule 3); the avatar's side (F-ACC-06 rule 3).
public let originalLongSide = 4096
public let thumbLongSide = 480
public let avatarSide = 512

/// F-FILE-07 rule 4, AC-FILE-07-10 (D13).
public let sourceMissingText = "原文件已不可用，请重新选择"
public let processFailedText = "无法处理这张图片，请用文件方式发送"
public let storageFullText = "存储空间不足"
public let keepMetadataTip = "文件会保留原始信息（可能包含位置）"
public let sourceTip = "文件来自其他用户，请确认来源可信"
public let pickTooManyText = "一次最多选择 \(maxPick) 个"

public enum ImageKind: String, Sendable {
    case jpeg = "image/jpeg", png = "image/png", gif = "image/gif", webp = "image/webp", heic = "image/heic"
}

/// What the header says: width and height (HEIC is not parsed), maybe transparent, the JPEG's EXIF orientation.
public struct ImageHead: Equatable, Sendable {
    public var kind: ImageKind
    public var width: Int?
    public var height: Int?
    public var alpha = false
    public var orientation: Int?
}

private func u16be(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
private func u32be(_ b: [UInt8], _ i: Int) -> Int64 { Int64(u16be(b, i)) << 16 | Int64(u16be(b, i + 2)) }
private func u16le(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
private func u24le(_ b: [UInt8], _ i: Int) -> Int { u16le(b, i) | Int(b[i + 2]) << 16 }
private func ascii(_ b: [UInt8], _ i: Int, _ n: Int) -> String {
    guard i >= 0, i + n <= b.count else { return "" }
    return String(decoding: b[i..<(i + n)], as: UTF8.self)
}

/// The image type by content, and its width and height without decoding pixels. nil when not recognized.
public func sniffImage(_ data: Data) -> ImageHead? {
    let b = [UInt8](data)
    if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return jpegHead(b) }
    if b.count >= 8, u32be(b, 0) == 0x8950_4E47, u32be(b, 4) == 0x0D0A_1A0A { return pngHead(b) }
    if b.count >= 6, ["GIF87a", "GIF89a"].contains(ascii(b, 0, 6)) {
        return b.count >= 10 ? ImageHead(kind: .gif, width: u16le(b, 6), height: u16le(b, 8)) : ImageHead(kind: .gif)
    }
    if b.count >= 12, ascii(b, 0, 4) == "RIFF", ascii(b, 8, 4) == "WEBP" { return webpHead(b) }
    if b.count >= 12, ascii(b, 4, 4) == "ftyp",
        ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(ascii(b, 8, 4))
    {
        return ImageHead(kind: .heic)
    }
    return nil
}

private func jpegHead(_ b: [UInt8]) -> ImageHead {
    var orientation: Int?
    var i = 2
    while i + 4 <= b.count {
        if b[i] != 0xFF { break }
        let marker = Int(b[i + 1])
        if marker == 0xFF {
            i += 1
            continue
        }
        if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
            i += 2
            continue
        }
        let len = u16be(b, i + 2)
        if marker == 0xE1, orientation == nil { orientation = exifOrientation(b, i + 4, len - 2) }
        let sof = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
        if sof, i + 9 <= b.count {
            return ImageHead(kind: .jpeg, width: u16be(b, i + 7), height: u16be(b, i + 5), orientation: orientation)
        }
        if marker == 0xDA { break }
        i += 2 + len
    }
    return ImageHead(kind: .jpeg, orientation: orientation)
}

private func exifOrientation(_ b: [UInt8], _ start: Int, _ len: Int) -> Int? {
    guard start + 14 <= b.count, ascii(b, start, 4) == "Exif" else { return nil }
    let t = start + 6
    let le = ascii(b, t, 2) == "II"
    func r16(_ i: Int) -> Int { le ? u16le(b, i) : u16be(b, i) }
    func r32(_ i: Int) -> Int64 { le ? Int64(u16le(b, i)) | Int64(u16le(b, i + 2)) << 16 : u32be(b, i) }
    let ifd = t + Int(r32(t + 4))
    guard ifd >= 0, ifd + 2 <= min(b.count, start + len) else { return nil }
    let n = r16(ifd)
    for k in 0..<n {
        let e = ifd + 2 + k * 12
        if e + 12 > b.count { return nil }
        if r16(e) == 0x0112 { return r16(e + 8) }
    }
    return nil
}

private func pngHead(_ b: [UInt8]) -> ImageHead {
    guard b.count >= 26, ascii(b, 12, 4) == "IHDR" else { return ImageHead(kind: .png) }
    let colorType = b[25]
    var alpha = colorType == 4 || colorType == 6
    var i = 8
    while !alpha, i + 8 <= b.count {
        let len = u32be(b, i)
        let type = ascii(b, i + 4, 4)
        if type == "tRNS" { alpha = true }
        if type == "IDAT" || type == "IEND" || len > Int64(Int32.max) - 12 { break }
        i += 12 + Int(len)
    }
    let w = Int(min(u32be(b, 16), Int64(Int32.max)))
    let h = Int(min(u32be(b, 20), Int64(Int32.max)))
    return ImageHead(kind: .png, width: w, height: h, alpha: alpha)
}

private func webpHead(_ b: [UInt8]) -> ImageHead {
    let chunk = ascii(b, 12, 4)
    if chunk == "VP8 ", b.count >= 30 {
        return ImageHead(kind: .webp, width: u16le(b, 26) & 0x3FFF, height: u16le(b, 28) & 0x3FFF)
    }
    if chunk == "VP8L", b.count >= 25 {
        let b0 = Int(b[21]), b1 = Int(b[22]), b2 = Int(b[23]), b3 = Int(b[24])
        return ImageHead(
            kind: .webp, width: 1 + (b0 | (b1 & 0x3F) << 8), height: 1 + (b1 >> 6 | b2 << 2 | (b3 & 0x0F) << 10), alpha: true)
    }
    if chunk == "VP8X", b.count >= 30 {
        return ImageHead(kind: .webp, width: 1 + u24le(b, 24), height: 1 + u24le(b, 27), alpha: b[20] & 0x10 != 0)
    }
    return ImageHead(kind: .webp)
}

/// Width and height are known and within the pixel limit (decompression bombs, F-FILE-02 rule 3, AC-FILE-02-12).
public func withinPixelLimit(_ width: Int?, _ height: Int?) -> Bool {
    guard let width, let height, width > 0, height > 0 else { return false }
    return Int64(width) * Int64(height) <= maxPixels
}

/// A picked file counts as an image: an image type, or an image extension.
public func looksLikeImage(mime: String?, name: String) -> Bool {
    if mime?.hasPrefix("image/") == true { return true }
    return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff"].contains(extensionOf(name))
}

/// Bytes for the file bubble: B, KB, MB, GB with one decimal.
public func formatSize(_ n: Int64) -> String {
    if n < 1024 { return "\(n) B" }
    let units = ["KB", "MB", "GB"]
    var v = Double(n) / 1024
    var u = 0
    while v >= 1024, u < units.count - 1 {
        v /= 1024
        u += 1
    }
    let shown: String
    if v >= 100 {
        shown = String(Int(v.rounded()))
    } else {
        let r = (v * 10).rounded() / 10
        shown = r == r.rounded(.down) ? String(Int(r)) : String(r)
    }
    return "\(shown) \(units[u])"
}

/// The extension, lower case, without the dot; empty when there is none.
public func extensionOf(_ name: String) -> String {
    guard let dot = name.lastIndex(of: ".") else { return "" }
    let ext = name[name.index(after: dot)...]
    guard (1...8).contains(ext.count), !ext.contains("/") else { return "" }
    return ext.lowercased()
}

/// F-FILE-03 rule 3: images, pdf and txt can be opened; the rest only saved (R-CS-13). The recorded mime and the extension
/// both have to agree.
public func canOpen(mime: String?, name: String) -> Bool {
    let ext = extensionOf(name)
    switch (mime ?? "").lowercased() {
    case "application/pdf": return ext == "pdf"
    case "text/plain": return ext == "txt"
    case "image/jpeg", "image/png", "image/gif", "image/webp": return ["jpg", "jpeg", "png", "gif", "webp"].contains(ext)
    default: return false
    }
}

/// The type label of the file bubble, by extension (F-FILE-03 rule 3's "type icon").
public func fileTypeLabel(_ name: String) -> String {
    switch extensionOf(name) {
    case "pdf": return "PDF"
    case "doc", "docx": return "DOC"
    case "xls", "xlsx", "csv": return "XLS"
    case "ppt", "pptx": return "PPT"
    case "zip", "rar", "7z", "gz", "tar": return "ZIP"
    case "txt", "md", "log": return "TXT"
    case "jpg", "jpeg", "png", "gif", "webp", "heic": return "IMG"
    case "mp3", "wav", "m4a", "aac": return "AUD"
    case "mp4", "mov", "mkv", "avi": return "VID"
    default: return "FILE"
    }
}

/// The image's size in the bubble (points): fits in box × box keeping the ratio, at least 40 on each side. Known before
/// loading, so the next message does not move (AC-FILE-02-6).
public func displaySize(_ w: Int?, _ h: Int?, box: CGFloat = 200) -> CGSize {
    guard let w, let h, w > 0, h > 0 else { return CGSize(width: box * 0.8, height: box * 0.6) }
    let s = min(box / CGFloat(w), box / CGFloat(h), 1)
    return CGSize(width: max(40, (CGFloat(w) * s).rounded()), height: max(40, (CGFloat(h) * s).rounded()))
}

/// The failure text of an attachment (F-FILE-01 rules 6, 6a; F-FILE-02 rule 2; F-FILE-07 rule 4 and its exceptions). The
/// PRD's text where there is one; a network or object-store failure has none (D12), so the same text as H5 and Android.
/// `.interrupted` (killed while processing or uploading, D4) reads like a network failure, as Android does.
public func attachmentErrorText(_ m: Message) -> String {
    guard let e = m.error else { return "" }
    let image = m.type == .image
    let uploaded = !(m.body.fileId ?? "").isEmpty
    switch e {
    case .process: return processFailedText
    case .sourceMissing: return sourceMissingText
    case .storage: return storageFullText
    case .network, .interrupted: return image ? "图片上传失败，请检查网络后重发" : "文件上传失败，请检查网络后重发"
    case .timeout, .kicked: return "发送失败，可以点击重发"
    case .code(let code):
        // With a fileId the upload finished and the error came from `send` (4292 is then the new-chat count, not the quota).
        if uploaded, code != 4048, code != 4096 { return errorText(code, cmd: "send") }
        switch code {
        case 4292: return "今天的上传额度已用完"
        case 4290: return m.errorReason == "uploadPendingLimit" ? "上传任务太多，请稍后再试" : errorText(4290)
        case 4139: return "文件过大，最大 \(image ? "20 MB" : "100 MB")"
        case 4150: return "不支持发送这种文件"
        default: return errorText(code, cmd: "send")
        }
    }
}

/// The failed attachment can only be deleted: its source is gone (F-FILE-07 rule 4).
public func attachmentDeleteOnly(_ m: Message) -> Bool {
    m.status == .failed && m.error == .sourceMissing
}

/// Summaries in the list (F-FILE-02 rule 5, F-FILE-03 rule 5: a file shows "[文件]" only, never its name).
public func attachmentSummary(_ type: String) -> String? {
    switch type {
    case "image": return "[图片]"
    case "file": return "[文件]"
    default: return nil
    }
}

/// The message's attachment status for its bubble (13.4): processing, uploading N%, waiting.
public func attachmentStatusText(_ status: MessageStatus, percent: Int?) -> String? {
    switch status {
    case .processing: return "处理中…"
    case .uploading: return percent.map { "上传中 \($0)%" } ?? "上传中…"
    case .queued: return "等待发送"
    default: return nil
    }
}

/// The MIME type of a picked file by its extension, for files the picker did not type.
public func mimeOf(_ name: String) -> String? {
    switch extensionOf(name) {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic", "heif": return "image/heic"
    case "pdf": return "application/pdf"
    case "txt": return "text/plain"
    case "zip": return "application/zip"
    default: return nil
    }
}
