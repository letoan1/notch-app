import SwiftUI
import Photos
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var portal = Portal.shared
    @StateObject private var library = PhotoLibrary()
    // @State, không @StateObject: màn hình không vẽ lại theo từng bước ngón tay, chỉ lớp phủ quan sát.
    @State private var drag = DragState()
    @State private var lifted = Lifted()
    @State private var importing = false

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            if let mac = portal.current {
                sendScreen(mac)
            } else {
                PairScreen(portal: portal)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { portal.start() }
    }

    private func sendScreen(_ mac: PortalMac) -> some View {
        ZStack {
            Group {
                switch library.status {
                case .authorized, .limited:
                    PhotoGrid(library: library, drag: drag, lifted: lifted, fling: { assets, entry in
                        Task { await send(assets, entry: entry) }
                    }, header: AnyView(VStack(spacing: 14) {
                        MacCard(mac: mac, portal: portal)
                        FilterChips(library: library)
                    }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)))
                case .notDetermined:
                    ProgressView()
                default:
                    VStack(spacing: 18) {
                        MacCard(mac: mac, portal: portal).padding(.horizontal, 12)
                        Spacer()
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundStyle(Theme.muted)
                        Text(L("Chưa có quyền xem ảnh", "No photo access")).font(.headline)
                        Text(L("Vẫn gửi được file và clipboard ở thanh dưới.", "You can still send files and the clipboard below."))
                            .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        Button(L("Mở Cài đặt", "Open Settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.glow).foregroundStyle(.black)
                        Spacer()
                    }
                }
            }
            HStack { EdgeRail(); Spacer() }
            DragOverlay(drag: drag, macName: mac.name)
            PaperStageView().ignoresSafeArea().allowsHitTesting(false)
            VStack {
                if let t = portal.transfer { TransferHUD(transfer: t).padding(.top, 4) }
                Spacer()
                Dock(lifted: lifted, importing: $importing, portal: portal) { assets in Task { await send(assets, entry: nil) } }
                    .padding(.bottom, 8)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: portal.transfer)
        }
        .task {
            PaperStage.shared.warmUp()
            await library.load()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { for url in urls { await sendPicked(url) } }
        }
    }

    /// Gửi lần lượt từng ảnh (Mac xếp các máy bay giấy cạnh nhau).
    private func send(_ assets: [PHAsset], entry: Double?) async {
        for (i, asset) in assets.enumerated() {
            let prefix = assets.count > 1 ? "\(i + 1)/\(assets.count)  " : ""
            do {
                let (url, name) = try await library.export(asset) { p in
                    portal.transfer = .init(title: prefix + L("Đang tải từ iCloud…", "Downloading from iCloud…"), progress: p, state: .sending)
                }
                await portal.send(file: url, name: name, title: prefix + name, entry: entry)
            } catch {
                portal.transfer = .init(title: L("Không đọc được ảnh", "Couldn't read the photo"), progress: 0, state: .failed(""))
            }
        }
    }

    /// File chọn từ app Tệp: chép ra thư mục tạm (quyền truy cập chỉ có tạm thời) rồi gửi.
    private func sendPicked(_ url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
        await portal.send(file: copy, name: url.lastPathComponent, entry: nil)
    }
}

// MARK: - Thẻ Mac

/// Đầu màn hình: Mac đang nối, mũi tên chỉ hướng hất, menu quên Mac.
struct MacCard: View {
    let mac: PortalMac
    @ObservedObject var portal: Portal

    var body: some View {
        HStack(spacing: 14) {
            NotchMark()
                .frame(width: 52, height: 52)
                .shadow(color: Color(red: 0.94, green: 0.42, blue: 0.66).opacity(0.35), radius: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.name).font(.title3.weight(.bold)).foregroundStyle(Theme.paper).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text(L("Đã kết nối", "Connected")).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Menu {
                Button(role: .destructive) { portal.forget() } label: { Label(L("Quên Mac này", "Forget this Mac"), systemImage: "xmark.circle") }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Theme.paper)
                    .frame(width: 36, height: 36).background(.white.opacity(0.08), in: Circle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.07)))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                PaperPlane().frame(height: 13).rotationEffect(.degrees(-90))
                Text(L("Nhấn giữ ảnh, hất về mép trái", "Hold a photo, fling it to the left edge"))
                    .font(.caption2.weight(.medium)).foregroundStyle(Theme.glow)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.ink, in: Capsule())
            .overlay(Capsule().stroke(Theme.glow.opacity(0.3)))
            .offset(x: 14, y: 12)
        }
        .padding(.bottom, 10)
    }
}

struct FilterChips: View {
    @ObservedObject var library: PhotoLibrary
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoLibrary.Filter.allCases, id: \.self) { f in
                    let on = library.filter == f
                    Button { library.filter = f } label: {
                        Text(f.title).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(on ? Color.black : Theme.paper)
                            .background(on ? AnyShapeStyle(Theme.paper) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - Thanh dưới

struct Dock: View {
    @ObservedObject var lifted: Lifted
    @Binding var importing: Bool
    let portal: Portal
    let sendSelected: ([PHAsset]) -> Void

    var body: some View {
        Group {
            if lifted.selecting {
                HStack(spacing: 10) {
                    Button { lifted.selecting = false; lifted.picked = [] } label: {
                        Text(L("Huỷ", "Cancel")).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.paper)
                            .padding(.horizontal, 18).padding(.vertical, 14)
                    }
                    Button {
                        let assets = lifted.pickedAssets()
                        lifted.picked = []
                        lifted.selecting = false
                        sendSelected(assets)
                    } label: {
                        HStack(spacing: 8) {
                            PlaneGlyph().fill(.black).frame(width: 16, height: 11)
                            Text(lifted.picked.isEmpty ? L("Chạm ảnh để chọn", "Tap photos to select")
                                 : L("Gửi \(lifted.picked.count) mục", "Send \(lifted.picked.count)"))
                                .font(.subheadline.weight(.bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 14)
                        .background(lifted.picked.isEmpty ? AnyShapeStyle(Theme.paper.opacity(0.5)) : AnyShapeStyle(Theme.brand), in: Capsule())
                    }
                    .disabled(lifted.picked.isEmpty)
                }
            } else {
                HStack(spacing: 4) {
                    item(L("Chọn", "Select"), "checkmark.circle") { lifted.selecting = true }
                    item(L("Tệp", "Files"), "folder") { importing = true }
                    item(L("Clipboard", "Clipboard"), "doc.on.clipboard") { Task { await portal.sendClipboard() } }
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: lifted.selecting)
    }

    private func item(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).symbolRenderingMode(.hierarchical).frame(height: 22)
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.paper)
            .frame(width: 84, height: 50)
        }
    }
}

// MARK: - Tiến độ gửi

struct TransferHUD: View {
    let transfer: Portal.Transfer

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: transfer.state == .sending ? transfer.progress : 1)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                switch transfer.state {
                case .sending: PlaneGlyph().fill(Theme.paper).frame(width: 13, height: 9)
                case .done: Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(.orange)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.paper).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.1)))
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var color: Color {
        switch transfer.state { case .sending: return Theme.glow; case .done: return .green; case .failed: return .orange }
    }
    private var subtitle: String {
        switch transfer.state {
        case .sending: return "\(Int(transfer.progress * 100))%"
        case .done: return L("Đã tới Mac", "Arrived on the Mac")
        case .failed(let why): return why.isEmpty ? L("Không gửi được", "Not sent") : why
        }
    }
}

// MARK: - Ghép đôi

/// Chưa ghép: vòng dò tìm, danh sách Mac đang bật Portal quanh đây, chạm để ghép bằng mã 4 số.
struct PairScreen: View {
    @ObservedObject var portal: Portal
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(Theme.glow.opacity(0.35), lineWidth: 1.5)
                        .scaleEffect(pulse ? 1.6 : 0.5).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: pulse)
                }
                Circle().fill(Theme.surface).frame(width: 96, height: 96)
                    .overlay(Circle().stroke(.white.opacity(0.08)))
                PaperPlane().frame(height: 46).rotationEffect(.degrees(-12)).shadow(color: Theme.glow.opacity(0.8), radius: 12)
            }
            .frame(width: 200, height: 200)
            .onAppear { pulse = true }

            if let code = portal.pairingCode {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        ForEach(Array(code), id: \.self) { ch in
                            Text(String(ch)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Theme.paper)
                                .frame(width: 58, height: 72)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.glow.opacity(0.4)))
                        }
                    }
                    Text(L("Bấm Cho phép trên Mac nếu thấy đúng mã này", "Click Allow on the Mac if it shows this code"))
                        .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
            } else {
                VStack(spacing: 6) {
                    Text("Roost Portal").font(.largeTitle.weight(.bold)).foregroundStyle(Theme.paper)
                    Text(portal.macs.isEmpty ? L("Đang tìm Mac quanh đây…", "Looking for Macs nearby…")
                         : L("Chọn Mac để ghép đôi", "Choose a Mac to pair"))
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            if let err = portal.pairError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
            }
            VStack(spacing: 10) {
                ForEach(portal.macs) { mac in
                    Button { Task { await portal.pair(mac) } } label: {
                        HStack(spacing: 14) {
                            NotchMark().frame(width: 34, height: 34)
                            Text(mac.name).font(.body.weight(.semibold)).foregroundStyle(Theme.paper)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                        }
                        .padding(16)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.07)))
                    }
                    .disabled(portal.pairingCode != nil)
                }
            }
            .padding(.horizontal, 20)
            Spacer()
            Text(L("Trên Mac: Roost > Cài đặt > Portal > bật Nhận từ iPhone. Không cần chung Wi-Fi.",
                   "On the Mac: Roost > Settings > Portal > turn on Receive from iPhone. No shared Wi-Fi needed."))
                .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.horizontal, 30).padding(.bottom, 16)
        }
    }
}
