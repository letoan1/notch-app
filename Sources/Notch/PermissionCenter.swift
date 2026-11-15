import AppKit

enum PermissionDecision {
    case allow, allowAlways, deny
}

/// Loại yêu cầu: xin dùng tool, câu hỏi (AskUserQuestion), duyệt kế hoạch (ExitPlanMode).
enum RequestKind {
    case tool, question, plan
}

/// Vòng đời một thẻ: Chờ → kết quả (hiện ~1 s) → rời hàng đợi.
enum RequestState: Equatable {
    case waiting
    case allowed, allowedAlways, denied, answered
    case expired            // hook hết giờ chờ
    case answeredElsewhere  // đã trả lời ở terminal / VS Code (PostToolUse, Stop…)
    case cancelled          // kết nối đóng: Claude Code dừng / hook bị kill
    case handedOff          // người dùng chọn trả lời ở app gốc

    var isWaiting: Bool { self == .waiting }

    var title: String {
        switch self {
        case .waiting: return L("Đang chờ", "Waiting")
        case .allowed: return L("Đã cho phép", "Allowed")
        case .allowedAlways: return L("Đã cho phép luôn", "Always allowed")
        case .denied: return L("Đã từ chối", "Denied")
        case .answered: return L("Đã gửi câu trả lời", "Answer sent")
        case .expired: return L("Hết giờ, Claude hỏi lại ở terminal", "Timed out, Claude asks in the terminal")
        case .answeredElsewhere: return L("Đã trả lời ở nơi khác", "Answered elsewhere")
        case .cancelled: return L("Claude đã ngừng chờ", "Claude stopped waiting")
        case .handedOff: return L("Trả lời ở app gốc", "Answer in the original app")
        }
    }

    /// Nhãn ngắn cho lịch sử.
    var shortTitle: String {
        switch self {
        case .expired: return L("Hết giờ", "Timed out")
        case .handedOff: return L("Chuyển về app gốc", "Sent back")
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "hourglass"
        case .allowed, .answered: return "checkmark.circle.fill"
        case .allowedAlways: return "checkmark.seal.fill"
        case .denied: return "xmark.circle.fill"
        case .expired: return "clock.badge.xmark"
        case .answeredElsewhere: return "arrow.uturn.right.circle"
        case .cancelled: return "minus.circle"
        case .handedOff: return "arrow.up.forward.app"
        }
    }

    var color: NSColor {
        switch self {
        case .allowed, .allowedAlways, .answered: return .systemGreen
        case .denied: return .systemRed
        case .expired: return .systemOrange
        default: return .systemGray
        }
    }
}

struct PermissionRequest: Identifiable {
    /// request_id do hook sinh, duy nhất cho mỗi lần hỏi.
    let id: String
    let kind: RequestKind
    let tool: String
    let summary: String
    let detail: String?
    /// Tên thư mục của cwd; `cwd` đầy đủ để hiện khi rê chuột.
    let project: String
    let cwd: String
    /// Thư mục gốc project (CLAUDE_PROJECT_DIR), nơi Claude Code ghi .claude/settings*.json.
    let projectDir: String
    /// `permission_suggestions` nguyên văn (chỉ để hiển thị / gỡ lỗi).
    let suggestions: [Any]?
    /// Mục hẹp nhất trong số gợi ý; nil = ẩn "Luôn cho phép".
    let allowScope: AllowScope?
    let rawTool: String
    /// `tool_input` nguyên văn: AskUserQuestion / ExitPlanMode cần trả lại qua `updatedInput`.
    let toolInput: [String: Any]
    /// Có giá trị khi đây là AskUserQuestion: hiện thẻ chọn đáp án thay vì Cho phép/Từ chối.
    let questions: [AskQuestion]?
    /// Khớp thẻ với event sau đó (trả lời ở terminal → PostToolUse/Stop… của cùng session).
    let session: String
    var sessionTitle: String?
    let inputKey: String
    let host: HostApp?
    let received: Date
    /// Lúc hook bỏ cuộc (thời điểm hook bắt đầu + timeout của hook).
    let deadline: Date
    let timeout: TimeInterval
    var state: RequestState = .waiting
    fileprivate let connection: HookConnection

    var canAlwaysAllow: Bool { allowScope != nil }

    /// "phiên 1a2b3c4d" khi chưa đọc được tiêu đề.
    var sessionLabel: String {
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        return session.isEmpty ? L("phiên không rõ", "unknown session") : L("phiên ", "session ") + session.prefix(8)
    }

    var kindTitle: String {
        switch kind {
        case .question: return L("Claude hỏi", "Claude asks")
        case .plan: return L("Claude trình kế hoạch", "Claude has a plan")
        case .tool:
            switch rawTool {
            case "Bash": return L("Claude muốn chạy lệnh", "Claude wants to run a command")
            case "Edit", "MultiEdit", "NotebookEdit": return L("Claude muốn sửa file", "Claude wants to edit a file")
            case "Write": return L("Claude muốn ghi file", "Claude wants to write a file")
            case "Read": return L("Claude muốn đọc file", "Claude wants to read a file")
            case "WebFetch": return L("Claude muốn mở trang web", "Claude wants to fetch a page")
            case "WebSearch": return L("Claude muốn tìm trên web", "Claude wants to search the web")
            default:
                return rawTool.hasPrefix("mcp__") ? L("Claude muốn dùng công cụ MCP", "Claude wants to use an MCP tool")
                    : L("Claude xin quyền", "Claude needs permission")
            }
        }
    }

    var kindSymbol: String {
        switch kind {
        case .question: return "questionmark.bubble.fill"
        case .plan: return "list.bullet.clipboard.fill"
        case .tool:
            switch rawTool {
            case "Bash": return "terminal.fill"
            case "Edit", "MultiEdit", "NotebookEdit", "Write": return "pencil.line"
            case "Read": return "doc.text.magnifyingglass"
            case "WebFetch", "WebSearch": return "globe"
            default: return rawTool.hasPrefix("mcp__") ? "puzzlepiece.extension.fill" : "lock.shield.fill"
            }
        }
    }

    /// Tooltip nguồn gốc: đường dẫn đầy đủ + phiên + app.
    var originHelp: String {
        var lines = [cwd.isEmpty ? project : cwd]
        lines.append(L("Phiên: ", "Session: ") + sessionLabel + (session.isEmpty ? "" : " (\(session))"))
        if let host { lines.append(L("Chạy trong ", "Running in ") + host.name) }
        return lines.joined(separator: "\n")
    }
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

/// Một kết nối từ roost-hook: 1 dòng JSON vào, 1 dòng JSON ra.
/// Hook bị kill / hết giờ → socket đóng → thẻ chuyển trạng thái rồi rời hàng đợi.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "notch.hook.connection")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var received = false
    private var closed = false
    private static let maxRequest = 16 * 1024 * 1024

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

    /// Gửi trả lời rồi đóng. `done(true)` chỉ khi đã ghi đủ vào socket còn sống.
    func respond(_ json: [String: Any], done: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard !closed, var data = try? JSONSerialization.data(withJSONObject: json) else {
                DispatchQueue.main.async { done(false) }
                return
            }
            data.append(0x0A)
            let ok = data.withUnsafeBytes { buf -> Bool in
                var offset = 0
                while offset < buf.count {
                    let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EINTR { continue }
                    return false
                }
                return true
            }
            finish(notify: false)
            DispatchQueue.main.async { done(ok) }
        }
    }

    func cancel() {
        queue.async { [self] in finish(notify: false) }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else {
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            finish(notify: true)
            return
        }
        guard !received else { return }
        buffer.append(chunk, count: n)
        guard buffer.count <= Self.maxRequest else { finish(notify: false); return }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return }
        received = true
        guard let obj = try? JSONSerialization.jsonObject(with: buffer[..<newline]) as? [String: Any] else {
            finish(notify: false)
            return
        }
        buffer = Data()
        let handler = onRequest
        DispatchQueue.main.async { handler?(obj) }
    }

    private func finish(notify: Bool) {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        let handler = onClose
        // Hai closure giữ chính kết nối này: bỏ đi để không rò ~0.5 KB mỗi yêu cầu của Claude.
        onRequest = nil
        onClose = nil
        if notify { DispatchQueue.main.async { handler?() } }
    }
}

@MainActor
final class PermissionCenter: ObservableObject {
    /// Mọi thẻ, cũ trước mới sau; mỗi thẻ có kết nối riêng, không có trạng thái "trả lời hiện tại" dùng chung.
    @Published private(set) var requests: [PermissionRequest] = []
    /// Thẻ người dùng đang xem. Không tự chuyển khỏi một thẻ còn chờ (tránh bấm nhầm thẻ vừa thay).
    @Published private(set) var selectedID: String?

    /// Instance đang chạy (QueueStrip cần để chọn thẻ).
    private(set) static weak var active: PermissionCenter?

    /// Phiên Claude cần bạn (Notification hook) → notch hiện thông báo nhanh.
    var onNotice: ((ClaudeNotice) -> Void)?

    var current: PermissionRequest? {
        requests.first { $0.id == selectedID } ?? requests.first
    }

    var waitingCount: Int { requests.filter(\.state.isWaiting).count }

    static let socketPath = NSHomeDirectory() + "/Library/Application Support/Roost/claude.sock"

    private let queue = DispatchQueue(label: "notch.hook.listener")
    private var acceptSource: DispatchSourceRead?
    private var selectionChanged = Date.distantPast
    private var titles: [String: String] = [:]
    private let activity = ClaudeActivity.shared

    init() { Self.active = self }

    func start() {
        Self.active = self
        let dir = (Self.socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        unlink(Self.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { activity.listenError = String(cString: strerror(errno)); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(Self.socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            activity.listenError = L("Đường dẫn socket quá dài", "Socket path too long")
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            activity.listenError = String(cString: strerror(errno))
            close(fd)
            return
        }
        chmod(Self.socketPath, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                let conn = HookConnection(fd: client)
                conn.onRequest = { obj in MainActor.assumeIsolated { self?.add(obj, from: conn) } }
                conn.onClose = { MainActor.assumeIsolated { self?.closed(conn) } }
                conn.start()
            }
        }
        acceptSource = src
        src.resume()
        activity.listening = true
        activity.listenError = nil
    }

    /// Socket còn đó và còn nghe (cho Cài đặt).
    func isListening() -> Bool { acceptSource != nil && FileManager.default.fileExists(atPath: Self.socketPath) }

    // MARK: - Chọn thẻ

    func select(_ id: String) {
        guard id != selectedID, requests.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selectionChanged = Date()
    }

    func selectNext(_ step: Int) {
        guard let current, let i = requests.firstIndex(where: { $0.id == current.id }), !requests.isEmpty else { return }
        let j = (i + step + requests.count) % requests.count
        select(requests[j].id)
    }

    // MARK: - Trả lời

    func resolve(_ request: PermissionRequest, _ decision: PermissionDecision) {
        guard let live = waiting(request.id) else { return }
        var body: [String: Any]
        var outcome: RequestState
        var scope: AllowScope?
        switch decision {
        case .allow where live.kind == .plan:
            // Tool cần tương tác: "allow" trơn không đủ, phải kèm updatedInput.
            body = ["behavior": "allow", "updatedInput": live.toolInput]
            outcome = .allowed
        case .allow:
            body = ["behavior": "allow"]
            outcome = .allowed
        case .allowAlways:
            // Chỉ gửi đúng một gợi ý hẹp nhất của Claude Code, không gộp các gợi ý khác.
            guard let s = live.allowScope else { return }
            scope = s
            body = ["behavior": "allow", "updatedPermissions": [s.entry]]
            if live.kind == .plan { body["updatedInput"] = live.toolInput }
            outcome = .allowedAlways
        case .deny:
            let message = live.kind == .plan
                ? L("Người dùng chưa duyệt kế hoạch này trên notch.", "The user did not approve this plan on the notch.")
                : L("Người dùng từ chối trên notch.", "The user denied this on the notch.")
            body = ["behavior": "deny", "message": message]
            outcome = .denied
        }
        let before = scope?.fileURL.map(ClaudeRulesFile.allowList) ?? []
        send(live, body: body, outcome: outcome) { [weak self] in
            if let scope { self?.activity.granted(scope, for: live, before: before) }
        }
    }

    /// Trả lời AskUserQuestion: echo nguyên input + `answers` {câu hỏi: nhãn}, chọn nhiều nối bằng ", ".
    func answer(_ request: PermissionRequest, _ answers: [String: String]) {
        guard let live = waiting(request.id) else { return }
        var input = live.toolInput
        input["answers"] = answers
        send(live, body: ["behavior": "allow", "updatedInput": input], outcome: .answered, then: nil)
    }

    /// Trả lời ở app gốc: đóng kết nối không quyết định (hộp thoại gốc vẫn đang mở) rồi đưa app đó lên trước.
    func dismiss(_ request: PermissionRequest) {
        guard let live = waiting(request.id) else { return }
        live.connection.cancel()
        finish(live.id, .handedOff, linger: 0.6)
        live.host?.bringToFront(cwd: live.cwd, projectDir: live.projectDir)
    }

    /// Mở app chứa phiên (nút trên thẻ), không đổi trạng thái thẻ.
    func openHost(_ request: PermissionRequest) {
        request.host?.bringToFront(cwd: request.cwd, projectDir: request.projectDir)
    }

    /// Thẻ còn chờ với đúng id; chặn bấm trong 0,3 s đầu sau khi thẻ vừa đổi (bấm nhầm thẻ mới).
    private func waiting(_ id: String) -> PermissionRequest? {
        guard let live = requests.first(where: { $0.id == id }), live.state.isWaiting else { return nil }
        if id == selectedID, Date().timeIntervalSince(selectionChanged) < 0.3 { return nil }
        // Sát hạn chót thì hook có thể đã thoát trước khi nhận được: coi như hết giờ.
        if Date() >= live.deadline.addingTimeInterval(-0.3) { finish(id, .expired, linger: 1.4); return nil }
        return live
    }

    private func send(_ request: PermissionRequest, body: [String: Any], outcome: RequestState,
                      then: (@MainActor () -> Void)?) {
        let id = request.id
        // Khoá thẻ ngay: bấm lần hai không gửi thêm gì.
        setState(id, outcome)
        request.connection.respond([
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body],
        ]) { ok in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                if ok {
                    then?()
                    self.finish(id, outcome, linger: 1.0)
                } else {
                    self.finish(id, .cancelled, linger: 1.4)
                }
            }
        }
    }

    // MARK: - Nhận yêu cầu

    private func add(_ obj: [String: Any], from conn: HookConnection) {
        if let event = obj["notch_event"] as? String {
            conn.cancel()
            switch event {
            case "Usage":
                if let limits = obj["rate_limits"] as? [String: Any] { ClaudeUsage.shared.ingest(limits) }
            case "Notification":
                notify(obj)
            default:
                clear(after: event, obj)
            }
            return
        }
        let meta = obj["roost"] as? [String: Any] ?? [:]
        let tool = obj["tool_name"] as? String ?? "?"
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let (summary, detail) = Self.summarize(tool: tool, input: input)
        let cwd = obj["cwd"] as? String ?? ""
        let projectDir = (meta["project_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cwd
        let timeout = (meta["timeout"] as? Double).map { min(max($0, 1), 600) } ?? 100
        let started = (meta["started"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let deadline = min(started, Date()).addingTimeInterval(timeout)
        guard deadline > Date() else { conn.cancel(); return }
        var id = meta["request_id"] as? String ?? UUID().uuidString
        if requests.contains(where: { $0.id == id }) { id = UUID().uuidString }
        let session = obj["session_id"] as? String ?? ""
        let suggestions = obj["permission_suggestions"] as? [Any]
        let kind: RequestKind = tool == "AskUserQuestion" ? .question : tool == "ExitPlanMode" ? .plan : .tool
        let host = HostApp.resolve(claudePid: (meta["claude_pid"] as? Int).map { pid_t($0) },
                                   bundleID: meta["host_bundle_id"] as? String)

        let request = PermissionRequest(
            id: id,
            kind: kind,
            tool: Self.displayName(tool),
            summary: summary,
            detail: detail,
            project: (cwd as NSString).lastPathComponent,
            cwd: cwd,
            projectDir: projectDir,
            suggestions: suggestions,
            allowScope: kind == .question ? nil : AllowScope.narrowest(suggestions, projectDir: projectDir),
            rawTool: tool,
            toolInput: input,
            questions: kind == .question
                ? (input["questions"] as? [Any] ?? []).compactMap(AskQuestion.init)
                : nil,
            session: session,
            sessionTitle: titles[session],
            inputKey: Self.key(input),
            host: host,
            received: Date(),
            deadline: deadline,
            timeout: timeout,
            connection: conn
        )
        requests.append(request)
        activity.noteProject(projectDir)
        // Chỉ tự chọn thẻ mới khi chưa có thẻ nào đang xem; thẻ đang chờ / đang hiện kết quả giữ nguyên.
        if selectedID == nil || !requests.contains(where: { $0.id == selectedID }) { select(id) }
        ClaudeExtras.shared.playSound()

        // Hết giờ: chuyển thẻ sang "Hết giờ" kể cả khi hook chưa kịp đóng socket.
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline.timeIntervalSinceNow) { [weak self] in
            guard let self, let live = self.requests.first(where: { $0.id == id }), live.state.isWaiting else { return }
            live.connection.cancel()
            self.finish(id, .expired, linger: 1.6)
        }

        if titles[session] == nil, let transcript = obj["transcript_path"] as? String {
            SessionTitles.load(transcript: transcript) { title in
                MainActor.assumeIsolated { [weak self] in
                    guard let self, let title else { return }
                    self.titles[session] = title
                    for i in self.requests.indices where self.requests[i].session == session {
                        self.requests[i].sessionTitle = title
                    }
                }
            }
        }
    }

    /// Notification của Claude Code: phiên đang chờ bạn. Bỏ qua khi thẻ xin quyền của phiên đó đã hiện
    /// (Claude Code cũng gửi Notification cho chính yêu cầu ấy).
    private func notify(_ obj: [String: Any]) {
        let session = obj["session_id"] as? String ?? ""
        let type = obj["notification_type"] as? String ?? ""
        if type == "auth_success" { return }
        if requests.contains(where: { $0.session == session && $0.state.isWaiting }) { return }
        let dir = (obj["project_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? obj["cwd"] as? String ?? ""
        ClaudeExtras.shared.playSound()
        onNotice?(.waiting(project: (dir as NSString).lastPathComponent))
    }

    /// Kết nối đóng khi thẻ còn chờ: hook hết giờ (đúng hạn) hoặc Claude Code dừng / hook bị kill.
    private func closed(_ conn: HookConnection) {
        guard let live = requests.first(where: { $0.connection === conn }), live.state.isWaiting else { return }
        let expired = live.deadline.timeIntervalSinceNow < 1.5
        finish(live.id, expired ? .expired : .cancelled, linger: 1.4)
    }

    /// Hộp thoại ở terminal chạy song song với hook: trả lời ở đó thì hook vẫn treo tới hết giờ.
    /// Event sau đó của cùng session cho biết yêu cầu đã xong → đóng kết nối (không quyết định), báo trên thẻ.
    private func clear(after event: String, _ obj: [String: Any]) {
        guard let session = obj["session_id"] as? String, !session.isEmpty else { return }
        let open = requests.filter { $0.session == session && $0.state.isWaiting }
        let stale: [PermissionRequest]
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            let tool = obj["tool_name"] as? String ?? ""
            let key = Self.key(obj["tool_input"] as? [String: Any] ?? [:])
            let same = open.filter { $0.rawTool == tool }
            // Khớp đúng input: Bash song song (1 lệnh tự cho phép, 1 lệnh chờ) không gỡ nhầm thẻ.
            // AskUserQuestion / ExitPlanMode: input bị thêm answers khi trả lời → lấy thẻ cũ nhất cùng tool.
            if let exact = same.first(where: { $0.inputKey == key }) {
                stale = [exact]
            } else {
                stale = ["AskUserQuestion", "ExitPlanMode"].contains(tool) ? Array(same.prefix(1)) : []
            }
        case "Stop", "SessionEnd", "UserPromptSubmit":
            stale = open
        default:
            return
        }
        for r in stale {
            r.connection.cancel()
            finish(r.id, .answeredElsewhere, linger: 1.0)
        }
    }

    // MARK: - Trạng thái

    private func setState(_ id: String, _ state: RequestState) {
        guard let i = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[i].state = state
    }

    /// Ghi kết quả, giữ thẻ `linger` giây để người dùng thấy, rồi gỡ và chuyển sang thẻ còn chờ kế tiếp.
    private func finish(_ id: String, _ state: RequestState, linger: TimeInterval) {
        guard let i = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[i].state = state
        activity.record(requests[i], state)
        // Thẻ đang không hiển thị thì gỡ luôn.
        let delay = id == current?.id ? linger : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.remove(id)
        }
    }

    private func remove(_ id: String) {
        requests.removeAll { $0.id == id }
        if selectedID == id || !requests.contains(where: { $0.id == selectedID }) {
            let next = requests.first(where: \.state.isWaiting) ?? requests.first
            selectedID = next?.id
            selectionChanged = Date()
        }
    }

    private static func key(_ input: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
        return parts.dropFirst().joined(separator: " › ")
    }

    private static func summarize(tool: String, input: [String: Any]) -> (String, String?) {
        func str(_ key: String) -> String? { input[key] as? String }
        switch tool {
        case "Bash":
            return (str("command") ?? "", str("description"))
        case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
            return (ClaudePaths.short(str("file_path") ?? str("notebook_path") ?? ""), nil)
        case "WebFetch":
            return (str("url") ?? "", str("prompt"))
        case "WebSearch":
            return (str("query") ?? "", nil)
        case "ExitPlanMode":
            let plan = (str("plan") ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let first = plan.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
            let rest = plan.dropFirst().prefix(3).joined(separator: " ")
            return (first, rest.isEmpty ? nil : rest)
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return (first ?? "", nil)
        default:
            return (input.values.compactMap { $0 as? String }.first ?? "", nil)
        }
    }
}
