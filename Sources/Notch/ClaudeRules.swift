import Foundation

/// Một mục trong `permission_suggestions` mà "Luôn cho phép" sẽ trả lại nguyên văn qua `updatedPermissions`.
/// Chỉ chọn đúng 1 mục hẹp nhất, không gộp, không tự chế luật.
struct AllowScope {
    enum Destination: String {
        case session, localSettings, projectSettings, userSettings
    }

    /// Mục gốc của Claude Code, gửi lại y nguyên.
    let entry: [String: Any]
    let type: String
    let destination: Destination
    /// Luật dạng chữ như trong settings: `Bash(npm test:*)`, `mcp__github__get_issue`.
    let rules: [String]
    let mode: String?
    let directories: [String]
    /// Thư mục gốc project (nơi có .claude/) để biết file đích.
    let projectDir: String

    var isSession: Bool { destination == .session }

    /// File settings mà Claude Code sẽ ghi; nil = chỉ trong bộ nhớ của phiên.
    var fileURL: URL? {
        switch destination {
        case .session: return nil
        case .localSettings: return URL(fileURLWithPath: projectDir).appendingPathComponent(".claude/settings.local.json")
        case .projectSettings: return URL(fileURLWithPath: projectDir).appendingPathComponent(".claude/settings.json")
        case .userSettings: return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        }
    }

    /// "Bash(npm test:*)" hoặc mô tả đổi chế độ / thêm thư mục.
    var what: String {
        if !rules.isEmpty { return rules.joined(separator: ", ") }
        if let mode { return Self.modeTitle(mode) }
        if !directories.isEmpty {
            return L("thêm thư mục ", "add folder ") + directories.map(ClaudePaths.short).joined(separator: ", ")
        }
        return type
    }

    /// Nơi lưu, viết đủ câu để người dùng biết trước khi bấm.
    var whereText: String {
        let project = (projectDir as NSString).lastPathComponent
        switch destination {
        case .session: return L("chỉ phiên này, hết khi phiên kết thúc", "this session only, gone when it ends")
        case .localSettings: return L("lưu vào .claude/settings.local.json của \(project)", "saved to \(project)/.claude/settings.local.json")
        case .projectSettings: return L("lưu vào .claude/settings.json của \(project) (file chung của team)", "saved to \(project)/.claude/settings.json (shared with the team)")
        case .userSettings: return L("lưu vào ~/.claude/settings.json, áp cho mọi project", "saved to ~/.claude/settings.json for every project")
        }
    }

    var sentence: String {
        L("Luôn cho phép \(what), \(whereText).", "Always allow \(what), \(whereText).")
    }

    static func modeTitle(_ mode: String) -> String {
        switch mode {
        case "acceptEdits": return L("tự nhận mọi lần sửa file", "auto-accept file edits")
        case "plan": return L("chế độ lập kế hoạch", "plan mode")
        case "auto": return L("chế độ tự động", "auto mode")
        case "dontAsk": return L("chế độ không hỏi", "don't-ask mode")
        case "bypassPermissions": return L("bỏ qua mọi quyền", "bypass all permissions")
        default: return L("chế độ thường", "default mode")
        }
    }

    /// Chuỗi luật đúng cú pháp settings: thiếu ruleContent = cả tool.
    static func ruleString(_ rule: [String: Any]) -> String? {
        guard let tool = rule["toolName"] as? String, !tool.isEmpty else { return nil }
        guard let content = rule["ruleContent"] as? String, !content.isEmpty else { return tool }
        return "\(tool)(\(content))"
    }

    init?(entry: [String: Any], projectDir: String) {
        guard let type = entry["type"] as? String,
              let destination = Destination(rawValue: entry["destination"] as? String ?? "") else { return nil }
        self.entry = entry
        self.type = type
        self.destination = destination
        self.projectDir = projectDir
        let rawRules = entry["rules"] as? [[String: Any]] ?? []
        rules = rawRules.compactMap(Self.ruleString)
        mode = entry["mode"] as? String
        directories = entry["directories"] as? [String] ?? []
        switch type {
        case "addRules":
            // Chỉ nhận luật "allow" có ít nhất một luật đọc được.
            guard entry["behavior"] as? String == "allow", !rules.isEmpty, rules.count == rawRules.count else { return nil }
        case "setMode":
            // Đổi chế độ chỉ chấp nhận trong phạm vi phiên; bypass thì không bao giờ.
            guard let mode, destination == .session, mode != "bypassPermissions" else { return nil }
        case "addDirectories":
            guard !directories.isEmpty, destination == .session else { return nil }
        default:
            return nil
        }
    }

    /// Mục hẹp nhất: luật có nội dung cụ thể > luật cả tool > thêm thư mục (phiên) > đổi chế độ (phiên).
    /// Cùng hạng thì ưu tiên ít luật hơn, rồi phạm vi lưu hẹp hơn.
    static func narrowest(_ suggestions: [Any]?, projectDir: String) -> AllowScope? {
        let scopes = (suggestions ?? []).compactMap { ($0 as? [String: Any]).flatMap { AllowScope(entry: $0, projectDir: projectDir) } }
        func rank(_ s: AllowScope) -> (Int, Int, Int) {
            let kind: Int
            switch s.type {
            case "addRules":
                let wholeTool = (s.entry["rules"] as? [[String: Any]] ?? []).contains { ($0["ruleContent"] as? String ?? "").isEmpty }
                kind = wholeTool ? 1 : 0
            case "addDirectories": kind = 2
            default: kind = 3
            }
            let place: Int
            switch s.destination {
            case .session: place = 0
            case .localSettings: place = 1
            case .projectSettings: place = 2
            case .userSettings: place = 3
            }
            return (kind, s.rules.count, place)
        }
        return scopes.min { rank($0) < rank($1) }
    }
}

enum ClaudePaths {
    static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Đọc / gỡ luật trong file settings của Claude Code.
enum ClaudeRulesFile {
    enum RevokeError: LocalizedError {
        case unreadable, notFound, writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return L("Không đọc được file settings.", "Couldn't read the settings file.")
            case .notFound: return L("Không thấy luật này trong permissions.allow (có thể đã bị gỡ).", "This rule isn't in permissions.allow anymore (it may have been removed).")
            case let .writeFailed(why): return L("Không ghi được file: \(why)", "Couldn't write the file: \(why)")
            }
        }
    }

    static func allowList(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = root["permissions"] as? [String: Any] else { return [] }
        return permissions["allow"] as? [String] ?? []
    }

    /// Gỡ đúng một chuỗi luật khỏi `permissions.allow`. Sao lưu file cạnh bên trước khi ghi.
    /// Ưu tiên sửa tại chỗ trên văn bản (giữ nguyên thứ tự key, thụt lề); chỉ ghi lại toàn bộ khi cách đó không khớp.
    @discardableResult
    static func revoke(rule: String, in url: URL) throws -> URL {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RevokeError.unreadable }
        guard var permissions = root["permissions"] as? [String: Any],
              var allow = permissions["allow"] as? [String],
              let index = allow.firstIndex(of: rule) else { throw RevokeError.notFound }
        allow.remove(at: index)
        permissions["allow"] = allow
        root["permissions"] = permissions
        let expected = root as NSDictionary

        let output: Data
        if let edited = textualRemoval(of: rule, in: text, expected: expected) {
            output = Data(edited.utf8)
        } else {
            do {
                output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
            } catch {
                throw RevokeError.writeFailed(error.localizedDescription)
            }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = URL(fileURLWithPath: url.path + ".bak-roost-" + stamp.string(from: Date()))
        do {
            try data.write(to: backup, options: .withoutOverwriting)
            try output.write(to: url, options: .atomic)
        } catch {
            throw RevokeError.writeFailed(error.localizedDescription)
        }
        return backup
    }

    /// Xoá phần tử chuỗi khỏi văn bản JSON rồi parse lại để chắc kết quả đúng bằng bản mong muốn.
    private static func textualRemoval(of rule: String, in text: String, expected: NSDictionary) -> String? {
        guard let encoded = try? JSONSerialization.data(withJSONObject: [rule], options: [.withoutEscapingSlashes]),
              let array = String(data: encoded, encoding: .utf8) else { return nil }
        let literal = String(array.dropFirst().dropLast())
        var search = text.startIndex..<text.endIndex
        while let found = text.range(of: literal, range: search) {
            search = found.upperBound..<text.endIndex
            var start = found.lowerBound
            var end = found.upperBound
            var before = start
            while before > text.startIndex, text[text.index(before: before)].isWhitespace { before = text.index(before: before) }
            if before > text.startIndex, text[text.index(before: before)] == "," {
                start = text.index(before: before)
            } else {
                var after = end
                while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
                if after < text.endIndex, text[after] == "," {
                    end = text.index(after: after)
                    while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
                } else {
                    // Phần tử duy nhất: gỡ cả khoảng trắng hai bên → "[]".
                    start = before
                    end = after
                }
            }
            var candidate = text
            candidate.removeSubrange(start..<end)
            if let parsed = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? NSDictionary,
               parsed.isEqual(expected) {
                return candidate
            }
        }
        return nil
    }
}

/// Hook nào của Roost đang được cấu hình ở đâu (chỉ đọc).
enum ClaudeHookDetector {
    struct Found: Identifiable {
        var id: String { file }
        let file: String
        let events: [String]
        let timeout: Int?
    }

    static func scan(projects: [String]) -> [Found] {
        var files = [NSHomeDirectory() + "/.claude/settings.json", NSHomeDirectory() + "/.claude/settings.local.json"]
        // Hook có thể nằm ở thư mục cha của project (vd. workspace chứa nhiều repo): dò ngược lên tới $HOME.
        let home = NSHomeDirectory()
        for dir in projects {
            var url = URL(fileURLWithPath: dir).standardizedFileURL
            while url.path.hasPrefix(home), url.path != home {
                files.append(url.path + "/.claude/settings.json")
                files.append(url.path + "/.claude/settings.local.json")
                url.deleteLastPathComponent()
            }
        }
        var seen = Set<String>()
        return files.compactMap { file in
            guard seen.insert(file).inserted,
                  let data = FileManager.default.contents(atPath: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = root["hooks"] as? [String: Any] else { return nil }
            var events: [String] = []
            var timeout: Int?
            for (event, value) in hooks {
                let groups = value as? [[String: Any]] ?? []
                let commands = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                let ours = commands.filter {
                    let cmd = $0["command"] as? String ?? ""
                    return cmd.contains("roost-hook") || cmd.contains("notch-hook")
                }
                guard !ours.isEmpty else { continue }
                events.append(event)
                if event == "PermissionRequest" { timeout = ours.first?["timeout"] as? Int }
            }
            guard !events.isEmpty else { return nil }
            return Found(file: file, events: events.sorted(), timeout: timeout)
        }
    }
}
