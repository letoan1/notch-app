import AppKit
import SwiftUI

@MainActor
private final class ClaudePaneModel: ObservableObject {
    @Published var hooks: [ClaudeHookDetector.Found] = []
    @Published var socketExists = false
    @Published var message: String?

    func refresh(projects: [String]) {
        socketExists = FileManager.default.fileExists(atPath: PermissionCenter.socketPath)
        hooks = ClaudeHookDetector.scan(projects: projects)
    }
}

/// Cài đặt › Claude Code: trạng thái hook, lịch sử gần đây, các luật "Luôn cho phép" đã cấp và nút thu hồi.
struct ClaudePane: View {
    @ObservedObject private var activity = ClaudeActivity.shared
    @StateObject private var model = ClaudePaneModel()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Socket của Roost", "Roost socket")) {
                    if activity.listening && model.socketExists {
                        Label(L("Đang nghe", "Listening"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label(activity.listenError ?? L("Không nghe được", "Not listening"), systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if model.hooks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Chưa thấy hook roost-hook trong ~/.claude/settings.json hay settings của các project gần đây.", "No roost-hook entry found in ~/.claude/settings.json or in the settings of recent projects."))
                            .foregroundStyle(.secondary)
                        Button(L("Mở hướng dẫn cài đặt", "Open the setup guide")) { OnboardingWindowController.shared.show() }
                    }
                } else {
                    ForEach(model.hooks) { found in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ClaudePaths.short(found.file)).font(.system(size: 11, design: .monospaced))
                            Text(found.events.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            if !found.events.contains("PermissionRequest") {
                                Text(L("Thiếu PermissionRequest nên thẻ xin quyền sẽ không hiện.", "PermissionRequest is missing, so permission cards won't show."))
                                    .font(.caption).foregroundStyle(.orange)
                            } else if let t = found.timeout, t <= 100 {
                                Text(L("Timeout của hook là \(t) giây, ngắn hơn 100 giây Roost chờ. Nên đặt 110.", "The hook timeout is \(t)s, shorter than the 100s Roost waits. Set it to 110."))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                Button(L("Kiểm tra lại", "Check again")) { model.refresh(projects: activity.projects) }
            } header: {
                Text(L("Kết nối", "Connection"))
            } footer: {
                Text(L("Mỗi thẻ chờ tối đa 100 giây (đổi bằng biến NOTCH_HOOK_TIMEOUT), luôn ngắn hơn timeout 110 giây của hook trong Claude Code. Hết giờ, Roost tắt app hay hook lỗi thì Claude Code hỏi lại ở terminal như bình thường, không bao giờ bị treo.", "Each card waits up to 100 seconds (set NOTCH_HOOK_TIMEOUT to change it), always less than the 110 second hook timeout in Claude Code. If time runs out, Roost quits or the hook fails, Claude Code simply asks in the terminal. It never hangs."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Yêu cầu gần đây", "Recent requests")) {
                if activity.history.isEmpty {
                    Text(L("Chưa có yêu cầu nào từ lúc mở Roost.", "No requests since Roost started.")).foregroundStyle(.secondary)
                } else {
                    ForEach(activity.history.prefix(5)) { entry in
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

            Section {
                if activity.grants.isEmpty {
                    Text(L("Roost chưa cấp luật Luôn cho phép nào.", "Roost hasn't granted any Always allow rules.")).foregroundStyle(.secondary)
                } else {
                    ForEach(activity.grants) { grant in
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(grant.rule).font(.system(size: 11.5, design: .monospaced)).lineLimit(2)
                                Text(place(grant)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text("\(grant.project), \(Self.time.string(from: grant.time))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if grant.file != nil, grant.confirmed {
                                Button(L("Thu hồi", "Revoke")) {
                                    model.message = activity.revoke(grant)
                                }
                                .help(L("Gỡ đúng luật này khỏi permissions.allow. File cũ được sao lưu cạnh bên (.bak-roost-…).", "Removes exactly this rule from permissions.allow. The old file is backed up next to it (.bak-roost-…)."))
                            } else {
                                Button(L("Bỏ khỏi danh sách", "Remove from list")) { activity.forget(grant) }
                            }
                        }
                    }
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(L("Luôn cho phép do Roost cấp", "Always allow rules granted by Roost"))
            } footer: {
                Text(L("Luật chỉ trong phiên sẽ hết khi phiên Claude Code kết thúc nên không cần thu hồi. Thu hồi chỉ gỡ đúng chuỗi luật đó, các luật khác trong file giữ nguyên.", "Session-only rules end with the Claude Code session, so there is nothing to revoke. Revoking removes only that exact rule and leaves the rest of the file alone."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh(projects: activity.projects) }
    }

    private func place(_ grant: ClaudeActivity.Grant) -> String {
        guard let file = grant.file else {
            return L("Chỉ phiên này, hết khi phiên kết thúc", "This session only, gone when it ends")
        }
        let path = ClaudePaths.short(file)
        return grant.confirmed ? path : path + L(" (Claude Code chưa ghi luật này vào file, chỉ bỏ khỏi danh sách được)", " (Claude Code hasn't written this rule to the file, so it can only be removed from the list)")
    }
}
