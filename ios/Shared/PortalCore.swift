import Foundation
import Network
import Security
import CryptoKit

func L(_ vi: String, _ en: String) -> String { Lang.isVietnamese ? vi : en }

/// Ngôn ngữ app: chọn trong menu (UserDefaults "language": auto / vi / en). Tự động thì theo ngôn ngữ
/// iOS chọn cho app (Cài đặt > Roost Portal > Ngôn ngữ), không có thì theo ngôn ngữ đầu tiên của máy.
enum Lang {
    static var isVietnamese: Bool {
        switch UserDefaults.standard.string(forKey: "language") ?? "auto" {
        case "vi": return true
        case "en": return false
        default: return (Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en").hasPrefix("vi")
        }
    }
    static var locale: Locale { Locale(identifier: isVietnamese ? "vi_VN" : "en_US") }
}

// MARK: - HTTP tối giản trên NWConnection

/// Portal trên Mac là HTTP/1.1, mỗi kết nối một yêu cầu. Dùng NWConnection (không dùng URLSession)
/// để đi được cả Wi-Fi trực tiếp (AWDL) khi iPhone và Mac không chung mạng.
/// Mọi callback chạy trên main queue, khớp với MainActor mặc định của target.
enum PortalHTTP {
    struct Response { var status: Int; var body: Data }
    enum Failure: Error { case connection(String), badResponse }

    /// Khoá TLS 1.2 PSK dùng chung với Mac: danh tính = id thiết bị, khoá = SHA-256 (hex) của token.
    struct PSK { var identity: String; var key: Data }

    static func parameters(psk: PSK? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        var tls: NWProtocolTLS.Options?
        if let psk {
            let t = NWProtocolTLS.Options()
            let sec = t.securityProtocolOptions
            func dd(_ d: Data) -> __DispatchData { d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData }
            sec_protocol_options_add_pre_shared_key(sec, dd(psk.key), dd(Data(psk.identity.utf8)))
            sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
            sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
            tls = t
        }
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }

    /// Gửi một yêu cầu. Body là Data hoặc file (đọc từng khúc, không nạp cả file vào RAM).
    static func send(to endpoint: NWEndpoint, method: String, path: String, headers: [String: String] = [:],
                     body: Data? = nil, file: URL? = nil, timeout: TimeInterval = 30, psk: PSK? = nil,
                     progress: ((Double) -> Void)? = nil) async throws -> Response {
        let length: Int
        var handle: FileHandle?
        if let file {
            length = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            handle = try FileHandle(forReadingFrom: file)
        } else {
            length = body?.count ?? 0
        }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: roost\r\nConnection: close\r\nContent-Length: \(length)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        let conn = NWConnection(to: endpoint, using: parameters(psk: psk))
        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            var received = Data()
            func finish(_ r: Result<Response, Error>) {
                guard !finished else { return }
                finished = true
                try? handle?.close()
                conn.cancel()
                cont.resume(with: r)
            }
            func readResponse() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    if let data { received.append(data) }
                    if let r = parseResponse(received), r.complete { finish(.success(r.response)); return }
                    if complete || error != nil {
                        if let r = parseResponse(received) { finish(.success(r.response)) } else { finish(.failure(Failure.badResponse)) }
                        return
                    }
                    readResponse()
                }
            }
            var sent = 0
            func sendBody() {
                guard let handle else {
                    conn.send(content: body ?? Data(), completion: .contentProcessed { error in
                        if let error { finish(.failure(Failure.connection("\(error)"))) } else { readResponse() }
                    })
                    return
                }
                let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
                if chunk.isEmpty { progress?(1); readResponse(); return }
                conn.send(content: chunk, completion: .contentProcessed { error in
                    if let error { finish(.failure(Failure.connection("\(error)"))); return }
                    sent += chunk.count
                    progress?(length > 0 ? Double(sent) / Double(length) : 1)
                    sendBody()
                })
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(head.utf8), completion: .contentProcessed { error in
                        if let error { finish(.failure(Failure.connection("\(error)"))) } else { sendBody() }
                    })
                case .failed(let e): finish(.failure(Failure.connection("\(e)")))
                case .waiting(let e): finish(.failure(Failure.connection("\(e)")))
                default: break
                }
            }
            conn.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(.failure(Failure.connection("timeout"))) }
        }
    }

    /// Tách status + body. complete = đã đủ body theo Content-Length.
    static func parseResponse(_ data: Data) -> (response: Response, complete: Bool)? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        if status == 100 {   // bỏ qua "100 Continue", đọc tiếp phản hồi thật
            return parseResponse(Data(data[sep.upperBound...]))
        }
        var length: Int?
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" { length = Int(kv[1].trimmingCharacters(in: .whitespaces)) }
        }
        let body = Data(data[sep.upperBound...])
        return (Response(status: status, body: length.map { Data(body.prefix($0)) } ?? body), length.map { body.count >= $0 } ?? false)
    }

    #if DEBUG
    static func selfCheck() {
        let ok = parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8))
        assert(ok?.response.status == 200 && ok?.complete == true && ok?.response.body == Data("{}".utf8))
        let partial = parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}".utf8))
        assert(partial?.complete == false)
        let cont = parseResponse(Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8))
        assert(cont?.response.status == 403 && cont?.complete == true)
        assert(parseResponse(Data("HTTP/1.1 200".utf8)) == nil)
    }
    #endif
}

// MARK: - Keychain

enum TokenStore {
    /// Nhóm Keychain dùng chung giữa app và phần mở rộng Chia sẻ (khai báo trong *.entitlements).
    static let accessGroup = "3P6W338KYH.io.github.letoan1.RoostPortal.shared"

    private static func query(_ macID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.letoan1.RoostPortal",
         kSecAttrAccount as String: macID,
         kSecAttrAccessGroup as String: accessGroup]
    }
    static func save(_ token: String, macID: String) {
        SecItemDelete(query(macID) as CFDictionary)
        var q = query(macID)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load(_ macID: String) -> String? {
        var q = query(macID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ macID: String) { SecItemDelete(query(macID) as CFDictionary) }
}


// MARK: - Mac đã ghép (dùng chung app và phần mở rộng)

/// Thông tin Mac đã ghép, lưu trong Keychain nhóm chung để phần mở rộng Chia sẻ gửi được mà không cần mở app.
struct PortalConfig: Codable {
    var macID: String
    var deviceID: String
    var macName: String
    var hosts: [String] = []
    var port: UInt16?
    var tls: UInt16?

    private static let key = "config"

    static func load() -> PortalConfig? {
        guard let s = TokenStore.load(key), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PortalConfig.self, from: d)
    }
    func save() {
        guard let d = try? JSONEncoder().encode(self), let s = String(data: d, encoding: .utf8) else { return }
        TokenStore.save(s, macID: Self.key)
    }
    static func clear() { TokenStore.delete(key) }

    var token: String? { TokenStore.load(macID) }

    /// Khoá TLS PSK: danh tính = id thiết bị, khoá = SHA-256 (hex) của token.
    func psk(token: String) -> PortalHTTP.PSK {
        let hex = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return PortalHTTP.PSK(identity: deviceID, key: Data(hex.utf8))
    }

    /// Các đích mã hoá có thể thử (IP + cổng TLS), dùng ở phần mở rộng Chia sẻ.
    var secureEndpoints: [NWEndpoint] {
        guard let tls, let port = NWEndpoint.Port(rawValue: tls) else { return [] }
        return hosts.map { .hostPort(host: NWEndpoint.Host($0), port: port) }
    }
}
