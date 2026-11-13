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
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(claude)
                Text(L("Claude hỏi", "Claude asks")).foregroundStyle(.white)
                Text("· \(request.project)").foregroundStyle(.white.opacity(0.5))
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(claude)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(claude.opacity(0.18)))
                }
                Spacer()
                if questions.count > 1 {
                    Text("\(index.wrappedValue + 1)/\(questions.count)")
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)

            Text(question.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if typing.wrappedValue {
                VStack(alignment: .leading, spacing: 5) {
                    TextField(L("Nhập câu trả lời của bạn…", "Type your answer…"), text: otherText.projectedValue)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(claude.opacity(0.8), lineWidth: 1))
                        .focused(focused.projectedValue)
                        .onSubmit { submitOther() }
                        .onExitCommand { typing.wrappedValue = false }
                    Text(question.multiSelect && !picked.wrappedValue.isEmpty
                         ? L("Gửi kèm \(picked.wrappedValue.count) lựa chọn đã tích · Enter để gửi · Esc để quay lại", "Sends with \(picked.wrappedValue.count) checked option(s) · Enter to send · Esc to go back")
                         : L("Enter để gửi · Esc để quay lại", "Enter to send · Esc to go back"))
                        .font(.system(size: 10))
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

            HStack {
                Button(L("Trả lời trong VS Code", "Answer in VS Code"), action: dismiss)
                    .buttonStyle(PillButtonStyle(fill: .white.opacity(0.08), text: .white.opacity(0.6)))
                    .help(L("Ẩn thẻ này; dùng hộp thoại gốc", "Hide this card and use the original dialog"))
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
        NSApp.windows.first { $0 is NotchPanel }?.makeKey()
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
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? accent : .white.opacity(0.4))
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
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
                    .fill(selected ? accent.opacity(0.25) : .white.opacity(hover.wrappedValue ? 0.13 : 0.07))
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? accent : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .help(option.description)
    }
}
