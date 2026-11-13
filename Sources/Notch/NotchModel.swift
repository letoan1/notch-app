import AppKit
import SwiftUI

@MainActor
final class NotchModel: ObservableObject {
    enum Tab { case media, tray, mirror }

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

        var wing: CGFloat {
            switch self {
            case .charge, .screenshot: return 80
            case .audio: return 118
            }
        }
    }

    @Published var peek: Peek?

    /// Thẻ câu hỏi của Claude cần cao hơn để vừa 4 lựa chọn.
    @Published var tall = false
    /// Tab gương: cao hơn bình thường một chút cho khung camera.
    @Published var mirrorMode = false
    static let mirrorBodyHeight: CGFloat = 190

    var expandedBodyHeight: CGFloat {
        if tall { return Self.tallBodyHeight }
        if mirrorMode { return Self.mirrorBodyHeight }
        // Cassette: băng + phím cơ cao hơn trình phát thường.
        if Theme.isCassette && tab == .media { return 214 }
        return Self.normalBodyHeight
    }

    var topRadius: CGFloat { expanded ? 14 : 6 }
    var bottomRadius: CGFloat { expanded ? 24 : 10 }

    /// Thú cưng ngồi ở cánh phải khi notch thu gọn (không che thông báo nhanh).
    var petShown: Bool { SettingsStore.shared.showPet && !expanded }
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
    }

    /// Kích thước khung shape (đã gồm 2 "tai" ở mép trên).
    func shapeSize(playing: Bool) -> CGSize {
        if expanded {
            return CGSize(width: Self.expandedWidth * Self.scale, height: (notchSize.height + expandedBodyHeight) * Self.scale)
        }
        let wings = peek.map { $0.wing * 2 } ?? (playing ? notchSize.height * 2 : 0)
        return CGSize(width: notchSize.width + topRadius * 2 + wings + petWing, height: notchSize.height)
    }
}
