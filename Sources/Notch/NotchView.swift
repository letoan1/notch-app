import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var media: NowPlaying
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var tray: TrayStore
    @ObservedObject var calendar: CalendarStore
    let camera: CameraMirror
    @ObservedObject var settings: SettingsStore
    @ObservedObject var system = SystemMonitor.shared
    @ObservedObject var awake = KeepAwake.shared
    @ObservedObject var usage = ClaudeUsage.shared

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    // Không dùng macro @Namespace/@State (plugin chỉ có trong Xcode).
    private var ns = Namespace()

    var body: some View {
        let wings = WingLayout.resolve(settings: settings, hasTrack: media.hasTrack, calendar: calendar,
                                       battery: system.batteryPercent, height: model.notchSize.height)
        let size = model.shapeSize(wing: wings.width)
        let shape = NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius,
                               pixel: Theme.isPixel && (model.expanded || model.pill), pill: model.pill)
        let notch = model.notchSize

        // Nội dung có kích thước cố định ở trạng thái cuối; khung shape lớn dần và "lộ" nó ra
        // thay vì layout lại chữ ở mỗi frame animation.
        ZStack(alignment: .top) {
            shape.fill(Theme.isCassette ? CassettePalette.background : Color.black)
            if Theme.isVanGogh && model.expanded {
                // Cố định ở kích thước cuối: khung lớn dần chỉ "lộ" tranh ra, không co giãn ảnh mỗi khung hình.
                VGPanelBackground()
                    .frame(width: NotchModel.expandedWidth * NotchModel.scale,
                           height: notch.height + model.expandedBodyHeight * NotchModel.scale)
                    .clipped()
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
            if model.expanded {
                ExpandedView(model: model, media: media, permissions: permissions, tray: tray,
                             calendar: calendar, camera: camera, settings: settings,
                             notchHeight: notch.height / NotchModel.scale, ns: ns.wrappedValue)
                    // Hàng tab chia ngược tỉ lệ → sau khi co giãn vẫn cao đúng bằng notch thật,
                    // nội dung không lọt vào sau camera ở cỡ Gọn.
                    .frame(width: NotchModel.expandedWidth - 28,
                           height: notch.height / NotchModel.scale + model.expandedBodyHeight)
                    .scaleEffect(NotchModel.scale, anchor: .top)
                    .transition(.notchContent)
            } else if let alert = model.alert {
                AlertCard(alert: alert, notchHeight: notch.height)
                    .frame(width: size.width, height: size.height)
                    .transition(.notchContent)
            } else if model.minimal {
                EmptyView()
            } else if let peek = model.peek {
                Group {
                    switch peek {
                    case let .charge(charge): ChargeWings(peek: charge, wing: peek.wing)
                    case let .audio(name, symbol): AudioWings(name: name, symbol: symbol, wing: peek.wing)
                    case let .screenshot(thumb): ScreenshotWings(thumb: thumb, wing: peek.wing)
                    case let .unlocked(name): UnlockWings(name: name, wing: peek.wing)
                    case let .claude(notice): ClaudeNoticeWings(notice: notice, wing: peek.wing)
                    case let .capsLock(on): CapsLockWings(on: on, wing: peek.wing)
                    case let .hud(hud): HUDWings(hud: hud, wing: peek.wing)
                    }
                }
                .frame(width: notch.width + peek.wing * 2, height: notch.height)
                .offset(x: -model.petWing / 2)
                .transition(.notchContent)
            } else if wings.width > 0 {
                CollapsedWings(media: media, layout: wings, height: notch.height, ns: ns.wrappedValue)
                    .frame(width: notch.width + wings.width * 2, height: notch.height)
                    .offset(x: -model.petWing / 2)
                    .transition(.notchContent)
            }
            if model.petShown {
                PetView()
                    .frame(width: model.petWing, height: notch.height)
                    .padding(.trailing, model.topRadius)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.notchContent)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        // Van Gogh thu gọn: viền mảnh cobalt → vàng như một vệt sơn quanh notch.
        .overlay {
            if Theme.isVanGogh, !model.expanded, !model.minimal {
                shape.stroke(LinearGradient(colors: [VG.cobalt, VG.yellow, VG.cobalt.opacity(0.9), VG.yellow, VG.cobalt],
                                            startPoint: .leading, endPoint: .trailing), lineWidth: 1.6)
                    .opacity(0.9)
                    .transition(.opacity)
            }
        }
        .overlay(shape.stroke(Theme.isPixel ? PixelPalette.border.opacity(model.expanded ? 1 : 0)
                              : Theme.isVanGogh ? VG.ink.opacity(model.expanded ? 1 : 0)
                              : Color.white.opacity(model.expanded ? 0.08 : 0),
                              lineWidth: Theme.isPixel ? 3 : Theme.isVanGogh ? 2.5 : 1))
        // Bóng đổ chỉ tính trên khung (không trên cả nội dung) → co / giãn không phải dựng lại bóng của
        // ảnh bìa, lịch, chữ ở mỗi khung hình.
        .background {
            shape.fill(Color.black)
                // Viên nổi tách khỏi mép trên → có bóng nhẹ cả khi thu gọn.
                .shadow(color: .black.opacity(model.expanded ? 0.6 : model.pill && !model.minimal ? 0.35 : 0),
                        radius: model.expanded ? 18 : 6, y: model.expanded ? 8 : 2)
        }
        // Quầng sáng màu ảnh bìa: chỉ khi thu gọn, hiện dần sau khi co xong (không làm nhoè khung đang co).
        .background {
            if settings.ambientGlow, media.isPlaying, media.artwork != nil, !model.expanded, !model.minimal, !system.lowPower {
                // Van Gogh: quầng xanh cobalt pha vàng của tranh thay cho màu ảnh bìa.
                shape.fill(Theme.isVanGogh
                           ? AnyShapeStyle(LinearGradient(colors: [VG.cobalt, VG.yellow, VG.cobalt], startPoint: .leading, endPoint: .trailing))
                           : AnyShapeStyle(media.accent))
                    .blur(radius: 9)
                    .opacity(0.7)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.4).delay(0.35)),
                                            removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
        }
        // Van Gogh: vệt sáng vàng ấm dưới notch thu gọn.
        .background(alignment: .bottom) {
            if Theme.isVanGogh, !model.expanded, !model.minimal, !system.lowPower {
                Capsule()
                    .fill(LinearGradient(colors: [VG.yellow.opacity(0), VG.yellow, VG.yellow.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(size.width - model.bottomRadius * 2, 20), height: 3)
                    .blur(radius: 2)
                    .opacity(0.85)
                    .offset(y: 2.5)
                    .transition(.opacity.animation(.easeIn(duration: 0.4).delay(0.3)))
            }
        }
        .animation(.easeInOut(duration: 0.6), value: media.accent)
        // Nút tròn hai bên notch mở (Cài đặt › Giao diện › Bố cục notch).
        .overlay(alignment: .top) {
            if model.expanded, !model.minimal {
                NotchOrbColumns(media: media, settings: settings, model: model, panelWidth: size.width)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.6, anchor: .top))
                            .animation(.spring(response: 0.4, dampingFraction: 0.75).delay(0.12)),
                        removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
        }
        // "Nuốt" file vừa bay tới: phình nhẹ rồi nảy về.
        .scaleEffect(model.gulp ? 1.04 : 1, anchor: .top)
        .animation(.spring(response: 0.22, dampingFraction: 0.45), value: model.gulp)
        .offset(x: model.shapeOffsetX, y: model.topGap)
        .animation(spring, value: settings.showPet)
        .animation(spring, value: settings.expandedSize)
        .animation(model.expanded ? .spring(response: 0.46, dampingFraction: 0.72)
                                  : .spring(response: 0.3, dampingFraction: 0.9), value: model.expanded)
        .animation(spring, value: model.tall)
        .animation(spring, value: model.tallHeight)
        .animation(spring, value: model.mirrorMode)
        .animation(spring, value: model.peek)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.alert)
        .animation(spring, value: wings)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, settings.locale)
        .textCase(Theme.isPixel ? .uppercase : nil)
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// Hiện: mờ → rõ + phóng nhẹ, trễ một nhịp sau khi khung bắt đầu phình. Ẩn: tắt nhanh.
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurModifier(radius: 8), identity: BlurModifier(radius: 0))
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.92, anchor: .top))
                .animation(.spring(response: 0.4, dampingFraction: 0.86).delay(0.14)),
            // Đóng: mờ + thu nhẹ về mép trên cùng nhịp với khung, không biến mất cụt.
            removal: .opacity
                .combined(with: .scale(scale: 0.94, anchor: .top))
                .animation(.easeOut(duration: 0.15))
        )
    }
}

// MARK: - Collapsed

struct ChargeWings: View {
    let peek: NotchModel.ChargePeek
    let wing: CGFloat

    private let green = Color(red: 0.30, green: 0.85, blue: 0.40)

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.ui(11, weight: .bold))
                    .foregroundStyle(green)
                Text(peek.charging ? L("Đang sạc", "Charging") : L("Đã cắm sạc", "Plugged in"))
                    .font(Theme.isCassette ? .hand(13) : .ui(11, weight: .semibold))
                    .foregroundStyle(Theme.isCassette ? CassettePalette.ink : .white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.isCassette ? 6 : 0)
            .padding(.vertical, Theme.isCassette ? 2 : 0)
            .background(Theme.isCassette ? CassettePalette.note : Color.clear)
            .rotationEffect(.degrees(Theme.isCassette ? -2 : 0))
            .frame(width: wing)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Text("\(peek.percent)%")
                    .font(.ui(12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(green)
                BatteryGlyph(level: Double(peek.percent) / 100, color: green)
            }
            .frame(width: wing)
        }
    }
}

/// Vừa kết nối tai nghe: icon + tên thiết bị bên trái, "Đã kết nối" bên phải.
struct AudioWings: View {
    let name: String
    let symbol: String
    let wing: CGFloat

    var body: some View {
        let cassette = Theme.isCassette
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(cassette ? CassettePalette.ink : .white)
                Text(name)
                    .font(cassette ? .hand(13) : .ui(11, weight: .semibold))
                    .foregroundStyle(cassette ? CassettePalette.ink : .white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, cassette ? 6 : 0)
            .padding(.vertical, cassette ? 2 : 0)
            .background(cassette ? CassettePalette.note : Color.clear)
            .rotationEffect(.degrees(cassette ? -2 : 0))
            .frame(width: wing - 8)
            .padding(.leading, 8)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(Color(red: 0.30, green: 0.85, blue: 0.40)).frame(width: 6, height: 6)
                Text(L("Đã kết nối", "Connected"))
                    .font(cassette ? .hand(13) : .ui(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(width: wing)
        }
    }
}

/// Vừa chụp màn hình: ảnh thu nhỏ bên trái, "Vào khay" bên phải.
struct ScreenshotWings: View {
    let thumb: NSImage?
    let wing: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "camera.viewfinder").font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(width: 36, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 4))
            .overlay(RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 4)
                .stroke(Theme.isCassette ? CassettePalette.label : .white.opacity(0.5), lineWidth: Theme.isPixel ? 2 : 1))
            .rotationEffect(.degrees(Theme.isCassette ? -3 : 0))
            .frame(width: wing)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ThemedIcon(symbol: "tray.full.fill").font(.system(size: 10, weight: .semibold))
                Text(L("Vào khay", "In tray"))
                    .font(Theme.isCassette ? .hand(13) : .ui(11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: wing)
        }
    }
}

private struct BatteryGlyph: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
                    .frame(width: 24, height: 12)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, 20 * level), height: 8)
                    .padding(.leading, 2)
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var media: NowPlaying
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var tray: TrayStore
    @ObservedObject var calendar: CalendarStore
    let camera: CameraMirror
    @ObservedObject var settings: SettingsStore
    let notchHeight: CGFloat
    let ns: Namespace.ID
    /// Hiện lần lượt: hàng tab trước, nội dung sau (chỉ chạy lúc mở).
    var shown = State(initialValue: false)
    @ObservedObject var lyrics = LyricsStore.shared
    @ObservedObject var layoutStore = NotchLayoutStore.shared
    // Hiệu ứng đổi tab chỉ 0,3 s mỗi lần bấm: giữ cả khi tiết kiệm pin.
    private var tabFX: Bool { (Theme.isPixel || Theme.isCassette || Theme.isVanGogh) && permissions.current == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(settings.enabledTabs, id: \.self) { tab in
                    switch tab {
                    case .media:
                        TabPill(symbol: settings.showMedia ? "music.note" : "calendar", label: nil,
                                selected: model.tab == .media) {
                            model.tab = .media
                        }
                    case .tray:
                        TabPill(symbol: "tray.full.fill", label: nil, selected: model.tab == .tray,
                                badge: tray.files.isEmpty ? nil : tray.files.count) {
                            model.tab = .tray
                        }
                    case .mirror:
                        TabPill(symbol: "camera.fill", label: nil, selected: model.tab == .mirror) {
                            model.tab = .mirror
                        }
                    case .sound:
                        TabPill(symbol: "speaker.wave.2.fill", label: nil, selected: model.tab == .sound) {
                            model.tab = .sound
                        }
                    case .system:
                        TabPill(symbol: "cpu", label: nil, selected: model.tab == .system) {
                            model.tab = .system
                        }
                    case .bank:
                        TabPill(symbol: "qrcode", label: nil, selected: model.tab == .bank) {
                            model.tab = .bank
                        }
                    }
                }
                if permissions.requests.count > 1 {
                    QueueStrip(requests: permissions.requests)
                        .padding(.leading, 6)
                }
                Spacer()
                if settings.showPet, !SystemMonitor.shared.lowPower {
                    // Notch mở: thú cưng lên hàng tab (Claude hỏi vẫn thấy nó giật mình); bấm để vuốt ve.
                    PetView().frame(width: 34, height: notchHeight)
                }
                // Góc phải gọn: viên trạng thái (mức dùng Claude, ly cà phê khi đang bật), nút đặt trên thanh công cụ, nút Cài đặt.
                HeaderStatusPill()
                HeaderToolbarItems(model: model, media: media, settings: settings)
                HeaderSettingsButton()
            }
            .padding(.horizontal, 18)
            .frame(height: notchHeight)
            // Van Gogh: quầng tối sau thú cưng + nút ở góc phải (đè lên vầng xoáy sáng của tranh).
            .background(alignment: .trailing) {
                if Theme.isVanGogh { VGScrim(strength: 0.75).frame(width: 190, height: notchHeight * 2.2).offset(x: 30) }
            }
            .opacity(shown.wrappedValue ? 1 : 0)
            .offset(y: shown.wrappedValue ? 0 : -5)
            .animation(.spring(response: 0.36, dampingFraction: 0.85).delay(0.05), value: shown.wrappedValue)

            // Pixel / Cassette / Van Gogh: đổi tab có hiệu ứng riêng (ô vuông tan, tua băng, quét cọ).
            ZStack(alignment: .top) {
            Group {
            if let request = permissions.current, let questions = request.questions, !questions.isEmpty {
                QuestionCard(request: request, questions: questions,
                             answer: { permissions.answer(request, $0) },
                             dismiss: { permissions.dismiss(request) })
                    .background {
                        if Theme.isCassette { Corkboard().padding(.horizontal, 10).padding(.bottom, 6) }
                        if Theme.isPixel { PixelDialogFrame().padding(.horizontal, 10).padding(.bottom, 6) }
                        if Theme.isVanGogh {
                            RoundedRectangle(cornerRadius: 14).fill(VG.night.opacity(0.72))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(VG.yellow.opacity(0.5), lineWidth: 1.2))
                                .padding(.horizontal, 10).padding(.bottom, 6)
                        }
                    }
                    .id(request.id)
                    .transition(.opacity)
            } else if let request = permissions.current {
                Group {
                    if Theme.isCassette {
                        CassettePermissionCard(request: request, pending: permissions.requests.count) {
                            permissions.resolve(request, $0)
                        }
                    } else if Theme.isVanGogh {
                        VGLetterCard(request: request, pending: permissions.requests.count) {
                            permissions.resolve(request, $0)
                        }
                    } else if Theme.isPixel {
                        PixelDialogCard(request: request, pending: permissions.requests.count) {
                            permissions.resolve(request, $0)
                        }
                    } else {
                        PermissionCard(request: request, pending: permissions.requests.count) {
                            permissions.resolve(request, $0)
                        }
                    }
                }
                .id(request.id)
                .transition(.opacity)
            } else if settings.showTray && (model.tab == .tray || model.dropTargeted) {
                if Theme.isCassette {
                    CassetteTrayView(tray: tray, targeted: model.dropTargeted)
                } else if Theme.isVanGogh {
                    VGTrayView(tray: tray, targeted: model.dropTargeted)
                } else if Theme.isPixel {
                    PixelTrayView(tray: tray, targeted: model.dropTargeted)
                } else {
                    TrayView(tray: tray, targeted: model.dropTargeted)
                }
            } else if settings.showSound && model.tab == .sound {
                SoundPanel()
            } else if settings.showSystem && model.tab == .system {
                SystemPanel()
            } else if settings.showBank && model.tab == .bank {
                BankPanel()
            } else if settings.showMirror && model.tab == .mirror {
                if Theme.isCassette {
                    InstantCameraMirror(camera: camera, calendar: calendar, tray: tray)
                } else if Theme.isVanGogh {
                    VGMirrorView(camera: camera, calendar: calendar, tray: tray)
                } else if Theme.isPixel {
                    PixelMirrorView(camera: camera, calendar: calendar, tray: tray)
                } else {
                    MirrorView(camera: camera, calendar: calendar)
                }
            } else if settings.enabledTabs.isEmpty {
                Text(L("Bật ít nhất một tab trong Cài đặt ⚙️", "Turn on at least one tab in Settings ⚙️"))
                    .font(.ui(13))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    if settings.showMedia {
                    Group {
                        if lyrics.showInNotch, LyricsStore.supports(lyrics.track) {
                            NotchLyricsView(media: media)
                        } else if Theme.isCassette {
                            CassettePlayerView(media: media)
                        } else if Theme.isVanGogh, let track = media.track {
                            VGPlayerView(media: media, track: track)
                        } else if let track = media.track {
                            PlayerView(media: media, track: track, ns: ns)
                        } else {
                            Text(L("Không có nhạc đang phát", "Nothing playing"))
                                .font(.ui(13))
                                .foregroundStyle(Theme.isVanGogh ? VG.muted : .white.opacity(0.5))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .overlay(alignment: Theme.isCassette ? .bottomLeading : .topTrailing) {
                        // Lời bài hát: chỉ với Spotify và Apple Music.
                        if !lyrics.showInNotch, LyricsStore.supports(lyrics.track) {
                            LyricsToggleButton().padding(Theme.isCassette ? 6 : 4)
                        }
                    }
                    .frame(width: settings.showCalendar ? 350 : nil)
                    .frame(maxWidth: settings.showCalendar ? nil : .infinity)
                    }
                    if settings.showMedia && settings.showCalendar {
                        Rectangle().fill(Theme.isVanGogh ? VG.muted.opacity(0.3) : .white.opacity(0.08))
                            .frame(width: 1)
                            .padding(.bottom, 16)
                    }
                    if settings.showCalendar {
                        if Theme.isCassette {
                            TearOffCalendar(calendar: calendar)
                        } else {
                            CalendarWidget(calendar: calendar)
                                .background { if Theme.isVanGogh { VGScrim(strength: 0.55).padding(-10) } }
                        }
                    }
                }
            }
            }
            .id(tabFX ? AnyHashable(model.tab) : AnyHashable(0))
            .transition(.themedTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(tabFX ? .easeOut(duration: Theme.isPixel ? 0.25 : 0.3) : nil, value: model.tab)
            .opacity(shown.wrappedValue ? 1 : 0)
            .offset(y: shown.wrappedValue ? 0 : 10)
            .animation(.spring(response: 0.42, dampingFraction: 0.82).delay(0.11), value: shown.wrappedValue)
        }
        // Bảng mức dùng Claude thả xuống từ chip trên hàng tab.
        .overlay(alignment: .topTrailing) { ClaudeUsagePanelHost().padding(.top, notchHeight + 2).padding(.trailing, 14) }
        .onAppear { shown.wrappedValue = true }
        // Neo lên trên: tab nào thấp hơn thì hàng tab cũng không bị đẩy xuống.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Thả file vào bất kỳ đâu trên notch đang mở đều vào khay.
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { model.dropTargeted },
            set: { model.dropTargeted = $0 }
        )) { providers in
            guard settings.showTray else { return false }
            Haptics.tap(.alignment)
            // Điểm thả (toạ độ màn hình) = nơi file bắt đầu bay vào khay.
            tray.accept(providers, at: NSEvent.mouseLocation)
            model.tab = .tray
            return true
        }
    }
}

/// Nhiều yêu cầu của Claude cùng chờ: ‹ 2/3 › + một chip cho mỗi yêu cầu; bấm chip / mũi tên để xem thẻ đó.
/// Mỗi thẻ giữ kết nối riêng, đổi thẻ không trả lời thẻ nào.
struct QueueStrip: View {
    let requests: [PermissionRequest]
    @ObservedObject private var center: PermissionCenter
    private let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    init(requests: [PermissionRequest], center: PermissionCenter? = nil) {
        self.requests = requests
        self.center = center ?? PermissionCenter.active ?? PermissionCenter()
    }

    private var list: [PermissionRequest] { center.requests.isEmpty ? requests : center.requests }
    private var selectedIndex: Int { list.firstIndex { $0.id == center.current?.id } ?? 0 }

    var body: some View {
        let cassette = Theme.isCassette
        HStack(spacing: 4) {
            arrow("chevron.left") { center.selectNext(-1) }
            Text("\(selectedIndex + 1)/\(list.count)")
                .font(.ui(10, weight: .bold).monospacedDigit())
                .foregroundStyle(cassette ? CassettePalette.ink : .white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(cassette ? AnyView(RoundedRectangle(cornerRadius: 2).fill(CassettePalette.note))
                                     : AnyView(Capsule().fill(claude)))
            arrow("chevron.right") { center.selectNext(1) }
            ForEach(Array(list.enumerated().prefix(4)), id: \.element.id) { i, r in
                chip(i, r, selected: i == selectedIndex)
            }
            if list.count > 4 {
                Text("+\(list.count - 4)")
                    .font(.ui(10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ i: Int, _ r: PermissionRequest, selected: Bool) -> some View {
        let cassette = Theme.isCassette
        return Button { center.select(r.id) } label: {
            HStack(spacing: 3) {
                Image(systemName: r.state.isWaiting ? r.kindSymbol : r.state.symbol)
                    .font(.system(size: 8, weight: .bold))
                Text(r.project.isEmpty ? "\(i + 1)" : r.project)
                    .font(.ui(10, weight: selected ? .bold : .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            }
            .foregroundStyle(cassette ? CassettePalette.ink : .white.opacity(selected ? 0.95 : 0.6))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background {
                if cassette {
                    RoundedRectangle(cornerRadius: 2).fill(selected ? CassettePalette.note : CassettePalette.key)
                } else if Theme.isPixel {
                    Rectangle().strokeBorder(selected ? PixelPalette.pink : PixelPalette.dim, lineWidth: 2)
                } else {
                    Capsule().fill(.white.opacity(selected ? 0.22 : 0.1))
                }
            }
            .opacity(r.state.isWaiting ? 1 : 0.55)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(r.kindTitle): \(r.summary)\n\(r.originHelp)")
    }
}

struct TabPill: View {
    let symbol: String?
    let label: String?
    let selected: Bool
    var badge: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { ThemedIcon(symbol: symbol) }
                if let label { Text(label) }
            }
            .font(.ui(11, weight: .semibold))
            .foregroundStyle(Theme.isCassette ? CassettePalette.ink
                             : Theme.isVanGogh ? (selected ? VG.ink : VG.cream)
                             : .white.opacity(selected ? 0.95 : 0.45))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(TabBackground(selected: selected))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text("\(badge)")
                        .font(.ui(8, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.isVanGogh ? VG.ink : .black)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(Theme.isVanGogh ? VG.yellow : .white.opacity(0.9)))
                        .overlay(Capsule().stroke(Theme.isVanGogh ? VG.ink : .clear, lineWidth: 1))
                        // Đổi số → bản mới nảy từ to về (file vừa bay vào khay).
                        .id(badge)
                        .transition(.asymmetric(insertion: .scale(scale: 1.7).combined(with: .opacity),
                                                removal: .opacity))
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PlayerView: View {
    @ObservedObject var media: NowPlaying
    let track: Track
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 20) {
            Artwork(image: media.artwork, corner: 18)
                .frame(width: 104, height: 104)
                .matchedGeometryEffect(id: "artwork", in: ns)
                .background(ArtworkGlow(image: media.artwork))
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }
                .help(L("Mở \(track.appName)", "Open \(track.appName)"))
                .overlay(alignment: .bottomTrailing) {
                    SourceBadge(bundleID: track.bundleID, open: media.openPlayer).offset(x: 7, y: 7)
                }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.ui(17, weight: .bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Text(track.artist)
                            .font(.ui(14))
                            .foregroundStyle(.white.opacity(0.6))
                        if track.isPlaying {
                            EqualizerBars(active: true, color: media.accent)
                                .frame(width: 16, height: 14)
                        }
                    }
                }
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }

                ProgressRow(track: track, accent: media.accent, seek: media.seek)

                // Trộn / lặp chỉ hiện khi nguồn cho điều khiển (Spotify, Music…); hàng chật nên khít lại.
                let modes = media.modes
                let key: CGFloat? = modes != nil && Theme.isPixel ? 40 : nil
                HStack(spacing: modes == nil ? 14 : 4) {
                    if let modes { ModeButton(kind: .shuffle, modes: modes, compact: Theme.isPixel, action: media.toggleShuffle) }
                    ControlButton(symbol: "backward.fill", size: 18, width: key, action: media.previous)
                    ControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 24, width: key, action: media.playPause)
                    ControlButton(symbol: "forward.fill", size: 18, width: key, action: media.next)
                    if let modes { ModeButton(kind: .repeatMode, modes: modes, compact: Theme.isPixel, action: media.cycleRepeat) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .overlay { if Theme.isPixel { PixelLevelUpBanner() } }
        .onAppear { media.refreshModes(force: true) }
    }
}

/// Nhãn "Trực tiếp" cho giao diện Mặc định và Pixel (Van Gogh, Cassette có bản riêng).
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            if Theme.isPixel {
                Rectangle().fill(Color(red: 1, green: 0.27, blue: 0.3)).frame(width: 8, height: 8)
                Text("LIVE").font(.ui(14)).foregroundStyle(Color(red: 1, green: 0.27, blue: 0.3))
                Text(L("TRỰC TIẾP", "ON AIR")).font(.ui(12)).foregroundStyle(PixelPalette.border.opacity(0.7))
            } else {
                Circle().fill(Color(red: 1, green: 0.27, blue: 0.3)).frame(width: 7, height: 7)
                Text(L("Trực tiếp", "Live")).font(.ui(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 14)
    }
}

struct ProgressRow: View {
    let track: Track
    let accent: Color
    var seek: ((Double) -> Void)?
    /// Tỉ lệ đang kéo (nil = không kéo): thanh đi theo chuột, thả ra mới tua thật.
    private var drag = State<Double?>(initialValue: nil)
    private var hover = State(initialValue: false)

    init(track: Track, accent: Color, seek: ((Double) -> Void)? = nil) {
        self.track = track
        self.accent = accent
        self.seek = seek
    }

    // Thanh chạy bằng Core Animation (LiveProgressBar), chữ thời gian chỉ dựng lại khi sang giây mới.
    // Bản TimelineView 10 khung/giây làm cả notch layout lại liên tục: ~10% CPU khi mở lúc đang phát.
    var body: some View {
        if track.duration <= 0 {
            // Livestream (YouTube, Twitch…): không có độ dài, thay thanh tiến độ bằng nhãn trực tiếp.
            if Theme.isVanGogh { VGLiveBadge() } else { LiveBadge() }
        } else {
            timeline
        }
    }

    private var timeline: some View {
        let dragging = drag.wrappedValue
        let active = hover.wrappedValue || dragging != nil
        return HStack(spacing: 8) {
            if Theme.isPixel {
                PixelLevelTag()
            } else if let dragging {
                Text(Self.format(dragging * track.duration))
            } else {
                TimelineView(SecondTicks(track: track)) { ctx in
                    Text(Self.format(track.position(at: ctx.date)))
                }
            }
            GeometryReader { geo in
                bar(dragging: dragging, active: active)
                    .frame(height: Theme.isVanGogh ? 11 : active && !Theme.isPixel ? 7 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag.wrappedValue = min(max($0.location.x / geo.size.width, 0), 1) }
                        .onEnded { v in
                            let r = min(max(v.location.x / geo.size.width, 0), 1)
                            seek?(r * track.duration)
                            drag.wrappedValue = nil
                        })
            }
            .frame(height: 14)
            .onHover { hover.wrappedValue = $0 && seek != nil }
            .animation(.easeOut(duration: 0.12), value: active)
            if Theme.isPixel {
                Group {
                    if let dragging {
                        Text(Self.format(dragging * track.duration) + "/" + Self.format(track.duration))
                    } else {
                        TimelineView(SecondTicks(track: track)) { ctx in
                            Text(Self.format(track.position(at: ctx.date)) + "/" + Self.format(track.duration))
                        }
                    }
                }
                .fixedSize()
            } else {
                Text(Self.format(track.duration))
            }
        }
        .font(.ui(11, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.isVanGogh ? VG.muted : .white.opacity(0.55))
    }

    @ViewBuilder private func bar(dragging: Double?, active: Bool) -> some View {
        if Theme.isVanGogh {
            BrushProgressBar(track: track, override: dragging)
        } else if Theme.isPixel {
            // 16 ô: mỗi ô đổi màu vài giây một lần, cập nhật theo giây là đủ.
            if let dragging {
                PixelSegments(ratio: dragging, accent: PixelArt.green, count: 20)
            } else {
                TimelineView(SecondTicks(track: track)) { ctx in
                    PixelSegments(ratio: track.duration > 0 ? track.position(at: ctx.date) / track.duration : 0,
                                  accent: PixelArt.green, count: 20)
                }
            }
        } else {
            LiveProgressBar(track: track, accent: accent, knob: active, override: dragging)
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Mốc thời gian đúng lúc vị trí bài hát sang giây mới (đang dừng thì chỉ một mốc).
struct SecondTicks: TimelineSchedule {
    let track: Track

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var first = true
        guard track.isPlaying else {
            return AnyIterator { defer { first = false }; return first ? start : nil }
        }
        let pos = track.position(at: start)
        var next = start.addingTimeInterval(floor(pos) + 1 - pos + 0.01)
        return AnyIterator {
            if first { first = false; return start }
            defer { next = next.addingTimeInterval(1) }
            return next
        }
    }
}

/// Thanh tiến độ do render server tự chạy: app chỉ đặt lại animation khi bài, vị trí, trạng thái
/// phát hoặc kích thước đổi, không phải dựng lại view mỗi khung hình.
struct LiveProgressBar: NSViewRepresentable {
    let track: Track
    let accent: Color
    let knob: Bool
    /// Đang kéo: đứng yên ở tỉ lệ này.
    let override: Double?

    func makeNSView(context: Context) -> LiveProgressView { LiveProgressView() }

    func updateNSView(_ view: LiveProgressView, context: Context) {
        view.update(track: track, accent: NSColor(accent), knob: knob, override: override)
    }
}

final class LiveProgressView: NSView {
    private let rail = CALayer()
    private let fill = CAGradientLayer()
    private let thumb = CALayer()
    private var track: Track?
    private var override: Double?
    private var accent: NSColor = .white

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        rail.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        thumb.backgroundColor = NSColor.white.cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.4
        thumb.shadowRadius = 2
        thumb.shadowOffset = .zero
        thumb.isHidden = true
        for l in [rail, fill, thumb] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(track: Track, accent: NSColor, knob: Bool, override: Double?) {
        let changed = self.track.map { !Self.sameRun($0, track) } ?? true
        let accentChanged = accent != self.accent
        let wasDragging = self.override != nil
        self.track = track
        self.override = override
        self.accent = accent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if accentChanged || fill.colors == nil {
            fill.colors = [accent.withAlphaComponent(0.75).cgColor, accent.cgColor]
        }
        thumb.isHidden = !knob
        CATransaction.commit()
        if changed || override != nil || wasDragging || accentChanged { restart() }
    }

    /// Cùng một đoạn chạy liên tục: không cần đặt lại animation.
    private static func sameRun(_ a: Track, _ b: Track) -> Bool {
        a.isPlaying == b.isPlaying && a.duration == b.duration && a.title == b.title
            && abs(a.position(at: Date()) - b.position(at: Date())) < 0.25
    }

    override func layout() {
        super.layout()
        restart()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [layer, rail, fill, thumb] { l?.contentsScale = scale }
    }

    private func restart() {
        guard let track else { return }
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let now = Date()
        let dur = max(track.duration, 0.001)
        let ratio = override ?? min(max(track.position(at: now) / dur, 0), 1)
        let knobSize: CGFloat = 11
        let knobX = { (r: Double) in min(max(w * r - knobSize / 2, -2), w - 9) + knobSize / 2 }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rail.frame = bounds
        rail.cornerRadius = h / 2
        fill.cornerRadius = h / 2
        fill.removeAnimation(forKey: "run")
        thumb.removeAnimation(forKey: "run")
        fill.bounds = CGRect(x: 0, y: 0, width: w * ratio, height: h)
        fill.position = CGPoint(x: 0, y: h / 2)
        thumb.bounds = CGRect(x: 0, y: 0, width: knobSize, height: knobSize)
        thumb.cornerRadius = knobSize / 2
        thumb.position = CGPoint(x: knobX(ratio), y: h / 2)

        let remaining = track.duration - track.position(at: now)
        if override == nil, track.isPlaying, remaining > 0.05 {
            let begin = CACurrentMediaTime()
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = w * ratio
            grow.toValue = w
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = knobX(ratio)
            slide.toValue = knobX(1)
            for (a, l) in [(grow, fill as CALayer), (slide, thumb)] {
                a.beginTime = begin
                a.duration = remaining
                a.timingFunction = CAMediaTimingFunction(name: .linear)
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
                // Thanh chỉ nhích vài pt mỗi giây: không cần 60 khung/giây.
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 15)
                l.add(a, forKey: "run")
            }
        }
        CATransaction.commit()
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    /// Phím Pixel thu hẹp khi hàng có thêm nút trộn / lặp.
    var width: CGFloat? = nil
    let action: () -> Void
    // Không dùng macro @State: plugin SwiftUIMacros chỉ có trong Xcode, CLT không có.
    private var hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        Button(action: action) {
            if Theme.isVanGogh {
                VGControlFace(symbol: symbol, size: size, hovering: hovering)
                    .contentShape(Circle())
            } else {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Theme.isPixel ? Color.black : .white)
                .frame(width: width ?? (Theme.isPixel ? 52 : 38), height: Theme.isPixel ? 38 : 34)
                .background(Theme.isPixel
                    ? AnyView(PixelKey(fill: symbol.hasPrefix("pause") || symbol.hasPrefix("play") ? Color(red: 1, green: 0.9, blue: 0.43) : PixelPalette.border))
                    : AnyView(Circle().fill(.white.opacity(hovering ? 0.12 : 0))))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }
}

// MARK: - Shared

struct Artwork: View {
    let image: NSImage?
    let corner: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.isPixel ? 2 : corner).fill(.white.opacity(0.1))
            if let image {
                // Khung luôn giữ đúng kích thước (ảnh không làm giãn khung). Ảnh ngang kiểu video
                // (YouTube 16:9): hiện trọn khung hình, nền là chính ảnh làm mờ; ảnh vuông thì lấp đầy.
                Group {
                    if image.size.width > image.size.height * 1.15 {
                        Color.clear
                            .overlay(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                .blur(radius: 8).opacity(0.7))
                            .overlay(Image(nsImage: image).resizable().aspectRatio(contentMode: .fit))
                    } else {
                        Color.clear
                            .overlay(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill))
                    }
                }
                .transition(.opacity)
            } else {
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.isPixel ? 2 : corner))
        // Pixel: giữ ảnh bìa nguyên nét (pixel hoá ảnh chụp thật trông như vỡ ảnh), chỉ thêm khung vuông.
        .overlay(Theme.isPixel ? RoundedRectangle(cornerRadius: 2).strokeBorder(PixelPalette.border, lineWidth: 4) : nil)
        .background(Theme.isPixel ? Rectangle().fill(PixelPalette.shadow).offset(x: 4, y: 4) : nil)
        .animation(.easeOut(duration: 0.25), value: image)
    }
}

/// Sóng nhạc bằng Core Animation: animation chạy trong render server, app không phải
/// dựng lại view mỗi frame (bản SwiftUI repeatForever tốn ~7–15% CPU khi đang phát).
struct EqualizerBars: NSViewRepresentable {
    let active: Bool
    let color: Color

    func makeNSView(context: Context) -> EqualizerLayerView { EqualizerLayerView() }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.update(color: NSColor(color), active: active)
    }
}

final class EqualizerLayerView: NSView {
    /// Sóng giả lập: mỗi cột đi qua nhiều độ cao, nội suy cong (chậm, mượt), các cột lệch nhịp nhau.
    private static let levels: [[Double]] = [
        [0.35, 0.8, 0.5, 0.95, 0.4, 0.7, 0.35],
        [0.6, 0.35, 0.9, 0.55, 0.75, 0.4, 0.6],
        [0.45, 0.95, 0.6, 0.4, 0.85, 0.5, 0.45],
        [0.7, 0.45, 0.75, 0.95, 0.5, 0.35, 0.7],
    ]
    private static let periods: [Double] = [2.6, 3.1, 2.8, 3.4]
    private static var barWidth: CGFloat { Theme.isVanGogh ? 2.8 : 2 }
    private static let gap: CGFloat = 1.5, barHeight: CGFloat = 9
    private var bars: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = Theme.isPixel ? 0 : Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = Self.barWidth * 4 + Self.gap * 3
        let x0 = (bounds.width - total) / 2
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight)
            bar.position = CGPoint(x: x0 + CGFloat(i) * (Self.barWidth + Self.gap) + Self.barWidth / 2,
                                   y: bounds.midY)
        }
        CATransaction.commit()
    }

    private var active = false
    private var faking = false
    private var link: CADisplayLink?

    func update(color: NSColor, active: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if Theme.isVanGogh {
            // Vệt cọ vàng dựng đứng thay cho thanh trơn.
            for (i, bar) in bars.enumerated() {
                bar.backgroundColor = nil
                bar.cornerRadius = 0
                bar.contents = VGArt.verticalStroke(i)
                bar.contentsGravity = .resize
            }
        } else {
            bars.forEach { $0.contents = nil; $0.backgroundColor = color.cgColor }
        }
        CATransaction.commit()
        self.active = active
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    /// Đang phát + bật sóng thật: display link 30fps đọc mức âm thanh; không có dữ liệu thì giả lập.
    private func refresh() {
        let live = active && window != nil && AudioSpectrum.enabled
        if live, link == nil {
            let l = displayLink(target: self, selector: #selector(step))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            l.add(to: .main, forMode: .common)
            link = l
        } else if !live {
            link?.invalidate()
            link = nil
        }
        setFaking(active && (!live || AudioSpectrum.shared.currentLevels() == nil))
        if !active {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bars.forEach { $0.transform = CATransform3DIdentity }
            CATransaction.commit()
        }
    }

    @objc private func step() {
        guard let levels = AudioSpectrum.shared.currentLevels() else { setFaking(true); return }
        setFaking(false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() where i < levels.count {
            let level = Theme.isPixel ? (levels[i] * 4).rounded() / 4 : levels[i]
            bar.transform = CATransform3DMakeScale(1, CGFloat(0.22 + 0.78 * level), 1)
        }
        CATransaction.commit()
    }

    private func setFaking(_ on: Bool) {
        guard on != faking else { return }
        faking = on
        for (i, bar) in bars.enumerated() {
            if on {
                let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
                anim.values = Self.levels[i]
                // Pixel: cột nhảy theo nấc như đồng hồ âm lượng 8-bit.
                anim.calculationMode = Theme.isPixel ? .discrete : .cubic
                anim.duration = Self.periods[i]
                anim.timeOffset = Self.periods[i] * Double(i) / 4
                anim.repeatCount = .infinity
                anim.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
                bar.add(anim, forKey: "eq")
            } else {
                bar.removeAnimation(forKey: "eq")
            }
        }
    }
}

/// Quầng sáng mờ từ chính ảnh bìa, đặt sau artwork.
struct ArtworkGlow: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable()
                .blur(radius: 22)
                .opacity(0.55)
                .scaleEffect(1.15)
        }
    }
}

