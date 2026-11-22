import Foundation
import Network
import Security
import UIKit
import UniformTypeIdentifiers
import Combine

/// Chuỗi giao diện song ngữ, giống app Roost trên Mac.
func L(_ vi: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("vi") ? vi : en
}

// MARK: - HTTP tối giản trên NWConnection

/// Portal trên Mac là HTTP/1.1, mỗi kết nối một yêu cầu. Dùng NWConnection (không dùng URLSession)
/// để đi được cả Wi-Fi trực tiếp (AWDL) khi iPhone và Mac không chung mạng.
/// Mọi callback chạy trên main queue, khớp với MainActor mặc định của target.
enum PortalHTTP {
    struct Response { var status: Int; var body: Data }
    enum Failure: Error { case connection(String), badResponse }

    static func parameters() -> NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = true
        return p
    }

    /// Gửi một yêu cầu. Body là Data hoặc file (đọc từng khúc, không nạp cả file vào RAM).
    static func send(to endpoint: NWEndpoint, method: String, path: String, headers: [String: String] = [:],
                     body: Data? = nil, file: URL? = nil, timeout: TimeInterval = 30,
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

        let conn = NWConnection(to: endpoint, using: parameters())
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
    private static func query(_ macID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.letoan1.RoostPortal",
         kSecAttrAccount as String: macID]
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

// MARK: - Trạng thái app

struct PortalMac: Identifiable, Equatable {
    let endpoint: NWEndpoint          // dịch vụ Bonjour
    var name: String
    var id: String                    // macID từ /hello, rỗng khi chưa hỏi được
    var paired: Bool
    var hosts: [String] = []          // IPv4 của Mac lấy từ TXT
    var port: UInt16?
    var direct: NWEndpoint?           // IP đã nối được, dùng trước Bonjour
    /// Đường đi cho mọi yêu cầu: IP trực tiếp nếu đã thử được, không thì để Bonjour phân giải (cả Wi-Fi trực tiếp).
    var route: NWEndpoint { direct ?? endpoint }
}

final class Portal: ObservableObject {
    static let shared = Portal()

    @Published var macs: [PortalMac] = []
    @Published var current: PortalMac?
    @Published var pairingCode: String?
    @Published var pairError: String?
    @Published var transfer: Transfer?

    struct Transfer: Equatable { var title: String; var progress: Double; var state: State
        enum State: Equatable { case sending, done, failed(String) }
    }

    private var browser: NWBrowser?
    private var savedID: String? {
        get { UserDefaults.standard.string(forKey: "mac.id") }
        set { UserDefaults.standard.set(newValue, forKey: "mac.id") }
    }

    func start() {
        #if DEBUG
        PortalHTTP.selfCheck()
        #endif
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_roost-portal._tcp", domain: nil), using: PortalHTTP.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        b.start(queue: .main)
        browser = b
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var list: [PortalMac] = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            var m = macs.first { $0.endpoint == r.endpoint } ?? PortalMac(endpoint: r.endpoint, name: name, id: "", paired: false)
            if case let .bonjour(txt) = r.metadata {
                m.hosts = (txt["ip"] ?? "").split(separator: ",").map(String.init)
                m.port = txt["port"].flatMap { UInt16($0) }
            }
            guard !list.contains(where: { $0.endpoint == m.endpoint }) else { continue }
            list.append(m)
        }
        macs = list.sorted { $0.name < $1.name }
        if let c = current, !macs.contains(where: { $0.endpoint == c.endpoint }) { current = nil }
        for m in macs where m.id.isEmpty { Task { await hello(m) } }
    }

    /// Hỏi tên + id; Mac đã ghép (id trùng và token còn hợp lệ) thì chọn luôn.
    private func hello(_ m: PortalMac, attempt: Int = 0) async {
        var headers: [String: String] = [:]
        if let saved = savedID, let t = TokenStore.load(saved) { headers["Authorization"] = "Bearer \(t)" }
        var failure = ""
        var resp: PortalHTTP.Response?
        var direct: NWEndpoint?
        // Thử IP trực tiếp trước (nhanh), không được mới nhờ Bonjour.
        if let port = m.port.flatMap({ NWEndpoint.Port(rawValue: $0) }) {
            for host in m.hosts {
                let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
                if let r = try? await PortalHTTP.send(to: ep, method: "GET", path: "/hello", headers: headers, timeout: 2.5) {
                    resp = r; direct = ep; break
                }
            }
        }
        if resp == nil {
            do { resp = try await PortalHTTP.send(to: m.endpoint, method: "GET", path: "/hello", headers: headers, timeout: 8) }
            catch { failure = "\(error)" }
        }
        guard let r = resp, let json = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            // Lần đầu mở app (đang hỏi quyền mạng cục bộ) hay mạng chưa sẵn sàng: thử lại vài lần.
            guard attempt < 5, macs.contains(where: { $0.endpoint == m.endpoint }) else { return }
            try? await Task.sleep(for: .seconds(1.5 * Double(attempt + 1)))
            await hello(m, attempt: attempt + 1)
            return
        }
        guard let i = macs.firstIndex(where: { $0.endpoint == m.endpoint }) else { return }
        macs[i].direct = direct
        macs[i].name = json["name"] as? String ?? macs[i].name
        macs[i].id = json["id"] as? String ?? ""
        macs[i].paired = (json["paired"] as? Bool ?? false) && macs[i].id == savedID
        if macs[i].paired, current == nil { current = macs[i] }
    }

    var token: String? { current.flatMap { TokenStore.load($0.id) } }

    // MARK: Ghép đôi

    func pair(_ m: PortalMac) async {
        let code = String(format: "%04d", Int.random(in: 0...9999))
        pairingCode = code
        pairError = nil
        defer { pairingCode = nil }
        let body = try? JSONSerialization.data(withJSONObject: ["name": UIDevice.current.name, "code": code])
        do {
            let r = try await PortalHTTP.send(to: m.route, method: "POST", path: "/pair",
                                              headers: ["Content-Type": "application/json"], body: body, timeout: 75)
            guard r.status == 200, let json = try JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                  let token = json["token"] as? String else {
                pairError = r.status == 403 ? L("Mac đã từ chối.", "The Mac declined.")
                    : r.status == 429 ? L("Mac đang bận, thử lại sau ít giây.", "The Mac is busy, try again shortly.")
                    : L("Không ghép được.", "Couldn't pair.")
                return
            }
            let id = json["macID"] as? String ?? m.id
            TokenStore.save(token, macID: id)
            savedID = id
            var paired = m
            paired.id = id
            paired.paired = true
            if let i = macs.firstIndex(where: { $0.endpoint == m.endpoint }) { macs[i] = paired }
            current = paired
        } catch {
            pairError = L("Không kết nối được tới Mac.", "Couldn't reach the Mac.")
        }
    }

    func forget() {
        if let id = current?.id { TokenStore.delete(id) }
        savedID = nil
        if let c = current, let i = macs.firstIndex(where: { $0.endpoint == c.endpoint }) { macs[i].paired = false }
        current = nil
    }

    // MARK: Gửi

    /// entry: độ cao ngón tay lúc hất (0 = đỉnh màn hình, 1 = đáy). Mac cho máy bay giấy ra đúng độ cao này.
    func send(file: URL, name: String, title: String? = nil, entry: Double?) async {
        guard let mac = current, let token else { return }
        transfer = Transfer(title: title ?? name, progress: 0, state: .sending)
        let type = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["Authorization": "Bearer \(token)",
                       "Content-Type": type,
                       "X-Roost-Name": name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"]
        if let entry { headers["X-Roost-Y"] = String(format: "%.3f", min(max(entry, 0), 1)) }
        do {
            let r = try await PortalHTTP.send(to: mac.route, method: "POST", path: "/send", headers: headers, file: file,
                                              timeout: max(600, Double(Self.size(file)) / 300_000)) { [weak self] p in self?.transfer?.progress = p }
            if r.status == 200 {
                transfer?.state = .done
            } else if r.status == 401 {
                forget()
                transfer?.state = .failed(L("Mac đã gỡ iPhone này, hãy ghép lại.", "The Mac removed this iPhone, pair again."))
            } else {
                transfer?.state = .failed(L("Mac từ chối file (\(r.status)).", "The Mac refused the file (\(r.status))."))
            }
        } catch {
            transfer?.state = .failed(L("Mất kết nối với Mac.", "Lost connection to the Mac."))
        }
        try? FileManager.default.removeItem(at: file)
        clearTransferSoon()
    }

    // MARK: Báo trước cho Mac

    private var hoverSent: (near: Double, y: Double, at: TimeInterval) = (-1, -1, 0)
    private var hoverInFlight = false

    /// Ngón tay đang kéo ảnh gần mép trái: Mac sáng mép phải đúng độ cao, mạnh dần theo near (0..1).
    /// phase: move / fling / cancel. Gửi tối đa ~25 lần/giây và chỉ khi đổi đáng kể; fling, cancel luôn gửi.
    func hover(y: Double, near: Double, phase: String) {
        guard let mac = current, let token else { return }
        let now = CACurrentMediaTime()
        if phase == "move" {
            if near <= 0 && hoverSent.near <= 0 { return }
            let changed = abs(near - hoverSent.near) > 0.04 || abs(y - hoverSent.y) > 0.015
            guard changed, now - hoverSent.at > 0.04, !hoverInFlight else { return }
        }
        hoverSent = (near, y, now)
        hoverInFlight = phase == "move"
        let headers = ["Authorization": "Bearer \(token)",
                       "X-Roost-Y": String(format: "%.3f", min(max(y, 0), 1)),
                       "X-Roost-Near": String(format: "%.3f", min(max(near, 0), 1)),
                       "X-Roost-Phase": phase]
        Task {
            _ = try? await PortalHTTP.send(to: mac.route, method: "POST", path: "/hover", headers: headers, timeout: 2)
            if phase == "move" { hoverInFlight = false }
            if phase != "move" { hoverSent = (-1, -1, 0) }
        }
    }

    /// Không giới hạn cứng 10 phút: file lớn được thêm thời gian theo dung lượng (giả định tối thiểu ~300 KB/s).
    static func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }

    func sendClipboard() async {
        guard let mac = current, let token else { return }
        let pb = UIPasteboard.general
        let body: Data
        let type: String
        if let image = pb.image, let png = image.pngData() {
            body = png; type = "image/png"
        } else if let text = pb.string, !text.isEmpty {
            body = Data(text.utf8); type = "text/plain; charset=utf-8"
        } else {
            transfer = Transfer(title: L("Clipboard trống", "Clipboard is empty"), progress: 0, state: .failed(""))
            clearTransferSoon()
            return
        }
        transfer = Transfer(title: L("Clipboard", "Clipboard"), progress: 0, state: .sending)
        let r = try? await PortalHTTP.send(to: mac.route, method: "POST", path: "/clipboard",
                                           headers: ["Authorization": "Bearer \(token)", "Content-Type": type], body: body)
        transfer?.state = r?.status == 200 ? .done : .failed(L("Mac không nhận clipboard.", "The Mac didn't take the clipboard."))
        clearTransferSoon()
    }

    private func clearTransferSoon() {
        let snapshot = transfer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.transfer == snapshot { self?.transfer = nil }
        }
    }
}
