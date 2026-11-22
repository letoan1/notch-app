import AppKit
import AVFoundation
import EventKit
import FaceUnlockKit
import SwiftUI

/// Màn hình chào lần đầu: cấp quyền cần thiết, cài hook Claude Code, chọn giao diện.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private static let doneKey = "onboarded"

    /// Chưa qua màn hướng dẫn. Người đã dùng bản cũ (đã có cài đặt) coi như đã qua.
    var needsOnboarding: Bool {
        let d = UserDefaults.standard
        return !d.bool(forKey: Self.doneKey) && d.object(forKey: "theme") == nil && d.object(forKey: "language") == nil
    }

    /// Lần đầu mở app thì hiện.
    func showIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.doneKey) else { return }
        guard needsOnboarding else {
            d.set(true, forKey: Self.doneKey)
            return
        }
        show()
    }

    func show() {
        let win = window ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView { [weak self] in self?.finish() }))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = L("Chào mừng tới Roost", "Welcome to Roost")
            w.isReleasedWhenClosed = false
            w.delegate = self
            return w
        }()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
    }

    /// Cửa sổ phụ: huỷ view khi đóng để không layout ngầm.
    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}

private enum Grant: Equatable {
    /// manual: macOS tự hỏi khi cần, chỉ có nút mở Cài đặt hệ thống.
    case granted, denied, unknown, manual, info(String)
}

/// Trạng thái màn chào (không dùng macro @State: plugin chỉ có trong Xcode).
@MainActor
private final class OnboardingState: ObservableObject {
    @Published var calendar: Grant = .unknown
    @Published var camera: Grant = .unknown
    @Published var automation: Grant = .unknown
    @Published var accessibility: Grant = .unknown
    @Published var hooks: [ClaudeHookDetector.Found] = []
    @Published var copied = false
}

private struct OnboardingView: View {
    let done: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var state = OnboardingState()

    static let hookPath = "/Applications/Roost.app/Contents/MacOS/roost-hook"
    /// PermissionRequest: hiện thẻ. Notification: âm báo khi phiên chờ bạn. Các event còn lại: báo app gỡ
    /// thẻ khi đã trả lời ở terminal (hộp thoại terminal chạy song song với hook), chạy vài ms, không in gì.
    static let hookConfig = """
    {
      "hooks": {
        "PermissionRequest": [{
          "matcher": "*",
          "hooks": [{ "type": "command", "command": "\(hookPath)", "timeout": 110 }]
        }],
        "PostToolUse": [{
          "matcher": "*",
          "hooks": [{ "type": "command", "command": "\(hookPath)", "timeout": 5 }]
        }],
        "PostToolUseFailure": [{
          "matcher": "*",
          "hooks": [{ "type": "command", "command": "\(hookPath)", "timeout": 5 }]
        }],
        "Stop": [{
          "hooks": [{ "type": "command", "command": "\(hookPath)", "timeout": 5 }]
        }],
        "SessionEnd": [{
          "hooks": [{ "type": "command", "command": "\(hookPath)", "timeout": 5 }]
        }],
        "Notification": [{
          "hooks": [{ "type": "command", "command": "\(hookPath)", "timeout": 5 }]
        }]
      }
    }
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                permissions
                claude
                appearance
                faceUnlock
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .frame(width: 640, height: 700)
        .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        .buttonStyle(SButtonStyle(.secondary))
        .environment(\.locale, settings.locale)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Chào mừng tới Roost", "Welcome to Roost")).font(.system(size: 22, weight: .bold))
                Text(L("Vài bước để Roost dùng được đủ tính năng. Bước nào chưa cần thì cứ bỏ qua, sau này mở lại ở Cài đặt › Giới thiệu › Hướng dẫn cài đặt.",
                       "A few steps to get everything working. Skip any you don't need yet; you can come back from Settings › About › Setup guide."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissions: some View {
        SSection(L("Quyền", "Permissions"),
                 note: L("Roost chỉ đọc những gì cần để hiện lên notch, không gửi đi đâu. Mỗi quyền cũng có nút mở lại trong mục Cài đặt tương ứng.",
                         "Roost only reads what it needs to show on the notch and sends nothing anywhere. Each permission can also be reopened from its Settings page.")) {
            row("calendar", L("Lịch", "Calendar"),
                L("Tuần hiện tại, cuộc họp sắp tới và nút vào Meet. Roost chỉ đọc lịch.",
                  "This week, upcoming meetings and a Meet button. Roost only reads your calendars."),
                state.calendar, privacy: "Privacy_Calendars", divider: false) { requestCalendar() }
            row("camera", L("Camera", "Camera"),
                L("Tab Gương và mở khoá bằng khuôn mặt. Roost không quay video.",
                  "The Mirror tab and face unlock. Roost never records video."),
                state.camera, privacy: "Privacy_Camera") { requestCamera() }
            row("accessibility", L("Trợ năng", "Accessibility"),
                L("Thay HUD âm lượng và độ sáng, và gõ mật khẩu khi mở khoá bằng khuôn mặt.",
                  "Replaces the volume and brightness HUD, and types your password for face unlock."),
                state.accessibility, privacy: "Privacy_Accessibility") { requestAccessibility() }
            row("music.note", L("Điều khiển Spotify và Apple Music", "Control Spotify and Apple Music"),
                L("Dùng khi cần điều khiển trực tiếp hai app này, ví dụ chế độ lặp. Mở một trong hai app trước khi bấm.",
                  "Used to control these two apps directly, like repeat. Open one of them first."),
                state.automation, privacy: "Privacy_Automation") { requestAutomation() }
            row("waveform", L("Ghi âm thanh hệ thống", "System audio recording"),
                L("Sóng nhạc theo âm thanh thật và âm lượng từng app. Roost chỉ nghe, không ghi lại gì. macOS hỏi lần đầu bạn dùng.",
                  "A live visualizer and per-app volume. Roost only listens and records nothing. macOS asks the first time you use it."),
                .manual, privacy: "Privacy_AudioCapture", action: nil)
        }
    }

    private var claude: some View {
        SSection("Claude Code",
                 note: L("Mỗi thẻ chờ tối đa 100 giây, ngắn hơn timeout 110 giây của hook. Hết giờ hay Roost không chạy thì Claude Code hỏi lại ở terminal như bình thường.",
                         "Each card waits up to 100 seconds, less than the 110 second hook timeout. If time runs out or Roost isn't running, Claude Code simply asks in the terminal.")) {
            SRow("link", L("Hook của Roost", "Roost hook"), detail: hookStatus, divider: false) {
                let ok = state.hooks.contains { $0.events.contains("PermissionRequest") }
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ok ? .green : .secondary)
            }
            SBlock {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Duyệt quyền và trả lời câu hỏi của Claude Code ngay trên notch, có âm báo khi một phiên đang chờ bạn. Dán đoạn này vào ~/.claude/settings.json hoặc .claude/settings.json của một project:",
                           "Approve Claude Code permissions and answer its questions on the notch, with a sound when a session is waiting for you. Paste this into ~/.claude/settings.json or a project's .claude/settings.json:"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(Self.hookConfig)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                    HStack(spacing: 8) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.hookConfig, forType: .string)
                            state.copied = true
                        } label: {
                            Label(state.copied ? L("Đã sao chép", "Copied") : L("Sao chép cấu hình", "Copy config"),
                                  systemImage: state.copied ? "checkmark" : "doc.on.doc")
                        }
                        Button(L("Kiểm tra lại", "Check again")) { refresh() }
                            .buttonStyle(SButtonStyle(.link))
                    }
                }
                .padding(.leading, 40)
            }
        }
    }

    private var hookStatus: String {
        guard let found = state.hooks.first(where: { $0.events.contains("PermissionRequest") }) ?? state.hooks.first else {
            return L("Chưa thấy roost-hook trong ~/.claude/settings.json hay settings của các project gần đây.",
                     "No roost-hook entry in ~/.claude/settings.json or in recent projects yet.")
        }
        if !found.events.contains("PermissionRequest") {
            return L("Có ở \(ClaudePaths.short(found.file)) nhưng thiếu PermissionRequest nên thẻ xin quyền sẽ không hiện.",
                     "Found in \(ClaudePaths.short(found.file)) but PermissionRequest is missing, so permission cards won't show.")
        }
        if let t = found.timeout, t <= 100 {
            return L("Có ở \(ClaudePaths.short(found.file)), nhưng timeout \(t) giây ngắn hơn 100 giây Roost chờ. Nên đặt 110.",
                     "Found in \(ClaudePaths.short(found.file)), but the \(t)s timeout is shorter than the 100s Roost waits. Set it to 110.")
        }
        return L("Đã có ở \(ClaudePaths.short(found.file)).", "Set up in \(ClaudePaths.short(found.file)).")
    }

    private var appearance: some View {
        SSection(L("Giao diện", "Theme"),
                 note: L("Mỗi giao diện có cách hiển thị riêng cho từng tab và một thú cưng riêng. Đổi lại lúc nào cũng được ở Cài đặt › Giao diện.",
                         "Each theme has its own take on every tab and its own pet. Change it any time in Settings › Appearance.")) {
            SBlock(divider: false) {
                HStack(spacing: 12) {
                    ForEach(Theme.allCases) { theme in
                        SChoiceCard(title: theme.title, selected: settings.theme == theme, height: 74,
                                    action: { settings.theme = theme }) {
                            ThemeSwatch(theme: theme)
                        }
                    }
                }
            }
        }
    }

    private var faceUnlock: some View {
        SSection(L("Mở khoá bằng khuôn mặt (Thử nghiệm)", "Face unlock (Experimental)"),
                 note: L("Đây là tiện ích, không phải lớp bảo mật: camera MacBook chỉ thấy ảnh 2D. Tính năng tắt sẵn, chỉ chạy khi bạn đã đăng nhập.",
                         "A convenience, not a security layer: a MacBook camera only sees a flat image. It's off by default and only works after you've logged in.")) {
            SRow("faceid", L("Mở khoá bằng khuôn mặt", "Face unlock"),
                 detail: L("Cần quyền camera, quyền Trợ năng, phiên Touch ID, mật khẩu đăng nhập và một lần quét mặt. Thiết lập ở Cài đặt › Khuôn mặt.",
                           "Needs camera and Accessibility access, a Touch ID session, your login password and one face scan. Set it up in Settings › Face unlock."),
                 divider: false) {
                Button(L("Thiết lập…", "Set up…")) { SettingsWindowController.shared.show(pane: "face") }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button(L("Bắt đầu", "Get started"), action: done)
                .buttonStyle(SButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private var hint: String {
        if settings.hotkey == .off { return L("Rê chuột lên notch để mở.", "Hover the notch to open it.") }
        return L("Rê chuột lên notch để mở, hoặc bấm \(settings.hotkey.title).", "Hover the notch to open it, or press \(settings.hotkey.title).")
    }

    @ViewBuilder
    private func row(_ symbol: String, _ title: String, _ detail: String, _ grant: Grant, privacy: String,
                     divider: Bool = true, action: (() -> Void)?) -> some View {
        SRow(symbol, title, detail: detail, divider: divider) {
            switch grant {
            case .granted:
                Label(L("Đã cấp", "Granted"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.green)
            case .manual:
                Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { openPrivacyPane(privacy) }
                    .buttonStyle(SButtonStyle(.link))
            case .info(let text):
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            case .denied:
                Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { openPrivacyPane(privacy) }
            case .unknown:
                if let action { Button(L("Cho phép", "Allow"), action: action) }
            }
        }
    }

    // MARK: - Quyền

    private func refresh() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: state.calendar = .granted
        case .denied, .restricted, .writeOnly: state.calendar = .denied
        default: state.calendar = .unknown
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: state.camera = .granted
        case .denied, .restricted: state.camera = .denied
        default: state.camera = .unknown
        }
        state.accessibility = FaceUnlockService.isAccessibilityTrusted ? .granted : .unknown
        state.hooks = ClaudeHookDetector.scan(projects: ClaudeActivity.shared.projects)
        let running = runningPlayers()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.automationStatus(running, ask: false)
            DispatchQueue.main.async { state.automation = result }
        }
    }

    private func requestCalendar() {
        EKEventStore().requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { refresh() }
        }
    }

    private func requestAccessibility() {
        // Hộp thoại hệ thống chỉ hiện lần đầu: mở thẳng mục Trợ năng cho các lần sau.
        FaceUnlockService.promptForAccessibility()
        openPrivacyPane("Privacy_Accessibility")
    }

    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { refresh() }
        }
    }

    private func requestAutomation() {
        let running = runningPlayers()
        guard !running.isEmpty else {
            state.automation = .info(L("Mở Spotify hoặc Apple Music trước", "Open Spotify or Apple Music first"))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.automationStatus(running, ask: true)
            DispatchQueue.main.async { state.automation = result }
        }
    }

    private func runningPlayers() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Player.allCases.map(\.bundleID).filter(running.contains)
    }

    /// Quyền điều khiển app khác (Apple Events). `ask` = hiện hộp thoại xin quyền nếu chưa hỏi.
    nonisolated private static func automationStatus(_ bundleIDs: [String], ask: Bool) -> Grant {
        guard !bundleIDs.isEmpty else { return .unknown }
        var any = Grant.unknown
        for id in bundleIDs {
            let target = NSAppleEventDescriptor(bundleIdentifier: id)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
            if status == noErr { return .granted }
            if status == OSStatus(errAEEventNotPermitted) { any = .denied }
        }
        return any
    }
}
