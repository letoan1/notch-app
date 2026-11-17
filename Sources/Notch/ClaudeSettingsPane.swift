import AppKit
import SwiftUI

@MainActor
private final class ClaudePaneModel: ObservableObject {
    @Published var hooks: [ClaudeHookDetector.Found] = []
    @Published var socketExists = false
    @Published var message: String?
    @Published var copiedCodex = false

    func refresh(projects: [String]) {
        socketExists = FileManager.default.fileExists(atPath: PermissionCenter.socketPath)
        hooks = ClaudeHookDetector.scan(projects: projects)
    }
}

/// Cài đặt › Claude Code: trạng thái hook, lịch sử gần đây, các luật "Luôn cho phép" đã cấp và nút thu hồi.
struct ClaudePane: View {
    @ObservedObject private var activity = ClaudeActivity.shared
    @ObservedObject private var extras = ClaudeExtras.shared
    static let statusLine = """
    "statusLine": {
      "type": "command",
      "command": "/Applications/Roost.app/Contents/MacOS/roost-hook --statusline"
    }
    """
    @StateObject private var model = ClaudePaneModel()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        SPage {
            SSection(L("Kết nối", "Connection"),
                     note: L("Mỗi thẻ chờ tối đa 100 giây, luôn ngắn hơn timeout 110 giây của hook. Hết giờ, Roost tắt hay hook lỗi thì Claude Code hỏi lại ở terminal như bình thường, không bao giờ bị treo.",
                             "Each card waits up to 100 seconds, always less than the 110 second hook timeout. If time runs out, Roost quits or the hook fails, Claude Code simply asks in the terminal. It never hangs.")) {
                SRow("antenna.radiowaves.left.and.right", L("Socket của Roost", "Roost socket"), divider: false) {
                    if activity.listening && model.socketExists {
                        Label(L("Đang nghe", "Listening"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label(activity.listenError ?? L("Không nghe được", "Not listening"), systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if model.hooks.isEmpty {
                    SRow("exclamationmark.triangle", L("Chưa thấy hook", "No hook found"),
                         detail: L("Không có roost-hook trong ~/.claude/settings.json hay settings của các project gần đây.",
                                   "No roost-hook entry in ~/.claude/settings.json or in recent projects.")) {
                        Button(L("Hướng dẫn", "Setup guide")) { OnboardingWindowController.shared.show() }.controlSize(.small)
                    }
                } else {
                    ForEach(model.hooks) { found in
                        SRow("link", ClaudePaths.short(found.file), detail: hookDetail(found)) {
                            Image(systemName: found.events.contains("PermissionRequest") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(found.events.contains("PermissionRequest") ? .green : .orange)
                        }
                    }
                }
                SRow("arrow.clockwise", L("Kiểm tra lại cấu hình hook", "Check the hook setup again")) {
                    Button(L("Kiểm tra", "Check")) { model.refresh(projects: activity.projects) }.controlSize(.small)
                }
            }
            SSection("Codex CLI",
                     note: L("Lần đầu mở Codex sau khi thêm hook, Codex hỏi duyệt hook mới: chọn tin tưởng. Thẻ của Codex không có nút Luôn cho phép, vì luật của Codex nằm ở chỗ khác.",
                             "The first time you open Codex after adding the hook, Codex asks you to review it: trust it. Codex cards have no Always allow button, since Codex keeps its rules elsewhere.")) {
                SBlock {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("Duyệt yêu cầu của Codex trên notch như với Claude Code. Dán đoạn này vào \(ClaudePaths.short(CodexHooks.file)):",
                               "Approve Codex requests on the notch just like Claude Code. Paste this into \(ClaudePaths.short(CodexHooks.file)):"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            Text(CodexHooks.config)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 130)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                        Button(model.copiedCodex ? L("Đã chép", "Copied") : L("Chép", "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CodexHooks.config, forType: .string)
                            model.copiedCodex = true
                        }
                        .controlSize(.small)
                    }
                }
            }

            SSection(L("Âm báo", "Sound"),
                     note: L("Kêu khi có thẻ xin quyền hay câu hỏi, và khi một phiên Claude Code đang chờ bạn (cần hook Notification).",
                             "Plays when a permission card or a question arrives, and when a Claude Code session is waiting for you (needs the Notification hook)."),
                     reset: { extras.sound = true; extras.soundName = "Tink" }) {
                SToggleRow(icon: "speaker.wave.2", title: L("Âm báo khi Claude cần bạn", "Play a sound when Claude needs you"),
                           divider: false, isOn: $extras.sound)
                SRow("music.note.list", L("Âm thanh", "Sound")) {
                    SPicker($extras.soundName, Array(ClaudeExtras.sounds), title: { $0 })
                    .disabled(!extras.sound)
                    .onChange(of: extras.soundName) { _, name in NSSound(named: NSSound.Name(name))?.play() }
                }
            }

            SSection(L("Luôn cho phép do Roost cấp", "Always allow rules granted by Roost"),
                     note: L("Luật chỉ trong phiên sẽ hết khi phiên Claude Code kết thúc nên không cần thu hồi. Thu hồi chỉ gỡ đúng chuỗi luật đó, các luật khác trong file giữ nguyên.",
                             "Session-only rules end with the Claude Code session, so there is nothing to revoke. Revoking removes only that exact rule and leaves the rest of the file alone.")) {
                if activity.grants.isEmpty {
                    SRow("checkmark.shield", L("Chưa có luật nào", "No rules yet"),
                         detail: L("Roost chưa cấp luật Luôn cho phép nào.", "Roost hasn't granted any Always allow rules."), divider: false) { EmptyView() }
                } else {
                    ForEach(Array(activity.grants.enumerated()), id: \.element.id) { i, grant in
                        SBlock(divider: i > 0, padding: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(grant.rule).font(.system(size: 11.5, design: .monospaced)).lineLimit(2)
                                    Text(place(grant)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text("\(grant.project), \(Self.time.string(from: grant.time))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if grant.file != nil, grant.confirmed {
                                    Button(L("Thu hồi", "Revoke")) { model.message = activity.revoke(grant) }
                                        .controlSize(.small)
                                        .help(L("Gỡ đúng luật này khỏi permissions.allow. File cũ được sao lưu cạnh bên (.bak-roost-…).", "Removes exactly this rule from permissions.allow. The old file is backed up next to it (.bak-roost-…)."))
                                } else {
                                    Button(L("Bỏ khỏi danh sách", "Remove from list")) { activity.forget(grant) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
                if let message = model.message {
                    SBlock { Text(message).font(.caption).foregroundStyle(.red) }
                }
            }

            SSection(L("Yêu cầu gần đây", "Recent requests")) {
                if activity.history.isEmpty {
                    SRow("clock", L("Chưa có yêu cầu nào", "No requests yet"),
                         detail: L("Chưa có yêu cầu nào từ lúc mở Roost.", "No requests since Roost started."), divider: false) { EmptyView() }
                } else {
                    ForEach(Array(activity.history.prefix(5).enumerated()), id: \.element.id) { i, entry in
                        SBlock(divider: i > 0, padding: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(entry.project)  \(entry.tool)").font(.callout.weight(.medium)).lineLimit(1)
                                    Text(entry.summary).font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Label(entry.outcome.shortTitle, systemImage: entry.outcome.symbol)
                                        .font(.caption).foregroundStyle(Color(nsColor: entry.outcome.color)).lineLimit(1)
                                    Text(entry.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { model.refresh(projects: activity.projects) }
    }

    private func hookDetail(_ found: ClaudeHookDetector.Found) -> String {
        var text = found.events.joined(separator: ", ")
        if !found.events.contains("PermissionRequest") {
            text += "\n" + L("Thiếu PermissionRequest nên thẻ xin quyền sẽ không hiện.", "PermissionRequest is missing, so permission cards won't show.")
        } else if let t = found.timeout, t <= 100 {
            text += "\n" + L("Timeout của hook là \(t) giây, ngắn hơn 100 giây Roost chờ. Nên đặt 110.", "The hook timeout is \(t)s, shorter than the 100s Roost waits. Set it to 110.")
        }
        return text
    }

    private func place(_ grant: ClaudeActivity.Grant) -> String {
        guard let file = grant.file else {
            return L("Chỉ phiên này, hết khi phiên kết thúc", "This session only, gone when it ends")
        }
        let path = ClaudePaths.short(file)
        return grant.confirmed ? path : path + L(" (Claude Code chưa ghi luật này vào file, chỉ bỏ khỏi danh sách được)", " (Claude Code hasn't written this rule to the file, so it can only be removed from the list)")
    }
}

/// Cài đặt › Mức dùng Claude: số liệu hiện tại, nguồn số liệu, kiểu hiển thị, statusLine.
struct ClaudeUsagePane: View {
    @ObservedObject private var extras = ClaudeExtras.shared
    @ObservedObject private var usageAPI = ClaudeUsageAPI.shared
    @StateObject private var copy = CopyFlag()

    var body: some View {
        SPage {
            SSection(L("Hiện tại", "Now")) {
                SBlock(divider: false) { ClaudeUsageRows() }
            }
            SSection(L("Nguồn số liệu", "Data source"),
                     note: L("Roost đọc phiên đăng nhập Claude Code trong Keychain (lần đầu macOS sẽ hỏi, chọn Always Allow) và hỏi mức dùng từ api.anthropic.com mỗi 5 phút, chỉ khi có chỗ đang hiện mức dùng. Token chỉ gửi tới Anthropic, không lưu ở đâu khác. Đây là API Claude Code dùng cho /usage, chưa được công bố nên có thể đổi.",
                             "Roost reads the Claude Code sign-in from the Keychain (macOS asks the first time, choose Always Allow) and asks api.anthropic.com for usage every 5 minutes, only while something shows usage. The token goes only to Anthropic and is never stored elsewhere. This is the API Claude Code uses for /usage; it is unpublished and may change.")) {
                SRow("arrow.triangle.2.circlepath", L("Tự lấy số liệu", "Fetch automatically"),
                     detail: usageAPI.statusText, divider: false) {
                    Toggle("", isOn: $usageAPI.enabled).toggleStyle(.switch).controlSize(.small).tint(SUI.accent)
                }
                SBlock {
                    DisclosureGroup(L("Hoặc dùng statusLine của Claude Code (chỉ chạy trong Terminal)", "Or use the Claude Code statusLine (Terminal only)")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ClaudePane.statusLine).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                            Button(copy.on ? L("Đã chép", "Copied") : L("Chép dòng statusLine", "Copy the statusLine entry")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ClaudePane.statusLine, forType: .string)
                                copy.flash()
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 12.5))
                    .tint(SUI.accent)
                }
            }
            SSection(L("Hiển thị", "Display"),
                     note: L("Trên notch đang mở, mức dùng nằm ở ô trạng thái góc phải. Muốn thấy cả khi thu gọn: Giao diện › Hai bên notch › Mức dùng Claude.",
                             "On the open notch, usage sits in the status pill at the top right. To see it on the closed notch: Appearance › Beside the closed notch › Claude usage."),
                     reset: { extras.usageStyle = .ring; extras.usageShow = .used; extras.resetNotice = true }) {
                SRow("circle.dashed", L("Kiểu", "Style"), divider: false) {
                    SSegmented($extras.usageStyle, Array(ClaudeExtras.UsageStyle.allCases), title: { $0.title }).frame(width: 160)
                }
                SRow("percent", L("Hiển thị phần", "Show")) {
                    SSegmented($extras.usageShow, Array(ClaudeExtras.UsageShow.allCases), title: { $0.title }).frame(width: 220)
                }
                SToggleRow(icon: "bell", title: L("Báo khi hạn mức được đặt lại", "Tell me when a limit resets"),
                           isOn: $extras.resetNotice)
            }
        }
    }
}

@MainActor
private final class CopyFlag: ObservableObject {
    @Published var on = false
    func flash() {
        on = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.on = false }
    }
}
