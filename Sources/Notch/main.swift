import AppKit
import Quartz

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // App nền không có menu Edit → ⌘C / ⌘V / ⌘X / ⌘A không tới được ô nhập. Menu chính không hiện ra
        // (app không có thanh menu), chỉ để phím tắt có chỗ đi qua.
        NSApp.mainMenu = Self.editMenu()
        controller = NotchController()
        _ = AppUpdater.shared
        OnboardingWindowController.shared.showIfNeeded()
        // Lần mở sau một crash: hỏi có mở GitHub issue điền sẵn không (không tự gửi gì).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { CrashReport.checkOnLaunch() } }
    }

    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key, mods) in [
            ("Undo", "undo:", "z", NSEvent.ModifierFlags.command), ("Redo", "redo:", "z", [.command, .shift]),
            ("Cut", "cut:", "x", .command), ("Copy", "copy:", "c", .command),
            ("Paste", "paste:", "v", .command), ("Select All", "selectAll:", "a", .command),
        ] {
            let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            edit.addItem(item)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    // Quick Look của khay: panel tìm controller trong responder chain (kết thúc ở app delegate).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { TrayQuickLook.shared.attach(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { TrayQuickLook.shared.detach(panel) }
    }
}

// Dữ liệu bản cũ "Notch" → Roost, trước khi bất kỳ thứ gì đọc UserDefaults / Application Support
// (kể cả màn chào: cờ "onboarded" phải có trước).
// Roost --karaoke-selftest <file nhạc> <thư mục ra>: tự kiểm âm thanh karaoke rồi thoát (không mở giao diện).
KaraokeSelfTest.runIfRequested()
// NSLog của app không vào log hệ thống: ghi ra ~/Library/Logs/Roost.log (chỉ dòng chẩn đoán karaoke, mở lại app thì làm mới).
if !CommandLine.arguments.contains(where: { $0.hasSuffix("selftest") }) {
    freopen(NSHomeDirectory() + "/Library/Logs/Roost.log", "w", stderr)
}
KaraokeSelfTest.runTapTestIfRequested()
RoostMigration.run()

// pkill / build.sh gửi SIGTERM: thoát qua NSApp.terminate để dọn tiến trình con (MediaRemote stream).
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
