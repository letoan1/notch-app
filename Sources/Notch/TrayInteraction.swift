import AppKit
import Quartz
import SwiftUI

// MARK: - Chọn / kéo nhiều file

/// Lớp AppKit phủ lên 1 ô trong khay: click chọn, ⌘-click thêm/bớt, double-click mở,
/// kéo = kéo cả vùng chọn (onDrag của SwiftUI chỉ mang được 1 URL). Chuột phải đi xuyên qua
/// để menu (contextMenu / ThemedMenu) vẫn chạy.
struct TrayItemInteraction: NSViewRepresentable {
    let url: URL
    @ObservedObject var tray: TrayStore

    func makeNSView(context: Context) -> ItemView { ItemView() }

    func updateNSView(_ view: ItemView, context: Context) {
        view.url = url
        view.tray = tray
        view.toolTip = url.path
    }

    final class ItemView: NSView, NSDraggingSource {
        var url: URL?
        weak var tray: TrayStore?
        private var downEvent: NSEvent?
        private var dragged = false
        private var collapseOnUp = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: return nil
            default: return super.hitTest(point)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let url, let tray else { return }
            downEvent = event
            dragged = false
            collapseOnUp = false
            MainActor.assumeIsolated {
                if event.clickCount == 2 {
                    NSWorkspace.shared.open(url)
                    return
                }
                if event.modifierFlags.contains(.command) {
                    if tray.selection.contains(url) { tray.selection.remove(url) } else { tray.selection.insert(url) }
                } else if tray.selection.contains(url) {
                    // Có thể sắp kéo cả nhóm: chỉ thu về 1 file khi nhả chuột mà không kéo.
                    collapseOnUp = tray.selection.count > 1
                } else {
                    tray.selection = [url]
                }
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard collapseOnUp, !dragged, let url, let tray else { return }
            MainActor.assumeIsolated { tray.selection = [url] }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let down = downEvent, let url, let tray else { return }
            let a = down.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
            dragged = true
            let urls = MainActor.assumeIsolated { () -> [URL] in
                if !tray.selection.contains(url) { tray.selection = [url] }
                return tray.targets(for: url)
            }
            let origin = convert(down.locationInWindow, from: nil)
            let items = urls.prefix(12).enumerated().map { i, u -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: u as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: u.path)
                icon.size = NSSize(width: 48, height: 48)
                let o = CGFloat(i) * 6
                item.setDraggingFrame(NSRect(x: origin.x - 24 + o, y: origin.y - 24 - o, width: 48, height: 48), contents: icon)
                return item
            }
            // Ngoài 12 file đầu: kéo theo không có ảnh.
            let rest = urls.dropFirst(12).map { u -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: u as NSURL)
                item.setDraggingFrame(NSRect(x: origin.x, y: origin.y, width: 1, height: 1), contents: nil)
                return item
            }
            let session = beginDraggingSession(with: items + rest, event: down, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // Thả ra app khác = chép (không dời file gốc).
            context == .outsideApplication ? .copy : [.copy, .generic]
        }
    }
}

// MARK: - Xem nhanh (Quick Look)

/// Panel Quick Look cho khay; AppDelegate là controller trong responder chain.
/// Hai nguyên nhân làm Quick Look tự tắt sau ~0.4 s (đã tái hiện bằng log):
/// 1. Mở panel khi app (accessory) chưa active: `NSApp.activate` xong sau đó, ~0.2 s sau Quick Look tự đóng.
///    → kích hoạt trước, đợi didBecomeActive rồi mới mở.
/// 2. tick() của notch thấy `isVisible` còn false trong lúc panel chạy hiệu ứng mở → `makeKey()` giành key.
///    → NotchController dựa vào `isActive` (tính từ lúc gọi `show`).
@MainActor
final class TrayQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = TrayQuickLook()
    private var urls: [URL] = []
    private var openedAt = Date.distantPast
    /// App đang dùng trước khi mở: trả focus khi đóng.
    private var previousApp: NSRunningApplication?
    private(set) var isActive = false

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(_ urls: [URL]) {
        if isActive, isVisible { close(); return }
        show(urls)
    }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        if !isActive {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : front
        }
        isActive = true
        openedAt = Date()
        // Mở Quick Look khi app còn chưa active thì lúc app thành active nó tự đóng (~0.2 s sau).
        // → kích hoạt trước, đợi didBecomeActive (tối đa 0.3 s) rồi mới mở.
        pendingOpen = true
        if previousApp != nil {
            if activeObserver == nil {
                activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                        object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { TrayQuickLook.shared.openPanel() }
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { TrayQuickLook.shared.openPanel() }
            }
        } else {
            openPanel()
        }
    }

    private var pendingOpen = false
    private var activeObserver: NSObjectProtocol?

    private func openPanel() {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
            self.activeObserver = nil
        }
        guard pendingOpen, isActive, let panel = QLPreviewPanel.shared() else { return }
        pendingOpen = false
        openedAt = Date()
        attach(panel)
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) }
        finish()
    }

    func attach(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    /// QL bỏ controller: có thể chỉ vì đổi key window (panel vẫn mở) → không làm gì; đóng thật thì dọn.
    func detach(_ panel: QLPreviewPanel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated { self?.checkClosed() }
        }
    }

    /// Gọi từ tick của notch: panel đã đóng (Space / Esc / nút đóng / bấm ra ngoài) thì dọn + trả focus.
    func checkClosed() {
        guard isActive, !isVisible, Date().timeIntervalSince(openedAt) > 0.8 else { return }
        finish()
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        urls = []
        if QLPreviewPanel.sharedPreviewPanelExists() {
            let panel = QLPreviewPanel.shared()!
            panel.dataSource = nil
            panel.delegate = nil
        }
        // Trả focus cho app trước đó — trừ khi người dùng đã bấm sang app khác (Roost không còn active)
        // hoặc đang mở cửa sổ thường của Roost (Cài đặt).
        let others = NSApp.windows.contains { $0.isVisible && !($0 is NotchPanel) && !($0 is QLPreviewPanel) && $0.canBecomeMain }
        if NSApp.isActive, !others { previousApp?.activate() }
        previousApp = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    /// Giữ Space: bỏ phím lặp để Quick Look không bật / tắt liên tục.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        event.type == .keyDown && event.keyCode == 49 && event.isARepeat
    }
}

// MARK: - Bộ lọc

/// Hàng lọc nhỏ (Tất cả · Ảnh · Tài liệu · Khác), chỉ hiện khi khay có ≥ 2 nhóm file.
struct TrayFilterBar: View {
    @ObservedObject var tray: TrayStore

    var body: some View {
        let counts = tray.filterCounts
        if !counts.isEmpty {
            HStack(spacing: 4) {
                ForEach(counts, id: \.0) { filter, count in
                    chip(filter, count)
                }
                Spacer(minLength: 0)
                if tray.selection.count > 1 {
                    Text(L("\(tray.selection.count) đã chọn", "\(tray.selection.count) selected"))
                        .font(Theme.isCassette ? .hand(12) : .ui(10, weight: .medium))
                        .foregroundStyle(Theme.isCassette ? CassettePalette.key.opacity(0.7) : .white.opacity(0.45))
                }
            }
            .frame(height: 16)
        }
    }

    private func chip(_ filter: TrayStore.Filter, _ count: Int) -> some View {
        let on = tray.filter == filter
        let cassette = Theme.isCassette, pixel = Theme.isPixel
        return Button {
            tray.filter = filter
            tray.selection = []
        } label: {
            HStack(spacing: 3) {
                Text(filter.title)
                Text("\(count)").opacity(0.6).monospacedDigit()
            }
            .font(cassette ? .hand(13) : .ui(10, weight: .semibold))
            .foregroundStyle(cassette ? (on ? CassettePalette.ink : CassettePalette.key.opacity(0.75))
                             : pixel ? (on ? .black : PixelPalette.border.opacity(0.8))
                             : .white.opacity(on ? 0.95 : 0.5))
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background {
                if cassette {
                    if on { RoundedRectangle(cornerRadius: 2).fill(CassettePalette.note).rotationEffect(.degrees(-1.5)) }
                } else if pixel {
                    Rectangle().fill(on ? PixelPalette.pink : .clear)
                        .overlay(Rectangle().strokeBorder(on ? PixelPalette.pink : PixelPalette.dim, lineWidth: 1.5))
                } else {
                    Capsule().fill(.white.opacity(on ? 0.16 : 0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension TrayStore.Filter: Hashable {}

/// Nền đánh dấu ô đang chọn, theo theme.
struct TraySelectionMark: View {
    let selected: Bool

    var body: some View {
        if selected {
            if Theme.isCassette {
                RoundedRectangle(cornerRadius: 6).fill(CassettePalette.band.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(CassettePalette.band, lineWidth: 1.5))
            } else if Theme.isPixel {
                Rectangle().fill(PixelPalette.pink.opacity(0.18))
                    .overlay(Rectangle().strokeBorder(PixelPalette.pink, lineWidth: 2))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.9), lineWidth: 1))
            }
        }
    }
}

