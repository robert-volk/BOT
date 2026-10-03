import SwiftUI

struct BackgroundView: View {
    let theme: Theme
    let style: BackgroundStyle

    var body: some View {
        ZStack {
            theme.background
            switch style {
            case .solid:
                EmptyView()
            case .gradient:
                LinearGradient(colors: [theme.background, theme.backgroundAlt], startPoint: .top, endPoint: .bottom)
            case .grid:
                Canvas { ctx, size in
                    let step: CGFloat = 30
                    var path = Path()
                    var x: CGFloat = 0
                    while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                    var y: CGFloat = 0
                    while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                    ctx.stroke(path, with: .color(theme.accent.opacity(theme.isDark ? 0.14 : 0.16)), lineWidth: 0.6)
                }
                RadialGradient(colors: [theme.accent.opacity(0.20), .clear], center: .center, startRadius: 10, endRadius: 360)
            case .glow:
                RadialGradient(colors: [theme.accent.opacity(theme.isDark ? 0.38 : 0.30), .clear],
                               center: UnitPoint(x: 0.5, y: 0.34), startRadius: 10, endRadius: 420)
            }
        }
        .ignoresSafeArea()
    }
}
