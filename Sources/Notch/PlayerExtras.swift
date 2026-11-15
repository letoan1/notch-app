import AppKit
import SwiftUI

/// Icon ứng dụng đang phát nhạc (lấy từ NSWorkspace, nhớ lại theo bundle id).
enum SourceAppIcon {
    /// Tắt trong Cài đặt thì không hiện huy hiệu nào.
    static let key = "player.sourceIcon"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for bundleID: String) -> NSImage? {
        if let hit = cache.object(forKey: bundleID as NSString) { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: bundleID as NSString)
        return image
    }
}

/// Huy hiệu icon app ở góc ảnh bìa. Bấm để mở app đó.
struct SourceBadge: View {
    let bundleID: String
    var size: CGFloat = 26
    let open: () -> Void
    private var enabled = AppStorage(wrappedValue: true, SourceAppIcon.key)

    init(bundleID: String, size: CGFloat = 26, open: @escaping () -> Void) {
        self.bundleID = bundleID
        self.size = size
        self.open = open
    }

    var body: some View {
        if enabled.wrappedValue, let icon = SourceAppIcon.icon(for: bundleID) {
            badge(icon)
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
        }
    }

    @ViewBuilder
    private func badge(_ icon: NSImage) -> some View {
        if Theme.isPixel {
            Image(nsImage: icon.pixelated(16))
                .resizable().interpolation(.none)
                .frame(width: size - 6, height: size - 6)
                .padding(2)
                .background(Rectangle().fill(PixelPalette.shadow))
                .overlay(Rectangle().strokeBorder(PixelPalette.border, lineWidth: 2))
        } else if Theme.isCassette {
            // Nhãn dán: giấy vàng, hơi nghiêng, có băng keo.
            Image(nsImage: icon).resizable()
                .frame(width: size - 6, height: size - 6)
                .padding(3)
                .background(Rectangle().fill(CassettePalette.note).shadow(color: .black.opacity(0.35), radius: 2, x: 1, y: 2))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.55)).frame(width: size * 0.55, height: 5).offset(y: -2)
                }
                .rotationEffect(.degrees(-7))
        } else if Theme.isVanGogh {
            Image(nsImage: icon).resizable()
                .frame(width: size - 4, height: size - 4)
                .padding(2)
                .background(Circle().fill(VG.navy))
                .overlay(Circle().stroke(VG.yellow, lineWidth: 2.2))
                .overlay(Circle().stroke(VG.ink, lineWidth: 0.8).padding(-1.2))
        } else {
            Image(nsImage: icon).resizable()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        }
    }
}

/// Nút trộn bài / lặp lại theo giao diện. Bật: sáng + chấm nhỏ; tắt: mờ.
struct ModeButton: View {
    enum Kind { case shuffle, repeatMode }
    let kind: Kind
    let modes: PlayModes
    var compact = false
    /// Kiểu trắng trung tính (màn hình khoá, lời toàn màn hình) dù đang ở giao diện nào.
    var plain = false
    var side: CGFloat? = nil
    let action: () -> Void
    private var hover = State(initialValue: false)

    init(kind: Kind, modes: PlayModes, compact: Bool = false, plain: Bool = false, side: CGFloat? = nil,
         action: @escaping () -> Void) {
        self.kind = kind
        self.modes = modes
        self.compact = compact
        self.plain = plain
        self.side = side
        self.action = action
    }

    private var on: Bool { kind == .shuffle ? modes.shuffle : modes.repeatMode != .off }
    private var symbol: String {
        if kind == .shuffle { return "shuffle" }
        return modes.repeatMode == .one ? "repeat.1" : "repeat"
    }
    private var label: String {
        switch kind {
        case .shuffle: return modes.shuffle ? L("Trộn bài: bật", "Shuffle: on") : L("Trộn bài: tắt", "Shuffle: off")
        case .repeatMode:
            switch modes.repeatMode {
            case .off: return L("Lặp lại: tắt", "Repeat: off")
            case .all: return L("Lặp cả danh sách", "Repeat all")
            case .one: return L("Lặp một bài", "Repeat one")
            }
        }
    }

    var body: some View {
        let side: CGFloat = self.side ?? (compact ? 22 : 26)
        Button(action: action) {
            face(side: side)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func face(side: CGFloat) -> some View {
        let glyph = Image(systemName: symbol).font(.system(size: side * 0.48, weight: .bold))
        if plain {
            glyph
                .foregroundStyle(.white.opacity(on ? 1 : (hover.wrappedValue ? 0.75 : 0.45)))
                .frame(width: side, height: side)
                .overlay(alignment: .bottom) {
                    if on { Circle().fill(.white).frame(width: 4, height: 4).offset(y: 4) }
                }
        } else if Theme.isPixel {
            glyph
                .foregroundStyle(on ? Color.black : PixelPalette.border.opacity(0.75))
                .frame(width: side, height: side)
                .background(Rectangle().fill(on ? PixelPalette.pink : Color.clear))
                .overlay(Rectangle().strokeBorder(on ? PixelPalette.pink : PixelPalette.border.opacity(0.5), lineWidth: 2))
        } else if Theme.isCassette {
            glyph
                .foregroundStyle(on ? CassettePalette.marker : CassettePalette.ink.opacity(0.75))
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? CassettePalette.keyDown : CassettePalette.key))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.48, green: 0.42, blue: 0.32)))
        } else if Theme.isVanGogh {
            glyph
                .foregroundStyle(on ? VG.ink : VG.cream.opacity(0.85))
                .frame(width: side, height: side)
                .background(Circle().fill(on ? VG.yellow : VG.navy.opacity(0.85)))
                .overlay(Circle().stroke(on ? VG.ink : VG.cream.opacity(0.5), lineWidth: 1.4))
        } else {
            glyph
                .foregroundStyle(.white.opacity(on ? 1 : (hover.wrappedValue ? 0.75 : 0.45)))
                .frame(width: side, height: side)
                .overlay(alignment: .bottom) {
                    if on { Circle().fill(.white).frame(width: 3.5, height: 3.5).offset(y: 3) }
                }
        }
    }
}
