import AppKit
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case media, tray, mirror

        var title: String {
            switch self {
            case .media: return L("Nhạc và lịch", "Music and calendar")
            case .tray: return L("Khay file", "File tray")
            case .mirror: return L("Gương camera", "Camera mirror")
            }
        }
        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .tray: return "tray.full.fill"
            case .mirror: return "camera.fill"
            }
        }
    }

    @Published var expanded = false
    @Published var tab: Tab = .media
    /// Đang có file kéo lơ lửng trên notch.
    @Published var dropTargeted = false
    @Published private(set) var notchSize = CGSize(width: 190, height: 32)

    static let expandedWidth: CGFloat = 620
    /// Tỉ lệ notch mở theo Cài đặt (Gọn / Vừa / Rộng).
    static var scale: CGFloat { SettingsStore.shared.expandedSize.scale }
    static let normalBodyHeight: CGFloat = 154
    static let tallBodyHeight: CGFloat = 222

    struct ChargePeek: Equatable {
        let percent: Int
        let charging: Bool
    }

    /// Thông báo nhanh ở 2 cánh notch vài giây (kiểu iPhone): cắm sạc, kết nối tai nghe.
    enum Peek: Equatable {
        case charge(ChargePeek)
        case audio(name: String, symbol: String)
        case screenshot(NSImage?)
        /// Vừa mở khoá máy: quét → ✓ + "Chào <tên>".
        case unlocked(String)

        var wing: CGFloat {
            switch self {
            case .charge, .screenshot: return 80
            case .unlocked: return 96
            case .audio: return 118
            }
        }
    }

    @Published var peek: Peek?
    /// Nhịp "nuốt" ngắn khi file bay vào khay.
    @Published var gulp = false

    /// Thẻ câu hỏi của Claude cần cao hơn để vừa 4 lựa chọn.
    @Published var tall = false
    /// Tab gương: cao hơn bình thường một chút cho khung camera.
    @Published var mirrorMode = false
    /// Màn hình này đang có app toàn màn hình: chỉ còn notch đen, không cánh / thú cưng / thông báo nhanh.
    @Published var minimal = false
    static let mirrorBodyHeight: CGFloat = 190

    var expandedBodyHeight: CGFloat {
        if tall { return Self.tallBodyHeight }
        if mirrorMode { return Self.mirrorBodyHeight }
        return Self.normalBodyHeight
    }

    /// Viên nổi (màn không có notch + Cài đặt "Viên nổi"): bo tròn hết, cách mép trên `topGap`.
    @Published private(set) var pill = false
    static let pillGap: CGFloat = 5
    var topGap: CGFloat { pill ? Self.pillGap : 0 }

    var topRadius: CGFloat { expanded ? 14 : 6 }
    /// Viên nổi: thu gọn = con nhộng (bán kính bị kẹp ở nửa chiều cao), mở = chữ nhật bo góc.
    var bottomRadius: CGFloat { pill ? (expanded ? 22 : 99) : (expanded ? 24 : 10) }

    /// Thú cưng ngồi ở cánh phải khi notch thu gọn (không che thông báo nhanh).
    var petShown: Bool {
        SettingsStore.shared.showPet && !expanded && !minimal && !SystemMonitor.shared.lowPower
    }
    var petWing: CGFloat { petShown ? notchSize.height : 0 }
    /// Cánh thú cưng chỉ thêm bên phải: dời khung sang phải nửa cánh để mép trái vẫn khớp notch.
    var shapeOffsetX: CGFloat { petWing / 2 }

    func update(for screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - l.width - r.width, height: top)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 190, height: menuBar > 0 ? menuBar : 24)
        }
        let wantPill = top == 0 && SettingsStore.shared.noNotchStyle == .pill
        if pill != wantPill { pill = wantPill }
    }

    /// Kích thước khung shape (đã gồm 2 "tai" ở mép trên).
    /// `wing`: bề rộng mỗi cánh lúc thu gọn (WingLayout.width), 0 = không có cánh.
    func shapeSize(wing: CGFloat) -> CGSize {
        if expanded {
            return CGSize(width: Self.expandedWidth * Self.scale, height: notchSize.height + expandedBodyHeight * Self.scale)
        }
        let wings = minimal ? 0 : peek.map { $0.wing * 2 } ?? wing * 2
        return CGSize(width: notchSize.width + topRadius * 2 + wings + petWing, height: notchSize.height)
    }
}
