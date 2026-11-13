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
    static let normalBodyHeight: CGFloat = 154
    static let tallBodyHeight: CGFloat = 222

    struct ChargePeek: Equatable {
        let percent: Int
        let charging: Bool
    }

    /// Vừa cắm sạc: hiện 2 cánh pin vài giây (kiểu iPhone).
    @Published var chargePeek: ChargePeek?
    static let peekWing: CGFloat = 80

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
            return CGSize(width: Self.expandedWidth, height: notchSize.height + expandedBodyHeight)
        }
        let wings = chargePeek != nil ? Self.peekWing * 2 : (playing ? notchSize.height * 2 : 0)
        return CGSize(width: notchSize.width + topRadius * 2 + wings, height: notchSize.height)
    }
}
