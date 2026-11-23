import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import Network

/// Phần mở rộng Chia sẻ: từ app bất kỳ, Chia sẻ > Roost Portal gửi thẳng sang Mac đã ghép (qua cổng mã hoá).
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareCard(model: model) { [weak self] in self?.finish() })
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.run(providers: items.flatMap { $0.attachments ?? [] }); finishSoon() }
    }

    private func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + (model.failed ? 2.5 : 0.9)) { [weak self] in self?.finish() }
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var title = L("Đang chuẩn bị…", "Preparing…")
    @Published var progress: Double = 0
    @Published var done = false
    @Published var failed = false
    @Published var macName = "Mac"

    private var config: PortalConfig?
    private var token: String?
    private var endpoint: NWEndpoint?

    func run(providers: [NSItemProvider]) async {
        guard let config = PortalConfig.load(), let token = config.token else {
            fail(L("Mở app Roost Portal để ghép với Mac trước.", "Open Roost Portal and pair with your Mac first."))
            return
        }
        self.config = config
        self.token = token
        macName = config.macName
        guard await connect() else {
            fail(L("Không tìm thấy \(config.macName). Mac và iPhone cần chung Wi-Fi.", "Can't reach \(config.macName). Both need the same Wi-Fi."))
            return
        }
        for (i, p) in providers.enumerated() {
            let prefix = providers.count > 1 ? "\(i + 1)/\(providers.count)  " : ""
            if !(await send(p, prefix: prefix)) { return }
        }
        title = L("Đã tới \(macName)", "Arrived on \(macName)")
        progress = 1
        done = true
    }

    /// Thử lần lượt các địa chỉ của Mac qua cổng mã hoá.
    private func connect() async -> Bool {
        guard let config, let token else { return false }
        for ep in config.secureEndpoints {
            if let r = try? await PortalHTTP.send(to: ep, method: "GET", path: "/hello", headers: ["Authorization": "Bearer \(token)"],
                                                  timeout: 3, psk: config.psk(token: token)), r.status == 200 {
                endpoint = ep
                return true
            }
        }
        return false
    }

    private func send(_ p: NSItemProvider, prefix: String) async -> Bool {
        guard let config, let token, let endpoint else { return false }
        let psk = config.psk(token: token)
        let auth = ["Authorization": "Bearer \(token)"]
        // Link web: mở trên Mac.
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            title = prefix + (url.host ?? url.absoluteString)
            let r = try? await PortalHTTP.send(to: endpoint, method: "POST", path: "/link", headers: auth.merging(["Content-Type": "text/plain"]) { a, _ in a },
                                               body: Data(url.absoluteString.utf8), psk: psk)
            return check(r?.status)
        }
        // Chữ thuần: vào clipboard của Mac.
        if !p.hasItemConformingToTypeIdentifier(UTType.data.identifier) || p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            title = prefix + L("Văn bản", "Text")
            let r = try? await PortalHTTP.send(to: endpoint, method: "POST", path: "/clipboard",
                                               headers: auth.merging(["Content-Type": "text/plain; charset=utf-8"]) { a, _ in a },
                                               body: Data(text.utf8), psk: psk)
            return check(r?.status)
        }
        // Ảnh, video, file: chép ra file tạm rồi gửi từng khúc.
        guard let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) ?? p.registeredTypeIdentifiers.first,
              let file = await copyFile(p, type: type) else {
            fail(L("Không đọc được mục chia sẻ.", "Couldn't read the shared item."))
            return false
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let name = file.lastPathComponent
        title = prefix + name
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = auth.merging(["Content-Type": mime, "X-Roost-Y": "0.45",
                                    "X-Roost-Name": name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"]) { a, _ in a }
        let r = try? await PortalHTTP.send(to: endpoint, method: "POST", path: "/send", headers: headers, file: file, timeout: 600, psk: psk) { [weak self] v in
            self?.progress = v
        }
        return check(r?.status)
    }

    private func copyFile(_ p: NSItemProvider, type: String) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var name = p.suggestedName ?? url.deletingPathExtension().lastPathComponent
                if (name as NSString).pathExtension.isEmpty { name += "." + url.pathExtension }
                let dest = dir.appendingPathComponent(name)
                cont.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil)
            }
        }
    }

    private func check(_ status: Int?) -> Bool {
        if status == 200 { return true }
        fail(status == 401 ? L("Mac đã gỡ iPhone này, mở app để ghép lại.", "The Mac removed this iPhone, open the app to pair again.")
                           : L("Mac không nhận (\(status ?? -1)).", "The Mac refused it (\(status ?? -1))."))
        return false
    }

    private func fail(_ why: String) {
        title = why
        failed = true
    }
}

struct ShareCard: View {
    @ObservedObject var model: ShareModel
    let close: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    NotchMark().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Gửi tới", "Send to")).font(.caption).foregroundStyle(Theme.muted)
                        Text(model.macName).font(.headline).foregroundStyle(Theme.paper)
                    }
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Theme.paper)
                            .frame(width: 30, height: 30).background(.white.opacity(0.1), in: Circle())
                    }
                }
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 3)
                        Circle().trim(from: 0, to: model.done ? 1 : model.progress)
                            .stroke(model.failed ? Color.orange : (model.done ? .green : Theme.glow), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        if model.failed { Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(.orange) }
                        else if model.done { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green) }
                        else { PaperPlane().frame(width: 16) }
                    }
                    .frame(width: 34, height: 34)
                    Text(model.title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.paper).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            .padding(18)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.08)))
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.3), value: model.done)
    }
}
