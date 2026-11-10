import CoreGraphics
import Foundation
import Observation
import TiantingIM
import UniformTypeIdentifiers

/// One picked item, already copied into the app's own storage. `name` only goes to the server (file messages), never to a
/// log.
public struct Picked: Sendable, Equatable {
    public var file: URL
    public var name: String
    public var mime: String?
}

/// Copying a picked item failed: no space left, or the source cannot be read any more.
public struct PickFailed: Error, Equatable {
    public let storage: Bool
}

/// The download state of a file bubble (13.4 "下载中").
public enum DownloadState: Equatable {
    case running(Int64, Int64?)
    case done(URL)
    case failed
}

/// What a thumbnail or original shows.
public enum ImageLoad: Equatable, Sendable {
    case loading
    case loaded
    /// Not an image, over the pixel limit, or the decoder failed: "图片无法显示" (AC-FILE-02-12).
    case undecodable
    /// The download failed: "加载失败，点击重试".
    case failed
    /// 4048: expired, revoked, no access.
    case unavailable
}

/// Images and files in one login (FE-637, FE-638; PRD-chat F-FILE-02, 03, 05, 07; F-ACC-06 rule 3). A picked item is first
/// copied into the app's temporary storage; an image is processed when its turn comes (the SDK's "processing"); the result
/// goes to the SDK, which copies it into its sandbox (rule 2). Downloads use the SDK's URLSession into its private cache
/// (key fileId + variant). No file name or address reaches a log (F-FILE-04 rule 5).
@MainActor
@Observable
public final class MediaOps {
    public let client: IMClient
    /// The SDK's file endpoints, for the avatar (it is not a message).
    @ObservationIgnored public let files: FileClient?

    /// Upload progress in percent, by clientMsgId.
    public private(set) var progress: [String: Int] = [:]
    /// File bubbles' downloads, by fileId.
    public private(set) var downloads: [String: DownloadState] = [:]
    /// Others' files: the source prompt was confirmed in this conversation (F-FILE-05 rule 3; memory only, like H5's H17).
    public private(set) var sourceAcked: Set<String> = []
    /// The avatar changed in this login: shown from the uploaded file. The test environment's public address is http, which
    /// the app does not load (AC-UI-21-5); production is https (same as H13 on H5, A30 on Android).
    public private(set) var localAvatar: URL?
    /// Bumped when decoded images were dropped (files expired).
    public private(set) var imageEpoch = 0

    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loading: [String: Task<ImageLoad, Never>] = [:]
    @ObservationIgnored private let images = NSCache<NSString, CGImageBox>()

    public nonisolated static var pickDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("tt-pick", isDirectory: true) }
    nonisolated static var procDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("tt-proc", isDirectory: true) }
    nonisolated static var avatarDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("tt-avatar", isDirectory: true) }
    /// Named copies handed to the share sheet, Quick Look and Photos.
    nonisolated static var shareDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("tt-share", isDirectory: true) }

    public init(client: IMClient, files: FileClient?) {
        self.client = client
        self.files = files
        images.countLimit = 300
    }

    // MARK: Picking

    /// Copies a picked item into the app's storage (copied before sending, rule 2; the picker's file goes away after its
    /// callback). Runs off the main thread.
    public nonisolated static func copyIn(_ url: URL, name: String?, mime: String?) throws -> Picked {
        let given = name?.isEmpty == false ? name! : url.lastPathComponent
        let n = given.isEmpty ? "file" : given
        let m = mime ?? UTType(filenameExtension: extensionOf(n))?.preferredMIMEType ?? mimeOf(n)
        do {
            try FileManager.default.createDirectory(at: pickDir, withIntermediateDirectories: true)
        } catch {
            throw PickFailed(storage: isNoSpace(error))
        }
        let out = pickDir.appendingPathComponent(UUID().uuidString)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw PickFailed(storage: isNoSpace(error))
        }
        return Picked(file: out, name: n, mime: m)
    }

    /// An image to send (F-FILE-02, 07): a "processing" message at once; the processing runs off the main thread when its
    /// turn comes (one at a time, rule 6). A failure: "无法处理这张图片，请用文件方式发送".
    @discardableResult
    public func sendImage(_ convId: String, _ p: Picked) throws -> Message {
        let holder = Holder()
        let out = Self.procDir
        let m = try client.sendImage(
            convId,
            process: {
                defer { try? FileManager.default.removeItem(at: p.file) }
                let made = try await Task.detached(priority: .userInitiated) {
                    try ImageProcessing.process(p.file, outDir: out)
                }.value
                holder.made = made
                return made
            },
            onProgress: { [weak self] sent, total in
                Task { @MainActor in self?.onProgress(holder, sent, total) }
            })
        holder.id = m.clientMsgId
        return m
    }

    /// A file to send (F-FILE-03): not encoded again. The SDK copies it into its sandbox; the copy here is deleted then.
    @discardableResult
    public func sendFile(_ convId: String, _ p: Picked) throws -> Message {
        let holder = Holder()
        defer { try? FileManager.default.removeItem(at: p.file) }
        let m = try client.sendFile(
            convId, FileInput(file: p.file, name: p.name, mime: p.mime ?? "application/octet-stream"),
            onProgress: { [weak self] sent, total in
                Task { @MainActor in self?.onProgress(holder, sent, total) }
            })
        holder.id = m.clientMsgId
        return m
    }

    private func onProgress(_ holder: Holder, _ sent: Int64, _ total: Int64) {
        // The SDK copied the processed files into its sandbox before the first byte went out.
        if let made = holder.made {
            holder.made = nil
            try? FileManager.default.removeItem(at: made.original.file)
            try? FileManager.default.removeItem(at: made.thumb.file)
        }
        guard let id = holder.id else { return }
        progress[id] = total > 0 ? Int(min(100, max(0, sent * 100 / total))) : 0
    }

    // MARK: Images

    /// A decoded image of a variant, keyed fileId + variant, never by URL (F-FILE-04 rule 5).
    public func cachedImage(_ fileId: String, _ variant: FileVariant) -> CGImage? {
        images.object(forKey: "\(fileId):\(variant.rawValue)" as NSString)?.image
    }

    /// Downloads a variant through the SDK's cache (one batch of URLs per turn), checks its header, decodes it off the main
    /// thread at most `maxLong` on the long side.
    public func loadImage(_ fileId: String, _ variant: FileVariant, maxLong: Int) async -> ImageLoad {
        let key = "\(fileId):\(variant.rawValue)" as NSString
        if images.object(forKey: key) != nil { return .loaded }
        // A row rebuilt while its load is running joins that load: one download per fileId + variant (AC-FILE-04-10).
        if let running = loading[key as String] { return await running.value }
        let task = Task { await self.fetchImage(fileId, variant, maxLong: maxLong, key: key) }
        loading[key as String] = task
        let result = await task.value
        loading[key as String] = nil
        return result
    }

    private func fetchImage(_ fileId: String, _ variant: FileVariant, maxLong: Int, key: NSString) async -> ImageLoad {
        let file: URL
        do {
            file = try await client.download(fileId: fileId, variant: variant)
        } catch let e as FileTransferError {
            if case .unavailable = e { return .unavailable }
            return .failed
        } catch {
            return .failed
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageProcessing.displayImage(file, maxLong: maxLong).map(CGImageBox.init)
        }.value
        guard let decoded else { return .undecodable }
        images.setObject(decoded, forKey: key)
        TestHooks.imageLoaded()
        return .loaded
    }

    /// Files expired or deleted: their decoded images go too (the SDK removed the cached downloads).
    public func forget(_ fileIds: [String]) {
        for id in fileIds {
            for v in [FileVariant.original, .thumb] { images.removeObject(forKey: "\(id):\(v.rawValue)" as NSString) }
            cancelDownload(id)
        }
        imageEpoch += 1
    }

    // MARK: File downloads (F-FILE-03 rule 3)

    /// Into the SDK's private cache with progress, can be cancelled; a failure shows "下载失败，点击重试", and the retry starts
    /// from 0 with a new URL (the SDK).
    public func startDownload(_ fileId: String) {
        if downloadTasks[fileId] != nil { return }
        downloads[fileId] = .running(0, nil)
        downloadTasks[fileId] = Task { [weak self, client] in
            do {
                let f = try await client.download(fileId: fileId, variant: .original) { n, total in
                    Task { @MainActor in
                        guard let self, case .running = self.downloads[fileId] else { return }
                        self.downloads[fileId] = .running(n, total)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.downloads[fileId] = .done(f)
                TestHooks.downloaded(f)
            } catch {
                guard let self else { return }
                if error is DownloadAbortedError {
                    // Stopped by the SDK: `downloadAborted` (the event) already cleared the state and told the user.
                    if case .running = self.downloads[fileId] { self.downloads[fileId] = nil }
                } else if Task.isCancelled || (error as? FileTransferError) == .cancelled {
                    if self.downloadTasks[fileId] == nil { self.downloads[fileId] = nil }
                } else {
                    TTLog.event("file.download.failed")
                    self.downloads[fileId] = .failed
                }
            }
            self?.downloadTasks[fileId] = nil
        }
    }

    /// The SDK stopped this file's download (recalled, deleted or expired; AC-RCL-03-12): no "下载失败", the state goes.
    /// Returns whether a file bubble's download was running (thumbnails and originals for the viewer do not count).
    @discardableResult
    public func downloadAborted(_ fileId: String) -> Bool {
        guard case .running = downloads[fileId] else { return false }
        downloadTasks.removeValue(forKey: fileId)?.cancel()
        downloads[fileId] = nil
        return true
    }

    public func cancelDownload(_ fileId: String) {
        downloadTasks.removeValue(forKey: fileId)?.cancel()
        if case .running = downloads[fileId] { downloads[fileId] = nil }
    }

    /// Already downloaded (the SDK's cache, key fileId + variant).
    public func checkCached(_ fileId: String) {
        guard downloads[fileId] == nil, let f = client.cachedFile(fileId: fileId, variant: .original) else { return }
        downloads[fileId] = .done(f)
    }

    public func ackSource(_ convId: String) {
        sourceAcked.insert(convId)
    }

    // MARK: Avatar (F-ACC-06 rules 3, 4)

    /// kind=avatar → PUT → complete through the SDK's FileClient (4011 handled per rule 7), not the message pipeline.
    /// Returns the fileId; the caller sends PATCH profile.
    public func uploadAvatar(_ jpeg: URL) async throws -> String {
        guard let files else { throw FileTransferError.unavailable(code: 0) }
        let size = (try? FileManager.default.attributesOfItem(atPath: jpeg.path)[.size] as? NSNumber)?.int64Value ?? 0
        let up = try await files.createUpload(UploadRequest(kind: "avatar", name: "avatar.jpg", size: size, mime: "image/jpeg"))
        try await files.put(up.put, file: jpeg)
        return try await files.complete(up.fileId).fileId
    }

    public func setLocalAvatar(_ url: URL) {
        let keep = Self.avatarDir.appendingPathComponent("current-\(UUID().uuidString).jpg")
        try? FileManager.default.createDirectory(at: Self.avatarDir, withIntermediateDirectories: true)
        if (try? FileManager.default.copyItem(at: url, to: keep)) != nil {
            if let old = localAvatar { try? FileManager.default.removeItem(at: old) }
            localAvatar = keep
        }
    }

    // MARK: Lifetime

    /// Logout: the copies here go too (AC-FILE-07-9; the SDK clears its sandbox and download cache).
    public func clear() {
        for t in downloadTasks.values { t.cancel() }
        downloadTasks = [:]
        downloads = [:]
        progress = [:]
        images.removeAllObjects()
        localAvatar = nil
        Self.clearTemp()
    }

    /// At start and logout: copies left by an earlier run (killed while processing and so on).
    public nonisolated static func clearTemp() {
        for d in [pickDir, procDir, avatarDir, shareDir] { try? FileManager.default.removeItem(at: d) }
    }

    public nonisolated static func isNoSpace(_ error: Error) -> Bool {
        var e: NSError? = error as NSError
        while let c = e {
            if c.domain == NSCocoaErrorDomain, c.code == NSFileWriteOutOfSpaceError { return true }
            if c.domain == NSPOSIXErrorDomain, c.code == Int(ENOSPC) { return true }
            e = c.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// Holds what a callback learns later: the message's id, the processed files to delete.
private final class Holder: @unchecked Sendable {
    var id: String?
    var made: ProcessedImage?
}

final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
