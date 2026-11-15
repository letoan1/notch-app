import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bộ khung giao diện Cài đặt: thanh bên có icon màu, trang cuộn với các thẻ bo tròn, mỗi dòng có icon nét,
/// tiêu đề, mô tả ngắn và điều khiển bên phải.
enum SUI {
    /// Màu nhấn riêng của cửa sổ Cài đặt (tím dịu), không phụ thuộc màu nhấn hệ thống.
    static let accent = Color(red: 0.55, green: 0.44, blue: 0.9)
    static let sidebarWidth: CGFloat = 232
    static let contentWidth: CGFloat = 640
    static let windowSize = CGSize(width: 920, height: 680)
}

// MARK: - Trang và thẻ

/// Trang cuộn của một mục Cài đặt.
struct SPage<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .frame(maxWidth: SUI.contentWidth, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// Một nhóm: tiêu đề đậm, nút "Đặt lại" (tuỳ chọn), thẻ nội dung và chú thích bên dưới.
struct SSection<Content: View>: View {
    let title: String?
    var note: String?
    var reset: (() -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String?, note: String? = nil, reset: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.reset = reset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || reset != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
                    Spacer()
                    if let reset { SResetButton(action: reset) }
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content }
                .background(SCardBackground())
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

struct SCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct SResetButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(L("Đặt lại mặc định", "Reset to defaults"), systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(SButtonStyle(.link))
    }
}

// MARK: - Nút

/// Bộ nút chung của Cài đặt: chính (nền tím đặc), phụ (nền tím nhạt), liên kết (chữ tím), huỷ (đỏ nhạt).
/// Cao 28 pt, bo tròn hẳn, có trạng thái rê chuột, bấm và tắt.
struct SButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, link }
    var kind: Kind
    init(_ kind: Kind = .secondary) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View {
        SButtonBody(configuration: configuration, kind: kind)
    }
}

private struct SButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SButtonStyle.Kind
    private var enabled = Environment(\.isEnabled)
    private var hover = State(initialValue: false)

    init(configuration: ButtonStyleConfiguration, kind: SButtonStyle.Kind) {
        self.configuration = configuration
        self.kind = kind
    }

    private var destructive: Bool { configuration.role == .destructive }
    private var tint: Color { destructive ? Color(red: 0.9, green: 0.27, blue: 0.25) : SUI.accent }

    var body: some View {
        let on = hover.wrappedValue && enabled.wrappedValue
        configuration.label
            .labelStyle(SButtonLabelStyle())
            .font(.system(size: 12.5, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.white : tint)
            .lineLimit(1)
            .padding(.horizontal, kind == .link ? 6 : 13)
            .frame(height: kind == .link ? 24 : 28)
            .background {
                switch kind {
                case .primary:
                    Capsule().fill(tint.opacity(configuration.isPressed ? 0.8 : on ? 0.92 : 1))
                        .shadow(color: tint.opacity(0.3), radius: on ? 4 : 2, y: 1)
                case .secondary:
                    Capsule().fill(tint.opacity(configuration.isPressed ? 0.22 : on ? 0.17 : 0.11))
                case .link:
                    Capsule().fill(tint.opacity(configuration.isPressed ? 0.14 : on ? 0.08 : 0))
                }
            }
            .contentShape(Capsule())
            .opacity(enabled.wrappedValue ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: on)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hover.wrappedValue = $0 }
            .focusEffectDisabled()
    }
}

private struct SButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

// MARK: - Ô chọn

/// Ô chọn dạng menu, mũi tên màu tím của Roost (Picker gốc của macOS theo màu nhấn hệ thống).
struct SPicker<T: Hashable>: View {
    let selection: Binding<T>
    let options: [(T, String)]

    init(_ selection: Binding<T>, _ options: [(T, String)]) {
        self.selection = selection
        self.options = options
    }

    init(_ selection: Binding<T>, _ values: [T], title: (T) -> String) {
        self.init(selection, values.map { ($0, title($0)) })
    }

    private var current: String { options.first { $0.0 == selection.wrappedValue }?.1 ?? "" }

    var body: some View {
        Menu {
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            SPickerLabel(text: current)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct SPickerLabel: View {
    let text: String
    private var enabled = Environment(\.isEnabled)
    private var hover = State(initialValue: false)

    init(text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 7) {
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(SUI.accent)
                .frame(width: 16, height: 16)
                .background(Circle().fill(SUI.accent.opacity(0.13)))
        }
        .padding(.leading, 11).padding(.trailing, 5)
        .frame(height: 28)
        .background(Capsule().fill(Color.primary.opacity(hover.wrappedValue ? 0.09 : 0.055)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07)))
        .contentShape(Capsule())
        .opacity(enabled.wrappedValue ? 1 : 0.45)
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.wrappedValue)
    }
}

/// Nút chọn liền khối: đoạn đang chọn nền tím, chữ trắng.
struct SSegmented<T: Hashable>: View {
    let selection: Binding<T>
    let options: [(T, String)]

    init(_ selection: Binding<T>, _ values: [T], title: (T) -> String) {
        self.selection = selection
        self.options = values.map { ($0, title($0)) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = selection.wrappedValue == value
                Button { withAnimation(.easeOut(duration: 0.15)) { selection.wrappedValue = value } } label: {
                    Text(title)
                        .font(.system(size: 12, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(on ? SUI.accent : Color.clear)
                            .shadow(color: on ? SUI.accent.opacity(0.3) : .clear, radius: 2, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Dòng cài đặt: icon nét bên trái, tiêu đề + mô tả, điều khiển bên phải. Đường kẻ phía trên (trừ dòng đầu thẻ).
struct SRow<Control: View>: View {
    let icon: String
    let title: String
    var detail: String?
    var divider: Bool
    @ViewBuilder let control: Control

    init(_ icon: String, _ title: String, detail: String? = nil, divider: Bool = true,
         @ViewBuilder control: () -> Control) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.divider = divider
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.leading, 56) }
        }
    }
}

/// Dòng bật/tắt (trường hợp thường gặp nhất).
struct SToggleRow: View {
    let icon: String
    let title: String
    var detail: String?
    var divider = true
    @Binding var isOn: Bool

    var body: some View {
        SRow(icon, title, detail: detail, divider: divider) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).tint(SUI.accent)
        }
    }
}

/// Nội dung tự do trong thẻ (ô xem trước, danh sách…), có đường kẻ phía trên nếu cần.
struct SBlock<Content: View>: View {
    var divider = true
    var padding: CGFloat = 14
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .overlay(alignment: .top) {
                if divider { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 16) }
            }
    }
}

// MARK: - Ô chọn có hình xem trước

/// Một lựa chọn dạng thẻ: hình xem trước ở trên, tên và mô tả ngắn ở dưới, viền màu nhấn khi đang chọn.
struct SChoiceCard<Preview: View>: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    var height: CGFloat = 86
    let action: () -> Void
    @ViewBuilder let preview: Preview
    private var hover = State(initialValue: false)

    init(title: String, subtitle: String? = nil, selected: Bool, height: CGFloat = 86,
         action: @escaping () -> Void, @ViewBuilder preview: () -> Preview) {
        self.title = title
        self.subtitle = subtitle
        self.selected = selected
        self.height = height
        self.action = action
        self.preview = preview()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
                VStack(spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? SUI.accent : .primary)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? SUI.accent : Color.primary.opacity(hover.wrappedValue ? 0.2 : 0.1),
                              lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, SUI.accent)
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(hover.wrappedValue ? 0.1 : 0.04), radius: hover.wrappedValue ? 6 : 2, y: 1)
            .scaleEffect(hover.wrappedValue && !selected ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.wrappedValue)
    }
}

/// Nền giả hình nền desktop cho các ô xem trước notch.
struct SWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.86), Color(red: 0.62, green: 0.46, blue: 0.82),
                                Color(red: 0.92, green: 0.6, blue: 0.62)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Thanh bên

/// Icon thanh bên: ký hiệu trắng trên ô vuông bo tròn có màu.
struct SIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.92), color], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
    }
}

struct SSidebarItem: View {
    let pane: SettingsWindowController.PaneID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                SIconTile(symbol: pane.symbol, color: pane.tint)
                Text(pane.title)
                    .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SUI.accent.opacity(0.85))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Kéo thả để đổi thứ tự

/// Thả một chip lên chip khác: chuyển chip đang kéo tới vị trí đó.
struct SReorderDrop<Item: Equatable>: DropDelegate {
    let item: Item
    @Binding var items: [Item]
    @Binding var dragging: Item?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = items.firstIndex(of: dragging), let to = items.firstIndex(of: item) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
