import SwiftUI
import AppKit

// Góc phải hàng tab khi notch mở: tối đa 2 phần tử.
//  1. Viên trạng thái: mức dùng Claude (5h, 7d) và, chỉ khi đang bật, ly cà phê kèm thời gian còn lại.
//  2. Nút Cài đặt (chuột phải: Thoát Roost). Mục "Chưa dùng" trong Bố cục notch thì ẩn hẳn.

/// Màu viên trạng thái theo giao diện.
struct HeaderPalette {
    let fill: Color, border: Color, text: Color, secondary: Color, track: Color, radius: CGFloat

    static var current: HeaderPalette {
        switch Theme.current {
        case .pixel:
            return .init(fill: Color(red: 0.08, green: 0.06, blue: 0.16), border: PixelPalette.dim, text: .white,
                         secondary: PixelPalette.border.opacity(0.7), track: PixelPalette.dim.opacity(0.7), radius: 0)
        case .cassette:
            return .init(fill: CassettePalette.label.opacity(0.92), border: CassettePalette.line, text: CassettePalette.ink,
                         secondary: CassettePalette.faded, track: CassettePalette.ink.opacity(0.15), radius: 5)
        case .vangogh:
            return .init(fill: VG.night.opacity(0.78), border: VG.yellow.opacity(0.55), text: VG.cream,
                         secondary: VG.muted, track: VG.cream.opacity(0.2), radius: 11)
        case .standard:
            return .init(fill: .white.opacity(0.08), border: .white.opacity(0.1), text: .white,
                         secondary: .white.opacity(0.5), track: .white.opacity(0.16), radius: 11)
        }
    }
}

/// Viên trạng thái: "◔ 5h 81%  ◔ 7d 60%" và ly cà phê khi đang giữ máy thức. Ẩn hẳn khi không có gì để báo.
struct HeaderStatusPill: View {
    @ObservedObject var api = ClaudeUsageAPI.shared
    @ObservedObject var usage = ClaudeUsage.shared
    @ObservedObject var extras = ClaudeExtras.shared
    @ObservedObject var awake = KeepAwake.shared
    @ObservedObject var layout = NotchLayoutStore.shared

    // Chỉ hiện phần nào đang đặt trên thanh công cụ (Cài đặt › Giao diện › Bố cục notch).
    private var showsUsage: Bool { layout.layout.toolbar.contains(.usage) && (api.enabled || usage.hasData) }
    private var showsAwake: Bool { layout.layout.toolbar.contains(.keepAwake) && awake.active }

    var body: some View {
        if showsUsage || showsAwake {
            let p = HeaderPalette.current
            HStack(spacing: 0) {
                if showsUsage {
                    Button { withAnimation(.easeOut(duration: 0.18)) { api.panelOpen.toggle() } } label: {
                        HStack(spacing: 7) {
                            segment(.fiveHour, p)
                            segment(.sevenDay, p)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(helpText)
                    .onAppear { api.retain() }
                    .onDisappear { api.release(); api.panelOpen = false }
                }
                if showsUsage && showsAwake {
                    Rectangle().fill(p.border).frame(width: 1, height: 12)
                }
                if showsAwake {
                    Button { KeepAwakeMenu.shared.pop() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "cup.and.saucer.fill").font(.system(size: 10, weight: .semibold))
                            if awake.endsAt != nil {
                                TimelineView(.everyMinute) { ctx in
                                    Text(awake.remainingText(now: ctx.date) ?? "")
                                        .font(.ui(10, weight: .semibold).monospacedDigit())
                                }
                            }
                        }
                        .foregroundStyle(KeepAwakeButton.activeColor)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(awake.statusText)
                }
            }
            .background(RoundedRectangle(cornerRadius: p.radius).fill(p.fill))
            .overlay(RoundedRectangle(cornerRadius: p.radius).stroke(p.border, lineWidth: Theme.isPixel ? 2 : 1))
            .fixedSize()
        }
    }

    @ViewBuilder private func segment(_ w: ClaudeUsage.Window, _ p: HeaderPalette) -> some View {
        HStack(spacing: 4) {
            if let l = usage.limit(w) {
                let pct = Int((ClaudeUsage.fraction(l, show: extras.usageShow) * 100).rounded())
                UsageGauge(limit: l, style: .ring, show: extras.usageShow, size: 11, lineWidth: 2, track: p.track)
                Text(w.short).font(.ui(10, weight: .medium)).foregroundStyle(p.secondary)
                Text("\(pct)%").font(.ui(11, weight: .bold).monospacedDigit()).foregroundStyle(ClaudeUsage.color(l))
            } else {
                Circle().stroke(p.track, lineWidth: 2).frame(width: 11, height: 11)
                Text(w.short).font(.ui(10, weight: .medium)).foregroundStyle(p.secondary)
                Text("--").font(.ui(11, weight: .bold)).foregroundStyle(p.secondary)
            }
        }
    }

    private var helpText: String {
        let what = extras.usageShow == .used ? L("đã dùng", "used") : L("còn lại", "left")
        return L("Mức dùng Claude (phần \(what)). Bấm để xem chi tiết.", "Claude usage (\(what)). Click for details.")
    }
}

/// Các nút khác đặt trên thanh công cụ. Giữ máy thức / Mức dùng Claude chỉ thành nút khi viên trạng thái không hiện chúng.
struct HeaderToolbarItems: View {
    let model: NotchModel
    @ObservedObject var media: NowPlaying
    @ObservedObject var settings: SettingsStore
    @ObservedObject var layout = NotchLayoutStore.shared
    @ObservedObject var awake = KeepAwake.shared
    @ObservedObject var api = ClaudeUsageAPI.shared
    @ObservedObject var usage = ClaudeUsage.shared
    @ObservedObject var bt = BluetoothAudio.shared

    var body: some View {
        ForEach(layout.layout.toolbar.filter(shown)) { action in
            HeaderToolbarButton(action: action, model: model)
        }
    }

    private func shown(_ a: NotchAction) -> Bool {
        switch a {
        case .usage: return !(api.enabled || usage.hasData)
        case .keepAwake: return !awake.active
        default: return a.available(media: media, settings: settings)
        }
    }
}

/// Nút Cài đặt luôn ở cuối thanh công cụ. Chuột phải: Thoát Roost.
struct HeaderSettingsButton: View {
    var body: some View {
        Button { SettingsWindowController.shared.show() } label: {
            ThemedIcon(symbol: "gearshape")
                .font(.ui(12, weight: .semibold))
                .foregroundStyle(KeepAwakeButton.idleColor)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Cài đặt (chuột phải để thoát)", "Settings (right-click to quit)"))
        .contextMenu {
            Button(L("Cài đặt…", "Settings…")) { SettingsWindowController.shared.show() }
            Divider()
            Button(L("Thoát Roost", "Quit Roost")) { NSApp.terminate(nil) }
        }
    }
}
