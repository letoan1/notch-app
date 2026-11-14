import SwiftUI

/// Thẻ xin quyền / duyệt kế hoạch cho giao diện Mặc định và Pixel.
struct PermissionCard: View {
    let request: PermissionRequest
    let pending: Int
    let decide: (PermissionDecision) -> Void

    private let claude = ClaudeInk.claude
    private var waiting: Bool { request.state.isWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: request.kindSymbol)
                    .foregroundStyle(claude)
                Text(request.kindTitle)
                    .foregroundStyle(.white)
                if request.kind == .tool {
                    Text(request.tool)
                        .font(.ui(10, weight: .bold))
                        .foregroundStyle(claude)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(claude.opacity(0.18)))
                }
                Spacer(minLength: 8)
                CountdownBadge(request: request)
            }
            .font(.ui(12, weight: .semibold))
            .lineLimit(1)

            OriginRow(request: request)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.summary.isEmpty ? " " : request.summary)
                    .font(request.kind == .plan ? .ui(12, weight: .semibold) : .ui(11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(request.detail == nil ? 2 : 1)
                    .truncationMode(.middle)
                    .help(request.summary)
                if let detail = request.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.ui(10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 7).fill(.white.opacity(0.06)))
            .opacity(waiting ? 1 : 0.5)

            Spacer(minLength: 0)

            ScopeLine(request: request)

            HStack(spacing: 8) {
                HostButton(request: request) { PermissionCenter.active?.openHost(request) }
                Spacer()
                if waiting {
                    Button(request.kind == .plan ? L("Chưa duyệt", "Keep planning") : L("Từ chối", "Deny")) { decide(.deny) }
                        .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1), text: .white.opacity(0.8)))
                    if request.canAlwaysAllow {
                        Button(request.alwaysTitle) { decide(.allowAlways) }
                            .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1), text: .white))
                            .help(request.alwaysHelp)
                    }
                    Button(request.kind == .plan ? L("Duyệt kế hoạch", "Approve plan") : L("Cho phép", "Allow")) { decide(.allow) }
                        .buttonStyle(PillButtonStyle(fill: claude, text: .white))
                } else {
                    StateBanner(state: request.state)
                }
            }
            .animation(.easeOut(duration: 0.15), value: waiting)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        // Van Gogh: nút chính màu cam Claude thành vàng nét cọ, chữ mực.
        let main = Theme.isVanGogh && fill == ClaudeInk.claude
        return configuration.label
            .font(.ui(12, weight: .semibold))
            .foregroundStyle(Theme.isCassette ? CassettePalette.ink : main ? VG.ink : text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(ThemedBackground(fill: main ? VG.yellow : fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Capsule())
    }
}
