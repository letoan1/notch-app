import AppKit

enum PermissionDecision {
    case allow, allowAlways, deny
}

struct PermissionRequest: Identifiable {
    let id = UUID()
    let tool: String
    let summary: String
    let detail: String?
    let project: String
    /// `permission_suggestions` nguyên văn, trả lại làm `updatedPermissions` khi "Luôn cho phép".
    let suggestions: [Any]?
    let rawTool: String
    /// `tool_input` nguyên văn: AskUserQuestion / ExitPlanMode cần trả lại qua `updatedInput`.
    let toolInput: [String: Any]
    /// Có giá trị khi đây là AskUserQuestion: hiện thẻ chọn đáp án thay vì Cho phép/Từ chối.
    let questions: [AskQuestion]?
    fileprivate let connection: HookConnection

    var canAlwaysAllow: Bool { !(suggestions ?? []).isEmpty }
}

struct AskQuestion: Identifiable {
    struct Option: Identifiable {
        var id: String { label }
        let label: String
        let description: String
    }

    var id: String { text }
    let text: String
    let header: String
    let options: [Option]
    let multiSelect: Bool

    init?(_ raw: Any) {
        guard let dict = raw as? [String: Any], let text = dict["question"] as? String else { return nil }
        self.text = text
        header = dict["header"] as? String ?? ""
        multiSelect = dict["multiSelect"] as? Bool ?? false
        options = (dict["options"] as? [[String: Any]] ?? []).compactMap {
            guard let label = $0["label"] as? String else { return nil }
            return Option(label: label, description: $0["description"] as? String ?? "")
        }
    }
}

/// Một kết nối từ notch-hook: 1 dòng JSON vào, 1 dòng JSON ra.
/// Hook bị kill / hết giờ → socket đóng → thẻ tự biến mất.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "notch.hook.connection")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var received = false
    private var closed = false

    var onRequest: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32) { self.fd = fd }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [self] in readAvailable() }
        src.setCancelHandler { [fd] in close(fd) }
        source = src
        src.resume()
    }

    func respond(_ json: [String: Any]) {
        queue.async { [self] in
            guard !closed, var data = try? JSONSerialization.data(withJSONObject: json) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { buf in
                var offset = 0
                while offset < buf.count {
                    let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
            finish(notify: false)
        }
    }

    func cancel() {
        queue.async { [self] in finish(notify: false) }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { finish(notify: true); return }
        guard !received else { return }
        buffer.append(chunk, count: n)
        guard let newline = buffer.firstIndex(of: 0x0A) else { return }
        received = true
        guard let obj = try? JSONSerialization.jsonObject(with: buffer[..<newline]) as? [String: Any] else {
            finish(notify: false)
            return
        }
        let handler = onRequest
        DispatchQueue.main.async { handler?(obj) }
    }

    private func finish(notify: Bool) {
        guard !closed else { return }
        closed = true
        source?.cancel()
        if notify {
            let handler = onClose
            DispatchQueue.main.async { handler?() }
        }
    }
}

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var requests: [PermissionRequest] = []

    var current: PermissionRequest? { requests.first }

    static let socketPath = NSHomeDirectory() + "/Library/Application Support/Notch/claude.sock"

    private let queue = DispatchQueue(label: "notch.hook.listener")
    private var acceptSource: DispatchSourceRead?

    func start() {
        let dir = (Self.socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        unlink(Self.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(Self.socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(Self.socketPath, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let conn = HookConnection(fd: client)
            conn.onRequest = { obj in MainActor.assumeIsolated { self?.add(obj, from: conn) } }
            conn.onClose = { MainActor.assumeIsolated { self?.drop(conn) } }
            conn.start()
        }
        acceptSource = src
        src.resume()
    }

    func resolve(_ request: PermissionRequest, _ decision: PermissionDecision) {
        var body: [String: Any]
        switch decision {
        case .allow where request.rawTool == "ExitPlanMode":
            // Tool cần tương tác: "allow" trơn không đủ, phải kèm updatedInput.
            body = ["behavior": "allow", "updatedInput": request.toolInput]
        case .allow:
            body = ["behavior": "allow"]
        case .allowAlways:
            body = ["behavior": "allow", "updatedPermissions": request.suggestions ?? []]
        case .deny:
            body = ["behavior": "deny", "message": L("Người dùng từ chối trên notch.", "The user denied this on the notch.")]
        }
        request.connection.respond([
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body],
        ])
        requests.removeAll { $0.id == request.id }
    }

    /// Trả lời AskUserQuestion: echo nguyên input + `answers` {câu hỏi: nhãn}, chọn nhiều nối bằng ", ".
    func answer(_ request: PermissionRequest, _ answers: [String: String]) {
        var input = request.toolInput
        input["answers"] = answers
        request.connection.respond([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": input],
            ],
        ])
        requests.removeAll { $0.id == request.id }
    }

    /// Bỏ qua trên notch: đóng kết nối không quyết định → hộp thoại gốc (VS Code/terminal) xử lý.
    func dismiss(_ request: PermissionRequest) {
        request.connection.cancel()
        requests.removeAll { $0.id == request.id }
    }

    private func add(_ obj: [String: Any], from conn: HookConnection) {
        let tool = obj["tool_name"] as? String ?? "?"
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let (summary, detail) = Self.summarize(tool: tool, input: input)
        let cwd = obj["cwd"] as? String ?? ""
        requests.append(PermissionRequest(
            tool: Self.displayName(tool),
            summary: summary,
            detail: detail,
            project: (cwd as NSString).lastPathComponent,
            suggestions: obj["permission_suggestions"] as? [Any],
            rawTool: tool,
            toolInput: input,
            questions: tool == "AskUserQuestion"
                ? (input["questions"] as? [Any] ?? []).compactMap(AskQuestion.init)
                : nil,
            connection: conn
        ))
        NSSound(named: "Tink")?.play()
    }

    private func drop(_ conn: HookConnection) {
        requests.removeAll { $0.connection === conn }
    }

    private static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
        return parts.dropFirst().joined(separator: " · ")
    }

    private static func summarize(tool: String, input: [String: Any]) -> (String, String?) {
        func str(_ key: String) -> String? { input[key] as? String }
        let home = NSHomeDirectory()
        func short(_ path: String) -> String {
            path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
        switch tool {
        case "Bash":
            return (str("command") ?? "", str("description"))
        case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
            return (short(str("file_path") ?? str("notebook_path") ?? ""), nil)
        case "WebFetch":
            return (str("url") ?? "", nil)
        case "WebSearch":
            return (str("query") ?? "", nil)
        default:
            return (input.values.compactMap { $0 as? String }.first ?? "", nil)
        }
    }
}
