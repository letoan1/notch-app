import SwiftUI

struct PermissionCard: View {
    let request: PermissionRequest
    let pending: Int
    let decide: (PermissionDecision) -> Void

    private let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .foregroundStyle(claude)
                Text(L("Claude xin quyền", "Claude needs permission"))
                    .foregroundStyle(.white)
                Text("· \(request.project)")
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if pending > 1 {
                    Text("+\(pending - 1)")
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
            }
            .font(.ui(12, weight: .semibold))
            .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(request.tool)
                    .font(.ui(10, weight: .bold))
                    .foregroundStyle(claude)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(claude.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    if let detail = request.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.ui(11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Text(request.summary)
                        .font(.ui(11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(request.detail == nil ? 2 : 1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                Button(L("Từ chối", "Deny")) { decide(.deny) }
                    .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1), text: .white.opacity(0.8)))
                if request.canAlwaysAllow {
                    Button(L("Luôn cho phép", "Always allow")) { decide(.allowAlways) }
                        .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1), text: .white))
                }
                Button(L("Cho phép", "Allow")) { decide(.allow) }
                    .buttonStyle(PillButtonStyle(fill: claude, text: .white))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }
}

struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, weight: .semibold))
            .foregroundStyle(Theme.isCassette ? CassettePalette.ink : text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(ThemedBackground(fill: fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Capsule())
    }
}
