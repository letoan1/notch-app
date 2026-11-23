import Foundation
import Network
import Photos
import UIKit
import UniformTypeIdentifiers

// MARK: - Nhận file từ Mac

/// Khi app đang mở và đã ghép: lắng nghe `_roost-iphone._tcp` qua TLS PSK (cùng khoá lúc ghép), Mac thấy thì
/// hiện "Gửi sang iPhone" trong khay. Ảnh, video cất vào Ảnh; file khác vào Tệp > Roost Portal.
/// Rời app thì tắt (iOS không cho lắng nghe ở nền).
final class PortalReceiver {
    static let shared = PortalReceiver()
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ReceiveSession] = [:]

    func start() {
        guard listener == nil, let config = PortalConfig.load(), let token = config.token else { return }
        let params = PortalHTTP.parameters(psk: config.psk(token: token))
        guard let l = try? NWListener(using: params) else { return }
        l.service = NWListener.Service(name: UIDevice.current.name, type: "_roost-iphone._tcp", domain: nil,
                                       txtRecord: NWTXTRecord(["device": config.deviceID]).data)
        l.newConnectionHandler = { [weak self] conn in
            guard let self, self.sessions.count < 4 else { conn.cancel(); return }
            let s = ReceiveSession(conn) { [weak self] s in self?.sessions.removeValue(forKey: ObjectIdentifier(s)) }
            self.sessions[ObjectIdentifier(s)] = s
            s.start()
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Một yêu cầu HTTP `POST /receive` từ Mac: đọc header, ghi body ra file tạm, trả lời, rồi cất file.
final class ReceiveSession {
    private let conn: NWConnection
    private let ended: (ReceiveSession) -> Void
    private var buffer = Data()
    private var expected = 0, received = 0
    private var name = "file", from = "Mac"
    private var file: URL?
    private var handle: FileHandle?

    init(_ conn: NWConnection, ended: @escaping (ReceiveSession) -> Void) {
        self.conn = conn
        self.ended = ended
    }

    func start() {
        conn.start(queue: .main)
        read()
    }

    private func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, complete, error in
            if let data { consume(data) }
            if error != nil || (complete && received < expected) { fail(); return }
            if handle == nil || received < expected { read() }
        }
    }

    private func consume(_ data: Data) {
        guard handle == nil else { write(data); return }
        buffer.append(data)
        guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)), let head = String(data: buffer[..<sep.lowerBound], encoding: .utf8) else {
            if buffer.count > 32 * 1024 { fail() }
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("POST /receive ") == true else { respond(404); return }
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "content-length": expected = Int(kv[1]) ?? 0
            case "x-roost-name": name = Self.safeName(kv[1].removingPercentEncoding ?? kv[1])
            case "x-roost-from": from = kv[1].removingPercentEncoding ?? kv[1]
            default: break
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = url
        handle = try? FileHandle(forWritingTo: url)
        Portal.shared.transfer = .init(title: L("Nhận từ \(from): \(name)", "From \(from): \(name)"), progress: 0, state: .sending)
        let rest = Data(buffer[sep.upperBound...])
        buffer = Data()
        if expected == 0 { finish() } else if !rest.isEmpty { write(rest) }
    }

    private func write(_ data: Data) {
        let chunk = data.prefix(expected - received)
        try? handle?.write(contentsOf: chunk)
        received += chunk.count
        Portal.shared.transfer?.progress = expected > 0 ? Double(received) / Double(expected) : 1
        if received >= expected { finish() }
    }

    private func finish() {
        try? handle?.close()
        respond(200)
        guard let file else { return }
        let name = name
        Task { @MainActor in
            let where_ = await Self.store(file, name: name)
            Portal.shared.transfer = .init(title: name, progress: 1, state: .done)
            Portal.shared.receivedNote = where_
            PaperStage.shared.arrive(image: UIImage(contentsOfFile: file.path))
        }
    }

    private func fail() {
        try? handle?.close()
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        Portal.shared.transfer?.state = .failed(L("Mất kết nối với Mac.", "Lost connection to the Mac."))
        conn.cancel()
        ended(self)
    }

    private func respond(_ status: Int) {
        let body = status == 200 ? "{\"ok\":true}" : "{\"error\":\"\(status)\"}"
        let text = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(text.utf8), completion: .contentProcessed { [self] _ in
            conn.cancel()
            ended(self)
        })
    }

    /// Ảnh, video: vào thư viện Ảnh. File khác: Tệp > Roost Portal (thư mục Documents của app).
    @MainActor static func store(_ file: URL, name: String) async -> String {
        let type = UTType(filenameExtension: file.pathExtension)
        if let type, type.conforms(to: .image) || type.conforms(to: .movie) {
            let ok: Bool = await withCheckedContinuation { cont in
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetCreationRequest.forAsset()
                    let o = PHAssetResourceCreationOptions()
                    o.originalFilename = name
                    req.addResource(with: type.conforms(to: .movie) ? .video : .photo, fileURL: file, options: o)
                }) { ok, _ in cont.resume(returning: ok) }
            }
            if ok {
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                return L("Đã lưu vào Ảnh", "Saved to Photos")
            }
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var dest = docs.appendingPathComponent(name)
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = docs.appendingPathComponent("\((name as NSString).deletingPathExtension) \(i).\((name as NSString).pathExtension)")
            i += 1
        }
        try? FileManager.default.moveItem(at: file, to: dest)
        return L("Đã lưu vào Tệp > Roost Portal", "Saved to Files > Roost Portal")
    }

    /// Tên file an toàn: bỏ đường dẫn, ký tự lạ, giới hạn độ dài.
    static func safeName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
        let trimmed = String(base.prefix(120)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "file" : trimmed
    }
}
