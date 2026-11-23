import AppKit
import Network
import UniformTypeIdentifiers

// MARK: - Mac gửi sang iPhone

/// iPhone đã ghép đang mở app RoostPortal thì quảng bá `_roost-iphone._tcp` (TXT có id thiết bị).
/// Mac thấy thì hiện "Gửi sang <iPhone>" trong menu chuột phải của khay; gửi qua TLS PSK cùng khoá lúc ghép.
/// Chỉ dò khi Portal bật (đi theo PortalServer), không chạy gì khi tắt.
@MainActor
final class PortalPhones: ObservableObject {
    static let shared = PortalPhones()

    struct Phone: Identifiable, Equatable {
        let endpoint: NWEndpoint
        let name: String
        let deviceID: String
        var id: String { deviceID }
    }

    @Published private(set) var phones: [Phone] = []
    private var browser: NWBrowser?

    func setEnabled(_ on: Bool) {
        if on, browser == nil {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_roost-iphone._tcp", domain: nil), using: params)
            b.browseResultsChangedHandler = { results, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { PortalPhones.shared.update(results) } }
            }
            b.start(queue: .main)
            browser = b
        } else if !on {
            browser?.cancel()
            browser = nil
            phones = []
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let paired = Dictionary(PortalSettings.shared.devices.filter { $0.kind == "app" }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var list: [Phone] = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata,
                  let id = txt["device"], paired[id] != nil, !list.contains(where: { $0.deviceID == id }) else { continue }
            list.append(Phone(endpoint: r.endpoint, name: name, deviceID: id))
        }
        phones = list.sorted { $0.name < $1.name }
    }

    /// Gửi file: máy bay giấy cất cánh từ notch bay ra mép phải (phía iPhone), iPhone nhận và cất vào Ảnh / Tệp.
    func send(_ url: URL, to phone: Phone) {
        guard let device = PortalSettings.shared.devices.first(where: { $0.id == phone.deviceID }) else { return }
        PortalFlight.depart(image: NSWorkspace.shared.icon(forFile: url.path), url: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        let name = url.lastPathComponent
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var head = "POST /receive HTTP/1.1\r\nHost: iphone\r\nConnection: close\r\nContent-Length: \(size)\r\n"
        head += "Content-Type: \(mime)\r\nX-Roost-Name: \(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file")\r\n"
        head += "X-Roost-From: \(PortalSettings.macName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Mac")\r\n\r\n"

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(sec, PortalServer.dispatchData(Data(device.tokenHash.utf8)), PortalServer.dispatchData(Data(device.id.utf8)))
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        Self.transmit(handle: handle, head: head, to: phone.endpoint, using: params)
    }

    /// Phần mạng chạy trên hàng đợi riêng: gửi header rồi bơm file từng khúc 256 KB.
    nonisolated private static func transmit(handle: FileHandle, head: String, to endpoint: NWEndpoint, using params: NWParameters) {
        let conn = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "roost.portal.out")
        @Sendable func finish() { try? handle.close(); conn.cancel() }
        @Sendable func pump() {
            let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
            if chunk.isEmpty {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in finish() }
                return
            }
            conn.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { finish() } else { pump() }
            })
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: conn.send(content: Data(head.utf8), completion: .contentProcessed { e in if e == nil { pump() } else { finish() } })
            case .failed, .waiting: finish()
            default: break
            }
        }
        conn.start(queue: queue)
    }
}
