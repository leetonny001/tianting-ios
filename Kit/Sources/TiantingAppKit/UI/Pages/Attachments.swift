import Photos
import PhotosUI
import QuickLook
import SwiftUI
import TiantingIM
import UIKit
import UniformTypeIdentifiers

// Images and files in the chat page (FE-637, FE-638; PRD-chat F-FILE-02, 03, 05, 07; 13.4). The bubbles reserve their size
// from width and height before anything loads; thumbnails load only when their row is built (the lazy stack); decoded
// images are keyed fileId + variant; a header over the pixel limit never reaches the decoder.

public enum PickKind: Equatable {
    case images, files
}

// MARK: Pickers

/// PHPicker (13.2: no full photo-library permission), at most 9 (F-FILE-07 rule 6). Each item is copied into the app's
/// storage inside the provider's callback, where its temporary file still exists.
struct PhotoPicker: UIViewControllerRepresentable {
    var limit = maxPick
    let onDone: ([Result<Picked, PickFailed>]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var c = PHPickerConfiguration()
        c.filter = .images
        c.selectionLimit = limit
        c.preferredAssetRepresentationMode = .current  // HEIC stays HEIC; the app converts it (F-FILE-02 rule 2).
        let vc = PHPickerViewController(configuration: c)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onDone: ([Result<Picked, PickFailed>]) -> Void
        init(_ onDone: @escaping ([Result<Picked, PickFailed>]) -> Void) { self.onDone = onDone }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let done = onDone
            guard !results.isEmpty else { return done([]) }
            Task {
                var out: [Result<Picked, PickFailed>] = []
                for r in results { out.append(await Self.load(r.itemProvider)) }
                await MainActor.run { done(out) }
            }
        }

        private static func load(_ p: NSItemProvider) async -> Result<Picked, PickFailed> {
            // GIF before a generic image type, so it is not converted (F-FILE-02 rule 4).
            let types = p.registeredTypeIdentifiers
            let pick = types.first { UTType($0)?.conforms(to: .gif) == true }
                ?? types.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
            return await withCheckedContinuation { cont in
                _ = p.loadFileRepresentation(forTypeIdentifier: pick) { url, _ in
                    guard let url else { return cont.resume(returning: .failure(PickFailed(storage: false))) }
                    let mime = UTType(pick)?.preferredMIMEType
                    do {
                        cont.resume(returning: .success(try MediaOps.copyIn(url, name: url.lastPathComponent, mime: mime)))
                    } catch let e as PickFailed {
                        cont.resume(returning: .failure(e))
                    } catch {
                        cont.resume(returning: .failure(PickFailed(storage: false)))
                    }
                }
            }
        }
    }
}

/// UIDocumentPicker (13.2) as a copy: the copy is then copied into the app's storage.
struct DocumentPicker: UIViewControllerRepresentable {
    let onDone: ([Result<Picked, PickFailed>]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.allowsMultipleSelection = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: ([Result<Picked, PickFailed>]) -> Void
        init(_ onDone: @escaping ([Result<Picked, PickFailed>]) -> Void) { self.onDone = onDone }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDone(urls.map { u in
                Result { try MediaOps.copyIn(u, name: u.lastPathComponent, mime: nil) }
                    .mapError { ($0 as? PickFailed) ?? PickFailed(storage: false) }
            })
            for u in urls { try? FileManager.default.removeItem(at: u) }  // The picker's own copy.
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onDone([]) }
    }
}

/// The debug hook for UI tests (`TT_TEST_PICK_DIR`): the files in the directory, in name order, as if picked.
@MainActor
func testPicked(_ kind: PickKind) -> [Result<Picked, PickFailed>]? {
    guard let dir = TestHooks.pickDir else { return nil }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    return names.map { n in
        Result { try MediaOps.copyIn(dir.appendingPathComponent(n), name: n, mime: nil) }
            .mapError { ($0 as? PickFailed) ?? PickFailed(storage: false) }
    }
}

// MARK: The "+" panel

struct AttachPanel: View {
    let onPick: (PickKind) -> Void

    var body: some View {
        HStack(spacing: TS.s5) {
            tile(.image, "图片", "attach-image") { onPick(.images) }
            tile(.file, "文件", "attach-file") { onPick(.files) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TS.s4)
        .padding(.vertical, TS.s3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attach-panel")
    }

    private func tile(_ icon: IconName, _ title: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: TS.s1) {
                Icon(name: icon, size: 28)
                    .foregroundStyle(TC.textSecondary)
                    .frame(width: 56, height: 56)
                    .background(TC.bg, in: RoundedRectangle(cornerRadius: TR.lg))
                Text(title).font(TTFont.caption).foregroundStyle(TC.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }
}

// MARK: Image bubble

struct ImageBubble: View {
    let message: Message
    let convId: String
    /// Full screen is the chat page's: it closes when the message is recalled or deleted (AC-RCL-03-8).
    let onOpen: () -> Void
    @Environment(AppModel.self) private var model
    @State private var load = ImageLoad.loading
    @State private var attempt = 0

    private var body_: ImageBody? { message.body.image }
    private var fileId: String? { message.body.fileId }

    var body: some View {
        let size = displaySize(body_?.width, body_?.height)
        ZStack {
            TC.surfaceSelected
            content(size)
            if body_?.mime == "image/gif", body_?.expired != true {
                // First frame and a mark (F-FILE-02 rule 4, AC-FILE-02-14).
                Text("GIF")
                    .font(TTFont.caption)
                    .foregroundStyle(TC.onBrand)
                    .padding(.horizontal, TS.s1)
                    .background(TC.scrim, in: RoundedRectangle(cornerRadius: TR.sm))
                    .padding(TS.s1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .accessibilityIdentifier("image-gif")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: TR.lg))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: TR.lg))
        .onTapGesture { tapped() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("图片")  // 13.4: the alternative text is "图片".
        // The send status as on text messages, then what the thumbnail shows: "已发送 loaded".
        .accessibilityValue("\(messageStatusValue(message.status)) \(stateValue)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("image-bubble")
        .task(id: "\(fileId ?? "")-\(attempt)-\(body_?.expired == true)-\(media?.imageEpoch ?? 0)") { await loadThumb() }
    }

    private var media: MediaOps? { model.media }

    private var stateValue: String {
        if body_?.expired == true { return "expired" }
        if fileId == nil { return "local" }
        switch load {
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .undecodable: return "undecodable"
        case .failed: return "failed"
        case .unavailable: return "unavailable"
        }
    }

    @ViewBuilder private func content(_ size: CGSize) -> some View {
        if body_?.expired == true {
            caption("图片已过期", "image-expired")
        } else if let fileId {
            switch load {
            case .loaded:
                if let img = media?.cachedImage(fileId, .thumb) {
                    Image(decorative: img, scale: 1).resizable().scaledToFill().frame(width: size.width, height: size.height)
                }
            case .loading:
                EmptyView()
            case .undecodable, .unavailable:
                caption("图片无法显示", "image-undecodable")
            case .failed:
                Text("加载失败，点击重试")
                    .font(TTFont.caption)
                    .foregroundStyle(TC.brand)
                    .multilineTextAlignment(.center)
                    .padding(TS.s1)
                    .accessibilityIdentifier("image-retry")
            }
        }
    }

    private func caption(_ text: String, _ id: String) -> some View {
        Text(text)
            .font(TTFont.caption)
            .foregroundStyle(TC.textTertiary)
            .multilineTextAlignment(.center)
            .padding(TS.s1)
            .accessibilityIdentifier(id)
    }

    private func loadThumb() async {
        guard let fileId, body_?.expired != true, let media else { return }
        if media.cachedImage(fileId, .thumb) != nil {
            load = .loaded
            return
        }
        load = .loading
        load = await media.loadImage(fileId, .thumb, maxLong: thumbLongSide)
    }

    private func tapped() {
        guard fileId != nil, body_?.expired != true else { return }
        if load == .failed {
            attempt += 1
        } else {
            onOpen()
        }
    }
}

/// Full screen original (F-FILE-02 rules 6, 9): pinch to zoom, double tap to reset, save to Photos.
struct ImageViewer: View {
    let fileId: String
    let mime: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var load = ImageLoad.loading
    @State private var attempt = 0
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero
    @State private var saving = false
    @State private var denied = false

    var body: some View {
        ZStack {
            TC.bg.ignoresSafeArea()
            Group {
                switch load {
                case .loaded:
                    if let img = model.media?.cachedImage(fileId, .original) {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(zoom.simultaneously(with: pan))
                            .onTapGesture(count: 2) { reset() }
                            .accessibilityLabel("图片")
                            .accessibilityIdentifier("viewer-image")
                    }
                case .loading:
                    Spinner(size: 24).foregroundStyle(TC.textTertiary).accessibilityIdentifier("viewer-loading")
                case .undecodable, .unavailable:
                    Text("图片无法显示").font(TTFont.small).foregroundStyle(TC.textSecondary)
                        .accessibilityIdentifier("image-undecodable")
                case .failed:
                    Button("加载失败，点击重试") { attempt += 1 }
                        .font(TTFont.small)
                        .foregroundStyle(TC.brand)
                        .accessibilityIdentifier("viewer-retry")
                }
            }
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Icon(name: .close).foregroundStyle(TC.textPrimary)
                            .frame(width: Tokens.Size.touchMin, height: Tokens.Size.touchMin)
                    }
                    .accessibilityLabel("关闭")
                    .accessibilityIdentifier("viewer-close")
                    Spacer()
                    if load == .loaded {
                        Button("保存") { save() }
                            .font(TTFont.body)
                            .foregroundStyle(TC.brand)
                            .disabled(saving)
                            .frame(minWidth: Tokens.Size.touchMin, minHeight: Tokens.Size.touchMin)
                            .accessibilityIdentifier("viewer-save")
                    }
                }
                .padding(.horizontal, TS.s2)
                Spacer()
            }
            if denied { deniedDialog }
        }
        .overlay { ToastLayer() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("image-viewer")
        .task(id: attempt) {
            guard let media = model.media else { return }
            load = .loading
            load = await media.loadImage(fileId, .original, maxLong: originalLongSide)
        }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { scale = min(5, max(1, base * $0.magnification)) }
            .onEnded { _ in base = scale }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { v in
                guard scale > 1 else { return }
                offset = CGSize(width: dragBase.width + v.translation.width, height: dragBase.height + v.translation.height)
            }
            .onEnded { _ in dragBase = offset }
    }

    private func reset() {
        scale = 1
        base = 1
        offset = .zero
        dragBase = .zero
    }

    /// "没有相册权限" with a way to Settings when the system refuses (F-FILE-02 rule 9, 13.4).
    private var deniedDialog: some View {
        ZStack {
            TC.scrim.ignoresSafeArea().onTapGesture { denied = false }
            VStack(spacing: TS.s4) {
                Text("没有相册权限")
                    .font(TTFont.body)
                    .foregroundStyle(TC.textPrimary)
                    .accessibilityIdentifier("dialog-text")
                HStack(spacing: TS.s3) {
                    Button {
                        denied = false
                    } label: {
                        Text("取消").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TTButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("dialog-cancel")
                    Button {
                        denied = false
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Text("前往设置").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TTButtonStyle())
                    .accessibilityIdentifier("gallery-settings")
                }
            }
            .padding(TS.s4)
            .background(TC.surface, in: RoundedRectangle(cornerRadius: TR.lg))
            .padding(TS.s5)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("gallery-denied")
        }
    }

    private func save() {
        guard let file = model.media?.client.cachedFile(fileId: fileId, variant: .original) else { return }
        saving = true
        Task {
            defer { saving = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                denied = true
                return
            }
            // The cached file has no extension: a copy with one, so Photos knows the type.
            let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "jpg"
            let copy = MediaOps.shareDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            do {
                try FileManager.default.createDirectory(at: MediaOps.shareDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: copy)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: copy, options: nil)
                }
                model.hub.show("已保存到相册")
            } catch {
                model.hub.show(MediaOps.isNoSpace(error) ? storageFullText : "保存失败")
            }
            try? FileManager.default.removeItem(at: copy)
        }
    }
}

// MARK: File bubble (F-FILE-03 rule 3)

struct FileBubble: View {
    let message: Message
    let convId: String
    let isSelf: Bool
    @Environment(AppModel.self) private var model
    @State private var share: ShareItem?
    @State private var preview: ShareItem?

    private var body_: FileBody? { message.body.file }
    private var name: String { (body_?.name?.isEmpty == false ? body_?.name : nil) ?? "file" }
    private var sizeText: String { formatSize(body_?.size ?? 0) }
    private var expired: Bool { body_?.expired == true }
    private var media: MediaOps? { model.media }

    var body: some View {
        HStack(alignment: .top, spacing: TS.s3) {
            Text(fileTypeLabel(name))
                .font(TTFont.caption.weight(.semibold))
                .foregroundStyle(TC.brand)
                .frame(width: 44, height: 44)
                .background(TC.surfaceSelected, in: RoundedRectangle(cornerRadius: TR.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TS.s1) {
                // Plain text, middle truncation: the extension stays visible, no horizontal scroll (AC-FILE-03-4, 02-7).
                Text(verbatim: name)
                    .font(TTFont.body)
                    .foregroundStyle(TC.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityHidden(true)  // The bubble's label reads it: "文件 名字，大小" (13.4).
                    .accessibilityIdentifier("file-name")
                Text(expired ? "文件已过期" : sizeText)
                    .font(TTFont.caption)
                    .foregroundStyle(TC.textTertiary)
                    .accessibilityHidden(!expired)
                    .accessibilityIdentifier(expired ? "file-expired" : "file-size")
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(TS.s3)
        .frame(minWidth: 200)
        .background(TC.bubbleOtherBg, in: RoundedRectangle(cornerRadius: TR.lg))
        .overlay(RoundedRectangle(cornerRadius: TR.lg).stroke(TC.divider, lineWidth: 1))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: TR.lg))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(expired ? "文件 \(name)，已过期" : "文件 \(name)，\(sizeText)")
        .accessibilityValue(messageStatusValue(message.status))
        .accessibilityIdentifier("file-bubble")
        .onAppear { if let id = message.body.fileId, !expired { media?.checkCached(id) } }
        .sheet(item: $share) { item in ShareSheet(url: item.url).ignoresSafeArea() }
        .sheet(item: $preview) { item in QuickLookView(url: item.url).ignoresSafeArea() }
    }

    @ViewBuilder private var actions: some View {
        if let fileId = message.body.fileId, !expired, message.seq != nil {
            switch media?.downloads[fileId] {
            case nil:
                link("下载", "file-download") { download(fileId) }
            case .running(let n, let total):
                HStack(spacing: TS.s3) {
                    Text(verbatim: total.flatMap { $0 > 0 ? "下载中 \(min(100, n * 100 / $0))%" : nil } ?? "下载中…")
                        .font(TTFont.caption)
                        .foregroundStyle(TC.textSecondary)
                        .accessibilityIdentifier("file-downloading")
                    link("取消", "file-cancel-download") { media?.cancelDownload(fileId) }
                }
            case .failed:
                Button("下载失败，点击重试") { media?.startDownload(fileId) }
                    .font(TTFont.caption)
                    .foregroundStyle(TC.danger)
                    .accessibilityIdentifier("file-download-failed")
            case .done(let file):
                HStack(spacing: TS.s4) {
                    // pdf, txt and images may open; everything else can only be saved (F-FILE-03 rule 3, AC-FILE-03-9).
                    if canOpen(mime: body_?.mime, name: name) {
                        link("打开", "file-open") { preview = named(file).map(ShareItem.init) }
                    }
                    link("保存", "file-save") { share = named(file).map(ShareItem.init) }
                }
            }
        }
    }

    private func link(_ title: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(TTFont.caption)
            .foregroundStyle(TC.brand)
            .frame(minHeight: 28)
            .accessibilityIdentifier(id)
    }

    /// Others' files: the source prompt the first time in this conversation (F-FILE-05 rule 3, AC-FILE-05-3).
    private func download(_ fileId: String) {
        guard let media else { return }
        if isSelf || media.sourceAcked.contains(convId) {
            media.startDownload(fileId)
            return
        }
        let conv = convId
        model.hub.confirm(id: "source-dialog", text: sourceTip, ok: "下载") {
            media.ackSource(conv)
            media.startDownload(fileId)
        }
    }

    /// The cached download under its (cleaned) name, for the share sheet and Quick Look.
    private func named(_ file: URL) -> URL? {
        let clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let dir = MediaOps.shareDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let out = dir.appendingPathComponent(clean.isEmpty ? "file" : clean)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: out)
            return out
        } catch {
            model.hub.show(MediaOps.isNoSpace(error) ? storageFullText : "保存失败")
            return nil
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The share sheet hands a downloaded file out (13.2: "分享面板").
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// "打开": Quick Look, the system's own viewer, for the allowed types only.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let q = QLPreviewController()
        q.dataSource = context.coordinator
        return UINavigationController(rootViewController: q)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: Sending state under the bubble (13.4)

struct AttachmentStatus: View {
    let message: Message
    let convId: String
    @Environment(AppModel.self) private var model
    @Environment(IMStore.self) private var store

    var body: some View {
        if message.status == .failed {
            Text(attachmentErrorText(message))
                .font(TTFont.caption)
                .foregroundStyle(TC.danger)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("attach-error")
        } else if let text = attachmentStatusText(
            message.status, percent: message.status == .uploading ? model.media?.progress[message.clientMsgId] : nil)
        {
            HStack(spacing: TS.s3) {
                Text(verbatim: text)
                    .font(TTFont.caption)
                    .foregroundStyle(TC.textSecondary)
                    .accessibilityIdentifier("attach-status")
                // Cancelling stops the upload and sends DELETE; the message goes (AC-FILE-02-5, AC-FILE-01-17).
                Button("取消") { _ = store.client.cancelUpload(convId, message.clientMsgId) }
                    .font(TTFont.caption)
                    .foregroundStyle(TC.brand)
                    .frame(minHeight: 28)
                    .accessibilityIdentifier("attach-cancel")
            }
        }
    }
}
