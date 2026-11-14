import SwiftUI

/// AskUserQuestion của Claude trên notch: lần lượt từng câu, chọn 1 → gửi ngay, chọn nhiều → bấm Gửi.
struct QuestionCard: View {
    let request: PermissionRequest
    let questions: [AskQuestion]
    let answer: ([String: String]) -> Void
    let dismiss: () -> Void

    private let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    private var index = State(initialValue: 0)
    private var answers = State(initialValue: [String: String]())
    private var picked = State(initialValue: Set<String>())
    // Ô "Khác…": gõ câu trả lời tự do.
    private var typing = State(initialValue: false)
    private var otherText = State(initialValue: "")
    private var focused = FocusState<Bool>()

    init(request: PermissionRequest, questions: [AskQuestion],
         answer: @escaping ([String: String]) -> Void, dismiss: @escaping () -> Void) {
        self.request = request
        self.questions = questions
        self.answer = answer
        self.dismiss = dismiss
    }

    private var question: AskQuestion { questions[min(index.wrappedValue, questions.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: request.kindSymbol).foregroundStyle(claude)
                    Text(request.kindTitle).foregroundStyle(.white)
                }
                .font(.ui(12, weight: .semibold))
                .fixedSize()
                OriginRow(request: request)
                Spacer(minLength: 4)
                if questions.count > 1 {
                    Text("\(index.wrappedValue + 1)/\(questions.count)")
                        .font(.ui(11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                CountdownBadge(request: request)
            }
            .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.ui(10, weight: .bold))
                        .foregroundStyle(claude)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(claude.opacity(0.18)))
                        .fixedSize()
                }
                Text(question.text)
                    .font(.ui(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !request.state.isWaiting {
                StateBanner(state: request.state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(Theme.isCassette ? 0.35 : 0.15)))
            } else if typing.wrappedValue {
                VStack(alignment: .leading, spacing: 5) {
                    TextField(L("Nhập câu trả lời của bạn…", "Type your answer…"), text: otherText.projectedValue)
                        .textFieldStyle(.plain)
                        .font(.ui(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(claude.opacity(0.8), lineWidth: 1))
                        .focused(focused.projectedValue)
                        .onSubmit { submitOther() }
                        .onExitCommand { typing.wrappedValue = false }
                    Text(question.multiSelect && !picked.wrappedValue.isEmpty
                         ? L("Gửi kèm \(picked.wrappedValue.count) lựa chọn đã tích. Enter để gửi, Esc để quay lại.", "Your \(picked.wrappedValue.count) checked option(s) go along. Press Enter to send, Esc to go back.")
                         : L("Enter để gửi, Esc để quay lại.", "Press Enter to send, Esc to go back."))
                        .font(.ui(10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .transition(.opacity)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(question.options) { option in
                        OptionTile(option: option,
                                   selected: picked.wrappedValue.contains(option.label),
                                   multi: question.multiSelect,
                                   accent: claude) { choose(option.label) }
                    }
                }
            }

            Spacer(minLength: 0)

            if request.state.isWaiting {
            HStack {
                Button(request.host.map { L("Trả lời trong \($0.name)", "Answer in \($0.name)") }
                       ?? L("Trả lời ở terminal", "Answer in the terminal"), action: dismiss)
                    .buttonStyle(PillButtonStyle(fill: .white.opacity(0.08), text: .white.opacity(0.6)))
                    .help(L("Ẩn thẻ này và mở hộp thoại gốc của Claude Code", "Hide this card and go to Claude Code's own dialog"))
                Spacer()
                if typing.wrappedValue {
                    Button(L("Gửi", "Send")) { submitOther() }
                        .buttonStyle(PillButtonStyle(fill: trimmedOther.isEmpty ? .white.opacity(0.1) : claude,
                                                     text: .white))
                        .disabled(trimmedOther.isEmpty)
                } else {
                    Button(L("Khác…", "Other…")) { startTyping() }
                        .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1), text: .white.opacity(0.85)))
                        .help(L("Gõ câu trả lời riêng", "Type your own answer"))
                }
                if question.multiSelect && !typing.wrappedValue {
                    Button(isLast ? L("Gửi", "Send") : L("Tiếp", "Next")) { commitMulti() }
                        .buttonStyle(PillButtonStyle(fill: picked.wrappedValue.isEmpty ? .white.opacity(0.1) : claude,
                                                     text: .white))
                        .disabled(picked.wrappedValue.isEmpty)
                }
            }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .animation(.easeOut(duration: 0.15), value: index.wrappedValue)
    }

    private var isLast: Bool { index.wrappedValue >= questions.count - 1 }

    private func choose(_ label: String) {
        if question.multiSelect {
            if picked.wrappedValue.contains(label) {
                picked.wrappedValue.remove(label)
            } else {
                picked.wrappedValue.insert(label)
            }
        } else {
            record(label)
        }
    }

    private func commitMulti() {
        // Giữ thứ tự như danh sách lựa chọn gốc.
        let labels = question.options.map(\.label).filter(picked.wrappedValue.contains)
        record(labels.joined(separator: ", "))
    }

    private var trimmedOther: String {
        otherText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startTyping() {
        typing.wrappedValue = true
        // Panel chỉ nhận bàn phím lúc có câu hỏi (allowsKey); makeKey để ô gõ nhận phím
        // mà không kích hoạt app (nonactivatingPanel) → VS Code vẫn là app đang dùng.
        NSApp.windows.first { ($0 as? NotchPanel)?.allowsKey == true }?.makeKey()
        DispatchQueue.main.async { focused.wrappedValue = true }
    }

    private func submitOther() {
        let text = trimmedOther
        guard !text.isEmpty else { return }
        var parts: [String] = []
        if question.multiSelect {
            parts = question.options.map(\.label).filter(picked.wrappedValue.contains)
        }
        parts.append(text)
        record(parts.joined(separator: ", "))
    }

    private func record(_ value: String) {
        var all = answers.wrappedValue
        all[question.text] = value
        answers.wrappedValue = all
        picked.wrappedValue = []
        typing.wrappedValue = false
        otherText.wrappedValue = ""
        if isLast {
            answer(all)
        } else {
            index.wrappedValue += 1
        }
    }
}

private struct OptionTile: View {
    let option: AskQuestion.Option
    let selected: Bool
    let multi: Bool
    let accent: Color
    let action: () -> Void
    private var hover = State(initialValue: false)

    init(option: AskQuestion.Option, selected: Bool, multi: Bool, accent: Color, action: @escaping () -> Void) {
        self.option = option
        self.selected = selected
        self.multi = multi
        self.accent = accent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                if multi {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.ui(11))
                        .foregroundStyle(selected ? accent : .white.opacity(0.4))
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(Theme.isCassette ? .hand(15) : .ui(12, weight: .semibold))
                        .foregroundStyle(Theme.isCassette ? CassettePalette.ink : .white)
                        .lineLimit(1)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(Theme.isCassette ? .hand(12) : .ui(10))
                            .foregroundStyle(Theme.isCassette ? CassettePalette.faded : .white.opacity(0.55))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.isCassette ? (selected ? CassettePalette.note : Color(red: 0.98, green: 0.97, blue: 0.93))
                          : (selected ? accent.opacity(0.25) : .white.opacity(hover.wrappedValue ? 0.13 : 0.07)))
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? (Theme.isCassette ? CassettePalette.marker : accent) : .clear,
                                                              lineWidth: Theme.isCassette ? 2 : 1))
            .overlay(alignment: .top) {
                if Theme.isCassette { Circle().fill(CassettePalette.marker).frame(width: 9, height: 9).offset(y: -3) }
            }
            .overlay(alignment: .trailing) {
                if Theme.isCassette && selected {
                    Image(systemName: "checkmark").font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(CassettePalette.marker).padding(.trailing, 10)
                }
            }
            .rotationEffect(.degrees(Theme.isCassette ? (option.label.count % 2 == 0 ? -1.2 : 1.2) : 0))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .help(option.description)
    }
}
