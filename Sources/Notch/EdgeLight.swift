import AppKit
import SwiftUI

/// Đèn viền: viền trắng ấm quanh mép màn hình để rọi sáng mặt khi gọi video.
/// Cửa sổ trong suốt, không nhận chuột, nằm dưới notch; vẫn sáng khi notch thu gọn.
@MainActor
final class EdgeLight: ObservableObject {
    static let shared = EdgeLight()

    enum Level: Int, CaseIterable {
        case off, soft, medium, strong

        var title: String {
            switch self {
            case .off: return L("Đèn viền", "Edge light")
            case .soft: return L("Đèn: Dịu", "Light: Soft")
            case .medium: return L("Đèn: Vừa", "Light: Medium")
            case .strong: return L("Đèn: Mạnh", "Light: Strong")
            }
        }

        var width: CGFloat {
            switch self {
            case .off: return 0
            case .soft: return 40
            case .medium: return 80
            case .strong: return 130
            }
        }
    }

    @Published private(set) var level: Level = .off
    private var window: NSWindow?

    var isOn: Bool { level != .off }

    func cycle() {
        let all = Level.allCases
        level = all[(all.firstIndex(of: level)! + 1) % all.count]
        apply()
    }

    func set(_ new: Level) {
        level = new
        apply()
    }

    func turnOff() {
        level = .off
        apply()
    }

    private func apply() {
        guard isOn else {
            window?.orderOut(nil)
            window = nil
            return
        }
        // Màn hình có camera (notch) trước, không thì màn hình chính.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let win = window ?? makeWindow()
        win.contentView = NSHostingView(rootView: EdgeLightView(width: level.width))
        win.setFrame(screen.frame, display: true)
        win.orderFrontRegardless()
        window = win
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        // Dưới notch (mainMenu + 3) để notch vẫn bấm được.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return win
    }
}

private struct EdgeLightView: View {
    let width: CGFloat
    private let warm = Color(red: 1.0, green: 0.95, blue: 0.86)

    var body: some View {
        ZStack {
            // Lớp sáng chính + lớp tán mềm vào trong cho giống đèn thật.
            Rectangle().strokeBorder(warm, lineWidth: width)
            Rectangle().strokeBorder(warm.opacity(0.55), lineWidth: width * 1.6)
                .blur(radius: width * 0.5)
        }
        .ignoresSafeArea()
    }
}
