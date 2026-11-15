import Foundation

// Claude Code gọi binary này cho các hook event (JSON qua stdin).
// - PermissionRequest: gửi yêu cầu lên app Roost qua Unix socket rồi chờ người dùng bấm.
// - PostToolUse / PostToolUseFailure / Stop / SessionEnd / UserPromptSubmit: báo app gỡ thẻ đã được
//   trả lời ở terminal (hộp thoại terminal chạy song song với hook), không chờ, không in gì.
// - Notification: báo app phiên đang cần bạn (âm báo + thông báo nhanh), không chờ.
// - --statusline: lệnh statusLine, xem bên dưới.
// Mọi lỗi (app tắt, app chết giữa chừng, socket cũ, hết giờ, JSON hỏng) → thoát 0 không in gì
// = không quyết định, Claude Code giữ luồng hỏi quyền bình thường.
// Không bao giờ được treo quá timeout của Claude Code (110 s): có watchdog SIGALRM chặn cứng.

let started = Date()
let env = ProcessInfo.processInfo.environment

var timeout = Double(env["NOTCH_HOOK_TIMEOUT"] ?? "") ?? 100
if !(timeout >= 1 && timeout <= 600) { timeout = 100 }

// Watchdog: kẹt ở bất kỳ đâu (stdin, connect, write, read) cũng tự thoát, không in gì.
signal(SIGALRM) { _ in _exit(0) }
signal(SIGPIPE, SIG_IGN)
alarm(UInt32(timeout.rounded(.up)) + 2)

let socketPath = env["ROOST_HOOK_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
    ?? NSHomeDirectory() + "/Library/Application Support/Roost/claude.sock"
let parent = getppid()
let claudePid = Int32(env["CLAUDE_PID"] ?? "") ?? parent

// `roost-hook --statusline`: dùng làm lệnh statusLine của Claude Code. In dòng trạng thái ngắn
// (mức dùng 5 giờ / tuần) và chuyển `rate_limits` cho app. Không bao giờ chờ quá 2 giây.
let statusline = CommandLine.arguments.contains("--statusline")

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
if statusline {
    let limits = object["rate_limits"] as? [String: Any]
    func pct(_ key: String) -> String? {
        ((limits?[key] as? [String: Any])?["used_percentage"] as? NSNumber).map { "\(key == "five_hour" ? "5h" : "7d") \(Int($0.doubleValue.rounded()))%" }
    }
    let text = [pct("five_hour"), pct("seven_day")].compactMap { $0 }.joined(separator: "  ")
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
    guard limits != nil else { exit(0) }
}
let event = statusline ? "Usage" : object["hook_event_name"] as? String ?? "PermissionRequest"
let isRequest = event == "PermissionRequest"
let deadline = started.addingTimeInterval(isRequest ? timeout : 2)
if !isRequest { alarm(3) }

var message: [String: Any] = object
if isRequest {
    var meta: [String: Any] = [
        "request_id": UUID().uuidString,
        "timeout": timeout,
        "started": started.timeIntervalSince1970,
        "claude_pid": Int(claudePid),
        "hook_pid": Int(getpid()),
    ]
    // App chủ (VS Code, Terminal, iTerm…) để thẻ có nút mở đúng cửa sổ.
    for (key, name) in [("host_bundle_id", "__CFBundleIdentifier"), ("term_program", "TERM_PROGRAM"),
                        ("project_dir", "CLAUDE_PROJECT_DIR"), ("entrypoint", "CLAUDE_CODE_ENTRYPOINT")] {
        if let value = env[name], !value.isEmpty { meta[key] = value }
    }
    message["roost"] = meta
} else {
    // Event phụ chỉ gửi phần cần để khớp thẻ (bỏ tool_response có thể rất lớn).
    message = ["notch_event": event, "session_id": object["session_id"] ?? ""]
    if let tool = object["tool_name"] { message["tool_name"] = tool }
    if let toolInput = object["tool_input"] { message["tool_input"] = toolInput }
    // Notification: phiên cần bạn (chờ nhập, xin quyền…). Usage: mức dùng từ statusline.
    for key in ["message", "notification_type", "cwd", "rate_limits"] {
        if let value = object[key] { message[key] = value }
    }
    if event == "Notification", let dir = env["CLAUDE_PROJECT_DIR"], !dir.isEmpty { message["project_dir"] = dir }
}
guard var line = try? JSONSerialization.data(withJSONObject: message) else { exit(0) }
line.append(0x0A)

func remainingMs() -> Int32 {
    Int32(max(0, min(deadline.timeIntervalSinceNow * 1000, Double(Int32.max))))
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
// Non-blocking: connect / write không thể kẹt quá hạn chót.
_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
// App không chạy: file socket không có (ENOENT) hoặc còn sót (ECONNREFUSED) → thoát ngay.
if connected != 0 {
    guard errno == EINPROGRESS || errno == EAGAIN else { exit(0) }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, min(remainingMs(), 2000)) == 1, pfd.revents & Int16(POLLOUT) != 0 else { exit(0) }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { exit(0) }
}

let sent = line.withUnsafeBytes { buf -> Bool in
    var offset = 0
    while offset < buf.count {
        let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
        if n > 0 { offset += n; continue }
        guard n < 0, errno == EAGAIN || errno == EINTR else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = remainingMs()
        if ms <= 0 || poll(&pfd, 1, ms) <= 0 { return false }
    }
    return true
}
guard sent, isRequest else { close(fd); exit(0) }

// Chờ trả lời bằng kqueue: socket có dữ liệu / bị đóng (app chết, app bỏ qua), hoặc Claude Code chết.
let kq = kqueue()
guard kq >= 0 else { exit(0) }
let blankEvent = kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil)
var changes = [kevent(ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)]
for pid in Set([parent, claudePid]) where pid > 1 {
    changes.append(kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD),
                          fflags: NOTE_EXIT, data: 0, udata: nil))
}
// Đăng ký từng cái: tiến trình cha đã chết thì EVFILT_PROC báo lỗi (ESRCH) → thoát luôn.
for change in changes {
    var c = change
    var out = blankEvent
    var zero = timespec(tv_sec: 0, tv_nsec: 0)
    let n = kevent(kq, &c, 1, &out, 1, &zero)
    if n < 0 || (n == 1 && out.flags & UInt16(EV_ERROR) != 0 && out.data != 0) {
        if change.filter == Int16(EVFILT_PROC) { exit(0) }
    }
}

var response = Data()
var chunk = [UInt8](repeating: 0, count: 4096)
var finished = false
wait: while !finished {
    let ms = remainingMs()
    if ms <= 0 { break }
    // Thức dậy tối đa mỗi giây để kiểm lại tiến trình cha (phòng khi EVFILT_PROC trượt).
    let step = min(ms, 1000)
    var ts = timespec(tv_sec: Int(step / 1000), tv_nsec: Int(step % 1000) * 1_000_000)
    var events = Array(repeating: blankEvent, count: 4)
    let n = kevent(kq, nil, 0, &events, 4, &ts)
    if n < 0 {
        if errno == EINTR { continue }
        break
    }
    if n == 0 {
        if getppid() != parent || kill(claudePid, 0) != 0 && errno == ESRCH { break }
        continue
    }
    for e in events.prefix(Int(n)) {
        if e.filter == Int16(EVFILT_PROC) { response = Data(); break wait }
        if e.filter == Int16(EVFILT_READ) {
            while true {
                let r = read(fd, &chunk, chunk.count)
                if r > 0 {
                    response.append(chunk, count: r)
                    if response.contains(0x0A) { finished = true; break }
                    continue
                }
                if r == 0 { finished = true; break }      // EOF: app đóng kết nối
                if errno == EAGAIN || errno == EINTR { break }
                finished = true; break
            }
        }
    }
}
close(fd)

// Chỉ in khi là một quyết định PermissionRequest hợp lệ; còn lại im lặng.
if let newline = response.firstIndex(of: 0x0A) { response = response[..<newline] }
guard deadline.timeIntervalSinceNow > -1,
      let reply = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
      let specific = reply["hookSpecificOutput"] as? [String: Any],
      specific["hookEventName"] as? String == "PermissionRequest",
      let decision = specific["decision"] as? [String: Any],
      let behavior = decision["behavior"] as? String, behavior == "allow" || behavior == "deny"
else { exit(0) }
var out = Data(response)
out.append(0x0A)
FileHandle.standardOutput.write(out)
exit(0)
