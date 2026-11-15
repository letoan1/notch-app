import AppKit
import SwiftUI

/// Tab "Âm thanh" trên notch: chọn thiết bị, âm lượng tổng, mic, rồi một thanh dọc cho mỗi app đang phát.
struct SoundPanel: View {
    @ObservedObject var center = SoundCenter.shared
    private var monitor = State<Any?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Cài đặt âm thanh mở từ nút Cài đặt trên header (không đặt nút riêng ở đây nữa).
            HStack(spacing: 8) {
                DeviceMenu(center: center)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 14) {
                VolumeColumn(id: "out", value: Double(center.outputVolume), active: false,
                             muted: center.outputMuted || !center.outputHasVolume,
                             label: center.outputHasVolume ? Self.percent(center.outputVolume) : "—",
                             set: { center.setOutputVolume(Float($0)) }) {
                    SymbolTile(symbol: center.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { center.toggleOutputMute() }
                } footer: { EmptyView() }
                VolumeColumn(id: "in", value: Double(center.inputVolume), active: false,
                             muted: center.inputMuted || !center.inputHasVolume,
                             label: center.inputHasVolume ? Self.percent(center.inputVolume) : "Mic",
                             set: { center.setInputVolume(Float($0)) }) {
                    SymbolTile(symbol: center.inputMuted ? "mic.slash.fill" : "mic.fill") { center.toggleInputMute() }
                } footer: { EmptyView() }
                Rectangle().fill(SoundStyle.text.opacity(0.12)).frame(width: 1).padding(.vertical, 6)
                apps
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .onAppear { monitor.wrappedValue = SoundScroll.install() }
        .onDisappear {
            if let m = monitor.wrappedValue { NSEvent.removeMonitor(m) }
            monitor.wrappedValue = nil
        }
    }

    @ViewBuilder private var apps: some View {
        if #unavailable(macOS 14.2) {
            note(L("Chỉnh âm lượng từng app cần macOS 14.2 trở lên.", "Per-app volume needs macOS 14.2 or later."))
        } else if center.permissionDenied {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Cần quyền Ghi âm thanh hệ thống để chỉnh âm lượng từng app.",
                       "Per-app volume needs the System Audio Recording permission."))
                    .font(.ui(11))
                    .foregroundStyle(SoundStyle.text.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Mở Cài đặt", "Open Settings")) { center.openPrivacySettings() }
                    .buttonStyle(.plain)
                    .font(.ui(11, weight: .semibold))
                    .foregroundStyle(SoundStyle.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if center.apps.isEmpty {
            note(L("Chưa có app nào đang phát âm thanh.", "No app is playing audio."))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(center.apps) { app in
                        let gain = center.gain(for: app.id)
                        let muted = center.isMuted(app.id)
                        VolumeColumn(id: app.id, value: Double(min(gain, 1)), active: app.active, muted: muted,
                                     label: muted ? L("Tắt", "Off") : Self.percent(gain),
                                     set: { center.setGain(Float($0), for: app.id) }) {
                            AppTile(app: app)
                        } footer: {
                            HStack(spacing: 3) {
                                if gain != 1 || muted {
                                    Button { center.reset(app.id) } label: { Image(systemName: "arrow.counterclockwise") }
                                        .help(L("Về 100%", "Back to 100%"))
                                }
                                Button { center.toggleMute(app.id) } label: {
                                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                }
                                .help(muted ? L("Bật tiếng", "Unmute") : L("Tắt tiếng", "Mute"))
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SoundStyle.text.opacity(0.55))
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.ui(11))
            .foregroundStyle(SoundStyle.text.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    static func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
}

// MARK: - Thiết bị

private struct DeviceMenu: View {
    @ObservedObject var center: SoundCenter

    var body: some View {
        Menu {
            Section(L("Đầu ra", "Output")) {
                ForEach(center.outputs) { d in
                    Button { center.setOutputDevice(d.id) } label: {
                        if d.id == center.outputID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            }
            Section(L("Mic", "Input")) {
                ForEach(center.inputs) { d in
                    Button { center.setInputDevice(d.id) } label: {
                        if d.id == center.inputID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                Text(center.outputName).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
            .font(.ui(11.5, weight: .semibold))
            .foregroundStyle(SoundStyle.text)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(SoundStyle.chip, in: Capsule())
            .overlay { if Theme.isPixel { Rectangle().strokeBorder(PixelPalette.dim, lineWidth: 2) } }
        }
        // Kiểu .button + .plain: giữ nguyên nhãn tự vẽ (nền viên, font theo giao diện).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Cột âm lượng

private struct VolumeColumn<Top: View, Footer: View>: View {
    let id: String
    let value: Double
    let active: Bool
    let muted: Bool
    let label: String
    let set: (Double) -> Void
    @ViewBuilder let top: () -> Top
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 4) {
            top()
                .overlay(alignment: .bottomTrailing) {
                    if active {
                        Circle().fill(Color(red: 0.2, green: 0.85, blue: 0.4))
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.2))
                            .offset(x: 2, y: 2)
                    }
                }
            VolumeSlider(value: muted ? 0 : value, dim: muted, set: set)
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { SoundScroll.register(id, geo.frame(in: .global), set: set, value: value) }
                        .onChange(of: geo.frame(in: .global)) { _, f in SoundScroll.register(id, f, set: set, value: value) }
                        .onChange(of: value) { _, v in SoundScroll.register(id, geo.frame(in: .global), set: set, value: v) }
                        .onDisappear { SoundScroll.unregister(id) }
                })
            HStack(spacing: 3) {
                Text(label)
                    .font(.ui(10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(SoundStyle.text.opacity(muted ? 0.5 : 0.95))
                footer()
            }
            .frame(height: 13)
            .fixedSize()
        }
        .frame(minWidth: 40)
    }
}

/// Thanh dọc kéo được, mỗi giao diện một kiểu.
private struct VolumeSlider: View {
    let value: Double
    let dim: Bool
    let set: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let v = min(max(value, 0), 1)
            Group {
                if Theme.isPixel {
                    pixel(v)
                } else if Theme.isCassette {
                    cassette(v, height: h)
                } else if Theme.isVanGogh {
                    vanGogh(v, height: h)
                } else {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.white.opacity(0.13))
                        // Mép trên phẳng (như Control Center); khung Capsule ngoài lo phần bo đáy.
                        Rectangle().fill(Color.white.opacity(dim ? 0.35 : 0.92))
                            .frame(height: h * v)
                    }
                    .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                set(Double(min(max(1 - g.location.y / max(h, 1), 0), 1)))
            })
        }
    }

    private func pixel(_ v: Double) -> some View {
        let count = 10
        return VStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                let level = Double(count - i) / Double(count)
                Rectangle().fill(level <= v + 0.001 ? (dim ? PixelPalette.dim : PixelPalette.pink) : PixelPalette.shadow)
            }
        }
        .padding(2)
        .overlay(Rectangle().strokeBorder(PixelPalette.border.opacity(0.8), lineWidth: 2))
    }

    /// Kiểu VU: đèn LED xanh, vàng, đỏ cùng nắp cần gạt màu kem.
    private func cassette(_ v: Double, height h: CGFloat) -> some View {
        let count = 12
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3).fill(CassettePalette.plate)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(CassettePalette.shellEdge, lineWidth: 1))
            VStack(spacing: 1.5) {
                ForEach(0..<count, id: \.self) { i in
                    let level = Double(count - i) / Double(count)
                    let color: Color = level > 0.85 ? .red : level > 0.6 ? .yellow : Color(red: 0.35, green: 0.85, blue: 0.4)
                    RoundedRectangle(cornerRadius: 1).fill(level <= v + 0.001 ? color.opacity(dim ? 0.35 : 0.9) : color.opacity(0.1))
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            RoundedRectangle(cornerRadius: 2).fill(CassettePalette.key)
                .overlay(Rectangle().fill(CassettePalette.ink).frame(height: 1.5))
                .frame(height: 7)
                .padding(.horizontal, -2)
                .offset(y: -(h - 7) * v)
        }
    }

    private func vanGogh(_ v: Double, height h: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(VG.navy.opacity(0.85))
            // Mép trên phẳng như bản Mặc định; viền vẽ sau cùng để nằm trên phần màu.
            Rectangle().fill(VG.yellow.opacity(dim ? 0.4 : 1))
                .overlay(BrushDaubs(color: VG.yellow2, seed: 7, density: 1.4))
                .frame(height: h * v)
                .clipped()
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(VG.muted.opacity(0.5), lineWidth: 1))
    }
}

private struct SymbolTile: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SoundStyle.text)
                .frame(width: 30, height: 28)
                .background(SoundStyle.tile)
        }
        .buttonStyle(.plain)
    }
}

private struct AppTile: View {
    let app: AudioApp

    var body: some View {
        Button {
            NSRunningApplication(processIdentifier: app.pid)?.activate()
        } label: {
            Image(nsImage: AppIcons.icon(for: app))
                .resizable()
                .interpolation(Theme.isPixel ? .none : .high)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(app.name)
    }
}

enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for app: AudioApp) -> NSImage {
        let key = app.id + (Theme.isPixel ? "#px" : "")
        if let hit = cache[key] { return hit }
        let image = NSRunningApplication(processIdentifier: app.pid)?.icon
            ?? NSWorkspace.shared.icon(for: .application)
        let out = Theme.isPixel ? image.pixelated(16) : image
        cache[key] = out
        return out
    }
}

/// Màu chung theo giao diện.
enum SoundStyle {
    static var text: Color {
        if Theme.isCassette { return CassettePalette.label }
        if Theme.isVanGogh { return VG.cream }
        if Theme.isPixel { return PixelPalette.border }
        return .white
    }
    static var chip: Color {
        if Theme.isCassette { return CassettePalette.shell }
        if Theme.isVanGogh { return VG.night.opacity(0.75) }
        if Theme.isPixel { return PixelPalette.shadow }
        return Color.white.opacity(0.1)
    }
    static var accent: Color {
        if Theme.isCassette { return CassettePalette.band }
        if Theme.isVanGogh { return VG.yellow }
        if Theme.isPixel { return PixelPalette.pink }
        return Color(red: 0.4, green: 0.7, blue: 1)
    }
    static var tile: some View {
        Group {
            if Theme.isPixel {
                Rectangle().fill(PixelPalette.shadow).overlay(Rectangle().strokeBorder(PixelPalette.dim, lineWidth: 2))
            } else if Theme.isCassette {
                RoundedRectangle(cornerRadius: 4).fill(CassettePalette.key.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(CassettePalette.shellEdge, lineWidth: 1))
            } else if Theme.isVanGogh {
                RoundedRectangle(cornerRadius: 9).fill(VG.night.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(VG.yellow.opacity(0.45), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.1))
            }
        }
    }
}

// MARK: - Lăn chuột trên thanh

/// Lăn chuột dọc trên một thanh thì đổi âm lượng (lăn ngang vẫn cuộn danh sách app).
@MainActor
enum SoundScroll {
    private struct Entry { let frame: CGRect; let set: (Double) -> Void; let value: Double }
    private static var entries: [String: Entry] = [:]

    static func register(_ id: String, _ frame: CGRect, set: @escaping (Double) -> Void, value: Double) {
        entries[id] = Entry(frame: frame, set: set, value: value)
    }

    static func unregister(_ id: String) { entries[id] = nil }

    static func install() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { handle(event) ? nil : event }
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let view = event.window?.contentView else { return false }
        let loc = view.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: loc.x, y: view.isFlipped ? loc.y : view.bounds.height - loc.y)
        guard let (id, entry) = entries.first(where: { $0.value.frame.contains(point) }) else { return false }
        let step = event.hasPreciseScrollingDeltas ? Double(event.scrollingDeltaY) / 300 : Double(event.scrollingDeltaY) * 0.03
        let next = min(max(entry.value + step, 0), 1)
        entries[id] = Entry(frame: entry.frame, set: entry.set, value: next)
        entry.set(next)
        return true
    }
}

// MARK: - Cài đặt

struct SoundPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var center = SoundCenter.shared

    var body: some View {
        SPage {
            SSection(L("Tab Âm thanh", "Sound tab"),
                     note: L("Chỉnh âm lượng riêng một app cần quyền \"Ghi âm thanh hệ thống\". Lúc có app đang được chỉnh khác 100%, macOS hiện chấm tím trên thanh menu. Đưa hết về 100% thì Roost thôi nghe và chấm tím biến mất.",
                             "Per-app volume needs the \"System Audio Recording\" permission. While any app is set to something other than 100%, macOS shows a purple dot in the menu bar. Put every app back to 100% and Roost stops listening, so the dot goes away.")) {
                SToggleRow(icon: "speaker.wave.2", title: L("Tab Âm thanh trên notch", "Sound tab on the notch"),
                           detail: L("Chọn loa, mic, âm lượng tổng và âm lượng từng app.", "Pick the output and mic, set the main volume and each app's volume."),
                           divider: false, isOn: $settings.showSound)
                SToggleRow(icon: "memorychip", title: L("Nhớ mức âm lượng từng app", "Remember each app's volume"),
                           detail: L("Mở lại app thì giữ mức đã chỉnh. Tắt thì về 100% khi app thoát.", "Keeps your level when the app opens again. Off means back to 100% when the app quits."),
                           isOn: $center.remember)
                SRow("lock.shield", L("Quyền ghi âm thanh hệ thống", "System audio permission")) {
                    Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { center.openPrivacySettings() }
                        .controlSize(.small)
                }
            }
        }
    }
}
