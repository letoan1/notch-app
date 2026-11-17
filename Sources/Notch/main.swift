import AppKit
import Quartz

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = NotchController()
        _ = AppUpdater.shared
        OnboardingWindowController.shared.showIfNeeded()
        // Lần mở sau một crash: hỏi có mở GitHub issue điền sẵn không (không tự gửi gì).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { CrashReport.checkOnLaunch() } }
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
