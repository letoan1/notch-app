import SwiftUI

struct TrayView: View {
    @ObservedObject var tray: TrayStore
    let targeted: Bool

    var body: some View {
        Group {
            if tray.files.isEmpty {
                DropHint(targeted: targeted)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tray.files, id: \.self) { url in
                                TrayTile(url: url) { tray.remove(url) }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    Button { tray.clear() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Xoá hết khay (file gốc không bị xoá)")
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(targeted ? 0.5 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onAppear { tray.prune() }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

private struct DropHint: View {
    let targeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(Color.white.opacity(targeted ? 0.7 : 0.22), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(targeted ? 0.08 : 0)))
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: targeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                        .font(.system(size: 20))
                    Text(targeted ? "Thả vào khay" : "Kéo file lên notch để cất tạm")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(targeted ? 0.9 : 0.5))
            )
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
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 66)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hover.wrappedValue ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover.wrappedValue {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85), .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path)
    }
}
