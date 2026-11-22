import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Điều phối

/// Nhận sự kiện từ PortalServer (đã về main): chạy hiệu ứng, lưu file, ghi clipboard, hỏi ghép đôi.
@MainActor
final class PortalCenter {
    static let shared = PortalCenter()

    /// NotchController gắn: thêm vào khay, notch "nuốt", báo DownloadsWatcher bỏ qua file sắp lưu.
    var addToTray: ((URL) -> Void)?
    var gulp: (() -> Void)?
    var willSave: ((URL) -> Void)?

    private var flights: [UUID: PortalFlight] = [:]

    // MARK: File

    /// entry: độ cao ngón tay lúc hất trên iPhone (header X-Roost-Y, 0 = đỉnh, 1 = đáy).
    func incoming(id: UUID, name: String, size: Int, from: String, entry: Double? = nil) {
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        let flight = PortalFlight(title: name, image: NSWorkspace.shared.icon(for: type), entry: entry)
        flights[id] = flight
        flight.arrive()
    }

    func progress(id: UUID, _ fraction: Double) {
        flights[id]?.setProgress(fraction)
    }

    /// Chuyển file tạm vào thư mục lưu. Trả nil nếu không lưu được.
    func received(id: UUID, temp: URL, name: String) -> URL? {
        let settings = PortalSettings.shared
        let fm = FileManager.default
        let folder = settings.folder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = Self.unique(folder.appendingPathComponent(name))
        willSave?(dest)
        let flight = flights.removeValue(forKey: id)
        do {
            try fm.moveItem(at: temp, to: dest)
        } catch {
            try? fm.removeItem(at: temp)
            flight?.fail()
            return nil
        }
        let toTray = settings.toTray && addToTray != nil
        flight?.complete(url: dest, intoNotch: toTray) { [weak self] in
            if toTray { self?.addToTray?(dest) }
            self?.gulp?()
        }
        return dest
    }

    func failed(id: UUID) {
        flights.removeValue(forKey: id)?.fail()
    }

    /// "ảnh.jpg" đã có thì thành "ảnh 2.jpg", "ảnh 3.jpg"…
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for i in 2...9999 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    // MARK: Clipboard

    func clipboard(id: UUID, data: Data, type: String, from: String) -> Bool {
        guard PortalSettings.shared.acceptClipboard else { return false }
        let pb = NSPasteboard.general
        let title: String
        let image: NSImage
        if type.isEmpty || type.hasPrefix("text/") || type == "application/json" {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return false }
            pb.clearContents()
            pb.setString(text, forType: .string)
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            title = "“" + String(line.prefix(40)) + (line.count > 40 ? "…" : "") + "”"
            image = Self.symbol("doc.on.clipboard")
        } else if type.hasPrefix("image/"), let picture = NSImage(data: data) {
            pb.clearContents()
            pb.writeObjects([picture])
            title = L("Ảnh trong clipboard", "Image on clipboard")
            image = picture
        } else if let uti = UTType(mimeType: type) {
            pb.clearContents()
            pb.setData(data, forType: NSPasteboard.PasteboardType(uti.identifier))
            title = L("Đã chép vào clipboard", "Copied to clipboard")
            image = Self.symbol("doc.on.clipboard")
        } else {
            return false
        }
        let flight = PortalFlight(title: title, image: image)
        flight.arrive()
        flight.complete(url: nil, intoNotch: false, hold: 0.9) {}
        return true
    }

    static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    // MARK: Ghép đôi

    enum PairResult { case approved(PortalDevice, String), denied, busy }

    private var pairing: PortalPairingPanel?
    private var lastDenied = Date.distantPast

    /// Một yêu cầu một lúc; từ chối xong thì 10 s sau mới hỏi lại (chống spam từ máy lạ trong mạng).
    func askToPair(name: String, code: String?, reply: @escaping (PairResult) -> Void) {
        guard pairing == nil, Date().timeIntervalSince(lastDenied) > 10 else { reply(.busy); return }
        let panel = PortalPairingPanel()
        pairing = panel
        panel.show(name: name, code: code) { [weak self] allowed in
            guard let self else { return }
            self.pairing = nil
            if allowed {
                let (device, token) = PortalSettings.shared.addDevice(name: name, kind: "app")
                reply(.approved(device, token))
            } else {
                self.lastDenied = Date()
                reply(.denied)
            }
        }
    }
}

// MARK: - Hộp duyệt ghép đôi

/// Thẻ nổi ngay dưới notch: "iPhone của X muốn kết nối", Cho phép / Từ chối. Tự từ chối sau 60 s.
@MainActor
final class PortalPairingPanel {
    private var panel: NSPanel?
    private var decide: ((Bool) -> Void)?

    func show(name: String, code: String?, decide: @escaping (Bool) -> Void) {
        self.decide = decide
        let view = PortalPairingView(name: name, code: code) { [weak self] allowed in self?.finish(allowed) }
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) - 10
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.finish(false) }
    }

    private func finish(_ allowed: Bool) {
        guard let decide else { return }
        self.decide = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        decide(allowed)
    }
}

private struct PortalPairingView: View {
    let name: String
    let code: String?
    let decide: (Bool) -> Void

    private var radius: CGFloat { Theme.isPixel ? 0 : 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(red: 0.45, green: 0.82, blue: 1))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("“\(name)” muốn kết nối Portal", "“\(name)” wants to connect to Portal"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("Cho phép thì thiết bị này gửi được file và clipboard sang máy Mac, lần sau không hỏi lại.",
                           "If you allow it, this device can send files and clipboard to this Mac without asking again."))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let code, !code.isEmpty {
                HStack {
                    Text(L("Mã hiện trên iPhone", "Code shown on the iPhone"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(code).font(.system(size: 20, weight: .bold, design: .monospaced)).tracking(4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: radius / 2).fill(.white.opacity(0.07)))
            }
            HStack(spacing: 10) {
                Spacer()
                pill(L("Từ chối", "Decline"), fill: .white.opacity(0.12)) { decide(false) }
                pill(L("Cho phép", "Allow"), fill: Color(red: 0.2, green: 0.55, blue: 1)) { decide(true) }
            }
        }
        .padding(18)
        .frame(width: 380)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: radius).fill(Color.black.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.12), lineWidth: Theme.isPixel ? 2 : 1))
        .environment(\.colorScheme, .dark)
    }

    private func pill(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 99).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
