import SwiftUI
import TiantingIM

/// Changing the avatar (F-ACC-06 rule 3, AC-ACC-06-6): "我" page avatar → PHPicker, one image → a square crop (drag, pinch)
/// → 512 × 512 JPEG → kind=avatar → PATCH profile. Account sessions with `features.files` only.
struct AvatarEditor: ViewModifier {
    @Binding var active: Bool
    @Environment(AppModel.self) private var model
    @State private var picking = false
    @State private var image: CropSource?

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, on in
                guard on else { return }
                active = false
                if let items = testPicked(.images) {
                    picked(Array(items.prefix(1)))
                } else {
                    picking = true
                }
            }
            .sheet(isPresented: $picking) {
                PhotoPicker(limit: 1) { picked($0) }.ignoresSafeArea()
            }
            .fullScreenCover(item: $image) { src in
                AvatarCropPage(source: src) { image = nil }.environment(model)
            }
    }

    private func picked(_ results: [Result<Picked, PickFailed>]) {
        picking = false
        guard let first = results.first else { return }
        guard case .success(let p) = first else {
            if case .failure(let e) = first { model.hub.show(e.storage ? storageFullText : "无法处理这张图片，请换一张") }
            return
        }
        Task {
            let decoded = await Task.detached(priority: .userInitiated) {
                try? ImageProcessing.upright(p.file, maxLong: 2048)
            }.value
            try? FileManager.default.removeItem(at: p.file)
            guard let decoded else {
                model.hub.show("无法处理这张图片，请换一张")
                return
            }
            image = CropSource(image: decoded)
        }
    }
}

struct CropSource: Identifiable {
    let id = UUID()
    let image: CGImage
}

struct AvatarCropPage: View {
    let source: CropSource
    let onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetBase: CGSize = .zero
    @State private var saving = false

    private var w: CGFloat { CGFloat(source.image.width) }
    private var h: CGFloat { CGFloat(source.image.height) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 2 * TS.s4, 360)
            VStack(spacing: TS.s5) {
                Text("裁剪头像").font(TTFont.title).foregroundStyle(TC.textPrimary).accessibilityAddTraits(.isHeader)
                cropArea(side)
                HStack(spacing: TS.s3) {
                    Button {
                        onClose()
                    } label: {
                        Text("取消").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TTButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("avatar-cancel")
                    Button {
                        save(side)
                    } label: {
                        Text(saving ? "保存中…" : "保存").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TTButtonStyle())
                    .disabled(saving)
                    .accessibilityIdentifier("avatar-save")
                }
                .frame(width: side)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TC.bg.ignoresSafeArea())
        .overlay { ToastLayer() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("avatar-crop")
    }

    /// Points per pixel at zoom 1: the image covers the square.
    private func base(_ side: CGFloat) -> CGFloat { side / min(w, h) }

    private func clamp(_ o: CGSize, _ side: CGFloat, _ z: CGFloat) -> CGSize {
        let k = base(side) * z
        let mx = max(0, (w * k - side) / 2)
        let my = max(0, (h * k - side) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    private func cropArea(_ side: CGFloat) -> some View {
        let k = base(side) * zoom
        return Image(decorative: source.image, scale: 1)
            .resizable()
            .frame(width: w * k, height: h * k)
            .offset(offset)
            .frame(width: side, height: side)
            .clipped()
            .overlay(Circle().stroke(TC.onBrand, lineWidth: 2).allowsHitTesting(false))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        offset = clamp(
                            CGSize(width: offsetBase.width + v.translation.width, height: offsetBase.height + v.translation.height),
                            side, zoom)
                    }
                    .onEnded { _ in offsetBase = offset }
                    .simultaneously(
                        with: MagnifyGesture()
                            .onChanged { v in
                                zoom = min(5, max(1, zoomBase * v.magnification))
                                offset = clamp(offset, side, zoom)
                            }
                            .onEnded { _ in
                                zoomBase = zoom
                                offsetBase = offset
                            })
            )
            .accessibilityElement()
            .accessibilityLabel("拖动和双指缩放选择头像范围")
            .accessibilityIdentifier("avatar-crop-area")
    }

    private func save(_ side: CGFloat) {
        let k = base(side) * zoom
        let px = Int((side / k).rounded())
        let x = Int(((w * k - side) / 2 - offset.width) / k)
        let y = Int(((h * k - side) / 2 - offset.height) / k)
        let image = source.image
        saving = true
        Task {
            defer { saving = false }
            let out = MediaOps.avatarDir.appendingPathComponent("\(UUID().uuidString).jpg")
            let made = await Task.detached(priority: .userInitiated) {
                try? ImageProcessing.avatar(image, x: x, y: y, side: px, out: out)
            }.value
            guard let made else {
                model.hub.show("无法处理这张图片，请换一张")
                return
            }
            do {
                try await model.changeAvatar(made)
                try? FileManager.default.removeItem(at: made)
                model.hub.show("头像已更新")
                onClose()
            } catch {
                try? FileManager.default.removeItem(at: made)
                // F-ACC-06's exceptions: the avatar was not changed (5032, 4048 ...).
                model.hub.show(MediaOps.isNoSpace(error) ? storageFullText : "头像没有修改成功，请稍后重试")
            }
        }
    }
}
