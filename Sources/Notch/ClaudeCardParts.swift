import SwiftUI

/// Mảnh dùng chung cho thẻ Claude (xin quyền, câu hỏi, kế hoạch) ở cả 3 giao diện.
enum ClaudeInk {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    /// Chữ chính / phụ: nền tối (Mặc định, Pixel, bảng ghim) hoặc giấy Cassette.
    static func primary(_ paper: Bool) -> Color { paper ? CassettePalette.ink : .white }
    static func secondary(_ paper: Bool) -> Color { paper ? CassettePalette.faded : .white.opacity(0.55) }

    static func font(_ size: CGFloat, paper: Bool, bold: Bool = false) -> Font {
        paper ? .typewriter(size, bold: bold) : .ui(size, weight: bold ? .semibold : .regular)
    }
}

/// Nguồn gốc yêu cầu: thư mục project, phiên, app đang chạy Claude Code. Rê chuột để xem đường dẫn đầy đủ.
struct OriginRow: View {
    let request: PermissionRequest
    var paper = false
    var size: CGFloat = 10.5

    var body: some View {
        HStack(spacing: 10) {
            item("folder.fill", request.project.isEmpty ? "?" : request.project, bold: true)
            item("text.bubble.fill", request.sessionLabel)
                .layoutPriority(-1)
            if let host = request.host {
                HStack(spacing: 4) {
                    if let icon = host.icon, !Theme.isPixel {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: size + 3, height: size + 3)
                    } else {
                        Image(systemName: "macwindow").font(.system(size: size - 1))
                    }
                    Text(host.name).font(ClaudeInk.font(size, paper: paper))
                }
                .foregroundStyle(ClaudeInk.secondary(paper))
                .fixedSize()
            }
        }
        .lineLimit(1)
        .help(request.originHelp)
    }

    private func item(_ symbol: String, _ text: String, bold: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: size - 1.5))
                .foregroundStyle(paper ? CassettePalette.marker.opacity(0.8) : ClaudeInk.claude.opacity(0.85))
            Text(text)
                .font(ClaudeInk.font(size, paper: paper, bold: bold))
                .foregroundStyle(bold ? ClaudeInk.primary(paper).opacity(paper ? 1 : 0.85) : ClaudeInk.secondary(paper))
                .truncationMode(.tail)
        }
    }
}

/// Đếm ngược tới lúc hook bỏ cuộc: vòng mảnh (Mặc định), thanh đốt (Pixel), chữ mực đỏ (Cassette).
struct CountdownBadge: View {
    let request: PermissionRequest
    var paper = false

    var body: some View {
        if request.state.isWaiting {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, request.deadline.timeIntervalSince(context.date))
                let ratio = request.timeout > 0 ? left / request.timeout : 0
                content(left: Int(left.rounded(.up)), ratio: ratio)
            }
            .help(L("Hết giờ thì Claude hỏi lại ở terminal / VS Code như bình thường.", "When time runs out, Claude asks in the terminal / VS Code as usual."))
        }
    }

    @ViewBuilder private func content(left: Int, ratio: Double) -> some View {
        let urgent = left <= 15
        let tint: Color = urgent ? (paper ? CassettePalette.marker : .orange) : (paper ? CassettePalette.faded : .white.opacity(0.5))
        let text = left > 0 ? L("còn \(left) giây", "\(left)s left") : L("hết giờ", "timed out")
        HStack(spacing: 5) {
            if paper {
                EmptyView()
            } else if Theme.isPixel {
                PixelSegments(ratio: ratio, accent: urgent ? .orange : PixelPalette.pink, count: 8)
                    .frame(width: 40, height: 7)
            } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: ratio)
                        .stroke(urgent ? Color.orange : ClaudeInk.claude, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: ratio)
                }
                .frame(width: 11, height: 11)
            }
            Text(text)
                .font(paper ? .typewriter(11) : .ui(10, weight: .medium).monospacedDigit())
                .foregroundStyle(tint)
        }
        .fixedSize()
    }
}

/// Kết quả sau khi bấm / khi thẻ bị gỡ ở nơi khác, hiện ~1 s trước khi thẻ rời đi.
struct StateBanner: View {
    let state: RequestState
    var paper = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
            Text(state.title)
        }
        .font(paper ? .typewriter(13, bold: true) : .ui(12, weight: .semibold))
        .foregroundStyle(paper ? CassettePalette.ink : Color(nsColor: state.color))
        .lineLimit(1)
        .transition(.opacity)
    }
}

/// Nút đưa app đang chạy phiên (VS Code, Terminal…) lên trước. Ẩn khi không rõ app.
struct HostButton: View {
    let request: PermissionRequest
    let open: () -> Void
    var paper = false

    var body: some View {
        if let host = request.host {
            Button(action: open) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                    Text(L("Mở \(host.name)", "Open \(host.name)"))
                }
            }
            .buttonStyle(PillButtonStyle(fill: .white.opacity(0.08), text: .white.opacity(0.65)))
            .help(host.isCodeEditor
                  ? L("Đưa cửa sổ \(host.name) của \(request.project) lên trước", "Bring the \(host.name) window for \(request.project) to the front")
                  : L("Đưa \(host.name) lên trước", "Bring \(host.name) to the front"))
        }
    }
}

/// Dòng nói rõ "Luôn cho phép" sẽ làm gì, hiện trước khi bấm.
struct ScopeLine: View {
    let request: PermissionRequest
    var paper = false

    var body: some View {
        if request.state.isWaiting {
            if let scope = request.allowScope {
                HStack(spacing: 4) {
                    Image(systemName: scope.isSession ? "clock" : "doc.badge.gearshape")
                    Text(L("Luôn cho phép: ", "Always allow: "))
                        + Text(scope.what).font(paper ? .typewriter(10.5, bold: true) : .ui(10, design: .monospaced))
                        + Text(L(", \(scope.whereText)", ", \(scope.whereText)"))
                }
                .font(paper ? .typewriter(10.5) : .ui(10))
                .foregroundStyle(ClaudeInk.secondary(paper))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(scope.sentence + (scope.fileURL.map { "\n" + $0.path } ?? ""))
            } else if request.kind == .tool {
                Text(L("Claude không gợi ý luật nào cho yêu cầu này nên không có nút Luôn cho phép.", "Claude suggested no rule for this request, so there is no Always allow button."))
                    .font(paper ? .typewriter(10.5) : .ui(10))
                    .foregroundStyle(ClaudeInk.secondary(paper).opacity(0.8))
                    .lineLimit(1)
            }
        }
    }
}

/// Tooltip cho nút "Luôn cho phép".
extension PermissionRequest {
    /// Kế hoạch: gợi ý thường là đổi chế độ (vd. tự nhận sửa file) nên ghi rõ thay vì "Luôn cho phép".
    var alwaysTitle: String {
        guard kind == .plan, let scope = allowScope else { return L("Luôn cho phép", "Always allow") }
        return L("Duyệt và \(scope.what)", "Approve and \(scope.what)")
    }

    var alwaysHelp: String {
        guard let scope = allowScope else { return "" }
        return scope.sentence + (scope.isSession ? "" : L(" Gỡ được trong Cài đặt › Claude Code.", " You can revoke it in Settings › Claude Code."))
    }
}
