import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct TrayView: View {
    @ObservedObject var tray: TrayStore
    let targeted: Bool
    private var menu = State<TrayMenuTarget?>(initialValue: nil)

    init(tray: TrayStore, targeted: Bool) {
        self.tray = tray
        self.targeted = targeted
    }

    var body: some View {
        HStack(spacing: 16) {
            if !tray.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(tray.files, id: \.self) { url in
                            TrayTile(url: url, remove: { tray.remove(url) }, onMenu: { menu.wrappedValue = .init(url: url, point: $0) })
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                }
            }
            DropZone(targeted: targeted, wide: tray.files.isEmpty)
                .frame(width: tray.files.isEmpty ? nil : 150)
                .trayDropMenu(tray: tray) { menu.wrappedValue = .init(url: nil, point: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear { tray.prune() }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .trayMenu(menu.binding, tray: tray)
    }
}

/// Ô thả file: viền nét đứt chạy vòng, mũi tên tải xuống.
private struct DropZone: View {
    let targeted: Bool
    let wide: Bool
    private var phase = State(initialValue: CGFloat(0))

    init(targeted: Bool, wide: Bool) {
        self.targeted = targeted
        self.wide = wide
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 14)
            .fill(Theme.isPixel ? Color(red: 0.1, green: 0.09, blue: 0.2) : .white.opacity(targeted ? 0.14 : 0.07))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 14)
                    .stroke(Theme.isPixel ? PixelPalette.border.opacity(targeted ? 1 : 0.85) : .white.opacity(targeted ? 0.95 : 0.6),
                            style: StrokeStyle(lineWidth: Theme.isPixel ? 4 : 1.6, dash: Theme.isPixel ? [8, 8] : [7, 5], dashPhase: phase.wrappedValue))
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.ui(22, weight: .semibold))
                        .foregroundStyle(Theme.isPixel ? Color(red: 1, green: 0.9, blue: 0.43) : Color.white)
                    Text(targeted || !wide ? L("Thả vào khay", "Drop here") : L("Kéo file lên notch để cất tạm", "Drag files onto the notch to keep them here"))
                        .font(.ui(12, weight: .bold))
                }
                .foregroundStyle(.white.opacity(targeted ? 1 : 0.85))
            )
            .scaleEffect(targeted ? 1.03 : 1)
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    phase.wrappedValue = Theme.isPixel ? -32 : -24  // đúng 2 chu kỳ dash (8+8 hoặc 7+5) để vòng lặp không giật
                }
            }
    }
}

private struct TrayTile: View {
    let url: URL
    let remove: () -> Void
    let onMenu: (CGPoint) -> Void
    private var hover = State(initialValue: false)

    init(url: URL, remove: @escaping () -> Void, onMenu: @escaping (CGPoint) -> Void) {
        self.url = url
        self.remove = remove
        self.onMenu = onMenu
    }

    var body: some View {
        VStack(spacing: 8) {
            if FileThumbnails.isVisual(url) {
                ThumbnailImage(url: url, size: CGSize(width: 72, height: 55)) { DocGlyph(url: url) }
                    .frame(width: 72, height: 55)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 6))
                    .overlay(RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 6)
                        .strokeBorder(Theme.isPixel ? PixelPalette.border : .white.opacity(0.25), lineWidth: Theme.isPixel ? 2 : 1))
                    .background(Rectangle().fill(Theme.isPixel ? PixelPalette.shadow : .clear).offset(x: 3, y: 3))
                    .shadow(color: .black.opacity(Theme.isPixel ? 0 : 0.4), radius: 6, y: 3)
            } else {
                DocGlyph(url: url)
            }
            Text(url.lastPathComponent.precomposedStringWithCanonicalMapping)  // tên file macOS ở dạng NFD → NFC để font hiện đủ dấu
                .font(.ui(11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hover.wrappedValue ? 0.08 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover.wrappedValue {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.ui(14))
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .offset(x: -8, y: 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .fileMenu(url: url, remove: remove, onThemed: onMenu)
        .help(url.path)
    }
}

/// Biểu tượng tài liệu góc gấp, màu theo loại file, ghi đuôi file (theo thiết kế README).
private struct DocGlyph: View {
    let url: URL

    var body: some View {
        ZStack(alignment: .bottom) {
            DocShape().fill(color)
            DocFold().fill(.white.opacity(0.45))
            Text(label)
                .font(.ui(9, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.bottom, 8)
        }
        .frame(width: 40, height: 55)
        .shadow(color: color.opacity(Theme.isPixel ? 0 : 0.35), radius: Theme.isPixel ? 0 : 8, y: 3)
    }

    private var label: String {
        if url.hasDirectoryPath { return "DIR" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }

    private var color: Color {
        if url.hasDirectoryPath { return Color(red: 0.39, green: 0.82, blue: 1.0) }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return Self.fallback }
        if type.conforms(to: .pdf) { return Color(red: 1.0, green: 0.35, blue: 0.32) }
        if type.conforms(to: .image) { return Color(red: 0.19, green: 0.69, blue: 0.35) }
        if type.conforms(to: .movie) { return Color(red: 0.66, green: 0.33, blue: 0.97) }
        if type.conforms(to: .audio) { return Color(red: 1.0, green: 0.31, blue: 0.55) }
        if type.conforms(to: .archive) { return Color(red: 0.56, green: 0.56, blue: 0.58) }
        if type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
            return Color(red: 1.0, green: 0.62, blue: 0.04)
        }
        if type.conforms(to: .sourceCode) || type.conforms(to: .text) || type.conforms(to: .json) {
            return Color(red: 0.04, green: 0.52, blue: 1.0)
        }
        return Self.fallback
    }

    private static let fallback = Color(red: 0.43, green: 0.48, blue: 0.85)
}

private struct DocShape: Shape {
    func path(in r: CGRect) -> Path {
        let fold: CGFloat = 12, c: CGFloat = 3
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct DocFold: Shape {
    func path(in r: CGRect) -> Path {
        let fold: CGFloat = 12
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY + fold - 3))
        p.addQuadCurve(to: CGPoint(x: r.maxX - fold + 3, y: r.minY + fold),
                       control: CGPoint(x: r.maxX - fold, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.closeSubpath()
        return p
    }
}

/// Menu chuột phải của 1 file trong khay: mở, Finder, AirDrop, Chia sẻ (dịch vụ của macOS), gỡ.
struct ShareMenu: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        Button(L("Mở", "Open")) { NSWorkspace.shared.open(url) }
        Button(L("Hiện trong Finder", "Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Divider()
        Button("AirDrop") {
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
        }
        Menu(L("Chia sẻ", "Share")) {
            ForEach(NSSharingService.sharingServices(forItems: [url]), id: \.title) { service in
                Button {
                    service.perform(withItems: [url])
                } label: {
                    Label { Text(service.title) } icon: { Image(nsImage: service.image) }
                }
            }
        }
        Divider()
        Button(L("Gỡ khỏi khay", "Remove from tray"), action: remove)
    }
}

// MARK: - Menu chuột phải theo theme

/// Menu đang mở: của 1 file (url) hoặc của ô thả (url = nil), tại vị trí chuột (toạ độ .global).
struct TrayMenuTarget: Equatable {
    let url: URL?
    let point: CGPoint
}

extension State where Value == TrayMenuTarget? {
    var binding: Binding<TrayMenuTarget?> { projectedValue }
}

extension View {
    /// Theme mặc định: menu gốc macOS. Pixel / Cassette: bắt chuột phải để hiện ThemedMenu.
    @ViewBuilder func fileMenu(url: URL, remove: @escaping () -> Void, onThemed: @escaping (CGPoint) -> Void) -> some View {
        if Theme.current == .standard {
            contextMenu { ShareMenu(url: url, remove: remove) }
        } else {
            overlay { RightClickCatcher(action: onThemed) }
        }
    }

    @ViewBuilder func trayDropMenu(tray: TrayStore, onThemed: @escaping (CGPoint) -> Void) -> some View {
        if Theme.current == .standard {
            contextMenu {
                if !tray.files.isEmpty {
                    Button(L("AirDrop tất cả", "AirDrop all")) {
                        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: tray.files)
                    }
                    Divider()
                    Button(L("Xoá hết khay (file gốc không bị xoá)", "Clear tray (files stay on disk)")) { tray.clear() }
                }
            }
        } else {
            overlay { if !tray.files.isEmpty { RightClickCatcher(action: onThemed) } }
        }
    }

    func trayMenu(_ target: Binding<TrayMenuTarget?>, tray: TrayStore) -> some View {
        modifier(TrayMenuOverlay(target: target, tray: tray))
    }
}

private struct TrayMenuOverlay: ViewModifier {
    @Binding var target: TrayMenuTarget?
    @ObservedObject var tray: TrayStore

    func body(content: Content) -> some View {
        content
            .overlay {
                if let t = target {
                    GeometryReader { geo in
                        let frame = geo.frame(in: .global)
                        let items = menuItems(t)
                        let h = ThemedMenu.height(items)
                        let x = min(max(t.point.x - frame.minX + 4, 4), frame.width - ThemedMenu.width - 4)
                        let y = min(max(t.point.y - frame.minY + 4, 4), frame.height - h - 4)
                        ZStack(alignment: .topLeading) {
                            // bấm ra ngoài để đóng
                            Color.black.opacity(0.001)
                                .onTapGesture { target = nil }
                            ThemedMenu(items: items) { target = nil }
                                .offset(x: x, y: y)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .onDisappear { target = nil }
            .onChange(of: tray.files) { _, files in
                if let url = target?.url, !files.contains(url) { target = nil }
            }
    }

    private func menuItems(_ t: TrayMenuTarget) -> [ThemedMenu.Item] {
        guard let url = t.url else {
            return [
                .init(title: L("AirDrop tất cả", "AirDrop all"), action: {
                    NSSharingService(named: .sendViaAirDrop)?.perform(withItems: tray.files)
                }),
                .init(title: "", action: nil),
                .init(title: L("Xoá hết khay", "Clear tray"), action: { tray.clear() }),
            ]
        }
        return [
            .init(title: L("Mở", "Open"), action: { NSWorkspace.shared.open(url) }),
            .init(title: L("Hiện trong Finder", "Show in Finder"), action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
            .init(title: "", action: nil),
            .init(title: "AirDrop", action: { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url]) }),
            .init(title: L("Chia sẻ…", "Share…"), action: { showSharePicker(url) }),
            .init(title: "", action: nil),
            .init(title: L("Gỡ khỏi khay", "Remove from tray"), action: { tray.remove(url) }),
        ]
    }

    /// Bảng chia sẻ của macOS, neo tại vị trí chuột trên cửa sổ notch.
    private func showSharePicker(_ url: URL) {
        guard let view = NSApp.windows.first(where: { $0 is NotchPanel && !$0.ignoresMouseEvents })?.contentView, let window = view.window else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        NSSharingServicePicker(items: [url]).show(relativeTo: NSRect(origin: point, size: .init(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }
}

// MARK: - Ảnh xem trước

/// Ảnh xem trước của file ảnh / video qua QuickLook (cache theo đường dẫn + ngày sửa).
@MainActor
enum FileThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func isVisual(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    private static func key(_ url: URL, _ size: CGSize) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

    static func cached(_ url: URL, size: CGSize) -> NSImage? { cache.object(forKey: key(url, size)) }

    static func load(_ url: URL, size: CGSize) async -> NSImage? {
        let k = key(url, size)
        if let hit = cache.object(forKey: k) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size,
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: k)
        return image
    }
}

/// Ảnh xem trước lấp đầy khung; chưa có (đang tải / không tạo được) thì hiện placeholder.
struct ThumbnailImage<Placeholder: View>: View {
    let url: URL
    let size: CGSize
    let placeholder: Placeholder
    private var image: State<NSImage?>

    init(url: URL, size: CGSize, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.size = size
        self.placeholder = placeholder()
        image = State(initialValue: FileThumbnails.cached(url, size: size))
    }

    var body: some View {
        Group {
            if let img = image.wrappedValue {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: url) { image.wrappedValue = await FileThumbnails.load(url, size: size) }
    }
}
