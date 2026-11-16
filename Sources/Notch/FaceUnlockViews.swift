import AppKit
import FaceUnlockKit
import SwiftUI

// MARK: - Biểu tượng Face ID

enum FaceGlyphState: Equatable { case idle, scanning, success, failure }

/// Khung mặt kiểu Face ID; quét = vòng xoay, xong = dấu ✓ tự vẽ, lỗi = đỏ. Pixel: lưới ô vuông.
struct FaceIDGlyph: View {
    let state: FaceGlyphState
    private var spin = State(initialValue: false)
    private var drawn = State(initialValue: false)

    init(state: FaceGlyphState) { self.state = state }

    private static let pixelFace = ["11.11", "1...1", ".1.1.", "..1..", "1.1.1", "11111"]
    private static let pixelCheck = ["....1", "...11", "1.11.", "111..", ".1..."]

    var body: some View {
        let color = Self.color(state)
        ZStack {
            if Theme.isPixel {
                PixelShape(rows: state == .success ? Self.pixelCheck : Self.pixelFace).fill(color)
                    .padding(2)
                    .opacity(state == .scanning && !spin.wrappedValue ? 0.45 : 1)
                    .animation(state == .scanning ? .easeInOut(duration: 0.4).repeatForever() : .default, value: spin.wrappedValue)
            } else if state == .success {
                CheckShape()
                    .trim(from: 0, to: drawn.wrappedValue ? 1 : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .padding(3)
                    .onAppear { withAnimation(.easeOut(duration: 0.35)) { drawn.wrappedValue = true } }
                    .onDisappear { drawn.wrappedValue = false }
            } else {
                FaceGlyphShape()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            if state == .scanning, !Theme.isPixel {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .padding(-4)
                    .rotationEffect(.degrees(spin.wrappedValue ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin.wrappedValue)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { if state == .scanning { spin.wrappedValue = true } }
        .onChange(of: state) { _, s in spin.wrappedValue = s == .scanning }
    }

    static func color(_ state: FaceGlyphState) -> Color {
        switch state {
        case .success: return Color(red: 0.30, green: 0.85, blue: 0.40)
        case .failure: return Color(red: 1.0, green: 0.36, blue: 0.33)
        case .idle, .scanning:
            if Theme.isCassette { return CassettePalette.key }
            if Theme.isPixel { return PixelPalette.border }
            return .white
        }
    }
}

/// 4 góc khung + 2 mắt + mũi + miệng.
struct FaceGlyphShape: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height), x = r.midX - s / 2, y = r.midY - s / 2
        let c = s * 0.28
        var p = Path()
        func corner(_ a: CGPoint, _ b: CGPoint, _ ctrl: CGPoint) {
            p.move(to: a); p.addQuadCurve(to: b, control: ctrl)
        }
        corner(CGPoint(x: x, y: y + c), CGPoint(x: x + c, y: y), CGPoint(x: x, y: y))
        corner(CGPoint(x: x + s - c, y: y), CGPoint(x: x + s, y: y + c), CGPoint(x: x + s, y: y))
        corner(CGPoint(x: x + s, y: y + s - c), CGPoint(x: x + s - c, y: y + s), CGPoint(x: x + s, y: y + s))
        corner(CGPoint(x: x + c, y: y + s), CGPoint(x: x, y: y + s - c), CGPoint(x: x, y: y + s))
        p.move(to: CGPoint(x: x + s * 0.34, y: y + s * 0.34)); p.addLine(to: CGPoint(x: x + s * 0.34, y: y + s * 0.44))
        p.move(to: CGPoint(x: x + s * 0.66, y: y + s * 0.34)); p.addLine(to: CGPoint(x: x + s * 0.66, y: y + s * 0.44))
        p.move(to: CGPoint(x: x + s * 0.5, y: y + s * 0.36))
        p.addLine(to: CGPoint(x: x + s * 0.5, y: y + s * 0.55)); p.addLine(to: CGPoint(x: x + s * 0.45, y: y + s * 0.55))
        p.move(to: CGPoint(x: x + s * 0.34, y: y + s * 0.68))
        p.addQuadCurve(to: CGPoint(x: x + s * 0.66, y: y + s * 0.68), control: CGPoint(x: x + s * 0.5, y: y + s * 0.8))
        return p
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.55))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.4, y: r.minY + r.height * 0.82))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.9, y: r.minY + r.height * 0.2))
        return p
    }
}

/// Lắc ngang khi quét thất bại.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(animatableData * .pi * 6), y: 0))
    }
}

// MARK: - Lời chào trên notch sau khi mở khoá (Lớp 1)

/// Cánh trái: quét → ✓; cánh phải: "Chào <tên>". Chạy một lần rồi notch tự thu (peek 3.2s).
struct UnlockWings: View {
    let name: String
    let wing: CGFloat
    private var done = State(initialValue: false)

    init(name: String, wing: CGFloat) {
        self.name = name
        self.wing = wing
    }

    var body: some View {
        let cassette = Theme.isCassette
        HStack(spacing: 0) {
            FaceIDGlyph(state: done.wrappedValue ? .success : .scanning)
                .frame(width: 16, height: 16)
                .frame(width: wing)
            Spacer(minLength: 0)
            Text(L("Chào \(name)", "Hi \(name)"))
                .font(cassette ? .hand(14) : .ui(12, weight: .semibold))
                .foregroundStyle(cassette ? CassettePalette.ink : .white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, cassette ? 6 : 0)
                .padding(.vertical, cassette ? 1 : 0)
                .background(cassette ? CassettePalette.note : Color.clear)
                .rotationEffect(.degrees(cassette ? -2 : 0))
                .frame(width: wing)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { done.wrappedValue = true }
        }
    }
}

// MARK: - Notch trên màn hình khoá

struct LockOverlayView: View {
    @ObservedObject var controller: FaceUnlockController
    @ObservedObject var geometry: NotchModel
    private var shakes = State(initialValue: CGFloat(0))

    init(controller: FaceUnlockController, geometry: NotchModel) {
        self.controller = controller
        self.geometry = geometry
    }

    private var phase: FaceUnlockPhase { controller.service?.phase ?? .idle }
    private var enabled: Bool { controller.isEnabled }

    private var glyphState: FaceGlyphState {
        switch phase {
        case .scanning: return .scanning
        case .matched, .unlocked: return .success
        case .failed: return enabled ? .failure : .idle
        case .idle: return .idle
        }
    }

    private var message: String? {
        guard enabled else { return nil }
        if controller.suspended { return L("Đã tạm dừng, hãy mở khoá bằng mật khẩu", "Paused, unlock with your password") }
        if case .failed(let f) = phase { return FaceUnlockController.shortReason(f) }
        // Đã nhận ra mặt, chỉ còn chờ dấu hiệu người thật: chớp mắt là qua ngay.
        if case .scanning = phase, controller.service?.awaitingLiveness == true {
            return L("Chớp mắt nhẹ để xác nhận", "Blink to confirm")
        }
        return nil
    }

    var body: some View {
        let notch = geometry.notchSize
        let wing = notch.height * 1.3
        let extra: CGFloat = message == nil ? 0 : 22
        let shape = NotchShape(topRadius: 6, bottomRadius: geometry.pill ? 99 : (extra > 0 ? 14 : 10),
                               pixel: Theme.isPixel && geometry.pill, pill: geometry.pill)
        let fill = Theme.isCassette ? CassettePalette.background : Color.black
        let cassette = Theme.isCassette
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(fill)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Image(systemName: controller.suspended ? "lock.slash.fill" : "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(cassette ? CassettePalette.key : .white.opacity(0.8))
                            .frame(width: wing)
                        Spacer(minLength: 0)
                        FaceIDGlyph(state: glyphState)
                            .frame(width: notch.height * 0.55, height: notch.height * 0.55)
                            .frame(width: wing)
                    }
                    .frame(height: notch.height)
                    if let message {
                        Text(message)
                            .font(cassette ? .hand(13) : .ui(11, weight: .semibold))
                            .foregroundStyle(cassette ? CassettePalette.key : .white.opacity(0.85))
                            .lineLimit(1)
                            .frame(height: extra - 4)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(width: notch.width + 12 + wing * 2, height: notch.height + extra)
            .modifier(ShakeEffect(animatableData: shakes.wrappedValue))
            .offset(y: geometry.topGap)
            .contentShape(Rectangle())
            // Rê chuột thật lên notch (chỉ có ở đây, không qua IPC) → quét khi tính năng đang bật.
            .onHover { if $0 { controller.hoverScan() } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: message)
        .onChange(of: phase) { _, p in
            if case .failed = p, enabled {
                withAnimation(.easeOut(duration: 0.45)) { shakes.wrappedValue += 1 }
            }
        }
        .textCase(Theme.isPixel ? .uppercase : nil)
    }
}

// MARK: - Cài đặt

struct FaceUnlockPane: View {
    @ObservedObject var controller = FaceUnlockController.shared
    @ObservedObject var settings = SettingsStore.shared
    private var password = State(initialValue: "")
    private var error = State<String?>(initialValue: nil)
    private var busy = State(initialValue: false)
    private var refresh = State(initialValue: 0)
    private var confirmReset = State(initialValue: false)

    init() {}

    private static let idleOptions: [TimeInterval] = [3600, 8 * 3600, 24 * 3600, 7 * 24 * 3600]

    var body: some View {
        Group {
            if let service = controller.service {
                form(service)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Tạo service khi mở pane (tải model), không tạo trong lúc dựng view.
        .onAppear { DispatchQueue.main.async { controller.ensureService() } }
    }

    private func form(_ service: FaceUnlockService) -> some View {
        _ = refresh.wrappedValue
        return SPage {
            SSection(L("Hiệu ứng", "Effect"),
                     note: L("Chỉ là hiệu ứng, không cần bật tính năng bên dưới. Khi bạn mở khoá bằng bất kỳ cách nào (Touch ID, Apple Watch, mật khẩu), notch chạy hiệu ứng quét, hiện dấu ✓ rồi chào bạn.",
                             "Just an effect; you don't need the feature below. When you unlock in any way (Touch ID, Apple Watch, password), the notch plays a scan, shows a ✓ and greets you.")) {
                SToggleRow(icon: "faceid", title: L("Hiệu ứng Face ID khi mở khoá", "Face ID effect on unlock"),
                           divider: false, isOn: $settings.unlockEffect)
            }

            SSection(L("Mở khoá bằng khuôn mặt (Thử nghiệm)", "Face unlock (Experimental)")) {
                SBlock(divider: false) {
                    Label {
                        Text(L("Đây là tiện ích, không phải lớp bảo mật. Camera MacBook chỉ thấy ảnh 2D: bước kiểm tra người thật chặn được ảnh in và ảnh trên điện thoại, nhưng một video quay mặt bạn vẫn có thể qua được. Tính năng chỉ chạy khi bạn đã đăng nhập, không dùng được sau khi khởi động lại máy. App gõ mật khẩu đăng nhập đã lưu vào màn hình khoá nên cần quyền Trợ năng.", "This is a convenience, not a security layer. A MacBook camera only sees a flat image: the liveness check stops printed photos and photos on a phone, but a video of your face may still get through. It only works after you've logged in, not after a restart. Roost types your saved login password on the lock screen, so it needs Accessibility access."))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            SSection(L("Thiết lập", "Setup")) {
                let camera = FaceUnlockService.cameraPermission == .granted
                step("camera", L("Quyền camera", "Camera access"), ok: camera, divider: false) {
                    if FaceUnlockService.cameraPermission == .notDetermined {
                        Button(L("Cấp quyền", "Allow")) {
                            Task { _ = await FaceUnlockService.requestCameraAccess(); refresh.wrappedValue += 1 }
                        }
                    } else if !camera {
                        // Đã từ chối: macOS không hỏi lại, phải bật trong Cài đặt hệ thống.
                        Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { openPrivacyPane("Privacy_Camera") }
                    }
                }
                let ax = FaceUnlockService.isAccessibilityTrusted
                step("accessibility", L("Quyền Trợ năng (để gõ mật khẩu)", "Accessibility (to type the password)"), ok: ax) {
                    if !ax {
                        Button(L("Mở Cài đặt hệ thống", "Open System Settings")) {
                            // Hộp thoại hệ thống chỉ hiện lần đầu: mở thẳng mục Trợ năng cho các lần sau.
                            FaceUnlockService.promptForAccessibility()
                            openPrivacyPane("Privacy_Accessibility")
                        }
                    }
                }
                step("touchid", L("Phiên Touch ID", "Touch ID session"), ok: service.isSessionUnlocked,
                     detail: L("Mở lại mỗi lần chạy app, tự khoá khi hết thời gian chờ", "Open it once per app launch; it locks itself after the idle limit")) {
                    if service.isSessionUnlocked {
                        Button(L("Khoá lại", "Lock")) { service.lockSession() }
                    } else {
                        Button(L("Mở phiên…", "Unlock…")) {
                            run { try await service.unlockSession(reason: L("Mở khoá dữ liệu khuôn mặt của Roost", "Unlock Roost's face data")) }
                        }
                    }
                }
                step("key", L("Mật khẩu đăng nhập", "Login password"), ok: service.hasStoredPassword,
                     detail: L("Mã hoá bằng một khoá chỉ mở sau Touch ID. Roost không biết mật khẩu đúng hay sai, hãy nhập cẩn thận.",
                               "Encrypted with a key that only opens after Touch ID. Roost can't tell whether it is correct, so type it carefully.")) {
                    if service.hasStoredPassword {
                        Button(L("Xoá", "Delete")) { run { try service.deleteStoredPassword() } }
                    }
                }
                SBlock(padding: 12) {
                    HStack {
                        SecureField(L("Mật khẩu đăng nhập Mac", "Mac login password"), text: password.projectedValue)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button(service.hasStoredPassword ? L("Thay (Touch ID)", "Replace (Touch ID)") : L("Lưu (Touch ID)", "Save (Touch ID)")) {
                            let pw = password.wrappedValue
                            password.wrappedValue = ""
                            run { try await service.storePassword(pw, reason: L("Lưu mật khẩu cho mở khoá bằng khuôn mặt", "Store your password for face unlock")) }
                        }
                        .buttonStyle(SButtonStyle(.primary))
                        .disabled(password.wrappedValue.isEmpty)
                    }
                    .padding(.leading, 40)
                }
                step("person.crop.circle", L("Khuôn mặt", "Face"), ok: !service.identities.isEmpty || service.hasEnrollmentData,
                     detail: service.identities.first.map { "\($0.name), \($0.sampleCount) " + L("mẫu", "samples") + ($0.isStale ? L(", cần quét lại", ", needs a rescan") : "") }) {
                    HStack {
                        Button(service.identities.isEmpty ? L("Quét mặt…", "Enroll…") : L("Quét lại…", "Re-enroll…")) {
                            EnrollmentWindowController.shared.show(replacing: service.identities.first?.id)
                        }
                        .buttonStyle(SButtonStyle(.primary))
                        .disabled(service.modelState != .ready || FaceUnlockService.cameraPermission != .granted)
                        if let first = service.identities.first {
                            Button(L("Xoá", "Delete")) { run { try service.deleteIdentity(id: first.id) } }
                        }
                    }
                }
                if case .failed(let why) = service.modelState {
                    SBlock { Text(L("Không tải được model: ", "Model failed to load: ") + why).font(.caption).foregroundStyle(.red) }
                } else if service.modelState == .loading {
                    SBlock { Text(L("Đang tải model…", "Loading the model…")).font(.caption).foregroundStyle(.secondary) }
                }
                if let e = error.wrappedValue {
                    SBlock { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }

            SSection(L("Tuỳ chọn", "Options"),
                     note: L("Roost quét mặt khi máy khoá hoặc thức dậy, và khi bạn rê chuột lên notch trên màn hình khoá. Sai \(FaceUnlockController.maxFailures) lần liên tiếp thì app ngừng quét, cho tới khi bạn mở khoá bằng cách khác. Chỉ dùng camera thật (tích hợp hoặc USB).",
                             "Roost scans when the Mac locks or wakes, and when you hover the notch on the lock screen. After \(FaceUnlockController.maxFailures) failed tries in a row it stops until you unlock another way. Only real cameras (built-in or USB) are used.")) {
                SRow("lock.open", L("Bật mở khoá bằng khuôn mặt", "Enable face unlock"),
                     detail: service.settings.isEnabled ? service.notReadyReason.map { L("Chưa chạy được: ", "Can't run yet: ") + $0 } : nil,
                     divider: false) {
                    Toggle("", isOn: Binding(get: { service.settings.isEnabled }, set: { service.settings.isEnabled = $0 }))
                        .toggleStyle(.switch).controlSize(.small).tint(SUI.accent)
                }
                SRow("eye", L("Kiểm tra mặt thật", "Liveness check")) {
                    SPicker(Binding(get: { service.settings.livenessMode }, set: { service.settings.livenessMode = $0 }),
                            [(FaceUnlockLivenessMode.heavy, L("Nặng (khuyên dùng)", "Heavy (recommended)")),
                             (.light, L("Nhẹ", "Light")),
                             (.off, L("Tắt (ảnh chụp cũng qua)", "Off (a photo can pass)"))])
                }
                SRow("timer", L("Phiên Touch ID tự khoá sau", "Touch ID session re-locks after")) {
                    SPicker(Binding(get: { service.settings.sessionIdleLimit ?? FaceUnlockController.defaultIdleLimit },
                                    set: { service.settings.sessionIdleLimit = $0 }),
                            Array(Self.idleOptions), title: { Self.idleTitle($0) })
                }
                let cameras = FaceUnlockService.availableCameras()
                if cameras.count > 1 {
                    SRow("web.camera", L("Camera", "Camera")) {
                        SPicker(Binding(get: { service.settings.cameraDeviceID ?? "" },
                                        set: { service.settings.cameraDeviceID = $0.isEmpty ? nil : $0 }),
                                [("", L("Mặc định (camera tích hợp)", "Default (built-in)"))] + cameras.map { ($0.id, $0.name) })
                    }
                }
            }

            SSection(L("Nhật ký mở khoá", "Unlock log")) {
                if controller.log.isEmpty {
                    SRow("list.bullet.rectangle", L("Chưa có lần mở khoá nào", "No unlock attempts yet"), divider: false) { EmptyView() }
                } else {
                    SBlock(divider: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(controller.log.prefix(12)) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(entry.success ? .green : .red)
                                    Text(Self.time(entry.date)).monospacedDigit().foregroundStyle(.secondary)
                                    Text(entry.reason).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    SRow("trash", L("Xoá nhật ký", "Clear log")) {
                        Button(L("Xoá", "Clear")) { controller.clearLog() }.controlSize(.small)
                    }
                }
            }

            SSection(nil) {
                SRow("exclamationmark.octagon", L("Xoá hết dữ liệu", "Delete all data"),
                     detail: L("Khuôn mặt, mật khẩu và khoá phiên.", "Face, password and session key."), divider: false) {
                    Button(L("Xoá hết…", "Delete all…"), role: .destructive) { confirmReset.wrappedValue = true }
                        .controlSize(.small)
                        .confirmationDialog(L("Xoá hết dữ liệu mở khoá bằng khuôn mặt?", "Delete all face-unlock data?"),
                                            isPresented: confirmReset.projectedValue) {
                            Button(L("Xoá hết", "Delete all"), role: .destructive) { run { try service.resetAll() } }
                        }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh.wrappedValue += 1
        }
    }

    @ViewBuilder
    private func step<Accessory: View>(_ icon: String, _ title: String, ok: Bool, detail: String? = nil, divider: Bool = true,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        SRow(icon, title, detail: detail, divider: divider) {
            HStack(spacing: 8) {
                accessory().controlSize(.small)
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ok ? .green : .secondary)
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        error.wrappedValue = nil
        busy.wrappedValue = true
        Task { @MainActor in
            do { try await work() } catch { self.error.wrappedValue = error.localizedDescription }
            busy.wrappedValue = false
            refresh.wrappedValue += 1
        }
    }

    private static func idleTitle(_ t: TimeInterval) -> String {
        switch t {
        case 3600: return L("1 giờ", "1 hour")
        case 8 * 3600: return L("8 giờ", "8 hours")
        case 24 * 3600: return L("1 ngày", "1 day")
        default: return L("7 ngày", "7 days")
        }
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - Cửa sổ quét mặt (đăng ký)

@MainActor
final class EnrollmentWindowController: NSObject, NSWindowDelegate {
    static let shared = EnrollmentWindowController()
    private var window: NSWindow?

    func show(replacing id: UUID?) {
        let service = FaceUnlockController.shared.ensureService()
        window?.close()
        let host = NSHostingController(rootView: EnrollmentView(service: service, replacing: id) { [weak self] in
            self?.window?.close()
        })
        let win = NSWindow(contentViewController: host)
        win.title = L("Quét khuôn mặt", "Enroll your face")
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.delegate = self
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        FaceUnlockController.shared.service?.cancelEnrollment()
        // Huỷ view để camera và layout dừng hẳn.
        window?.contentViewController = nil
        window = nil
    }
}

/// Cửa sổ quét mặt, cùng kiểu thẻ với Cài đặt › Khuôn mặt.
struct EnrollmentView: View {
    @ObservedObject var service: FaceUnlockService
    let replacing: UUID?
    let close: () -> Void
    private var name = State(initialValue: FaceUnlockController.greetingName)
    private var error = State<String?>(initialValue: nil)

    init(service: FaceUnlockService, replacing: UUID?, close: @escaping () -> Void) {
        self.service = service
        self.replacing = replacing
        self.close = close
    }

    var body: some View {
        let progress = service.enrollment
        let done = progress?.isComplete == true
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SIconTile(symbol: "faceid", color: SettingsWindowController.PaneID.face.tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(replacing == nil ? L("Quét khuôn mặt", "Enroll your face") : L("Quét lại khuôn mặt", "Re-enroll your face"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(L("Xoay đầu chậm theo hướng được tô sáng. Roost chỉ giữ số đo khuôn mặt, không lưu ảnh.",
                           "Turn your head slowly toward the highlighted direction. Roost keeps face measurements only, never photos."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SSection(nil) {
                SBlock(divider: false, padding: 18) {
                    VStack(spacing: 14) {
                        ZStack {
                            CameraPreview(session: service.previewSession, cornerRadius: 96, mirrored: true)
                                .frame(width: 192, height: 192)
                                .clipShape(Circle())
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                                .overlay {
                                    if done {
                                        Circle().fill(.black.opacity(0.35))
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 54)).foregroundStyle(.white, SUI.accent)
                                    }
                                }
                            PoseRing(progress: progress)
                                .frame(width: 228, height: 228)
                        }
                        .frame(width: 250, height: 262, alignment: .top)

                        Text(Self.instruction(progress))
                            .font(.system(size: 14, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 20)
                        EnrollmentBar(value: progress?.overallProgress ?? 0)
                            .frame(width: 260)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            SSection(L("Thông tin", "Details"),
                     note: Self.livenessNote(service.settings.livenessMode)) {
                SRow("square.grid.3x3", L("Mẫu khuôn mặt", "Face samples"),
                     detail: L("\(EnrollmentPose.allCases.count) hướng, mỗi hướng \(Self.perPose(progress)) mẫu", "\(EnrollmentPose.allCases.count) directions, \(Self.perPose(progress)) samples each"),
                     divider: false) {
                    Text("\(Self.captured(progress))/\(Self.total(progress))")
                        .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(done ? SUI.accent : .secondary)
                }
                SRow("eye", L("Kiểm tra mặt thật", "Liveness check")) {
                    SPicker(Binding(get: { service.settings.livenessMode }, set: { service.settings.livenessMode = $0 }),
                            [(FaceUnlockLivenessMode.heavy, L("Nặng (khuyên dùng)", "Heavy (recommended)")),
                             (.light, L("Nhẹ", "Light")),
                             (.off, L("Tắt (ảnh chụp cũng qua)", "Off (a photo can pass)"))])
                }
                if done {
                    SRow("person.crop.circle", L("Tên để chào", "Name for the greeting"),
                         detail: L("Notch chào bạn bằng tên này sau khi mở khoá.", "The notch greets you with this name after unlocking.")) {
                        TextField(L("Tên", "Name"), text: name.projectedValue)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                }
                if let e = error.wrappedValue ?? progress?.error {
                    SBlock {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L("Huỷ", "Cancel")) { close() }
                    .buttonStyle(SButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                if progress == nil || progress?.error != nil {
                    Button(L("Bắt đầu lại", "Start again")) { begin() }
                        .buttonStyle(SButtonStyle(.secondary))
                }
                if done {
                    Button { save() } label: { Label(L("Lưu bằng Touch ID", "Save with Touch ID"), systemImage: "touchid") }
                        .buttonStyle(SButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 22)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: done)
        .onAppear { begin() }
    }

    private func begin() {
        error.wrappedValue = nil
        do { try service.startEnrollment(replacing: replacing) } catch { self.error.wrappedValue = error.localizedDescription }
    }

    private func save() {
        let n = name.wrappedValue.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            do {
                _ = try await service.finishEnrollment(name: n.isEmpty ? FaceUnlockController.greetingName : n,
                                                       reason: L("Lưu khuôn mặt của bạn", "Save your face"))
                close()
            } catch {
                self.error.wrappedValue = error.localizedDescription
            }
        }
    }

    private static func perPose(_ p: EnrollmentProgress?) -> Int { p?.samplesPerPose ?? 2 }
    private static func total(_ p: EnrollmentProgress?) -> Int { perPose(p) * EnrollmentPose.allCases.count }
    private static func captured(_ p: EnrollmentProgress?) -> Int {
        guard let p else { return 0 }
        if p.isComplete { return total(p) }
        return EnrollmentPose.allCases.reduce(0) { $0 + Int(((p.poseProgress[$1] ?? 0) * Double(p.samplesPerPose)).rounded(.down)) }
    }

    private static func livenessNote(_ mode: FaceUnlockLivenessMode) -> String {
        guard mode != .off else { return livenessDetail(mode) }
        return livenessDetail(mode) + " " + L("Khi mở khoá, nếu notch hiện \"Chớp mắt nhẹ để xác nhận\" thì chớp mắt một lần là qua.",
                                              "When unlocking, if the notch says \"Blink to confirm\", one blink is enough.")
    }

    private static func livenessDetail(_ mode: FaceUnlockLivenessMode) -> String {
        switch mode {
        case .heavy: return L("Mức Nặng cần thêm một dấu hiệu người thật: chiều sâu khuôn mặt, chuyển động khi quay đầu hoặc chớp mắt.",
                              "Heavy needs one more sign of a live person: face depth, movement as you turn, or a blink.")
        case .light: return L("Mức Nhẹ chỉ chặn ảnh trên màn hình và ảnh in rõ ràng.", "Light only blocks obvious screens and printed photos.")
        case .off: return L("Đang tắt kiểm tra mặt thật: ảnh chụp khuôn mặt bạn cũng mở được máy.", "The liveness check is off, so a photo of your face can unlock the Mac.")
        }
    }

    private static func instruction(_ p: EnrollmentProgress?) -> String {
        guard let p else { return L("Đang bật camera…", "Starting the camera…") }
        if p.isComplete { return L("Xong! Đặt tên rồi lưu.", "Done! Name it and save.") }
        if !p.faceDetected { return L("Đưa mặt vào giữa khung", "Center your face in the frame") }
        if p.isTooFar { return L("Ngồi gần camera hơn", "Move closer to the camera") }
        if p.excessiveTurn != nil { return L("Bạn quay hơi quá, xoay lại một chút", "Too far, turn back a little") }
        switch p.currentPose {
        case .center?: return L("Nhìn thẳng vào camera", "Look straight at the camera")
        case .left?: return L("Quay đầu sang trái một chút", "Turn your head slightly left")
        case .right?: return L("Quay đầu sang phải một chút", "Turn your head slightly right")
        case .top?: return L("Ngẩng lên một chút", "Tilt your head slightly up")
        case .bottom?: return L("Cúi xuống một chút", "Tilt your head slightly down")
        case .topLeft?: return L("Ngẩng lên, chếch trái", "Up and to the left")
        case .topRight?: return L("Ngẩng lên, chếch phải", "Up and to the right")
        case .bottomLeft?: return L("Cúi xuống, chếch trái", "Down and to the left")
        case .bottomRight?: return L("Cúi xuống, chếch phải", "Down and to the right")
        case nil: return p.instruction
        }
    }
}

/// Thanh tiến độ kiểu Cài đặt: rãnh mờ, phần đã xong màu tím.
private struct EnrollmentBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(SUI.accent)
                    .frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

/// Vòng 8 hướng quanh khung camera (+ chấm dưới cho tư thế nhìn thẳng), mỗi cung đầy dần theo tiến độ.
private struct PoseRing: View {
    let progress: EnrollmentProgress?

    var body: some View {
        ZStack {
            ForEach(EnrollmentPose.allCases, id: \.rawValue) { pose in
                let value = progress?.poseProgress[pose] ?? 0
                let current = progress?.currentPose == pose
                if let angle = pose.compassAngle {
                    // compassAngle: 0 = trên, theo chiều kim đồng hồ; khung camera lật gương nên đảo trái/phải.
                    let mirrored = 360 - angle
                    Arc(start: mirrored - 17, end: mirrored + 17)
                        .stroke(current ? SUI.accent.opacity(0.3) : Color.primary.opacity(0.1),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    Arc(start: mirrored - 17, end: mirrored - 17 + 34 * value)
                        .stroke(SUI.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                } else {
                    Circle().fill(value >= 1 ? SUI.accent : current ? SUI.accent.opacity(0.4) : Color.primary.opacity(0.15))
                        .frame(width: 9, height: 9)
                        .offset(y: 114 + 14)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: progress?.overallProgress)
        .animation(.easeOut(duration: 0.2), value: progress?.currentPose)
    }

    private struct Arc: Shape {
        let start: Double
        let end: Double
        func path(in r: CGRect) -> Path {
            var p = Path()
            // SwiftUI: 0° = phải, theo chiều kim đồng hồ (y hướng xuống) → la bàn trừ 90°.
            p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2,
                     startAngle: .degrees(start - 90), endAngle: .degrees(end - 90), clockwise: false)
            return p
        }
    }
}

/// Mở một mục trong Cài đặt hệ thống > Quyền riêng tư & Bảo mật.
func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}
