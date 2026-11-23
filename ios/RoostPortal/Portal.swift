import Foundation
import Network
import Security
import UIKit
import UniformTypeIdentifiers
import Combine
import CryptoKit
import ActivityKit
import BackgroundTasks

// MARK: - Trạng thái app

struct PortalMac: Identifiable, Equatable {
    let endpoint: NWEndpoint          // dịch vụ Bonjour
    var name: String
    var id: String                    // macID từ /hello, rỗng khi chưa hỏi được
    var paired: Bool
    var hosts: [String] = []          // IPv4 của Mac lấy từ TXT
    var port: UInt16?
    var direct: NWEndpoint?           // IP đã nối được, dùng trước Bonjour
    var tlsPort: UInt16?              // cổng mã hoá (TXT "tls"), có khi Mac đã có thiết bị ghép
    var encrypted = false             // lần nối gần nhất đi qua cổng mã hoá
    /// Đường đi cho mọi yêu cầu: IP trực tiếp nếu đã thử được, không thì để Bonjour phân giải (cả Wi-Fi trực tiếp).
    var route: NWEndpoint { direct ?? endpoint }

    /// Đường đi có mã hoá cho mọi yêu cầu có token: IP trực tiếp + cổng TLS.
    /// shortcut: khi chỉ có Wi-Fi trực tiếp (không có IP) thì vẫn đi HTTP thường; muốn mã hoá cả lúc đó
    /// thì Mac cần quảng bá thêm một dịch vụ Bonjour riêng cho cổng TLS.
    func secure(_ psk: PortalHTTP.PSK?) -> (NWEndpoint, PortalHTTP.PSK?) {
        if let psk, let tlsPort, let port = NWEndpoint.Port(rawValue: tlsPort),
           case let .hostPort(host, _)? = direct {
            return (.hostPort(host: host, port: port), psk)
        }
        return (route, nil)
    }
}

final class Portal: ObservableObject {
    static let shared = Portal()

    @Published var macs: [PortalMac] = []
    @Published var current: PortalMac?
    @Published var pairingCode: String?
    @Published var pairError: String?
    @Published var transfer: Transfer?
    @Published var receivedNote: String?     // file từ Mac vừa được cất ở đâu

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
                m.tlsPort = txt["tls"].flatMap { UInt16($0) }
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
        let headers: [String: String] = [:]   // không gửi token qua kết nối chưa mã hoá
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
        macs[i].paired = false
        // Mac đã ghép: hỏi lại qua cổng mã hoá xem token còn hợp lệ không (Mac gỡ thiết bị thì bắt tay TLS thất bại).
        // Ghép từ bản cũ (chưa có id thiết bị nên chưa mã hoá được): bỏ token cũ, ghép lại một lần.
        if macs[i].id == savedID, deviceID == nil, TokenStore.load(macs[i].id) != nil {
            TokenStore.delete(macs[i].id)
            savedID = nil
            pairError = L("Bản mới mã hoá kết nối: hãy ghép lại với Mac một lần.", "This version encrypts the connection: please pair with the Mac once more.")
        }
        if macs[i].id == savedID, let token = TokenStore.load(macs[i].id) {
            let mac = macs[i]
            let (ep, psk) = mac.secure(psk(for: mac.id, token: token))
            let auth = ["Authorization": "Bearer \(token)"]
            if let r = try? await PortalHTTP.send(to: ep, method: "GET", path: "/hello", headers: auth, timeout: 5, psk: psk),
               let j = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], j["paired"] as? Bool == true,
               let k = macs.firstIndex(where: { $0.endpoint == m.endpoint }) {
                macs[k].paired = true
                macs[k].encrypted = psk != nil
                if current == nil || current?.endpoint == macs[k].endpoint { current = macs[k] }
                if let dev = deviceID {   // cập nhật địa chỉ cho phần mở rộng Chia sẻ
                    PortalConfig(macID: mac.id, deviceID: dev, macName: macs[k].name, hosts: mac.hosts, port: mac.port, tls: mac.tlsPort).save()
                }
            }
        }
    }

    private var deviceID: String? {
        get { UserDefaults.standard.string(forKey: "device.id") }
        set { UserDefaults.standard.set(newValue, forKey: "device.id") }
    }

    private func psk(for macID: String, token: String) -> PortalHTTP.PSK? {
        guard let deviceID else { return nil }
        let hex = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return PortalHTTP.PSK(identity: deviceID, key: Data(hex.utf8))
    }

    /// Đích + khoá cho yêu cầu có token tới Mac đang chọn.
    private func secureTarget() -> (NWEndpoint, PortalHTTP.PSK?, String)? {
        guard let mac = current, let token else { return nil }
        let (ep, psk) = mac.secure(psk(for: mac.id, token: token))
        return (ep, psk, token)
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
            deviceID = json["device"] as? String
            if let dev = deviceID {
                PortalConfig(macID: id, deviceID: dev, macName: m.name, hosts: m.hosts, port: m.port, tls: m.tlsPort).save()
            }
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
        PortalConfig.clear()
        if let c = current, let i = macs.firstIndex(where: { $0.endpoint == c.endpoint }) { macs[i].paired = false }
        current = nil
    }

    // MARK: Gửi

    /// entry: độ cao ngón tay lúc hất (0 = đỉnh màn hình, 1 = đáy). Mac cho máy bay giấy ra đúng độ cao này.
    func send(file: URL, name: String, title: String? = nil, entry: Double?) async {
        guard let (ep, psk, token) = secureTarget() else { return }
        transfer = Transfer(title: title ?? name, progress: 0, state: .sending)
        receivedNote = nil
        let big = Self.size(file) > 15_000_000
        beginBackground(title: title ?? name, big: big)
        defer { endBackground() }
        let type = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["Authorization": "Bearer \(token)",
                       "Content-Type": type,
                       "X-Roost-Name": name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"]
        if let entry { headers["X-Roost-Y"] = String(format: "%.3f", min(max(entry, 0), 1)) }
        do {
            let r = try await PortalHTTP.send(to: ep, method: "POST", path: "/send", headers: headers, file: file,
                                              timeout: max(600, Double(Self.size(file)) / 300_000), psk: psk) { [weak self] p in
                self?.transfer?.progress = p
                self?.reportProgress(p)
            }
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
        guard let (ep, psk, token) = secureTarget() else { return }
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
            _ = try? await PortalHTTP.send(to: ep, method: "POST", path: "/hover", headers: headers, timeout: 2, psk: psk)
            if phase == "move" { hoverInFlight = false }
            if phase != "move" { hoverSent = (-1, -1, 0) }
        }
    }

    // MARK: Gửi tiếp khi rời app, tiến độ trên Dynamic Island

    static let continuedID = "io.github.letoan1.RoostPortal.send"
    private var activity: Activity<PortalActivity>?
    private var continued: BGContinuedProcessingTask?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var lastReport = 0.0

    /// Gọi một lần lúc mở app (trước khi app chạy xong khởi động).
    static func registerBackgroundSending() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedID + ".*", using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { Portal.shared.attach(task) }
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        guard transfer?.state == .sending else { task.setTaskCompleted(success: true); return }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64((transfer?.progress ?? 0) * 1000)
        task.expirationHandler = { [weak self] in MainActor.assumeIsolated { self?.continued = nil } }
        continued = task
    }

    /// File lớn: xin hệ thống cho chạy tiếp ở nền (hệ thống tự hiện tiến độ trên Dynamic Island).
    /// File nhỏ: Live Activity của app + vài chục giây chạy nền là đủ.
    private func beginBackground(title: String, big: Bool) {
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "portal.send") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        lastReport = 0
        if big {
            let req = BGContinuedProcessingTaskRequest(identifier: Self.continuedID + "." + UUID().uuidString.prefix(8),
                                                       title: L("Gửi sang \(current?.name ?? "Mac")", "Sending to \(current?.name ?? "Mac")"),
                                                       subtitle: title)
            req.strategy = .fail
            if (try? BGTaskScheduler.shared.submit(req)) != nil { return }
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: PortalActivity(macName: current?.name ?? "Mac"),
                                         content: .init(state: .init(title: title, progress: 0), staleDate: nil))
    }

    private func reportProgress(_ p: Double) {
        continued?.progress.completedUnitCount = Int64(p * 1000)
        let now = CACurrentMediaTime()
        guard let activity, now - lastReport > 0.5 || p >= 1 else { return }   // Live Activity: cập nhật thưa, đỡ tốn pin
        lastReport = now
        let state = PortalActivity.ContentState(title: transfer?.title ?? "", progress: p)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func endBackground() {
        let ok = transfer?.state == .done
        if let task = continued {
            task.progress.completedUnitCount = ok ? 1000 : task.progress.completedUnitCount
            task.setTaskCompleted(success: ok)
            continued = nil
        }
        if let activity {
            let state = PortalActivity.ContentState(title: transfer?.title ?? "", progress: 1, done: ok, failed: !ok)
            Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 3)) }
            self.activity = nil
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    /// Không giới hạn cứng 10 phút: file lớn được thêm thời gian theo dung lượng (giả định tối thiểu ~300 KB/s).
    static func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }

    func sendClipboard() async {
        guard let (ep, psk, token) = secureTarget() else { return }
        let pb = UIPasteboard.general
        // Clipboard là một link: mở luôn trên Mac.
        if pb.hasURLs, let url = pb.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            await sendLink(url)
            return
        }
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
        let r = try? await PortalHTTP.send(to: ep, method: "POST", path: "/clipboard",
                                           headers: ["Authorization": "Bearer \(token)", "Content-Type": type], body: body, psk: psk)
        transfer?.state = r?.status == 200 ? .done : .failed(L("Mac không nhận clipboard.", "The Mac didn't take the clipboard."))
        clearTransferSoon()
    }

    /// Mở link trên Mac (trình duyệt mặc định), đồng thời chép vào clipboard của Mac.
    func sendLink(_ url: URL) async {
        guard let (ep, psk, token) = secureTarget() else { return }
        transfer = Transfer(title: url.host ?? url.absoluteString, progress: 0, state: .sending)
        let r = try? await PortalHTTP.send(to: ep, method: "POST", path: "/link",
                                           headers: ["Authorization": "Bearer \(token)", "Content-Type": "text/plain; charset=utf-8"],
                                           body: Data(url.absoluteString.utf8), psk: psk)
        transfer?.state = r?.status == 200 ? .done : .failed(L("Mac không mở được link.", "The Mac couldn't open the link."))
        clearTransferSoon()
    }

    private func clearTransferSoon() {
        let snapshot = transfer
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.transfer == snapshot { self?.transfer = nil }
        }
    }
}
