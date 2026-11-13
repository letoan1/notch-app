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
                Text("Sẵn sàng họp?")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                meeting
                Spacer(minLength: 0)
                MirrorButton(title: camera.mirrored ? "Lật: gương" : "Lật: thật",
                             symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                             active: false) {
                    camera.mirrored.toggle()
                }
                .help(camera.mirrored ? "Đang soi kiểu gương (như Photo Booth)" : "Đang hiện như người khác nhìn thấy")
                MirrorButton(title: edge.level.title,
                             symbol: edge.isOn ? "lightbulb.fill" : "lightbulb",
                             active: edge.isOn) {
                    edge.cycle()
                }
                .help("Viền sáng quanh màn hình để rọi mặt khi gọi video · bấm để đổi mức / tắt")
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
            placeholder(icon: "camera.fill", text: "Bật camera để soi gương", action: camera.requestAccess)
        case .denied:
            placeholder(icon: "camera.badge.ellipsis", text: "Mở Cài đặt để cấp quyền camera",
                        action: camera.openPrivacySettings)
        }
    }

    private func placeholder(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(0.07))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: icon).font(.system(size: 24))
                        Text(text).font(.system(size: 12, weight: .semibold))
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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(Self.timeText(next))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                if let link = next.meeting {
                    Spacer(minLength: 4)
                    JoinButton(meeting: link, prominent: true)
                }
            }
        } else {
            Text(calendar.access == .granted ? "Hôm nay không còn cuộc họp nào" : "Soi lại trước khi lên hình")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func timeText(_ item: CalendarStore.Item) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let minutes = Int(item.start.timeIntervalSinceNow / 60)
        if minutes <= 0 { return "Đang diễn ra · đến \(f.string(from: item.end))" }
        if minutes < 60 { return "Sau \(minutes) phút · \(f.string(from: item.start))" }
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color(white: 0.12) : .white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(active ? warm : .white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
