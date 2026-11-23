import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RoostLiveBundle: WidgetBundle {
    var body: some Widget { PortalLiveActivity() }
}

/// Tiến độ gửi sang Mac: Dynamic Island (gọn, mở rộng, tối giản) và màn hình khoá.
struct PortalLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PortalActivity.self) { ctx in
            LockCard(state: ctx.state, mac: ctx.attributes.macName)
                .activityBackgroundTint(Theme.ink)
                .activitySystemActionForegroundColor(Theme.paper)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PaperPlane().frame(width: 30, height: 30).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(ctx.state)).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(Theme.paper)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(ctx.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(status(ctx.state, mac: ctx.attributes.macName)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: ctx.state.done ? 1 : ctx.state.progress).tint(tintColor(ctx.state)).padding(.horizontal, 8)
                }
            } compactLeading: {
                PaperPlane().frame(width: 18, height: 18)
            } compactTrailing: {
                if ctx.state.done { Image(systemName: "checkmark").foregroundStyle(.green) }
                else { Text(percent(ctx.state)).font(.caption2.weight(.bold)).monospacedDigit() }
            } minimal: {
                ProgressView(value: ctx.state.done ? 1 : ctx.state.progress).progressViewStyle(.circular).tint(tintColor(ctx.state))
            }
        }
    }
}

private func percent(_ s: PortalActivity.ContentState) -> String { "\(Int((s.done ? 1 : s.progress) * 100))%" }
private func tintColor(_ s: PortalActivity.ContentState) -> Color { s.failed ? .orange : (s.done ? .green : Theme.glow) }
private func status(_ s: PortalActivity.ContentState, mac: String) -> String {
    s.failed ? L("Không gửi được", "Not sent") : (s.done ? L("Đã tới \(mac)", "Arrived on \(mac)") : L("Đang gửi tới \(mac)", "Sending to \(mac)"))
}

struct LockCard: View {
    let state: PortalActivity.ContentState
    let mac: String
    var body: some View {
        HStack(spacing: 14) {
            NotchMark().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.paper).lineLimit(1)
                    Spacer()
                    Text(percent(state)).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(Theme.paper)
                }
                ProgressView(value: state.done ? 1 : state.progress).tint(tintColor(state))
                Text(status(state, mac: mac)).font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(16)
    }
}
