import SwiftUI

/// BOT's face. Drawn entirely in SwiftUI (blue & white), animated by conversation state:
/// idle = gentle bob + blinking, listening = glowing antenna + pulsing rings reacting to your voice,
/// thinking = eyes scanning side to side, speaking = mouth moving.
struct RobotView: View {
    var style: RobotStyle = .classic
    var eyes: EyeStyle = .round
    var mouth: MouthStyle = .bars
    var accent: Color = Color(red: 0.22, green: 0.66, blue: 0.96)
    var isDark = false
    var phase: Phase = .idle
    var level: Float = 0
    var animation: Double = 1
    var size: CGFloat = 260

    private struct Palette {
        var head: AnyShapeStyle
        var headStroke: Color
        var headStrokeWidth: CGFloat
        var visor: AnyShapeStyle
        var eye: Color
        var mouth: Color
        var ear: AnyShapeStyle
        var antenna: Color
        var ball: Color
        var vent: Color
    }

    private var palette: Palette {
        let deep = Color(red: 0.05, green: 0.20, blue: 0.58)
        let glow = Color(red: 0.74, green: 0.93, blue: 1.0)
        switch style {
        case .classic:
            return Palette(
                head: AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.88, green: 0.94, blue: 1.0)], startPoint: .top, endPoint: .bottom)),
                headStroke: accent.opacity(0.45), headStrokeWidth: 0.8,
                visor: AnyShapeStyle(LinearGradient(colors: [deep.opacity(0.95), Color(red: 0.08, green: 0.30, blue: 0.74)], startPoint: .bottom, endPoint: .top)),
                eye: glow, mouth: Color(red: 0.55, green: 0.85, blue: 1.0),
                ear: AnyShapeStyle(Color(red: 0.82, green: 0.91, blue: 1.0)),
                antenna: .white, ball: accent, vent: accent.opacity(0.45))
        case .inverted:
            return Palette(
                head: AnyShapeStyle(LinearGradient(colors: [accent, accent.opacity(0.78)], startPoint: .top, endPoint: .bottom)),
                headStroke: .white.opacity(0.35), headStrokeWidth: 0.8,
                visor: AnyShapeStyle(Color.white.opacity(0.96)),
                eye: deep, mouth: deep,
                ear: AnyShapeStyle(Color.white.opacity(0.92)),
                antenna: accent, ball: .white, vent: .white.opacity(0.7))
        case .outline:
            return Palette(
                head: AnyShapeStyle(accent.opacity(0.06)),
                headStroke: accent, headStrokeWidth: 3,
                visor: AnyShapeStyle(accent.opacity(0.16)),
                eye: accent, mouth: accent,
                ear: AnyShapeStyle(accent.opacity(0.8)),
                antenna: accent, ball: accent, vent: accent.opacity(0.6))
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            robot(t: ctx.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Composition

    @ViewBuilder
    private func robot(t: Double) -> some View {
        let u = size / 100
        let k = CGFloat(animation)
        let lvl = CGFloat(level)
        let p = palette
        let bob = CGFloat(sin(t * 1.5)) * 1.3 * u * k
            + (phase == .speaking ? CGFloat(sin(t * 8)) * 0.5 * u * k : 0)

        ZStack {
            rings(t: t, u: u, k: k, lvl: lvl)
            ZStack {
                antenna(t: t, u: u, k: k, lvl: lvl, p: p)
                ears(u: u, k: k, lvl: lvl, p: p)
                head(u: u, p: p)
                visor(u: u, p: p)
                eyesView(t: t, u: u, k: k, lvl: lvl, p: p)
                mouthView(t: t, u: u, k: k, lvl: lvl, p: p)
                vents(u: u, p: p)
            }
            .frame(width: size, height: size)
            .offset(y: bob)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func rings(t: Double, u: CGFloat, k: CGFloat, lvl: CGFloat) -> some View {
        if phase == .listening && k > 0 {
            ForEach(0..<2, id: \.self) { i in
                let pp = (t * 0.75 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(accent.opacity((1 - pp) * (0.25 + Double(lvl) * 0.6)), lineWidth: 1.6 * u)
                    .frame(width: size * CGFloat(0.62 + pp * 0.38), height: size * CGFloat(0.62 + pp * 0.38))
            }
        }
    }

    @ViewBuilder
    private func antenna(t: Double, u: CGFloat, k: CGFloat, lvl: CGFloat, p: Palette) -> some View {
        let thinkingPulse = phase == .thinking ? 0.5 + 0.5 * sin(t * 6) : 1
        let glowRadius: CGFloat = phase == .listening ? (3 + lvl * 12) * u * k : (phase == .speaking ? 4 * u * k : 1.5 * u)
        Rectangle().fill(p.antenna)
            .frame(width: 1.8 * u, height: 12 * u)
            .position(x: 50 * u, y: 16 * u)
        Circle().fill(p.ball)
            .frame(width: 9 * u, height: 9 * u)
            .opacity(thinkingPulse)
            .shadow(color: p.ball.opacity(0.9), radius: glowRadius)
            .position(x: 50 * u, y: 10 * u)
    }

    @ViewBuilder
    private func ears(u: CGFloat, k: CGFloat, lvl: CGFloat, p: Palette) -> some View {
        let pulse = phase == .listening ? 1 + lvl * 0.45 * k : 1
        ForEach([CGFloat(11), CGFloat(89)], id: \.self) { x in
            RoundedRectangle(cornerRadius: 3.5 * u, style: .continuous)
                .fill(p.ear)
                .frame(width: 8 * u, height: 20 * u)
                .scaleEffect(x: 1, y: pulse)
                .position(x: x * u, y: 54 * u)
        }
    }

    @ViewBuilder
    private func head(u: CGFloat, p: Palette) -> some View {
        RoundedRectangle(cornerRadius: 21 * u, style: .continuous)
            .fill(p.head)
            .overlay(RoundedRectangle(cornerRadius: 21 * u, style: .continuous)
                .stroke(p.headStroke, lineWidth: p.headStrokeWidth * u))
            .frame(width: 70 * u, height: 62 * u)
            .shadow(color: .black.opacity(isDark ? 0.45 : 0.16), radius: 7 * u, x: 0, y: 4 * u)
            .position(x: 50 * u, y: 54 * u)
    }

    @ViewBuilder
    private func visor(u: CGFloat, p: Palette) -> some View {
        RoundedRectangle(cornerRadius: 14 * u, style: .continuous)
            .fill(p.visor)
            .frame(width: 54 * u, height: 34 * u)
            .position(x: 50 * u, y: 47 * u)
    }

    @ViewBuilder
    private func vents(u: CGFloat, p: Palette) -> some View {
        HStack(spacing: 2.4 * u) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule().fill(p.vent).frame(width: 4.4 * u, height: 2.6 * u)
            }
        }
        .position(x: 50 * u, y: 74 * u)
    }

    // MARK: Eyes

    @ViewBuilder
    private func eyeShape(u: CGFloat) -> some View {
        switch eyes {
        case .round: Circle().frame(width: 15 * u, height: 15 * u)
        case .square: RoundedRectangle(cornerRadius: 4 * u, style: .continuous).frame(width: 14 * u, height: 14 * u)
        case .pill: Capsule().frame(width: 10 * u, height: 19 * u)
        }
    }

    @ViewBuilder
    private func eyesView(t: Double, u: CGFloat, k: CGFloat, lvl: CGFloat, p: Palette) -> some View {
        let blinkCycle = t.truncatingRemainder(dividingBy: 4.3)
        let blink: CGFloat = (k > 0 && blinkCycle < 0.14) ? 0.12 : 1
        let look: CGFloat = phase == .thinking ? CGFloat(sin(t * 2.6)) * 3.6 * u * k : 0
        let grow: CGFloat = phase == .listening ? 1.08 + lvl * 0.14 * k : 1
        ForEach([CGFloat(38), CGFloat(62)], id: \.self) { x in
            eyeShape(u: u)
                .foregroundStyle(p.eye)
                .shadow(color: p.eye.opacity(0.85), radius: 5 * u)
                .scaleEffect(x: grow, y: grow * blink)
                .position(x: x * u + look, y: 44.5 * u)
        }
    }

    // MARK: Mouth

    private func amp(_ i: Int, _ t: Double) -> CGFloat {
        CGFloat(abs(sin(t * 9 + Double(i) * 1.9)) * 0.6 + abs(sin(t * 5.3 + Double(i) * 0.7)) * 0.4)
    }

    @ViewBuilder
    private func mouthView(t: Double, u: CGFloat, k: CGFloat, lvl: CGFloat, p: Palette) -> some View {
        Group {
            switch mouth {
            case .bars: barsMouth(t: t, u: u, k: k, lvl: lvl, p: p)
            case .smile: smileMouth(t: t, u: u, k: k, p: p)
            }
        }
        .frame(width: 26 * u, height: 14 * u)
        .position(x: 50 * u, y: 58.5 * u)
    }

    @ViewBuilder
    private func barsMouth(t: Double, u: CGFloat, k: CGFloat, lvl: CGFloat, p: Palette) -> some View {
        let idle: [CGFloat] = [2.4, 3.8, 4.8, 3.8, 2.4]
        let profile: [CGFloat] = [0.6, 0.9, 1.0, 0.9, 0.6]
        HStack(spacing: 2.2 * u) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(p.mouth)
                    .frame(width: 3 * u, height: barHeight(i, t: t, u: u, k: k, lvl: lvl, idle: idle, profile: profile))
            }
        }
    }

    private func barHeight(_ i: Int, t: Double, u: CGFloat, k: CGFloat, lvl: CGFloat, idle: [CGFloat], profile: [CGFloat]) -> CGFloat {
        switch phase {
        case .speaking: return (2.6 + amp(i, t) * 9.5 * (0.4 + 0.6 * k)) * u
        case .listening: return (idle[i] + lvl * 9 * profile[i] * k) * u
        case .thinking: return (2.8 + CGFloat(sin(t * 5 - Double(i) * 0.9) + 1) * 1.3 * k) * u
        case .idle: return idle[i] * u
        }
    }

    @ViewBuilder
    private func smileMouth(t: Double, u: CGFloat, k: CGFloat, p: Palette) -> some View {
        switch phase {
        case .speaking:
            let a = (amp(0, t) + amp(2, t)) / 2
            RoundedRectangle(cornerRadius: 3.2 * u, style: .continuous).fill(p.mouth)
                .frame(width: 14 * u, height: (2.6 + a * 9 * (0.4 + 0.6 * k)) * u)
        case .thinking:
            Capsule().fill(p.mouth).frame(width: 9 * u, height: 2.6 * u)
        default:
            SmileShape(curve: phase == .listening ? 0.9 : 0.6)
                .stroke(p.mouth, style: StrokeStyle(lineWidth: 2.8 * u, lineCap: .round))
                .frame(width: 18 * u, height: 7 * u)
        }
    }
}

struct SmileShape: Shape {
    var curve: CGFloat = 0.6
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.minY + 2 * rect.height * curve))
        return path
    }
}
