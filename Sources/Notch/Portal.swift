import AppKit
import CryptoKit
import Network
import Security
import SystemConfiguration
import UniformTypeIdentifiers

// Portal: iPhone gửi ảnh, video, file, clipboard sang Mac qua mạng cục bộ (Bonjour, có cả AWDL).
// Giao thức HTTP/1.1 đơn giản để Phím tắt iOS cũng gửi được. Chi tiết: docs/PORTAL.md.

// MARK: - Thiết bị đã ghép

struct PortalDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// SHA-256 của token (hex). Token gốc chỉ đưa cho thiết bị một lần.
    var tokenHash: String
    var pairedAt: Date
    /// "app" (app RoostPortal) hoặc "shortcut" (mã tạo tay cho Phím tắt).
    var kind: String
}

/// Danh sách thiết bị nằm trong Keychain (một mục, dạng JSON).
enum PortalKeychain {
    private static let service = "io.github.letoan1.roost.portal"
    private static let account = "devices"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> [PortalDevice] {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([PortalDevice].self, from: data)) ?? []
    }

    static func save(_ devices: [PortalDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Roost Portal"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Cài đặt

@MainActor
final class PortalSettings: ObservableObject {
    static let shared = PortalSettings()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "portal.enabled"); PortalServer.shared.sync() }
    }
    /// File nhận xong bay vào khay của notch.
    @Published var toTray: Bool { didSet { UserDefaults.standard.set(toTray, forKey: "portal.toTray") } }
    @Published var acceptClipboard: Bool { didSet { UserDefaults.standard.set(acceptClipboard, forKey: "portal.clipboard") } }
    /// Thư mục lưu ("" = Downloads).
    @Published var folderPath: String { didSet { UserDefaults.standard.set(folderPath, forKey: "portal.folder") } }
    /// Đọc từ Keychain lần đầu khi bật Portal (không bật thì không đụng Keychain).
    @Published private(set) var devices: [PortalDevice] = []
    @Published var status: PortalServer.Status = .off

    /// ID cố định của máy Mac này, iPhone dùng để nhận ra "Mac của mình" giữa nhiều máy.
    let macID: String
    private var loaded = false

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "portal.enabled") as? Bool ?? false
        toTray = d.object(forKey: "portal.toTray") as? Bool ?? true
        acceptClipboard = d.object(forKey: "portal.clipboard") as? Bool ?? true
        folderPath = d.string(forKey: "portal.folder") ?? ""
        if let id = d.string(forKey: "portal.macID") {
            macID = id
        } else {
            macID = UUID().uuidString
            d.set(macID, forKey: "portal.macID")
        }
    }

    nonisolated static var storedMacID: String { UserDefaults.standard.string(forKey: "portal.macID") ?? "" }

    var folder: URL {
        folderPath.isEmpty ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// Tên hiện trên iPhone, ví dụ "MacBook Pro của Toàn".
    nonisolated static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// Địa chỉ cho Phím tắt, ví dụ "Toans-MacBook-Pro.local".
    nonisolated static var localHost: String {
        ((SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "localhost") + ".local"
    }

    func loadDevices() {
        guard !loaded else { return }
        loaded = true
        devices = PortalKeychain.load()
        PortalServer.shared.setDevices(devices)
    }

    /// Ghép một thiết bị mới, trả token gốc (chỉ lần này).
    func addDevice(name: String, kind: String) -> (PortalDevice, String) {
        loadDevices()
        let token = PortalKeychain.newToken()
        let device = PortalDevice(id: UUID().uuidString, name: name, tokenHash: PortalKeychain.hash(token),
                                  pairedAt: Date(), kind: kind)
        devices.append(device)
        persist()
        return (device, token)
    }

    func remove(_ device: PortalDevice) {
        devices.removeAll { $0.id == device.id }
        persist()
    }

    private func persist() {
        PortalKeychain.save(devices)
        PortalServer.shared.setDevices(devices)
    }
}

// MARK: - Máy chủ

/// Lắng nghe TCP qua Network.framework, quảng bá Bonjour `_roost-portal._tcp` (cả peer-to-peer).
/// Không có kết nối thì không chạy gì (CPU ~0%).
final class PortalServer: @unchecked Sendable {
    static let shared = PortalServer()
    static let preferredPort: UInt16 = 52525
    static let serviceType = "_roost-portal._tcp"
    static let maxSessions = 8

    enum Status: Equatable {
        case off, starting, ready(UInt16), failed(String)
    }

    let queue = DispatchQueue(label: "roost.portal")
    private var listener: NWListener?
    /// Cổng thứ hai mã hoá TLS 1.2 PSK cho app RoostPortal (khoá = SHA-256 của token, danh tính = id thiết bị).
    /// Cổng thường vẫn mở cho /hello, /pair và Phím tắt iOS.
    private var tlsListener: NWListener?
    private var pathMonitor: NWPathMonitor?
    private var serviceName = "", serviceID = ""
    private var sessions: [ObjectIdentifier: PortalSession] = [:]
    private let lock = NSLock()
    private var byHash: [String: PortalDevice] = [:]

    // MARK: Bật / tắt

    @MainActor func sync() {
        let settings = PortalSettings.shared
        PortalPhones.shared.setEnabled(settings.enabled)
        if settings.enabled {
            settings.loadDevices()
            let name = PortalSettings.macName
            let id = settings.macID
            settings.status = .starting
            queue.async { self.start(name: name, macID: id, port: Self.preferredPort) }
        } else {
            settings.status = .off
            queue.async { self.stop() }
        }
    }

    private func start(name: String, macID: String, port: UInt16?) {
        stop()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        let made: NWListener?
        if let port, let p = NWEndpoint.Port(rawValue: port) {
            made = try? NWListener(using: params, on: p)
        } else {
            made = try? NWListener(using: params)
        }
        guard let listener = made else {
            if port != nil { start(name: name, macID: macID, port: nil) } else { publish(.failed("listener")) }
            return
        }
        serviceName = name
        serviceID = macID
        advertise(listener)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.publish(.ready(listener?.port?.rawValue ?? 0))
                if let listener { self.advertise(listener) }   // giờ mới biết cổng thật
            case .failed(let error):
                listener?.cancel()
                if self.listener === listener { self.listener = nil }
                // Cổng cố định bị chiếm: thử cổng bất kỳ (Bonjour vẫn báo đúng cổng cho app iPhone).
                if port != nil {
                    self.start(name: name, macID: macID, port: nil)
                } else {
                    self.publish(.failed(error.localizedDescription))
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.sessions.count < Self.maxSessions else { connection.cancel(); return }
            let session = PortalSession(connection: connection, server: self)
            self.sessions[ObjectIdentifier(session)] = session
            session.start()
        }
        self.listener = listener
        listener.start(queue: queue)
        startTLS()
        // Đổi mạng (Wi-Fi khác, cắm cáp) thì cập nhật địa chỉ trong TXT. Chỉ chạy khi Portal bật.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self, let l = self.listener else { return }
            self.advertise(l)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// TXT gồm id, cổng và các địa chỉ IPv4 của Mac: iPhone nối thẳng IP (nhanh, chắc) trước,
    /// không được mới nhờ Bonjour phân giải (có lúc treo ở tên máy ngẫu nhiên *.local).
    private func advertise(_ listener: NWListener) {
        var fields = ["id": serviceID, "v": "1", "ip": Self.ipv4Addresses().joined(separator: ",")]
        if let port = listener.port?.rawValue { fields["port"] = String(port) }
        if let tls = tlsListener?.port?.rawValue { fields["tls"] = String(tls) }
        listener.service = NWListener.Service(name: serviceName, type: Self.serviceType, domain: nil,
                                              txtRecord: NWTXTRecord(fields).data)
    }

    static func ipv4Addresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  (Int32(a.ifa_flags) & IFF_UP) != 0, (Int32(a.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }

    private func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        tlsListener?.cancel()
        tlsListener = nil
        listener?.cancel()
        listener = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { MainActor.assumeIsolated { PortalSettings.shared.status = status } }
    }

    func ended(_ session: PortalSession) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    // MARK: Xác thực

    func setDevices(_ devices: [PortalDevice]) {
        lock.lock()
        byHash = Dictionary(devices.map { ($0.tokenHash, $0) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()
        queue.async { if self.listener != nil { self.startTLS() } }   // ghép / gỡ thiết bị: nạp lại bộ khoá
    }

    private var allDevices: [PortalDevice] {
        lock.lock()
        defer { lock.unlock() }
        return Array(byHash.values)
    }

    /// Mỗi thiết bị app một khoá PSK. Không có thiết bị nào thì không mở cổng TLS.
    private func startTLS() {
        tlsListener?.cancel()
        tlsListener = nil
        let apps = allDevices.filter { $0.kind == "app" }
        guard !apps.isEmpty else { if let l = listener { advertise(l) }; return }
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        for d in apps {
            sec_protocol_options_add_pre_shared_key(sec, Self.dispatchData(Data(d.tokenHash.utf8)), Self.dispatchData(Data(d.id.utf8)))
        }
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        guard let l = (try? NWListener(using: params, on: 52526)) ?? (try? NWListener(using: params)) else { return }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            if case .ready = state, let plain = self.listener { self.advertise(plain) }
            if case .failed = state { l.cancel(); if self.tlsListener === l { self.tlsListener = nil } }
        }
        l.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.sessions.count < Self.maxSessions else { connection.cancel(); return }
            let session = PortalSession(connection: connection, server: self)
            self.sessions[ObjectIdentifier(session)] = session
            session.start()
        }
        tlsListener = l
        l.start(queue: queue)
    }

    static func dispatchData(_ d: Data) -> __DispatchData {
        d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }

    func device(token: String?) -> PortalDevice? {
        guard let token, !token.isEmpty else { return nil }
        let hash = PortalKeychain.hash(token)
        lock.lock()
        defer { lock.unlock() }
        return byHash[hash]
    }
}

// MARK: - Một kết nối HTTP

/// Đọc header, rồi theo đường dẫn: GET /hello, POST /pair, POST /send (file), POST /clipboard, POST /hover.
/// Mỗi kết nối một yêu cầu (Connection: close). Mọi thứ chạy trên hàng đợi của PortalServer.
final class PortalSession {
    private let connection: NWConnection
    private weak var server: PortalServer?
    private var buffer = Data()
    private var request: Request?
    private var timeout: DispatchWorkItem?
    private var closed = false
    private var responded = false

    // Nhận file
    private var expected = 0
    private var received = 0
    private var file: FileHandle?
    private var temp: URL?
    private var transferID = UUID()
    private var lastProgress: CFAbsoluteTime = 0
    private var device: PortalDevice?
    private var body = Data()

    static let maxHeader = 32 * 1024
    static let maxClipboard = 25 * 1024 * 1024
    static let maxPairBody = 8 * 1024

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var contentLength: Int?
        var contentType: String { headers["content-type"]?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? "" }
        var token: String? {
            if let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
                return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            return headers["x-roost-token"] ?? query["token"]
        }
    }

    init(connection: NWConnection, server: PortalServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finishWithError()
            default: break
            }
        }
        connection.start(queue: server?.queue ?? .main)
        armTimeout()
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        connection.cancel()
        cleanupPartial(notify: true)
        server?.ended(self)
    }

    // Không nhận gì trong 30 s thì đóng (iPhone khoá máy giữa chừng chẳng hạn).
    private func armTimeout() {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.close() }
        timeout = item
        server?.queue.asyncAfter(deadline: .now() + 30, execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.armTimeout()
                self.consume(data)
            }
            if self.closed { return }
            if error != nil || complete {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        guard !responded else { return }
        guard let request else {
            buffer.append(data)
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxHeader { respond(431, ["error": "header too large"]) }
                return
            }
            let head = buffer.subdata(in: 0..<end.lowerBound)
            let rest = buffer.subdata(in: end.upperBound..<buffer.count)
            buffer = Data()
            guard let parsed = Self.parse(head) else { respond(400, ["error": "bad request"]); return }
            self.request = parsed
            route(parsed)
            if !rest.isEmpty, !closed, !responded { consume(rest) }
            return
        }
        guard !closed, !responded else { return }
        switch request.path {
        case "/send": writeChunk(data)
        default: appendBody(data)
        }
    }

    private static func parse(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(first[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(first[0]).uppercased(), path: comps?.path ?? target, query: query,
                       headers: headers, contentLength: headers["content-length"].flatMap { Int($0) })
    }

    // MARK: Định tuyến

    private func route(_ r: Request) {
        switch (r.method, r.path) {
        case ("GET", "/hello"):
            let paired = server?.device(token: r.token) != nil
            respond(200, ["name": PortalSettings.macName, "id": PortalSettings.storedMacID, "v": 1, "paired": paired])
        case ("POST", "/pair"):
            guard let length = r.contentLength, length <= Self.maxPairBody else {
                respond(r.contentLength == nil ? 411 : 413, ["error": "length"]); return
            }
            expected = length
            continueIfAsked(r)
            if length == 0 { pair(Data()) }
        case ("POST", "/send"):
            beginFile(r)
        case ("POST", "/link"):
            // Mở link trên Mac (trình duyệt mặc định) và chép vào clipboard. Body là URL.
            guard authorize(r) else { return }
            guard let length = r.contentLength, length > 0, length <= Self.maxPairBody else {
                respond(r.contentLength == nil ? 411 : 413, ["error": "length"]); return
            }
            expected = length
            continueIfAsked(r)
        case ("POST", "/hover"):
            // iPhone đang kéo ảnh gần mép: Mac sáng mép phải trước khi file tới. Không có body.
            guard authorize(r) else { return }
            let y = r.headers["x-roost-y"].flatMap(Double.init) ?? 0.5
            let near = r.headers["x-roost-near"].flatMap(Double.init) ?? 0
            let phase = r.headers["x-roost-phase"] ?? "move"
            DispatchQueue.main.async { MainActor.assumeIsolated { PortalHover.shared.update(y: y, near: near, phase: phase) } }
            respond(200, ["ok": true])
        case ("POST", "/clipboard"):
            guard authorize(r) else { return }
            guard let length = r.contentLength else { respond(411, ["error": "length required"]); return }
            guard length <= Self.maxClipboard else { respond(413, ["error": "too large"]); return }
            expected = length
            continueIfAsked(r)
            if length == 0 { respond(400, ["error": "empty"]) }
        default:
            respond(404, ["error": "not found"])
        }
    }

    private func authorize(_ r: Request) -> Bool {
        guard let device = server?.device(token: r.token) else {
            respond(401, ["error": "not paired"])
            return false
        }
        self.device = device
        return true
    }

    /// curl và URLSession gửi "Expect: 100-continue" với body lớn: chỉ cho gửi tiếp khi đã xác thực.
    private func continueIfAsked(_ r: Request) {
        guard r.headers["expect"]?.lowercased() == "100-continue" else { return }
        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
    }

    private func appendBody(_ data: Data) {
        guard let request else { return }
        let need = expected - body.count
        guard need > 0 else { return }
        body.append(data.prefix(need))
        guard body.count >= expected else { return }
        switch request.path {
        case "/pair": pair(body)
        case "/link": link(body)
        case "/clipboard": clipboard(body, type: request.contentType)
        default: break
        }
    }

    // MARK: Ghép đôi

    private func pair(_ data: Data) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let raw = (json["name"] as? String) ?? request?.headers["x-roost-device"]?.removingPercentEncoding ?? "iPhone"
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let code = (json["code"] as? String).map { String($0.filter(\.isNumber).prefix(6)) }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PortalCenter.shared.askToPair(name: name.isEmpty ? "iPhone" : name, code: code) { result in
                    self.server?.queue.async {
                        switch result {
                        case .approved(let device, let token):
                            self.respond(200, ["token": token, "device": device.id,
                                               "mac": PortalSettings.macName, "macID": PortalSettings.storedMacID])
                        case .denied: self.respond(403, ["error": "denied"])
                        case .busy: self.respond(429, ["error": "busy"])
                        }
                    }
                }
            }
        }
    }

    // MARK: Link

    private func link(_ data: Data) {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            respond(400, ["error": "not a web link"]); return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { PortalCenter.shared.link(url) }
        }
        respond(200, ["ok": true])
    }

    // MARK: Clipboard

    private func clipboard(_ data: Data, type: String) {
        let id = UUID()
        let from = device?.name ?? "iPhone"
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let ok = PortalCenter.shared.clipboard(id: id, data: data, type: type, from: from)
                self.server?.queue.async { ok ? self.respond(200, ["ok": true]) : self.respond(415, ["error": "unsupported"]) }
            }
        }
    }

    // MARK: Nhận file

    private func beginFile(_ r: Request) {
        guard authorize(r) else { return }
        guard let length = r.contentLength else { respond(411, ["error": "length required"]); return }
        let name = Self.fileName(r)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.letoan1.roost/Portal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(transferID.uuidString + ".part")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else {
            respond(500, ["error": "cannot write"]); return
        }
        self.temp = temp
        self.file = handle
        self.expected = length
        let id = transferID
        let from = device?.name ?? "iPhone"
        let entry = r.headers["x-roost-y"].flatMap(Double.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { PortalCenter.shared.incoming(id: id, name: name, size: length, from: from, entry: entry) }
        }
        continueIfAsked(r)
        if length == 0 { completeFile(name: name) }
    }

    private func writeChunk(_ data: Data) {
        guard let file, let request else { return }
        let need = expected - received
        guard need > 0 else { return }
        let chunk = data.prefix(need)
        do { try file.write(contentsOf: chunk) } catch {
            respond(507, ["error": "disk"]); return
        }
        received += chunk.count
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastProgress > 0.1, expected > 0 {
            lastProgress = now
            let fraction = Double(received) / Double(expected)
            let id = transferID
            DispatchQueue.main.async { MainActor.assumeIsolated { PortalCenter.shared.progress(id: id, fraction) } }
        }
        if received >= expected { completeFile(name: Self.fileName(request)) }
    }

    private func completeFile(name: String) {
        try? file?.close()
        file = nil
        guard let temp else { return }
        self.temp = nil
        let id = transferID
        // Chuyển file vào thư mục đích trên main (để khay / DownloadsWatcher biết trước), rồi mới trả lời.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let saved = PortalCenter.shared.received(id: id, temp: temp, name: name)
                self.server?.queue.async {
                    if let saved {
                        self.respond(200, ["ok": true, "name": saved.lastPathComponent])
                    } else {
                        self.respond(500, ["error": "save failed"])
                    }
                }
            }
        }
    }

    private func cleanupPartial(notify: Bool) {
        try? file?.close()
        file = nil
        if let temp {
            try? FileManager.default.removeItem(at: temp)
            self.temp = nil
            if notify {
                let id = transferID
                DispatchQueue.main.async { MainActor.assumeIsolated { PortalCenter.shared.failed(id: id) } }
            }
        }
    }

    private func finishWithError() {
        guard !closed else { return }
        close()
    }

    /// Tên file an toàn: lấy từ X-Roost-Name (mã hoá %), thiếu đuôi thì suy từ Content-Type.
    static func fileName(_ r: Request) -> String {
        let raw = r.headers["x-roost-name"] ?? r.query["name"] ?? ""
        let given = raw.removingPercentEncoding ?? raw
        var name = (given as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            name = "iPhone " + f.string(from: Date())
        }
        name = String(name.prefix(180))
        // Phím tắt iOS tách tên và đuôi: X-Roost-Ext. Không có thì suy từ Content-Type.
        if (name as NSString).pathExtension.isEmpty {
            let given = (r.headers["x-roost-ext"] ?? "").filter { $0.isLetter || $0.isNumber }
            if !given.isEmpty {
                name += "." + String(given.prefix(12))
            } else if let ext = UTType(mimeType: r.contentType)?.preferredFilenameExtension {
                name += "." + ext
            }
        }
        return name
    }

    // MARK: Trả lời

    private func respond(_ status: Int, _ json: [String: Any]) {
        guard !closed else { return }
        let reason: String = switch status {
            case 200: "OK"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 403: "Forbidden"
            case 404: "Not Found"
            case 411: "Length Required"
            case 413: "Payload Too Large"
            case 415: "Unsupported Media Type"
            case 429: "Too Many Requests"
            case 431: "Request Header Fields Too Large"
            case 507: "Insufficient Storage"
            default: "Error"
        }
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        if status != 200 { cleanupPartial(notify: true) }
        // Đã trả lời: bỏ qua phần body còn lại, gửi xong thì đóng.
        responded = true
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }
}
