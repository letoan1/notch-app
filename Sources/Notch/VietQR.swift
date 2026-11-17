import AppKit
import CoreImage
import Security
import SwiftUI

/// VietQR (NAPAS 247): QR chuyển khoản vào tài khoản của bạn, tạo ngay trên máy theo chuẩn EMVCo. Không cần mạng.
enum VietQR {
    struct Bank: Identifiable, Hashable {
        let name: String
        let bin: String
        var id: String { bin }
    }

    /// Mã BIN NAPAS của các ngân hàng phổ biến.
    static let banks: [Bank] = [
        Bank(name: "Vietcombank", bin: "970436"), Bank(name: "VietinBank", bin: "970415"),
        Bank(name: "BIDV", bin: "970418"), Bank(name: "Agribank", bin: "970405"),
        Bank(name: "Techcombank", bin: "970407"), Bank(name: "MB Bank", bin: "970422"),
        Bank(name: "ACB", bin: "970416"), Bank(name: "VPBank", bin: "970432"),
        Bank(name: "TPBank", bin: "970423"), Bank(name: "Sacombank", bin: "970403"),
        Bank(name: "VIB", bin: "970441"), Bank(name: "HDBank", bin: "970437"),
        Bank(name: "SHB", bin: "970443"), Bank(name: "MSB", bin: "970426"),
        Bank(name: "OCB", bin: "970448"), Bank(name: "SeABank", bin: "970440"),
        Bank(name: "Eximbank", bin: "970431"), Bank(name: "LPBank", bin: "970449"),
        Bank(name: "Nam A Bank", bin: "970428"), Bank(name: "BVBank (Timo)", bin: "970454"),
        Bank(name: "Cake by VPBank", bin: "546034"), Bank(name: "PVcomBank", bin: "970412"),
    ]

    /// Chuỗi QR: `amount` nil = QR tĩnh (người quét tự nhập số tiền).
    static func payload(bin: String, account: String, amount: Int? = nil, note: String? = nil) -> String {
        func f(_ id: String, _ v: String) -> String { id + String(format: "%02d", v.utf8.count) + v }
        let beneficiary = f("00", bin) + f("01", account)
        var s = f("00", "01") + f("01", amount == nil ? "11" : "12")
        s += f("38", f("00", "A000000727") + f("01", beneficiary) + f("02", "QRIBFTTA"))
        s += f("53", "704")
        if let amount, amount > 0 { s += f("54", String(amount)) }
        s += f("58", "VN")
        if let note, !note.isEmpty { s += f("62", f("08", note)) }
        s += "6304"
        return s + String(format: "%04X", crc16(s))
    }

    /// CRC-16/CCITT-FALSE (đa thức 0x1021, khởi đầu 0xFFFF), như EMVCo quy định.
    static func crc16(_ s: String) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in s.utf8 {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// "50.000đ"
    static func money(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + "đ"
    }

    static func image(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Một chuỗi bí mật trong Keychain (generic password), theo tên service.
enum Keychain {
    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "account"]
    }
    static func read(_ service: String) -> String? {
        var q = query(service)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ service: String, _ value: String) {
        if value.isEmpty { SecItemDelete(query(service) as CFDictionary); return }
        let data = Data(value.utf8)
        if SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var q = query(service)
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

/// Tài khoản nhận: ngân hàng + tên trong UserDefaults, số tài khoản trong Keychain.
@MainActor
final class VietQRStore: ObservableObject {
    static let shared = VietQRStore()
    @Published var amount: Int?
    /// Màn hình Ngân hàng đang thay nội dung notch (mở từ nút QR trong Bố cục notch).
    @Published var panelOpen = false

    func toggle() { withAnimation(.easeOut(duration: 0.2)) { panelOpen.toggle() } }
    @Published private(set) var bin: String = UserDefaults.standard.string(forKey: "vietqr.bin") ?? ""
    @Published private(set) var name: String = UserDefaults.standard.string(forKey: "vietqr.name") ?? ""
    @Published private(set) var account: String = VietQRStore.readAccount() ?? ""

    var configured: Bool { !bin.isEmpty && !account.isEmpty }
    var bank: VietQR.Bank? { VietQR.banks.first { $0.bin == bin } }

    func save(bin: String, account: String, name: String) {
        self.bin = bin
        self.account = account.filter(\.isNumber)
        self.name = name.trimmingCharacters(in: .whitespaces).uppercased()
        UserDefaults.standard.set(bin, forKey: "vietqr.bin")
        UserDefaults.standard.set(self.name, forKey: "vietqr.name")
        Self.writeAccount(self.account)
    }

    /// Mã nội dung chuyển khoản riêng cho mỗi lần nhận, để SePay khớp đúng giao dịch ("RST4K9P2").
    @Published private(set) var code = VietQRStore.newCode()

    func newRequest() { code = Self.newCode(); amount = nil }

    static func newCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // bỏ 0/O, 1/I cho dễ đọc
        return "RST" + String((0..<5).map { _ in chars.randomElement()! })
    }

    private static func readAccount() -> String? { Keychain.read("io.github.letoan1.roost.vietqr") }
    private static func writeAccount(_ value: String) { Keychain.write("io.github.letoan1.roost.vietqr", value) }
}

/// Báo nhận tiền qua SePay (người dùng tự bật, token lưu Keychain): khi tab Ngân hàng đang hiện một mã QR,
/// hỏi giao dịch mới mỗi 10 giây (tối đa 10 phút), khớp theo mã nội dung + số tiền.
@MainActor
final class SePayWatcher: ObservableObject {
    static let shared = SePayWatcher()
    static let tokenService = "io.github.letoan1.roost.sepay"

    struct Received: Identifiable, Equatable {
        let id: String
        let amount: Int
        let content: String
        let date: Date
    }
    /// off = chưa bật / chưa có token; idle = đã bật nhưng đang không chờ (hết 10 phút).
    enum State: Equatable { case off, idle, waiting, received(Received), failed(String) }

    @Published private(set) var state: State = .off
    @Published private(set) var recent: [Received] = []
    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "sepay.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "sepay.enabled"); if !enabled { stop() } }
    }
    @Published private(set) var hasToken = !(Keychain.read(SePayWatcher.tokenService) ?? "").isEmpty
    var ready: Bool { enabled && hasToken }

    func setToken(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(Self.tokenService, v)
        if hasToken != !v.isEmpty { hasToken = !v.isEmpty }
    }

    private var task: Task<Void, Never>?
    private var seen = Set<String>()

    func watch(code: String, amount: Int?, account: String) {
        task?.cancel()
        guard ready, let token = Keychain.read(Self.tokenService) else { state = .off; return }
        state = .waiting
        task = Task { [weak self] in
            let deadline = Date().addingTimeInterval(600)
            while !Task.isCancelled, Date() < deadline {
                do {
                    let txs = try await Self.fetch(token: token, account: account)
                    guard let self, !Task.isCancelled else { return }
                    if let hit = Self.match(txs, code: code, amount: amount), !self.seen.contains(hit.id) {
                        self.seen.insert(hit.id)
                        self.got(hit)
                        return
                    }
                    if case .failed = self.state { self.state = .waiting }
                } catch {
                    self?.state = .failed(L("Không hỏi được SePay, kiểm tra token", "Couldn't reach SePay, check the token"))
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
            if let self, self.state == .waiting { self.state = .idle }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if state == .waiting { state = ready ? .idle : .off }
    }

    private func got(_ r: Received) {
        state = .received(r)
        recent.insert(r, at: 0)
        recent = Array(recent.prefix(5))
        AlertCenter.shared.post(NotchAlert(
            kind: .moneyReceived, title: L("Đã nhận", "Received"), highlight: VietQR.money(r.amount),
            subtitle: r.content, icon: .symbol("checkmark.seal.fill"), tone: .green,
            priority: 2, duration: 8, action: .none))
    }

    /// Giao dịch tiền vào khớp mã nội dung (không phân biệt hoa thường) và đủ số tiền (nếu QR có số tiền).
    nonisolated static func match(_ txs: [[String: Any]], code: String, amount: Int?) -> Received? {
        for t in txs {
            let content = "\(t["transaction_content"] ?? "")"
            let inAmount = Int(Double("\(t["amount_in"] ?? "0")") ?? 0)
            guard inAmount > 0, content.uppercased().contains(code.uppercased()) else { continue }
            if let amount, inAmount < amount { continue }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
            return Received(id: "\(t["id"] ?? content)", amount: inAmount, content: content,
                            date: f.date(from: "\(t["transaction_date"] ?? "")") ?? Date())
        }
        return nil
    }

    nonisolated static func fetch(token: String, account: String) async throws -> [[String: Any]] {
        var c = URLComponents(string: "https://my.sepay.vn/userapi/transactions/list")!
        c.queryItems = [URLQueryItem(name: "account_number", value: account), URLQueryItem(name: "limit", value: "20")]
        var req = URLRequest(url: c.url!, timeoutInterval: 8)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return root["transactions"] as? [[String: Any]] ?? []
    }
}

/// Tab Ngân hàng: QR lớn bên trái, tài khoản + số tiền ở giữa, trạng thái nhận tiền (SePay) bên phải.
struct BankPanel: View {
    @ObservedObject var store = VietQRStore.shared
    @ObservedObject var sepay = SePayWatcher.shared
    private var copied = State(initialValue: "")
    private var custom = State(initialValue: "")
    private static let quick = [50_000, 100_000, 200_000, 500_000]

    var body: some View {
        Group {
            if store.configured { content } else { empty }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: restart)
        .onDisappear { sepay.stop() }
        .onChange(of: store.amount) { _, _ in restart() }
        .onChange(of: store.code) { _, _ in restart() }
        // Bật SePay / dán token khi màn hình đang mở: bắt đầu chờ ngay.
        .onChange(of: sepay.enabled) { _, _ in restart() }
        .onChange(of: sepay.hasToken) { _, _ in restart() }
    }

    private func restart() {
        guard store.configured else { return }
        sepay.watch(code: store.code, amount: store.amount, account: store.account)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 16) {
            qr
            details.frame(width: 210, alignment: .leading)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1).padding(.vertical, 4)
            status.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var qr: some View {
        let text = VietQR.payload(bin: store.bin, account: store.account, amount: store.amount, note: store.code)
        return Group {
            if let img = VietQR.image(text) {
                Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
            } else { Color.white }
        }
        .padding(8)
        .frame(width: 130, height: 130)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
        .accessibilityLabel(L("Mã QR chuyển khoản", "Bank transfer QR code"))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(store.bank?.name ?? store.bin).font(.ui(13, weight: .bold)).foregroundStyle(.white)
                Text(store.name).font(.ui(10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            HStack(spacing: 10) {
                copyChip(store.account.count > 4 ? "•••• " + store.account.suffix(4) : store.account, value: store.account, key: "stk")
                copyChip(store.code, value: store.code, key: "code")
            }
            HStack(spacing: 4) { ForEach(Self.quick, id: \.self) { chip($0) } }
            TextField(L("Số tiền khác", "Other amount"), text: custom.projectedValue)
                .textFieldStyle(.plain)
                .font(.ui(11.5).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                .onChange(of: custom.wrappedValue) { _, v in
                    store.amount = Int(v.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
                }
        }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch sepay.state {
            case .received(let r):
                Label(L("Đã nhận", "Received"), systemImage: "checkmark.seal.fill")
                    .font(.ui(11, weight: .semibold)).foregroundStyle(.green)
                Text("+" + VietQR.money(r.amount)).font(.ui(22, weight: .heavy).monospacedDigit()).foregroundStyle(.white)
                Text(r.date.formatted(date: .omitted, time: .shortened) + " · " + r.content)
                    .font(.ui(10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                pill(L("Nhận khoản mới", "New request")) { custom.wrappedValue = ""; store.newRequest() }
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Đang chờ chuyển khoản…", "Waiting for the transfer…")).font(.ui(11.5, weight: .semibold)).foregroundStyle(.white)
                }
                Text(L("Người chuyển giữ nguyên nội dung \(store.code) để Roost nhận ra.",
                       "Ask the sender to keep \(store.code) in the transfer note."))
                    .font(.ui(10)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            case .idle:
                Label(L("Đã ngừng chờ", "Stopped waiting"), systemImage: "pause.circle.fill")
                    .font(.ui(11.5, weight: .semibold)).foregroundStyle(.white)
                Text(L("Roost chỉ chờ 10 phút cho mỗi mã QR.", "Roost waits up to 10 minutes per QR."))
                    .font(.ui(10)).foregroundStyle(.white.opacity(0.5))
                pill(L("Chờ tiếp", "Keep waiting")) { restart() }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.ui(10.5)).foregroundStyle(.orange)
            case .off:
                Text(L("Báo khi nhận tiền", "Payment alerts")).font(.ui(11.5, weight: .semibold)).foregroundStyle(.white)
                Text(L("Bật SePay để notch báo ngay khi tiền vào tài khoản.", "Turn on SePay to get a notch alert when money arrives."))
                    .font(.ui(10)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                pill(L("Thiết lập", "Set up")) { SettingsWindowController.shared.show(pane: "bank") }
            }
            if !sepay.recent.isEmpty, sepay.state != .waiting {
                ForEach(sepay.recent.dropFirst().prefix(2)) { r in
                    Text("+" + VietQR.money(r.amount) + " · " + r.date.formatted(date: .omitted, time: .shortened))
                        .font(.ui(10).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private var empty: some View {
        HStack(spacing: 14) {
            Image(systemName: "qrcode").font(.system(size: 34)).foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Nhận tiền bằng mã QR", "Receive money with a QR")).font(.ui(14, weight: .bold)).foregroundStyle(.white)
                Text(L("Thêm tài khoản ngân hàng để có mã VietQR, tạo ngay trên máy.",
                       "Add a bank account to get a VietQR code, made on this Mac."))
                    .font(.ui(11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            pill(L("Thiết lập", "Set up")) { SettingsWindowController.shared.show(pane: "bank") }
        }
        .frame(maxHeight: .infinity)
    }

    private func copyChip(_ text: String, value: String, key: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied.wrappedValue = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied.wrappedValue == key { copied.wrappedValue = "" } }
        } label: {
            HStack(spacing: 4) {
                Text(text).font(.ui(11).monospacedDigit())
                Image(systemName: copied.wrappedValue == key ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(copied.wrappedValue == key ? Color.green : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help(L("Chép", "Copy"))
    }

    private func chip(_ value: Int) -> some View {
        let on = store.amount == value
        return Button {
            store.amount = on ? nil : value
            custom.wrappedValue = ""
        } label: {
            Text(value >= 1_000_000 ? "\(value / 1_000_000)tr" : "\(value / 1000)k")
                .font(.ui(11, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(Capsule().fill(on ? Color.white : .white.opacity(0.1)))
                .foregroundStyle(on ? Color.black : .white)
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.ui(11, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
    }
}
/// Cài đặt › Chung › Nhận tiền (VietQR): lưu ngay khi đổi, số tài khoản vào Keychain.
struct VietQRSettingsSection: View {
    @ObservedObject var store = VietQRStore.shared
    private var account = State(initialValue: VietQRStore.shared.account)
    private var name = State(initialValue: VietQRStore.shared.name)

    var body: some View {
        SSection(L("Nhận tiền (VietQR)", "Receive money (VietQR)"),
                 note: L("Nút QR trên hàng tab mở mã chuyển khoản vào tài khoản này. Mã tạo ngay trên máy theo chuẩn VietQR; số tài khoản lưu trong Keychain, không gửi đi đâu.",
                         "The QR button on the tab bar shows a transfer QR for this account. It is made on this Mac using the VietQR standard; the account number stays in the Keychain.")) {
            SRow("building.columns", L("Ngân hàng", "Bank"), divider: false) {
                SPicker(Binding(get: { store.bin.isEmpty ? VietQR.banks[0].bin : store.bin },
                                set: { store.save(bin: $0, account: store.account, name: store.name) }),
                        VietQR.banks.map { ($0.bin, $0.name) })
            }
            SRow("number", L("Số tài khoản", "Account number")) {
                STextField("0123456789", text: account.projectedValue)
                    .onChange(of: account.wrappedValue) { _, v in save(account: v) }
            }
            SRow("person", L("Tên chủ tài khoản", "Account holder"), detail: L("Không bắt buộc, chỉ để bạn nhìn.", "Optional, only shown to you.")) {
                STextField("NGUYEN VAN A", text: name.projectedValue)
                    .onChange(of: name.wrappedValue) { _, v in store.save(bin: binOrDefault, account: store.account, name: v) }
            }
        }
    }

    private var binOrDefault: String { store.bin.isEmpty ? VietQR.banks[0].bin : store.bin }

    private func save(account v: String) {
        let digits = v.filter(\.isNumber)
        if digits != v { account.wrappedValue = digits }   // chỉ nhận chữ số
        store.save(bin: binOrDefault, account: digits, name: store.name)
    }
}

/// Cài đặt › Chung › Báo nhận tiền (SePay): tắt mặc định; token lưu Keychain.
struct SePaySettingsSection: View {
    @ObservedObject var sepay = SePayWatcher.shared
    private var token = State(initialValue: Keychain.read(SePayWatcher.tokenService) ?? "")

    var body: some View {
        SSection(L("Báo khi nhận tiền (SePay)", "Payment alerts (SePay)"),
                 note: L("Tắt mặc định. Khi bật, lúc tab Ngân hàng đang hiện mã QR, Roost gửi token tới my.sepay.vn để đọc các giao dịch gần đây của tài khoản (tối đa 10 phút, 10 giây một lần) và khớp theo mã nội dung RST… trong QR. Roost không lưu giao dịch xuống đĩa. Cần tài khoản SePay đã liên kết ngân hàng.",
                         "Off by default. When on and the Bank tab shows a QR, Roost sends your token to my.sepay.vn to read the account's recent transactions (every 10 seconds, up to 10 minutes) and matches the RST… code in the QR. Nothing is saved to disk. Needs a SePay account linked to your bank.")) {
            SToggleRow(icon: "bell.badge", title: L("Báo khi tiền vào", "Alert when money arrives"),
                       detail: L("Thẻ xanh trên notch kèm số tiền.", "A green notch card with the amount."),
                       divider: false, isOn: $sepay.enabled)
            SRow("key", L("API token của SePay", "SePay API token"),
                 detail: L("my.sepay.vn › Cấu hình công ty › API Access", "my.sepay.vn › Company settings › API Access")) {
                STextField(L("Dán token", "Paste token"), text: token.projectedValue, secure: true)
                    .onChange(of: token.wrappedValue) { _, v in sepay.setToken(v) }
            }
            .disabled(!sepay.enabled)
        }
    }
}
