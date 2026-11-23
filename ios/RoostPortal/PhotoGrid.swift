import SwiftUI
import Photos
import UIKit
import Combine

// MARK: - Thư viện ảnh

final class PhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Cả thư viện, mới nhất trước. Giữ PHFetchResult (tải lười) thay vì mảng, thư viện vài chục nghìn ảnh vẫn nhẹ.
    @Published var result: PHFetchResult<PHAsset>?
    var count: Int { result?.count ?? 0 }
    func asset(_ i: Int) -> PHAsset { result!.object(at: i) }
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    let images: PHCachingImageManager = {
        let m = PHCachingImageManager()
        m.allowsCachingHighQualityImages = false
        return m
    }()

    enum Filter: CaseIterable { case all, photos, videos, screenshots
        var title: String {
            switch self {
            case .all: return L("Tất cả", "All")
            case .photos: return L("Ảnh", "Photos")
            case .videos: return L("Video", "Videos")
            case .screenshots: return L("Chụp màn hình", "Screenshots")
            }
        }
    }
    @Published var filter: Filter = .all { didSet { if filter != oldValue { refetch() } } }

    func load() async {
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { return }
        refetch()
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
    }
    private var observing = false

    /// Chụp ảnh mới, xoá ảnh, đồng bộ iCloud: cập nhật lưới ngay (PhotoKit gọi trên luồng nền).
    nonisolated func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor in
            guard let current = self.result, let details = change.changeDetails(for: current) else { return }
            self.result = details.fetchResultAfterChanges
        }
    }

    private func refetch() {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        switch filter {
        case .all: result = PHAsset.fetchAssets(with: opts)
        case .photos: result = PHAsset.fetchAssets(with: .image, options: opts)
        case .videos: result = PHAsset.fetchAssets(with: .video, options: opts)
        case .screenshots:
            // Lọc theo cờ ảnh chụp màn hình của từng ảnh (album thông minh Ảnh chụp màn hình có lúc không trả về).
            opts.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
            result = PHAsset.fetchAssets(with: .image, options: opts)
        }

    }

    /// Xuất bản gốc ra file tạm (ảnh HEIC / JPEG, video MOV) để gửi nguyên chất lượng.
    /// progress: tiến độ tải bản gốc từ iCloud (0..1), chỉ gọi khi ảnh / video chưa có sẵn trên máy.
    func export(_ asset: PHAsset, progress: @escaping (Double) -> Void = { _ in }) async throws -> (URL, String) {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let res = preferred.lazy.compactMap({ t in resources.first { $0.type == t } }).first ?? resources.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(res.originalFilename)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true   // ảnh chỉ có trên iCloud thì tải về trước
        opts.progressHandler = { p in DispatchQueue.main.async { progress(p) } }
        try await PHAssetResourceManager.default().writeData(for: res, toFile: url, options: opts)
        return (url, res.originalFilename)
    }
}

// MARK: - Ô ảnh

/// Ảnh đang được nhấc và ảnh đang chọn (chỉ đổi khi nhấc / thả / chạm, không đổi theo từng bước ngón tay).
final class Lifted: ObservableObject {
    @Published var id: String?
    @Published var selecting = false
    @Published var picked: [String] = []      // theo thứ tự chạm

    func toggle(_ id: String) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
    }
    /// Ảnh đã chọn, giữ đúng thứ tự chạm.
    func pickedAssets() -> [PHAsset] {
        let r = PHAsset.fetchAssets(withLocalIdentifiers: picked, options: nil)
        var byID: [String: PHAsset] = [:]
        r.enumerateObjects { a, _, _ in byID[a.localIdentifier] = a }
        return picked.compactMap { byID[$0] }
    }
}

struct PhotoCell: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let side: CGFloat
    @ObservedObject var lifted: Lifted
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Theme.surface
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: side, height: side).clipped()
                    .allowsHitTesting(false)
            }
            if asset.mediaType == .video {
                Text(Self.duration(asset.duration))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .shadow(radius: 2).padding(5)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Ảnh dọc phóng lấp ô bị tràn ra ngoài (chỉ cắt phần vẽ, không cắt vùng chạm): giới hạn vùng chạm đúng ô.
        .contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if lifted.selecting {
                let n = lifted.picked.firstIndex(of: asset.localIdentifier)
                ZStack {
                    Circle().fill(n == nil ? Color.black.opacity(0.25) : Color.accentColor)
                    Circle().stroke(.white, lineWidth: 1.5)
                    if let n { Text("\(n + 1)").font(.caption2.weight(.bold)).foregroundStyle(.white) }
                }
                .frame(width: 22, height: 22).padding(6)
            }
        }
        .overlay {
            if lifted.picked.contains(asset.localIdentifier) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.glow, lineWidth: 3)
            }
        }
        .opacity(lifted.id == asset.localIdentifier ? 0.25 : 1)
        .onAppear { load() }
        .onDisappear {   // cuộn nhanh: huỷ ảnh chưa kịp tải của ô đã trôi qua
            if let request { library.images.cancelImageRequest(request) }
            request = nil
        }
    }

    /// Ảnh thu nhỏ, cắt nhanh.
    private func load() {
        guard image == nil else { return }
        let px = side * UIScreen.main.scale
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true    // ảnh chỉ có trên iCloud vẫn hiện; cuộn qua thì bị huỷ ở onDisappear
        request = library.images.requestImage(for: asset, targetSize: CGSize(width: px, height: px),
                                              contentMode: .aspectFill, options: opts) { img, _ in
            if let img { image = img }
        }
    }

    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Kéo và hất

/// Ảnh đang được nhấc lên. Toạ độ global (cả màn hình).
final class DragState: ObservableObject {
    @Published var asset: PHAsset?
    @Published var count = 1                  // số ảnh đang cầm (nhấc ảnh đã chọn thì cầm cả chồng)
    @Published var image: UIImage?
    @Published var location: CGPoint = .zero
    @Published var size: CGSize = .zero
    @Published var tilt: Double = 0
    @Published var home: CGPoint = .zero      // tâm ô gốc, để thả không đủ lực thì bay về chỗ cũ
    var velocityX: CGFloat = 0                 // pt/s, làm mượt theo các bước gần nhất
    var lastStamp: TimeInterval = 0

    var active: Bool { asset != nil }
    /// Độ gần mép trái 0..1 (để vệt sáng mép trái mạnh dần).
    var nearEdge: Double { active ? max(0, min(1, 1 - Double(location.x) / 200)) : 0 }
}

/// Lớp vẽ ảnh đang nhấc bay theo ngón tay, và vệt sáng ở mép trái chỉ về phía Mac.
struct DragOverlay: View {
    @ObservedObject var drag: DragState
    let macName: String

    var body: some View {
        ZStack(alignment: .leading) {
            if drag.active {
                LinearGradient(colors: [Theme.glow.opacity(0.2 + 0.6 * drag.nearEdge), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 70 + 60 * drag.nearEdge)
                    .ignoresSafeArea()
                    .overlay(alignment: .leading) {
                        Text(L("Hất về \(macName)", "Fling to \(macName)"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .rotationEffect(.degrees(-90))
                            .fixedSize()
                            .offset(x: -36)
                            .opacity(0.4 + 0.6 * drag.nearEdge)
                    }
                    .transition(.opacity)
            }
            if drag.active && drag.count > 1 {
                Text("\(drag.count)").font(.footnote.weight(.bold)).foregroundStyle(.black)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.glow, in: Capsule())
                    .position(x: drag.location.x + drag.size.width / 2, y: drag.location.y - drag.size.height / 2 - 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: drag.active)
    }
}

/// Nhấn giữ bằng UILongPressGestureRecognizer: không chặn cuộn (di chuyển trước 0,25 s thì là cuộn),
/// nhấc lên rồi thì vẫn theo dõi ngón tay cho tới khi thả.
struct LiftGesture: UIGestureRecognizerRepresentable {
    var began: (_ local: CGPoint, _ global: CGPoint) -> Void
    var moved: (_ global: CGPoint) -> Void
    var ended: (_ global: CGPoint, _ cancelled: Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.25
        return g
    }

    func handleUIGestureRecognizerAction(_ r: UILongPressGestureRecognizer, context: Context) {
        let global = context.converter.location(in: .global)
        switch r.state {
        case .began: began(context.converter.localLocation, global)
        case .changed: moved(global)
        case .ended: ended(global, false)
        case .cancelled, .failed: ended(global, true)
        default: break
        }
    }
}

struct PhotoGrid: View {
    @ObservedObject var library: PhotoLibrary
    let drag: DragState                 // không quan sát: lưới không vẽ lại theo ngón tay
    @ObservedObject var lifted: Lifted
    /// Gọi khi hất đủ lực: các ảnh, độ cao ngón tay (0..1).
    let fling: ([PHAsset], Double) -> Void

    var header: AnyView = AnyView(EmptyView())
    /// Chạm một ảnh (khi không ở chế độ chọn): mở xem toàn màn hình.
    var open: (PHAsset) -> Void = { _ in }
    private let gap: CGFloat = 6
    private let pad: CGFloat = 12
    private var side: CGFloat { (UIScreen.main.bounds.width - pad * 2 - gap * 2) / 3 }

    var body: some View {
        ScrollView {
            header
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: gap), count: 3), spacing: gap) {
                ForEach(0..<library.count, id: \.self) { i in
                    let asset = library.asset(i)
                    PhotoCell(asset: asset, library: library, side: side, lifted: lifted)
                        .id(asset.localIdentifier)
                        .onTapGesture { if lifted.selecting { lifted.toggle(asset.localIdentifier) } else { open(asset) } }
                }
            }
            .gesture(LiftGesture(began: begin, moved: move, ended: end))
            .padding(.horizontal, pad)
            .padding(.bottom, 120)
        }
        .scrollDisabled(lifted.id != nil)
    }

    /// Ô dưới ngón tay, tính từ toạ độ trong lưới (lưới cố định 3 cột).
    private func cell(at local: CGPoint) -> (PHAsset, CGPoint)? {
        let col = Int(local.x / (side + gap)), row = Int(local.y / (side + gap))
        let i = row * 3 + col
        guard col >= 0, col < 3, row >= 0, i < library.count else { return nil }
        let center = CGPoint(x: CGFloat(col) * (side + gap) + side / 2, y: CGFloat(row) * (side + gap) + side / 2)
        return (library.asset(i), center)
    }

    private static let liftHaptic = UIImpactFeedbackGenerator(style: .medium)
    private static let sendHaptic = UINotificationFeedbackGenerator()

    private func begin(_ local: CGPoint, _ global: CGPoint) {
        guard let (asset, center) = cell(at: local) else { return }
        Self.liftHaptic.impactOccurred()
        Self.sendHaptic.prepare()
        let s = side * 1.25
        drag.size = CGSize(width: s, height: s * 0.75)
        drag.home = CGPoint(x: global.x + center.x - local.x, y: global.y + center.y - local.y)
        drag.location = global
        drag.velocityX = 0
        drag.lastStamp = CACurrentMediaTime()
        drag.asset = asset
        drag.count = lifted.picked.contains(asset.localIdentifier) ? lifted.picked.count : 1
        lifted.id = asset.localIdentifier
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        let thumb = library.images.requestImage(for: asset, targetSize: CGSize(width: 600, height: 450), contentMode: .aspectFill,
                                    options: opts) { img, _ in if let img { drag.image = img; PaperStage.shared.setImage(img) } }
        _ = thumb
        PaperStage.shared.show(image: drag.image, size: drag.size, at: global)
    }

    private func move(_ p: CGPoint) {
        guard drag.active else { return }
        let now = CACurrentMediaTime(), dt = max(now - drag.lastStamp, 1.0 / 240)
        let v = (p.x - drag.location.x) / dt
        drag.velocityX = drag.velocityX * 0.6 + v * 0.4
        drag.lastStamp = now
        drag.location = p
        drag.tilt = max(-35, min(35, Double(drag.velocityX) / 60))
        PaperStage.shared.update(at: p, near: drag.nearEdge, tilt: drag.tilt)
        Portal.shared.hover(y: Double(p.y / UIScreen.main.bounds.height), near: drag.nearEdge, phase: "move")
    }

    private func end(_ p: CGPoint, _ cancelled: Bool) {
        guard let asset = drag.asset else { return }
        if !cancelled && (p.x < 70 || drag.velocityX < -900) {
            throwLeft(asset, at: p, velocity: drag.velocityX)
        } else {
            drop()
        }
    }

    private func drop() {
        Portal.shared.hover(y: 0, near: 0, phase: "cancel")
        PaperStage.shared.drop(to: drag.home) { clear() }
    }

    private func throwLeft(_ asset: PHAsset, at p: CGPoint, velocity: CGFloat) {
        Self.sendHaptic.notificationOccurred(.success)
        let entry = Double(p.y / UIScreen.main.bounds.height)
        Portal.shared.hover(y: entry, near: 1, phase: "fling")
        let speed = max(900, -velocity)
        let duration = min(0.35, max(0.12, Double((p.x + drag.size.width) / speed)))
        PaperStage.shared.fling(to: CGPoint(x: -drag.size.width, y: p.y - 30), duration: duration) {}
        clear()
        if lifted.picked.contains(asset.localIdentifier) {
            fling(lifted.pickedAssets(), entry)
            lifted.picked = []
            lifted.selecting = false
        } else {
            fling([asset], entry)
        }
    }

    private func clear() {
        drag.asset = nil
        drag.image = nil
        drag.tilt = 0
        drag.count = 1
        lifted.id = nil
    }
}
