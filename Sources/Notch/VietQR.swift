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

/// Tài khoản nhận: ngân hàng + tên trong UserDefaults, số tài khoản trong Keychain.
@MainActor
final class VietQRStore: ObservableObject {
    static let shared = VietQRStore()
    @Published var panelOpen = false
    @Published var amount: Int?
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

    func toggle() {
        withAnimation(.easeOut(duration: 0.18)) {
            panelOpen.toggle()
            if panelOpen { amount = nil }
        }
    }

    private static let service = "io.github.letoan1.roost.vietqr"
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "account"]
    }
    private static func readAccount() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func writeAccount(_ value: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var q = query()
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

/// Thẻ QR thả xuống dưới hàng tab, cùng kiểu bảng mức dùng Claude.
struct VietQRPanelHost: View {
    @ObservedObject var store = VietQRStore.shared
    var body: some View {
        if store.panelOpen {
            VietQRPanel()
                .padding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        }
    }
}

private struct VietQRPanel: View {
    @ObservedObject var store = VietQRStore.shared
    private var copied = State(initialValue: false)
    private var custom = State(initialValue: "")
    private static let quick = [50_000, 100_000, 200_000, 500_000]

    var body: some View {
        // Không có dòng tiêu đề: thẻ thấp để không bị đáy notch cắt; nút sửa / đóng nằm ở góc.
        VStack(alignment: .leading, spacing: 0) {
            if store.configured { card } else { empty }
        }
        .padding(10)
        .frame(width: 330, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if store.configured {
                    iconButton("pencil", L("Đổi tài khoản", "Change account")) { Self.openSettings() }
                }
                iconButton("xmark", L("Đóng", "Close")) { store.toggle() }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    private var card: some View {
        let text = VietQR.payload(bin: store.bin, account: store.account, amount: store.amount)
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if let img = VietQR.image(text) {
                    Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
                } else { Color.white }
            }
            .padding(6)
            .frame(width: 108, height: 108)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
            .accessibilityLabel(L("Mã QR chuyển khoản", "Bank transfer QR code"))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(store.bank?.name ?? store.bin).font(.ui(12, weight: .bold)).foregroundStyle(.white)
                    if !store.name.isEmpty {
                        Text(store.name).font(.ui(10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .lineLimit(1)
                .padding(.trailing, 48)   // chừa chỗ cho nút sửa / đóng
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.account, forType: .string)
                    copied.wrappedValue = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied.wrappedValue = false }
                } label: {
                    HStack(spacing: 4) {
                        Text(masked).font(.ui(11).monospacedDigit())
                        Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(copied.wrappedValue ? Color.green : .white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(L("Chép số tài khoản", "Copy account number"))
                HStack(spacing: 4) { ForEach(Self.quick, id: \.self) { v in chip(v) } }
                TextField(L("Số tiền khác", "Other amount"), text: custom.projectedValue)
                    .textFieldStyle(.plain)
                    .font(.ui(11).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
                    .onChange(of: custom.wrappedValue) { _, v in
                        let digits = v.filter(\.isNumber)
                        store.amount = Int(digits).flatMap { $0 > 0 ? $0 : nil }
                    }
            }
        }
    }

    /// Chưa có tài khoản: một dòng + nút mở Cài đặt (gõ phím trong notch không tiện).
    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "qrcode").font(.system(size: 18)).foregroundStyle(.white.opacity(0.7))
            Text(L("Thêm tài khoản ngân hàng để có mã QR nhận tiền.", "Add a bank account to get a QR for receiving money."))
                .font(.ui(11.5)).foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L("Thiết lập", "Set up")) { Self.openSettings() }
                .padding(.trailing, 26)   // chừa nút đóng ở góc
                .buttonStyle(.plain)
                .font(.ui(11.5, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.white))
        }
    }

    static func openSettings() {
        VietQRStore.shared.panelOpen = false
        SettingsWindowController.shared.show(pane: "general")
    }

    private var masked: String {
        let a = store.account
        return a.count > 4 ? "•••• " + a.suffix(4) : a
    }

    private func chip(_ value: Int) -> some View {
        let on = store.amount == value
        return Button {
            store.amount = on ? nil : value
            custom.wrappedValue = ""
        } label: {
            Text(value >= 1_000_000 ? "\(value / 1_000_000)tr" : "\(value / 1000)k")
                .font(.ui(10.5, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.white : .white.opacity(0.1)))
                .foregroundStyle(on ? Color.black : .white)
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
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
                Picker("", selection: Binding(get: { store.bin.isEmpty ? VietQR.banks[0].bin : store.bin },
                                              set: { store.save(bin: $0, account: store.account, name: store.name) })) {
                    ForEach(VietQR.banks) { Text($0.name).tag($0.bin) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            SRow("number", L("Số tài khoản", "Account number")) {
                TextField("0123456789", text: account.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onChange(of: account.wrappedValue) { _, v in save(account: v) }
            }
            SRow("person", L("Tên chủ tài khoản", "Account holder"), detail: L("Không bắt buộc, chỉ để bạn nhìn.", "Optional, only shown to you.")) {
                TextField("NGUYEN VAN A", text: name.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
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
