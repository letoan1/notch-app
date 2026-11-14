import AppKit

/// Lịch sử yêu cầu (trong bộ nhớ) + các luật "Luôn cho phép" Roost đã cấp (UserDefaults) + trạng thái socket.
/// Tách khỏi PermissionCenter để Cài đặt đọc được mà không cần tham chiếu tới NotchController.
@MainActor
final class ClaudeActivity: ObservableObject {
    static let shared = ClaudeActivity()

    struct HistoryEntry: Identifiable {
        let id = UUID()
        let time: Date
        let project: String
        let tool: String
        let summary: String
        let outcome: RequestState
    }

    struct Grant: Codable, Identifiable, Equatable {
        var id: UUID
        var rule: String
        /// nil = luật chỉ trong phiên (không có file để gỡ).
        var file: String?
        var destination: String
        var project: String
        var session: String
        var time: Date
        /// Đã thấy luật xuất hiện trong file sau khi cấp.
        var confirmed: Bool
    }

    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var grants: [Grant] = []
    @Published var listening = false
    @Published var listenError: String?
    /// Thư mục project đã gặp gần đây (để dò cấu hình hook).
    @Published private(set) var projects: [String] = []

    private static let grantsKey = "claude.grants"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.grantsKey),
           let saved = try? JSONDecoder().decode([Grant].self, from: data) {
            grants = saved
        }
    }

    func record(_ request: PermissionRequest, _ outcome: RequestState) {
        history.insert(HistoryEntry(time: Date(), project: request.project, tool: request.tool,
                                    summary: request.summary, outcome: outcome), at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
    }

    func noteProject(_ dir: String) {
        guard !dir.isEmpty else { return }
        projects.removeAll { $0 == dir }
        projects.insert(dir, at: 0)
        if projects.count > 6 { projects.removeLast() }
    }

    /// Ghi lại luật vừa cấp. Luật lưu file: đọc lại file sau vài giây để lấy đúng chuỗi Claude Code đã ghi.
    func granted(_ scope: AllowScope, for request: PermissionRequest, before: [String]) {
        let file = scope.fileURL?.path
        let rules = scope.rules.isEmpty ? [scope.what] : scope.rules
        let fresh = rules.map {
            Grant(id: UUID(), rule: $0, file: file, destination: scope.destination.rawValue,
                  project: request.project, session: request.session, time: Date(), confirmed: false)
        }
        grants.insert(contentsOf: fresh, at: 0)
        save()
        guard let url = scope.fileURL, !scope.rules.isEmpty else { return }
        let ids = fresh.map(\.id)
        let toolNames = Set((scope.entry["rules"] as? [[String: Any]] ?? []).compactMap { $0["toolName"] as? String })
        for delay in [1.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.confirm(ids: ids, url: url, before: before, toolNames: toolNames)
            }
        }
    }

    private func confirm(ids: [UUID], url: URL, before: [String], toolNames: Set<String>) {
        let now = ClaudeRulesFile.allowList(url)
        let added = now.filter { !before.contains($0) }
        var changed = false
        var unmatched = added
        for id in ids {
            guard let i = grants.firstIndex(where: { $0.id == id }), !grants[i].confirmed else { continue }
            // Luật đã có từ trước khi cấp thì không phải của Roost: không nhận, để không gỡ nhầm.
            if now.contains(grants[i].rule), !before.contains(grants[i].rule) {
                grants[i].confirmed = true
                unmatched.removeAll { $0 == grants[i].rule }
                changed = true
            }
        }
        // Claude Code ghi khác chữ (thoát ký tự…): nhận chuỗi mới xuất hiện cùng tool làm luật thật.
        for id in ids {
            guard let i = grants.firstIndex(where: { $0.id == id }), !grants[i].confirmed,
                  let real = unmatched.first(where: { rule in toolNames.contains { rule == $0 || rule.hasPrefix($0 + "(") } })
            else { continue }
            unmatched.removeAll { $0 == real }
            grants[i].rule = real
            grants[i].confirmed = true
            changed = true
        }
        if changed { save() }
    }

    /// Gỡ luật khỏi file đích (có sao lưu). Luật phiên, hoặc luật chưa thấy Claude Code ghi vào file,
    /// chỉ xoá khỏi danh sách để không đụng tới luật người dùng tự thêm.
    func revoke(_ grant: Grant) -> String? {
        if let file = grant.file, grant.confirmed {
            do {
                try ClaudeRulesFile.revoke(rule: grant.rule, in: URL(fileURLWithPath: file))
            } catch ClaudeRulesFile.RevokeError.notFound {
                // Không còn trong file: coi như đã gỡ, vẫn bỏ khỏi danh sách.
            } catch {
                return error.localizedDescription
            }
        }
        grants.removeAll { $0.id == grant.id }
        save()
        return nil
    }

    func forget(_ grant: Grant) {
        grants.removeAll { $0.id == grant.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(grants) {
            UserDefaults.standard.set(data, forKey: Self.grantsKey)
        }
    }
}

/// App đang chứa phiên Claude Code (VS Code, Cursor, Terminal, iTerm2, Warp, Ghostty…).
struct HostApp {
    let name: String
    let bundleID: String?
    let pid: pid_t
    let bundleURL: URL?
    let icon: NSImage?

    /// Editor họ VS Code → tên thư mục dữ liệu trong ~/Library/Application Support.
    private static let codeEditors = [
        "com.microsoft.VSCode": "Code", "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
    ]

    var isCodeEditor: Bool { Self.codeEditors[bundleID ?? ""] != nil }

    /// Leo cây tiến trình từ PID của Claude Code lên tới app GUI đầu tiên; không thấy thì dùng bundle id
    /// mà hook đọc từ môi trường (__CFBundleIdentifier, vd. iTerm2 chạy shell qua tiến trình con của launchd).
    static func resolve(claudePid: pid_t?, bundleID: String?) -> HostApp? {
        var pid = claudePid ?? 0
        var hops = 0
        while pid > 1, hops < 24 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return HostApp(app)
            }
            pid = parentPID(of: pid)
            hops += 1
        }
        if let bundleID, !bundleID.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return HostApp(app)
        }
        return nil
    }

    private init(_ app: NSRunningApplication) {
        name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App"
        bundleID = app.bundleIdentifier
        pid = app.processIdentifier
        bundleURL = app.bundleURL
        icon = app.icon
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    /// Đưa app lên trước. Editor họ VS Code: nếu một cửa sổ đang mở đúng project (theo storage.json của editor)
    /// thì mở lại thư mục / workspace đó để editor focus cửa sổ ấy; không chắc thì chỉ kích hoạt app,
    /// không mở cửa sổ mới. Chỉ chạy khi người dùng bấm nút.
    func bringToFront(cwd: String, projectDir: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let url = bundleURL, let target = editorWindow(cwd: cwd, projectDir: projectDir) {
            NSWorkspace.shared.open([target], withApplicationAt: url, configuration: config)
        } else if let url = bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Cửa sổ editor chứa project: thư mục bằng projectDir, hoặc là thư mục cha gần nhất của cwd.
    private func editorWindow(cwd: String, projectDir: String) -> URL? {
        guard let folder = Self.codeEditors[bundleID ?? ""] else { return nil }
        let path = NSHomeDirectory() + "/Library/Application Support/\(folder)/User/globalStorage/storage.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["windowsState"] as? [String: Any] else { return nil }
        var windows = state["openedWindows"] as? [[String: Any]] ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.insert(last, at: 0) }
        var best: (URL, Int)?
        for window in windows {
            var target: URL?
            var dirs: [String] = []
            if let uri = window["folder"] as? String, let url = URL(string: uri), url.isFileURL {
                target = url
                dirs = [url.path]
            } else if let workspace = window["workspaceIdentifier"] as? [String: Any],
                      let uri = workspace["configURIPath"] as? String, let url = URL(string: uri), url.isFileURL {
                target = url
                dirs = Self.workspaceFolders(url)
            }
            guard let target else { continue }
            for dir in dirs where dir == projectDir || cwd == dir || cwd.hasPrefix(dir + "/") {
                if best == nil || dir.count > best!.1 { best = (target, dir.count) }
            }
        }
        return best?.0
    }

    private static func workspaceFolders(_ file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #""folders"\s*:\s*\[[^\]]*\]"#, options: .regularExpression) else { return [] }
        let base = file.deletingLastPathComponent()
        let pattern = try? NSRegularExpression(pattern: #""path"\s*:\s*"([^"]+)""#)
        let chunk = String(text[range])
        let matches = pattern?.matches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)) ?? []
        return matches.compactMap { m in
            Range(m.range(at: 1), in: chunk).map { raw in
                let p = String(chunk[raw])
                return p.hasPrefix("/") ? p : base.appendingPathComponent(p).standardizedFileURL.path
            }
        }
    }
}

/// Tên phiên đọc từ cuối transcript: tiêu đề đặt tay / AI đặt, không có thì câu lệnh gần nhất.
enum SessionTitles {
    private static let queue = DispatchQueue(label: "roost.session-titles", qos: .utility)

    static func load(transcript: String, completion: @escaping @Sendable (String?) -> Void) {
        guard !transcript.isEmpty else { completion(nil); return }
        queue.async {
            let title = read(transcript)
            DispatchQueue.main.async { completion(title) }
        }
    }

    private static func read(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8)
                ?? String(data: data.dropFirst(), encoding: .utf8) else { return nil }
        var custom: String?
        var ai: String?
        var prompt: String?
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"custom-title\"") || line.contains("\"ai-title\"") || line.contains("\"last-prompt\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "custom-title": custom = custom ?? obj["customTitle"] as? String
            case "ai-title": ai = ai ?? obj["aiTitle"] as? String
            case "last-prompt": prompt = prompt ?? obj["lastPrompt"] as? String
            default: break
            }
            if custom != nil { break }
        }
        let title = (custom ?? ai ?? prompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return title.count > 60 ? String(title.prefix(58)) + "…" : title
    }
}
