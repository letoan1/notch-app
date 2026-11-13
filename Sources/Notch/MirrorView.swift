import SwiftUI

/// Tab gương: soi webcam + cuộc họp sắp tới + đèn viền màn hình (rọi sáng mặt khi gọi video).
struct MirrorView: View {
    @ObservedObject var camera: CameraMirror
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var edge = EdgeLight.shared

    var body: some View {
        HStack(spacing: 16) {
            preview
                .frame(width: 300)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Sẵn sàng họp?", "Ready for the call?"))
                    .font(.ui(15, weight: .bold))
                    .foregroundStyle(.white)
                meeting
                Spacer(minLength: 0)
                MirrorButton(title: camera.mirrored ? L("Lật: gương", "Flip: mirror") : L("Lật: thật", "Flip: true view"),
                             symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                             active: false) {
                    camera.mirrored.toggle()
                }
                .help(camera.mirrored ? L("Đang soi kiểu gương (như Photo Booth)", "Mirrored, like Photo Booth") : L("Đang hiện như người khác nhìn thấy", "As others see you"))
                MirrorButton(title: edge.level.title,
                             symbol: edge.isOn ? "lightbulb.fill" : "lightbulb",
                             active: edge.isOn) {
                    edge.cycle()
                }
                .help(L("Viền sáng quanh màn hình để rọi mặt khi gọi video · bấm để đổi mức / tắt", "A glowing screen border that lights your face on calls · click to change level / turn off"))
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var preview: some View {
        switch camera.access {
        case .granted:
            CameraPreview(session: camera.session, cornerRadius: 18, mirrored: camera.mirrored)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15), lineWidth: 1))
        case .notDetermined:
            placeholder(icon: "camera.fill", text: L("Bật camera để soi gương", "Turn on the camera"), action: camera.requestAccess)
        case .denied:
            placeholder(icon: "camera.badge.ellipsis", text: L("Mở Cài đặt để cấp quyền camera", "Open Settings to allow camera access"),
                        action: camera.openPrivacySettings)
        }
    }

    private func placeholder(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(0.07))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: icon).font(.ui(24))
                        Text(text).font(.ui(12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                )
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var meeting: some View {
        if let next = calendar.nextEvent {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(next.color).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.title)
                        .font(.ui(12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(Self.timeText(next))
                        .font(.ui(11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                if let link = next.meeting {
                    Spacer(minLength: 4)
                    JoinButton(meeting: link, prominent: true)
                }
            }
        } else {
            Text(calendar.access == .granted ? L("Hôm nay không còn cuộc họp nào", "No more meetings today") : L("Soi lại trước khi lên hình", "Check yourself before going on camera"))
                .font(.ui(12))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func timeText(_ item: CalendarStore.Item) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let minutes = Int(item.start.timeIntervalSinceNow / 60)
        if minutes <= 0 { return L("Đang diễn ra · đến \(f.string(from: item.end))", "Now · until \(f.string(from: item.end))") }
        if minutes < 60 { return L("Sau \(minutes) phút · \(f.string(from: item.start))", "In \(minutes) min · \(f.string(from: item.start))") }
        return "\(f.string(from: item.start)) – \(f.string(from: item.end))"
    }
}

private struct MirrorButton: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void

    private let warm = Color(red: 1.0, green: 0.86, blue: 0.55)

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.ui(12, weight: .semibold))
                .foregroundStyle(active ? Color(white: 0.12) : .white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ThemedBackground(fill: active ? warm : .white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
