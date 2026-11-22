import AppKit
import SwiftUI

/// Cài đặt Portal: bật/tắt, địa chỉ của Mac, nơi lưu, thiết bị đã ghép, mã cho Phím tắt iOS.
struct PortalPane: View {
    @ObservedObject var portal = PortalSettings.shared
    @ObservedObject var settings: SettingsStore
    /// Token vừa tạo cho Phím tắt: chỉ hiện một lần.
    private var shortcutToken = State(initialValue: String?.none)

    private var address: String { "http://\(PortalSettings.localHost):\(port)" }
    private var port: UInt16 {
        if case .ready(let p) = portal.status { return p }
        return PortalServer.preferredPort
    }

    private var statusText: String {
        switch portal.status {
        case .off: return L("Đang tắt", "Off")
        case .starting: return L("Đang mở…", "Starting…")
        case .ready: return L("Đang chờ iPhone", "Waiting for iPhone")
        case .failed(let why): return L("Không mở được: ", "Couldn't start: ") + why
        }
    }

    var body: some View {
        SPage {
            SSection(L("Portal", "Portal"),
                     note: L("iPhone hất ảnh, video, file hay clipboard sang, chúng rơi ra từ notch ngay cạnh con trỏ. Chỉ đi trong mạng cục bộ hoặc Wi-Fi trực tiếp giữa hai máy, không qua server nào. Lần đầu bật, macOS sẽ hỏi quyền Mạng cục bộ.",
                             "Flick photos, videos, files or the clipboard from your iPhone and they drop out of the notch right next to your cursor. Everything stays on your local network or a direct Wi-Fi link between the two devices, no servers involved. The first time, macOS asks for Local Network access.")) {
                SToggleRow(icon: "iphone.and.arrow.forward", title: L("Nhận từ iPhone", "Receive from iPhone"),
                           detail: statusText, divider: false, isOn: $portal.enabled)
                SRow("network", L("Địa chỉ cho Phím tắt", "Address for Shortcuts"), detail: address) {
                    Button(L("Chép", "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }
                    .buttonStyle(SButtonStyle())
                }
            }

            SSection(L("Khi nhận", "When receiving"),
                     reset: { portal.toTray = true; portal.acceptClipboard = true; portal.folderPath = "" }) {
                SRow("folder", L("Lưu vào", "Save to"), detail: portal.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                     divider: false) {
                    Button(L("Chọn…", "Choose…")) { chooseFolder() }.buttonStyle(SButtonStyle())
                }
                SToggleRow(icon: "tray.and.arrow.down", title: L("Bay vào khay", "Fly into the tray"),
                           detail: L("File nhận xong bị hút vào notch và nằm sẵn trong khay để kéo đi.",
                                     "Received files get pulled into the notch and wait in the tray."),
                           isOn: $portal.toTray)
                    .disabled(!settings.showTray)
                SToggleRow(icon: "doc.on.clipboard", title: L("Nhận clipboard", "Receive clipboard"),
                           detail: L("Chữ hoặc ảnh iPhone gửi sang được chép thẳng vào clipboard của Mac.",
                                     "Text or images sent from the iPhone go straight to the Mac clipboard."),
                           isOn: $portal.acceptClipboard)
            }
            .disabled(!portal.enabled)

            SSection(L("Thiết bị đã ghép", "Paired devices"),
                     note: L("App RoostPortal tự xin ghép: một thẻ hiện dưới notch để bạn cho phép. Phím tắt iOS thì dùng mã tạo ở đây, dán vào header Authorization của Phím tắt (xem hướng dẫn trong docs/PORTAL.md).",
                             "The RoostPortal app asks to pair on its own: a card shows under the notch for you to allow. For an iOS Shortcut, create a key here and paste it into the Shortcut's Authorization header (see docs/PORTAL.md).")) {
                if portal.devices.isEmpty {
                    SBlock(divider: false) {
                        Text(L("Chưa có thiết bị nào.", "No devices yet."))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(portal.devices.enumerated()), id: \.element.id) { i, device in
                    SRow(device.kind == "shortcut" ? "square.stack.3d.up" : "iphone", device.name,
                         detail: L("Ghép ", "Paired ") + device.pairedAt.formatted(date: .abbreviated, time: .shortened),
                         divider: i > 0) {
                        Button(L("Gỡ", "Remove")) { portal.remove(device) }.buttonStyle(SButtonStyle())
                    }
                }
                SBlock {
                    VStack(alignment: .leading, spacing: 10) {
                        Button(L("Tạo mã cho Phím tắt", "Create a Shortcut key")) { makeShortcutKey() }
                            .buttonStyle(SButtonStyle())
                        if let token = shortcutToken.wrappedValue {
                            Text(L("Đã chép vào clipboard (Universal Clipboard sẽ đưa sang iPhone). Mã chỉ hiện một lần:",
                                   "Copied to the clipboard (Universal Clipboard carries it to the iPhone). Shown only once:"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("Bearer " + token)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .disabled(!portal.enabled)
        }
    }

    private func makeShortcutKey() {
        let (_, token) = portal.addDevice(name: L("Phím tắt iOS", "iOS Shortcut"), kind: "shortcut")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Bearer " + token, forType: .string)
        shortcutToken.wrappedValue = token
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = portal.folder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { portal.folderPath = url.path }
    }
}
