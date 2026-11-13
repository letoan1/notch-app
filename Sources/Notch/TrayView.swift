import SwiftUI
import UniformTypeIdentifiers

struct TrayView: View {
    @ObservedObject var tray: TrayStore
    let targeted: Bool

    var body: some View {
        HStack(spacing: 16) {
            if !tray.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(tray.files, id: \.self) { url in
                            TrayTile(url: url) { tray.remove(url) }
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                }
            }
            DropZone(targeted: targeted, wide: tray.files.isEmpty)
                .frame(width: tray.files.isEmpty ? nil : 150)
                .contextMenu {
                    if !tray.files.isEmpty {
                        Button(L("AirDrop tất cả", "AirDrop all")) {
                            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: tray.files)
                        }
                        Divider()
                        Button(L("Xoá hết khay (file gốc không bị xoá)", "Clear tray (files stay on disk)")) { tray.clear() }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear { tray.prune() }
        .animation(.easeOut(duration: 0.15), value: targeted)
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
        RoundedRectangle(cornerRadius: 14)
            .fill(.white.opacity(targeted ? 0.14 : 0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(targeted ? 0.95 : 0.6),
                            style: StrokeStyle(lineWidth: 1.6, dash: [7, 5], dashPhase: phase.wrappedValue))
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.ui(22, weight: .semibold))
                    Text(targeted || !wide ? L("Thả vào khay", "Drop here") : L("Kéo file lên notch để cất tạm", "Drag files onto the notch to keep them here"))
                        .font(.ui(12, weight: .bold))
                }
                .foregroundStyle(.white.opacity(targeted ? 1 : 0.85))
            )
            .scaleEffect(targeted ? 1.03 : 1)
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    phase.wrappedValue = -24
                }
            }
    }
}

private struct TrayTile: View {
    let url: URL
    let remove: () -> Void
    private var hover = State(initialValue: false)

    init(url: URL, remove: @escaping () -> Void) {
        self.url = url
        self.remove = remove
    }

    var body: some View {
        VStack(spacing: 8) {
            DocGlyph(url: url)
            Text(url.lastPathComponent)
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
        .contextMenu { ShareMenu(url: url, remove: remove) }
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
        .shadow(color: color.opacity(0.35), radius: 8, y: 3)
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
