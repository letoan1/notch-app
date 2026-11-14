import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Giao diện Cassette cho các tab còn lại: kệ băng + đĩa mềm (khay), phiếu telex + con dấu
/// (Claude xin quyền), bảng ghim (Claude hỏi). Gương và lịch ở CassetteExtras.swift.

extension Font {
    /// Chữ trên giấy: đánh máy (Cassette) hoặc chữ có chân (thư Van Gogh).
    static func typewriter(_ size: CGFloat, bold: Bool = false) -> Font {
        if Theme.isVanGogh { return .system(size: size, weight: bold ? .semibold : .regular, design: .serif) }
        return .custom(bold ? "AmericanTypewriter-Bold" : "American Typewriter", size: size)
    }
}

/// Màu dải nhãn băng theo loại file.
func fileTint(_ url: URL) -> Color {
    if url.hasDirectoryPath { return Color(red: 0.39, green: 0.82, blue: 1.0) }
    guard let type = UTType(filenameExtension: url.pathExtension) else { return Color(red: 0.43, green: 0.48, blue: 0.85) }
    if type.conforms(to: .pdf) { return Color(red: 1.0, green: 0.35, blue: 0.32) }
    if type.conforms(to: .image) { return Color(red: 0.19, green: 0.69, blue: 0.35) }
    if type.conforms(to: .movie) { return Color(red: 0.66, green: 0.33, blue: 0.97) }
    if type.conforms(to: .audio) { return Color(red: 1.0, green: 0.31, blue: 0.55) }
    if type.conforms(to: .archive) { return Color(red: 0.56, green: 0.56, blue: 0.58) }
    if type.conforms(to: .sourceCode) || type.conforms(to: .text) { return Color(red: 0.04, green: 0.52, blue: 1.0) }
    return Color(red: 1.0, green: 0.62, blue: 0.04)
}

// MARK: - Băng mini (khay + notch thu gọn)

struct MiniTape: View {
    let band: Color
    let name: String

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: h * 0.09).fill(CassettePalette.shell)
                    .overlay(RoundedRectangle(cornerRadius: h * 0.09).stroke(CassettePalette.shellEdge, lineWidth: 1.5))
                VStack(spacing: 0) {
                    band.frame(height: h * 0.14)
                    if !name.isEmpty {
                        Text(name)
                            .font(.hand(max(8, h * 0.15)))
                            .foregroundStyle(CassettePalette.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 4)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 2)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: w - h * 0.18, height: h * 0.5)
                .background(CassettePalette.label)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(.top, h * 0.08)
                Capsule().fill(CassettePalette.window)
                    .frame(width: w * 0.5, height: h * 0.22)
                    .offset(y: h * 0.5)
                HStack(spacing: w * 0.2) { reelDot(h); reelDot(h) }
                    .offset(y: h * 0.525)
            }
        }
    }

    private func reelDot(_ h: CGFloat) -> some View {
        Circle().fill(CassettePalette.label).frame(width: h * 0.17, height: h * 0.17)
            .overlay(Circle().fill(CassettePalette.ink).frame(width: h * 0.06, height: h * 0.06))
    }
}

/// Trục băng nhỏ quay theo nhạc (cánh notch thu gọn).
struct MiniReel: View {
    let spinning: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.23, green: 0.2, blue: 0.17))
            ReelHub(spinning: spinning).padding(2)
        }
    }
}

// MARK: - Khay → kệ băng

struct CassetteTrayView: View {
    @ObservedObject var tray: TrayStore
    let targeted: Bool
    private var menu = State<TrayMenuTarget?>(initialValue: nil)

    init(tray: TrayStore, targeted: Bool) {
        self.tray = tray
        self.targeted = targeted
    }

    var body: some View {
        HStack(spacing: 14) {
            if !tray.files.isEmpty {
                VStack(spacing: 0) {
                    TrayFilterBar(tray: tray)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(tray.visibleFiles, id: \.self) { url in
                                MiniTapeTile(url: url, tray: tray, selected: tray.selection.contains(url),
                                             remove: { tray.remove(url) }, onMenu: { menu.wrappedValue = .init(url: url, point: $0) })
                                    .modifier(CassetteSlideIn(url: url, tray: tray))
                                    .modifier(TrayRemovalEffect(tray: tray, url: url))
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 6)
                        .animation(.easeOut(duration: 0.2), value: tray.visibleFiles)
                    }
                    .background(Color.black.opacity(0.001).onTapGesture { tray.selection = [] })
                    Rectangle().fill(Color(red: 0.42, green: 0.29, blue: 0.18)).frame(height: 8)
                    Rectangle().fill(Color(red: 0.29, green: 0.2, blue: 0.13)).frame(height: 4)
                }
            }
            Group {
                if tray.files.isEmpty {
                    EmptyCaseZone(targeted: targeted)
                } else {
                    TapeSlot(targeted: targeted, wide: false)
                }
            }
                .frame(width: tray.files.isEmpty ? nil : 170)
                .trayDropMenu(tray: tray) { menu.wrappedValue = .init(url: nil, point: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .onAppear { tray.prune() }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .trayMenu(menu.binding, tray: tray)
    }
}

private struct MiniTapeTile: View {
    let url: URL
    @ObservedObject var tray: TrayStore
    let selected: Bool
    let remove: () -> Void
    let onMenu: (CGPoint) -> Void
    private var hover = State(initialValue: false)

    init(url: URL, tray: TrayStore, selected: Bool, remove: @escaping () -> Void, onMenu: @escaping (CGPoint) -> Void) {
        self.url = url
        self.tray = tray
        self.selected = selected
        self.remove = remove
        self.onMenu = onMenu
    }

    private var type: UTType? { UTType(filenameExtension: url.pathExtension) }
    private var isMovie: Bool { type?.conforms(to: .movie) == true }
    /// Nhạc, video: băng cassette.
    private var isMedia: Bool { type.map { $0.conforms(to: .audio) || $0.conforms(to: .movie) } ?? false }

    var body: some View {
        Group {
            if FileThumbnails.isVisual(url) && !isMovie {
                Polaroid(url: url)
            } else if isMedia {
                MiniTape(band: fileTint(url), name: url.lastPathComponent.precomposedStringWithCanonicalMapping)
            } else {
                // Tài liệu, mã nguồn, file nén…: đĩa mềm dán nhãn viết tay.
                FloppyDisk(url: url)
            }
        }
            .frame(width: 112, height: 76)
            .background(TraySelectionMark(selected: selected).padding(-3))
            .overlay(TrayItemInteraction(url: url, tray: tray))
            .overlay(alignment: .topTrailing) {
                if hover.wrappedValue {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(CassettePalette.label, CassettePalette.ink)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                }
            }
            .scaleEffect(hover.wrappedValue ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: hover.wrappedValue)
            .contentShape(Rectangle())
            .onHover { hover.wrappedValue = $0 }
            .fileMenu(url: url, remove: remove, quickLook: { TrayQuickLook.shared.show(tray.targets(for: url)) },
                      onThemed: onMenu)
    }
}

/// File ảnh / video trên kệ: tấm Polaroid dán băng keo, chú thích viết tay, nghiêng nhẹ.
private struct Polaroid: View {
    let url: URL

    var body: some View {
        let name = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        // Góc nghiêng cố định theo tên file để mỗi tấm một kiểu nhưng không nhảy khi vẽ lại.
        let tilt = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 97 } % 7) - 3
        VStack(spacing: 2) {
            ThumbnailImage(url: url, size: CGSize(width: 84, height: 50)) {
                CassettePalette.window.overlay(Image(systemName: "photo").foregroundStyle(CassettePalette.faded))
            }
            .frame(width: 84, height: 50)
            .clipped()
            Text(name)
                .font(.hand(10))
                .foregroundStyle(CassettePalette.ink)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 84)
        }
        .padding(.horizontal, 5).padding(.top, 5).padding(.bottom, 3)
        .background(Color(red: 0.97, green: 0.95, blue: 0.9))
        .shadow(color: .black.opacity(0.45), radius: 3, x: 1, y: 3)
        .overlay(alignment: .top) {
            Rectangle().fill(CassettePalette.note.opacity(0.7))
                .frame(width: 34, height: 10)
                .rotationEffect(.degrees(-tilt * 1.5))
                .offset(y: -5)
        }
        .rotationEffect(.degrees(tilt))
    }
}

private struct TapeSlot: View {
    let targeted: Bool
    let wide: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(red: 0.14, green: 0.12, blue: 0.11))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(targeted ? CassettePalette.band : CassettePalette.shellEdge, lineWidth: 2))
            .overlay(
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.black).frame(height: 8).padding(.horizontal, 18)
                    Image(systemName: "arrow.down").font(.system(size: 18, weight: .bold))
                    Text(wide ? L("Nhét băng vào đây · kéo file lên notch", "Slot a tape in · drag files onto the notch")
                              : L("Nhét băng\nvào đây", "Slot a\ntape in"))
                        .font(.hand(15))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(CassettePalette.key.opacity(targeted ? 1 : 0.85))
                .padding(.top, 10)
            )
            .scaleEffect(targeted ? 1.03 : 1)
    }
}

/// Phím cơ có chữ (Lật / Đèn).
struct KeyButton: View {
    let title: String
    let pressed: Bool
    let lit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hand(14))
                .foregroundStyle(CassettePalette.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: pressed ? 31 : 35)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(lit ? Color(red: 1.0, green: 0.86, blue: 0.55) : (pressed ? CassettePalette.keyDown : CassettePalette.key))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.48, green: 0.42, blue: 0.32)))
                )
                .offset(y: pressed ? 2 : 0)
                .frame(height: 37, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Claude xin quyền → phiếu telex + con dấu

struct CassettePermissionCard: View {
    let request: PermissionRequest
    let pending: Int
    let decide: (PermissionDecision) -> Void
    /// Số dòng đã in ra (in một lần, từng dòng).
    private var printed = State(initialValue: 0)
    /// Dấu vừa đóng khi bấm (chữ, màu): hiện ngay, quyết định gửi đi sau ~0,3 s.
    private var stamped = State<(text: String, color: Color)?>(initialValue: nil)

    init(request: PermissionRequest, pending: Int, decide: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.pending = pending
        self.decide = decide
    }

    private var waiting: Bool { request.state.isWaiting }

    private var slipTitle: String {
        switch request.kind {
        case .plan: return L("TELEX · DUYỆT KẾ HOẠCH", "TELEX · PLAN APPROVAL")
        case .question: return L("TELEX · CÂU HỎI", "TELEX · QUESTION")
        case .tool: return L("TELEX · XIN QUYỀN", "TELEX · PERMISSION")
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TelexPaper()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(slipTitle)
                        .font(.typewriter(13, bold: true))
                        .fixedSize()
                    OriginRow(request: request, paper: true, size: 11)
                    Spacer(minLength: 4)
                    CountdownBadge(request: request, paper: true)
                }
                .lineLimit(1)
                .modifier(PrintLine(shown: printed.wrappedValue > 0))
                field(request.kind == .plan ? L("Kế hoạch", "Plan") : request.tool, request.summary)
                    .help(request.detail ?? request.summary)
                    .modifier(PrintLine(shown: printed.wrappedValue > 1))
                Group {
                    if let scope = request.allowScope, waiting {
                        field(L("Luôn duyệt", "Always"), scope.what + ", " + scope.whereText)
                            .help(request.alwaysHelp)
                    } else if let detail = request.detail, !detail.isEmpty {
                        field(request.kind == .plan ? L("Tiếp theo", "Then") : L("Mục đích", "Purpose"), detail)
                    }
                }
                .modifier(PrintLine(shown: printed.wrappedValue > 2))
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    if request.host != nil {
                        Button { PermissionCenter.active?.openHost(request) } label: {
                            Text(L("mở \(request.host?.name ?? "")", "open \(request.host?.name ?? "")"))
                                .font(.typewriter(12))
                                .underline()
                                .foregroundStyle(CassettePalette.faded)
                        }
                        .buttonStyle(.plain)
                        .help(L("Đưa app đang chạy phiên này lên trước", "Bring the app running this session to the front"))
                    }
                    Spacer()
                    if waiting && stamped.wrappedValue == nil {
                        StampButton(text: request.kind == .plan ? L("CHƯA", "NOT YET") : L("TỪ CHỐI", "DENY"),
                                    color: Color(red: 0.48, green: 0.48, blue: 0.48), tilt: -6) {
                            stamp(request.kind == .plan ? L("CHƯA", "NOT YET") : L("TỪ CHỐI", "DENIED"),
                                  Color(red: 0.36, green: 0.36, blue: 0.36), .deny)
                        }
                        if request.canAlwaysAllow {
                            StampButton(text: L("LUÔN DUYỆT", "ALWAYS"), color: Color(red: 0.18, green: 0.44, blue: 0.82), tilt: 4) {
                                stamp(L("LUÔN DUYỆT", "ALWAYS OK"), Color(red: 0.18, green: 0.44, blue: 0.82), .allowAlways)
                            }
                            .help(request.alwaysHelp)
                        }
                        StampButton(text: L("DUYỆT", "APPROVE"), color: CassettePalette.marker, tilt: -7) {
                            stamp(L("DUYỆT", "APPROVED"), CassettePalette.marker, .allow)
                        }
                    }
                }
                .modifier(PrintLine(shown: printed.wrappedValue > 3))
            }
            .foregroundStyle(CassettePalette.ink)
            .padding(.leading, 32)
            .padding(.trailing, 32)
            .padding(.vertical, 9)
            // Giấy được kéo lên theo từng dòng in.
            .offset(y: CGFloat(max(0, 4 - printed.wrappedValue)) * 3)
        }
        .overlay {
            if let s = stamped.wrappedValue {
                RubberStamp(text: s.text, color: s.color)
            } else if !waiting {
                ResultStamp(state: request.state).transition(.scale(scale: 1.4).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: waiting)
        .rotationEffect(.degrees(-0.6))
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onAppear(perform: startPrinting)
    }

    private func startPrinting() {
        guard printed.wrappedValue == 0 else { return }
        if SystemMonitor.shared.lowPower || !waiting { printed.wrappedValue = 4; return }
        for k in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(k)) {
                withAnimation(.easeOut(duration: 0.08)) { printed.wrappedValue = max(printed.wrappedValue, k) }
            }
        }
    }

    /// Đóng dấu ngay, gửi quyết định sau 0,3 s (dấu kịp hiện, hook không phải chờ lâu).
    private func stamp(_ text: String, _ color: Color, _ decision: PermissionDecision) {
        guard stamped.wrappedValue == nil else { return }
        stamped.wrappedValue = (text, color)
        printed.wrappedValue = 4
        Haptics.tap(.levelChange)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { decide(decision) }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":").font(.typewriter(12)).lineLimit(1).frame(width: 82, alignment: .leading)
            Text(value).font(.typewriter(13)).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Dòng telex: chưa in thì ẩn, in ra thì hiện từ trái sang (che bằng mặt nạ).
private struct PrintLine: ViewModifier {
    let shown: Bool
    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                // Nới mặt nạ ra ngoài: con dấu nghiêng tràn khỏi khung dòng, không được cắt.
                Rectangle().frame(maxWidth: shown ? .infinity : 0)
                    .padding(.vertical, -14)
                    .padding(.horizontal, shown ? -14 : 0)
            }
            .opacity(shown ? 1 : 0)
    }
}

/// Con dấu kết quả đóng lên phiếu sau khi xử lý.
private struct ResultStamp: View {
    let state: RequestState

    private var text: String {
        switch state {
        case .allowed, .answered: return L("ĐÃ DUYỆT", "APPROVED")
        case .allowedAlways: return L("LUÔN DUYỆT", "ALWAYS OK")
        case .denied: return L("ĐÃ BÁC", "DENIED")
        case .expired: return L("QUÁ HẠN", "EXPIRED")
        case .answeredElsewhere: return L("ĐÃ XỬ LÝ NƠI KHÁC", "HANDLED ELSEWHERE")
        case .cancelled: return L("HUỶ", "VOID")
        case .handedOff: return L("CHUYỂN VỀ APP", "SENT BACK")
        case .waiting: return ""
        }
    }

    private var color: Color {
        switch state {
        case .allowed, .allowedAlways, .answered: return CassettePalette.marker
        case .denied: return Color(red: 0.36, green: 0.36, blue: 0.36)
        default: return Color(red: 0.18, green: 0.44, blue: 0.82)
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(text).font(.typewriter(22, bold: true)).tracking(3)
            Text(state.title).font(.typewriter(10))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 3))
        .rotationEffect(.degrees(-9))
        .opacity(0.88)
    }
}

private struct StampButton: View {
    let text: String
    let color: Color
    let tilt: Double
    let action: () -> Void
    private var hover = State(initialValue: false)

    init(text: String, color: Color, tilt: Double, action: @escaping () -> Void) {
        self.text = text
        self.color = color
        self.tilt = tilt
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.typewriter(15, bold: true))
                .tracking(2)
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color, lineWidth: 2.5))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).padding(4))
                .rotationEffect(.degrees(tilt))
                .scaleEffect(hover.wrappedValue ? 1.08 : 1)
                .opacity(hover.wrappedValue ? 1 : 0.85)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.wrappedValue)
    }
}

// MARK: - Claude hỏi → bảng ghim

struct Corkboard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(red: 0.72, green: 0.54, blue: 0.35))
            .overlay(
                Canvas { ctx, size in
                    var x: CGFloat = 6
                    while x < size.width {
                        var y: CGFloat = 6
                        while y < size.height {
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.4, height: 2.4)),
                                     with: .color(Color(red: 0.54, green: 0.39, blue: 0.25).opacity(0.7)))
                            y += 14
                        }
                        x += 16
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
