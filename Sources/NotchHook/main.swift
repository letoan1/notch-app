import Foundation

// Claude Code gọi binary này cho event PermissionRequest (JSON qua stdin).
// Gửi yêu cầu lên app Notch qua Unix socket rồi chờ người dùng bấm.
// Mọi lỗi (app tắt, hết giờ, JSON hỏng) → thoát 0 không in gì = không quyết định,
// Claude Code giữ luồng hỏi quyền bình thường.

let timeout = Double(ProcessInfo.processInfo.environment["NOTCH_HOOK_TIMEOUT"] ?? "") ?? 100
let socketPath = NSHomeDirectory() + "/Library/Application Support/Notch/claude.sock"

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let object = try? JSONSerialization.jsonObject(with: input),
      var line = try? JSONSerialization.data(withJSONObject: object)
else { exit(0) }
line.append(0x0A)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

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
guard connected == 0 else { exit(0) }

let sent = line.withUnsafeBytes { buf -> Bool in
    var offset = 0
    while offset < buf.count {
        let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
        if n <= 0 { return false }
        offset += n
    }
    return true
}
guard sent else { exit(0) }

var response = Data()
let deadline = Date().addingTimeInterval(timeout)
var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
var chunk = [UInt8](repeating: 0, count: 4096)
while true {
    let remainingMs = Int32(deadline.timeIntervalSinceNow * 1000)
    if remainingMs <= 0 || poll(&pfd, 1, remainingMs) <= 0 { break }
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    response.append(chunk, count: n)
}
close(fd)

if !response.isEmpty { FileHandle.standardOutput.write(response) }
exit(0)
