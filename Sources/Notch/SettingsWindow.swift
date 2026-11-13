import AppKit
import SwiftUI

/// Cửa sổ Cài đặt (app dạng accessory không có menu bar → mở từ nút ⚙️ trên notch).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        let win = window ?? makeWindow()
        win.title = L("Cài đặt Notch", "Notch Settings")
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(rootView: SettingsView(settings: .shared))
        return win
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    private static func expiryTitle(_ days: Int) -> String {
        switch days {
        case 0: return L("Không bao giờ", "Never")
        case 1: return L("Sau 1 ngày", "After 1 day")
        default: return L("Sau \(days) ngày", "After \(days) days")
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        Form {
            Section(L("Chung", "General")) {
                Picker(L("Ngôn ngữ", "Language"), selection: $settings.language) {
                    ForEach(SettingsStore.Language.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Giao diện", "Theme"), selection: $settings.theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Notch") {
                Picker(L("Mở notch khi", "Open the notch on"), selection: $settings.openMode) {
                    ForEach(SettingsStore.OpenMode.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Độ trễ khi rê chuột", "Hover delay"), selection: $settings.hoverDelay) {
                    ForEach(SettingsStore.hoverDelays, id: \.self) { delay in
                        Text(delay == 0 ? L("Không", "None") : String(format: "%.2g s", delay)).tag(delay)
                    }
                }
                .disabled(settings.openMode != .hover)
                Picker(L("Phím tắt mở / đóng", "Toggle shortcut"), selection: $settings.hotkey) {
                    ForEach(SettingsStore.Hotkey.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Hiện trên", "Show on"), selection: $settings.displayMode) {
                    ForEach(SettingsStore.DisplayMode.allCases) { Text($0.title).tag($0) }
                }
            }

            Section(L("Tab", "Tabs")) {
                Toggle(L("Nhạc (Spotify, Apple Music)", "Music (Spotify, Apple Music)"), isOn: $settings.showMedia)
                Toggle(L("Lịch", "Calendar"), isOn: $settings.showCalendar)
                Toggle(L("Khay file", "File tray"), isOn: $settings.showTray)
                Toggle(L("Gương camera", "Camera mirror"), isOn: $settings.showMirror)
            }

            Section(L("Khay file", "File tray")) {
                Picker(L("Tự dọn khay", "Auto-clear tray"), selection: $settings.trayExpiryDays) {
                    ForEach(SettingsStore.trayExpiryOptions, id: \.self) { days in
                        Text(Self.expiryTitle(days)).tag(days)
                    }
                }
                Text(L("Khay chỉ giữ liên kết tới file gốc: di chuyển / đổi tên file vẫn còn trong khay; xoá file (hoặc bỏ vào Thùng rác) thì tự gỡ.",
                       "The tray keeps links to the original files: moved or renamed files stay in the tray; deleted (or trashed) files are removed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Giới thiệu", "About")) {
                LabeledContent(L("Phiên bản", "Version"), value: version)
                Link("github.com/letoan1/notch-app", destination: URL(string: "https://github.com/letoan1/notch-app")!)
                Button(L("Thoát Notch", "Quit Notch"), role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
