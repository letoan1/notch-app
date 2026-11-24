import AppKit
import SwiftUI

// Rái: linh thú của Chirp (rái cá ôm thẻ từ), port từ chirp/src/components/rai.tsx.
// Vẽ trong hệ toạ độ 160×160 giống viewBox của SVG gốc rồi thu theo `size`. Màu cố định, không theo theme.
// Hoạt ảnh chỉ chạy khi view đang hiện (notch mở); `animated: false` cho chỗ nhỏ hoặc luôn hiện.

enum RaiPose: String, CaseIterable {
    case wave, card, think, listen, speak, yay, oops, sleep
}

private enum RaiColor {
    static let ink = Color(hex: 0x233044)
    static let orange = Color(hex: 0xFF9F43)
    static let teal = Color(hex: 0x13A897)
    static let fur = Color(hex: 0xA8754F)
    static let dark = Color(hex: 0x7E5134)
    static let muzzle = Color(hex: 0xF4E0CD)
    static let ice = Color(hex: 0xC9D9E3)
    static let iceDark = Color(hex: 0x9FB4C2)
    static let cheek = Color(hex: 0xF0525A)
    static let sweat = Color(hex: 0x8FD3F4)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct RaiView: View {
    var pose: RaiPose = .card
    var size: CGFloat = 64
    /// Chữ trên thẻ (dáng .card).
    var word: String = "word"
    var animated: Bool = true

    /// Đổi khi đổi dáng để nhảy (yay) / vẫy (wave) chạy lại một lần.
    private var replay = State(initialValue: 0)

    private var moving: Bool { animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var frozen: Bool { pose == .sleep }
    private var fur: Color { frozen ? RaiColor.ice : RaiColor.fur }
    private var dark: Color { frozen ? RaiColor.iceDark : RaiColor.dark }

    var body: some View {
        canvas
            .frame(width: 160, height: 160)
            .scaleEffect(size / 160, anchor: .topLeading)
            .frame(width: size, height: size, alignment: .topLeading)
            .accessibilityHidden(true)
            .onChange(of: pose) { _, _ in replay.wrappedValue += 1 }
    }

    // MARK: - Khung chuyển động toàn thân

    @ViewBuilder private var canvas: some View {
        if !moving || pose == .sleep {
            figure
        } else if pose == .yay {
            figure.keyframeAnimator(initialValue: Hop(), trigger: replay.wrappedValue) { v, h in
                v.scaleEffect(x: h.sx, y: h.sy, anchor: UnitPoint(x: 0.5, y: 150.0 / 160)).offset(y: h.y)
            } keyframes: { _ in
                // cubic-bezier(0.2, 0.9, 0.3, 1.2), 700ms: lún, bật lên 14pt, chạm đất hơi bẹt.
                KeyframeTrack(\Hop.y) {
                    CubicKeyframe(2, duration: 0.14)
                    CubicKeyframe(-14, duration: 0.175)
                    CubicKeyframe(0, duration: 0.175)
                    CubicKeyframe(0, duration: 0.21)
                }
                KeyframeTrack(\Hop.sx) {
                    CubicKeyframe(1.06, duration: 0.14)
                    CubicKeyframe(0.97, duration: 0.175)
                    CubicKeyframe(1.03, duration: 0.175)
                    CubicKeyframe(1, duration: 0.21)
                }
                KeyframeTrack(\Hop.sy) {
                    CubicKeyframe(0.94, duration: 0.14)
                    CubicKeyframe(1.04, duration: 0.175)
                    CubicKeyframe(0.97, duration: 0.175)
                    CubicKeyframe(1, duration: 0.21)
                }
            }
        } else {
            // Nhấp nhô 3px, chu kỳ 3.2s.
            figure.keyframeAnimator(initialValue: 0.0, repeating: true) { v, y in
                v.offset(y: y)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    CubicKeyframe(-3, duration: 1.6)
                    CubicKeyframe(0, duration: 1.6)
                }
            }
        }
    }

    private struct Hop { var y: CGFloat = 0; var sx: CGFloat = 1; var sy: CGFloat = 1 }

    // MARK: - Hình

    private var figure: some View {
        ZStack(alignment: .topLeading) {
            // đuôi, thân, chân
            shape { p in
                p.move(to: pt(108, 128))
                p.addQuadCurve(to: pt(148, 106), control: pt(142, 132))
                p.addQuadCurve(to: pt(142, 134), control: pt(152, 120))
                p.addQuadCurve(to: pt(102, 142), control: pt(128, 148))
                p.closeSubpath()
            }.fill(dark)
            ellipse(80, 122, 36, 28).fill(fur)
            ellipse(80, 128, 22, 16).fill(RaiColor.muzzle)
            ellipse(62, 148, 11, 6).fill(dark)
            ellipse(98, 148, 11, 6).fill(dark)
            // đầu
            ellipse(40, 54, 7, 7).fill(dark)
            ellipse(120, 54, 7, 7).fill(dark)
            ellipse(80, 68, 44, 35).fill(fur)
            ellipse(80, 82, 31, 18).fill(RaiColor.muzzle)
            shape { p in
                p.move(to: pt(73, 74))
                p.addQuadCurve(to: pt(87, 74), control: pt(80, 70))
                p.addQuadCurve(to: pt(80, 82), control: pt(85, 81))
                p.addQuadCurve(to: pt(73, 74), control: pt(75, 81))
            }.fill(RaiColor.ink)
            shape { p in
                p.move(to: pt(58, 82)); p.addLine(to: pt(36, 82))
                p.move(to: pt(58, 88)); p.addLine(to: pt(38, 93))
                p.move(to: pt(102, 82)); p.addLine(to: pt(124, 82))
                p.move(to: pt(102, 88)); p.addLine(to: pt(122, 93))
            }.stroke(RaiColor.ink.opacity(0.55), style: cap(1.8))

            poseLayer
        }
        .frame(width: 160, height: 160, alignment: .topLeading)
    }

    @ViewBuilder private var poseLayer: some View {
        switch pose {
        case .wave:
            ZStack(alignment: .topLeading) {
                eye(62, 62); eye(98, 62); smile; cheeks
                ellipse(64, 108, 9, 7).fill(fur)
                waveArm
            }
        case .card:
            ZStack(alignment: .topLeading) {
                eye(62, 62); eye(98, 62); smile; cheeks
                card(word, size: word.count > 7 ? 9 : 12)
                paws(52, 108, 114)
            }
        case .think:
            ZStack(alignment: .topLeading) {
                eye(62, 62, px: 3, py: -3); eye(98, 62, px: 3, py: -3); cheeks
                line(75, 90, 85, 90).stroke(RaiColor.ink, style: cap(3))
                card("?", color: RaiColor.orange, size: 20)
                paws(52, 108, 114)
            }
        case .listen:
            ZStack(alignment: .topLeading) {
                eye(62, 62, closed: true); eye(98, 62, closed: true); smile; cheeks
                paws(64, 96, 108)
                shape { p in
                    p.move(to: pt(34, 60)); p.addQuadCurve(to: pt(126, 60), control: pt(80, 0))
                }.stroke(RaiColor.orange, style: cap(7))
                rect(26, 50, 16, 26, r: 7).fill(RaiColor.ink)
                rect(118, 50, 16, 26, r: 7).fill(RaiColor.ink)
            }
        case .speak:
            ZStack(alignment: .topLeading) {
                eye(62, 62); eye(98, 62); cheeks
                paws(64, 96, 108)
                ellipse(80, 92, 6, 7).fill(RaiColor.ink)
                rect(112, 14, 40, 28, r: 10).fill(RaiColor.teal)
                shape { p in
                    p.move(to: pt(120, 40)); p.addLine(to: pt(114, 50)); p.addLine(to: pt(128, 42)); p.closeSubpath()
                }.fill(RaiColor.teal)
                label("Hi", x: 132, y: 28, size: 14, color: .white)
            }
        case .yay:
            ZStack(alignment: .topLeading) {
                shape { p in
                    p.move(to: pt(54, 106)); p.addLine(to: pt(32, 74))
                    p.move(to: pt(106, 106)); p.addLine(to: pt(128, 74))
                }.stroke(fur, style: cap(13))
                ellipse(30, 70, 9, 9).fill(fur)
                ellipse(130, 70, 9, 9).fill(fur)
                eye(62, 62, closed: true); eye(98, 62, closed: true)
                shape { p in
                    p.move(to: pt(73, 87)); p.addQuadCurve(to: pt(87, 87), control: pt(80, 100)); p.closeSubpath()
                }.fill(RaiColor.ink)
                cheeks
                sparkles
            }
        case .oops:
            ZStack(alignment: .topLeading) {
                eye(62, 62); eye(98, 62); cheeks
                shape { p in
                    p.move(to: pt(73, 90)); p.addQuadCurve(to: pt(87, 90), control: pt(80, 86))
                }.stroke(RaiColor.ink, style: cap(3))
                ellipse(96, 108, 9, 7).fill(fur)
                shape { p in
                    p.move(to: pt(50, 112)); p.addQuadCurve(to: pt(30, 56), control: pt(22, 92))
                }.stroke(fur, style: cap(13))
                ellipse(34, 50, 9, 9).fill(fur)
                shape { p in
                    p.move(to: pt(128, 40))
                    p.addQuadCurve(to: pt(128, 54), control: pt(134, 50))
                    p.addQuadCurve(to: pt(128, 40), control: pt(122, 50))
                }.fill(RaiColor.sweat)
            }
        case .sleep:
            ZStack(alignment: .topLeading) {
                eye(62, 64, closed: true); eye(98, 64, closed: true); smile
                paws(64, 96, 108)
                shape { p in
                    p.move(to: pt(38, 96))
                    p.addQuadCurve(to: pt(122, 96), control: pt(80, 116))
                    p.addLine(to: pt(120, 110))
                    p.addQuadCurve(to: pt(40, 110), control: pt(80, 130))
                    p.closeSubpath()
                }.fill(RaiColor.orange)
                rect(100, 106, 12, 24, r: 5).fill(RaiColor.orange)
                shape { p in
                    p.move(to: pt(42, 30)); p.addLine(to: pt(50, 24))
                    p.move(to: pt(114, 22)); p.addLine(to: pt(121, 29))
                    p.move(to: pt(132, 46)); p.addLine(to: pt(141, 44))
                }.stroke(.white, style: cap(4))
                label("z", x: 137, y: 24, size: 16, color: RaiColor.iceDark)
                label("z", x: 147, y: 14, size: 12, color: RaiColor.iceDark)
            }
        }
    }

    // MARK: - Bộ phận

    private var smile: some View {
        shape { p in p.move(to: pt(74, 89)); p.addQuadCurve(to: pt(86, 89), control: pt(80, 94)) }
            .stroke(RaiColor.ink, style: cap(3))
    }

    private var cheeks: some View {
        ZStack(alignment: .topLeading) {
            ellipse(52, 78, 6, 3.5).fill(RaiColor.cheek.opacity(0.3))
            ellipse(108, 78, 6, 3.5).fill(RaiColor.cheek.opacity(0.3))
        }
    }

    private func paws(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ellipse(x1, y, 9, 7).fill(fur)
            ellipse(x2, y, 9, 7).fill(fur)
        }
    }

    /// Mắt r=9: tròng trắng, con ngươi r=6 lệch (px, py), đốm sáng. Nhắm: một nét cong.
    @ViewBuilder
    private func eye(_ x: CGFloat, _ y: CGFloat, px: CGFloat = 2, py: CGFloat = 1, closed: Bool = false) -> some View {
        let r: CGFloat = 9
        if closed {
            shape { p in
                p.move(to: pt(x - r + 2, y + 2))
                p.addQuadCurve(to: pt(x + r - 2, y + 2), control: pt(x, y - r + 3))
            }.stroke(RaiColor.ink, style: cap(3.6))
        } else {
            let open = ZStack(alignment: .topLeading) {
                ellipse(x, y, r, r).fill(.white)
                ellipse(x + px, y + py, 6, 6).fill(RaiColor.ink)
                ellipse(x + px + 2, y + py - 2, 2.2, 2.2).fill(.white)
            }
            .frame(width: 160, height: 160, alignment: .topLeading)
            if moving {
                // Chớp mắt: chu kỳ 4.5s, khép ở 95%.
                open.keyframeAnimator(initialValue: 1.0, repeating: true) { v, s in
                    v.scaleEffect(x: 1, y: s, anchor: UnitPoint(x: x / 160, y: y / 160))
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        LinearKeyframe(1, duration: 4.14)
                        CubicKeyframe(0.1, duration: 0.135)
                        CubicKeyframe(1, duration: 0.225)
                    }
                }
            } else {
                open
            }
        }
    }

    private func card(_ text: String, color: Color = RaiColor.ink, size: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            rect(52, 98, 56, 32, r: 6).fill(.white)
            rect(52, 98, 56, 32, r: 6).stroke(RaiColor.orange, lineWidth: 3)
            label(text, x: 80, y: 114, size: size, color: color, maxWidth: 52)
        }
    }

    private var waveArm: some View {
        let arm = ZStack(alignment: .topLeading) {
            line(104, 106, 128, 74).stroke(fur, style: cap(13))
            ellipse(130, 70, 9, 9).fill(fur)
        }
        .frame(width: 160, height: 160, alignment: .topLeading)
        let pivot = UnitPoint(x: 104.0 / 160, y: 106.0 / 160)
        return Group {
            if moving {
                // Vẫy 2 lần, mỗi lần 1.6s, rồi đứng yên.
                arm.keyframeAnimator(initialValue: 0.0, trigger: replay.wrappedValue) { v, deg in
                    v.rotationEffect(.degrees(deg), anchor: pivot)
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        CubicKeyframe(-14, duration: 0.24)
                        CubicKeyframe(10, duration: 0.24)
                        CubicKeyframe(-14, duration: 0.24)
                        CubicKeyframe(0, duration: 0.24)
                        LinearKeyframe(0, duration: 0.64)
                        CubicKeyframe(-14, duration: 0.24)
                        CubicKeyframe(10, duration: 0.24)
                        CubicKeyframe(-14, duration: 0.24)
                        CubicKeyframe(0, duration: 0.24)
                    }
                }
            } else {
                arm
            }
        }
    }

    private var sparkles: some View {
        let group = ZStack(alignment: .topLeading) {
            sparkle(18, 40, RaiColor.orange)
            sparkle(142, 36, RaiColor.teal)
            sparkle(80, 8, RaiColor.cheek)
            sparkle(150, 90, RaiColor.orange)
            sparkle(10, 92, RaiColor.teal)
        }
        .frame(width: 160, height: 160, alignment: .topLeading)
        return Group {
            if moving {
                group.keyframeAnimator(initialValue: 0.35, repeating: true) { v, o in
                    v.opacity(o)
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        CubicKeyframe(1, duration: 0.6)
                        CubicKeyframe(0.35, duration: 0.6)
                    }
                }
            } else {
                group
            }
        }
    }

    private func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ c: Color) -> some View {
        shape { p in
            p.move(to: pt(cx, cy - 10))
            p.addLine(to: pt(cx + 3, cy - 3)); p.addLine(to: pt(cx + 10, cy))
            p.addLine(to: pt(cx + 3, cy + 3)); p.addLine(to: pt(cx, cy + 10))
            p.addLine(to: pt(cx - 3, cy + 3)); p.addLine(to: pt(cx - 10, cy))
            p.addLine(to: pt(cx - 3, cy - 3)); p.closeSubpath()
        }.fill(c)
    }

    // MARK: - Hình học trong khung 160×160

    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private func cap(_ w: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }

    private func shape(_ build: @escaping (inout Path) -> Void) -> RaiPath { RaiPath(build: build) }

    private func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> RaiPath {
        RaiPath { $0.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)) }
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat) -> RaiPath {
        RaiPath { $0.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r)) }
    }

    private func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> RaiPath {
        RaiPath { $0.move(to: CGPoint(x: x1, y: y1)); $0.addLine(to: CGPoint(x: x2, y: y2)) }
    }

    /// Chữ đặt theo tâm (x, y). Bản web dùng Baloo 2 ExtraBold; ở đây SF Rounded heavy.
    private func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: Color, maxWidth: CGFloat = 60) -> some View {
        Text(text)
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: maxWidth)
            .position(x: x, y: y)
            .frame(width: 160, height: 160, alignment: .topLeading)
    }
}

/// Path vẽ thẳng trong toạ độ 160×160 (khung cha đã cố định 160×160).
private struct RaiPath: Shape {
    let build: (inout Path) -> Void
    func path(in rect: CGRect) -> Path {
        var p = Path()
        build(&p)
        return p
    }
}
