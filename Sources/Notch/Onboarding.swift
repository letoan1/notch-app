import AppKit
import AVFoundation
import EventKit
import SwiftUI

/// Màn hình chào lần đầu: cấp quyền cần thiết, cài hook Claude Code, chọn giao diện.
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private static let doneKey = "onboarded"

    /// Lần đầu mở app thì hiện. Người đã dùng bản cũ (đã có cài đặt) thì bỏ qua.
    func showIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.doneKey) else { return }
        if d.object(forKey: "theme") != nil || d.object(forKey: "language") != nil {
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
            w.isReleasedWhenClosed = false
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
}

private enum Grant: Equatable {
    case granted, denied, unknown, info(String)
}

/// Trạng thái màn chào (không dùng macro @State: plugin chỉ có trong Xcode).
@MainActor
private final class OnboardingState: ObservableObject {
    @Published var calendar: Grant = .unknown
    @Published var camera: Grant = .unknown
    @Published var automation: Grant = .unknown
    @Published var copied = false
}

private struct OnboardingView: View {
    let done: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var state = OnboardingState()

    static let hookPath = "/Applications/Roost.app/Contents/MacOS/roost-hook"
    /// PermissionRequest: hiện thẻ. Các event còn lại: báo app gỡ thẻ khi đã trả lời ở terminal
    /// (hộp thoại terminal chạy song song với hook) — chạy vài ms, không in gì.
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
        }]
      }
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Chào mừng tới Roost", "Welcome to Roost")).font(.title2.bold())
                    Text(L("Vài bước để Roost dùng được đủ tính năng. Bước nào chưa muốn làm thì cứ bỏ qua, sau này mở lại ở Cài đặt › Giới thiệu.", "A few steps to get everything working. Skip any you like; you can come back later from Settings › About."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox {
                VStack(spacing: 12) {
                    row("calendar", L("Lịch", "Calendar"),
                        L("Xem sự kiện, link Meet / Zoom ngay trên notch.", "See events and Meet / Zoom links on the notch."),
                        state.calendar) { requestCalendar() }
                    Divider()
                    row("music.note", L("Điều khiển Spotify / Music", "Control Spotify / Music"),
                        L("Hiện bài đang phát, phát / dừng, chuyển bài. Mở Spotify hoặc Music trước khi bấm.",
                          "Shows the current track and lets you play, pause and skip. Open Spotify or Music first."),
                        state.automation) { requestAutomation() }
                    Divider()
                    row("camera", L("Camera", "Camera"),
                        L("Tab Gương: soi gương trước khi họp, không ghi hình.", "Mirror tab: check yourself before a call; nothing is recorded."),
                        state.camera) { requestCamera() }
                    Divider()
                    row("waveform", L("Ghi âm thanh hệ thống", "System audio recording"),
                        L("Cho sóng nhạc chạy theo nhạc thật; chỉ nghe Spotify / Music.", "Lets the visualizer follow the real music; only Spotify / Music."),
                        .info(L("Hỏi khi phát nhạc", "Asked on first play")), action: nil)
                }
                .padding(6)
            } label: {
                Label(L("Quyền", "Permissions"), systemImage: "lock.shield")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Duyệt quyền / trả lời câu hỏi của Claude Code ngay trên notch. Dán đoạn này vào ~/.claude/settings.json (hoặc .claude/settings.json của project):",
                           "Approve Claude Code permissions and answer its questions on the notch. Paste this into ~/.claude/settings.json (or a project's .claude/settings.json):"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(Self.hookConfig)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.25)))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.hookConfig, forType: .string)
                        state.copied = true
                    } label: {
                        Label(state.copied ? L("Đã sao chép", "Copied") : L("Sao chép cấu hình", "Copy config"),
                              systemImage: state.copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .padding(6)
            } label: {
                Label("Claude Code", systemImage: "sparkle")
            }

            GroupBox {
                HStack(spacing: 10) {
                    ForEach(Theme.allCases) { theme in
                        Button { settings.theme = theme } label: {
                            VStack(spacing: 4) {
                                Text(theme == .standard ? "🦊" : theme == .pixel ? "🦖" : theme == .cassette ? "📼" : "🎨").font(.system(size: 26))
                                Text(theme.title).font(.callout)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(settings.theme == theme ? Color.accentColor.opacity(0.25) : .white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(settings.theme == theme ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            } label: {
                Label(L("Giao diện", "Theme"), systemImage: "paintpalette")
            }

            Label(L("Mở khoá bằng khuôn mặt (thử nghiệm, mặc định tắt): ⚙️ Cài đặt › Khuôn mặt.",
                    "Face unlock (experimental, off by default): ⚙️ Settings › Face unlock."), systemImage: "faceid")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text(L("Rê chuột lên notch để mở · ⌥Space là phím tắt mặc định", "Hover the notch to open it · ⌥Space is the default shortcut"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Bắt đầu", "Get started"), action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @ViewBuilder
    private func row(_ symbol: String, _ title: String, _ detail: String, _ grant: Grant, action: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch grant {
            case .granted:
                Label(L("Đã cấp", "Granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            case .info(let text):
                Text(text).font(.caption).foregroundStyle(.secondary)
            case .denied:
                Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { openPrivacy(symbol) }
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

    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { refresh() }
        }
    }

    private func requestAutomation() {
        let running = runningPlayers()
        guard !running.isEmpty else {
            state.automation = .info(L("Mở Spotify / Music trước", "Open Spotify / Music first"))
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

    private func openPrivacy(_ symbol: String) {
        let pane = switch symbol {
        case "calendar": "Privacy_Calendars"
        case "camera": "Privacy_Camera"
        default: "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
