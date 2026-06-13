import SwiftUI

/// The AARC brand mark — cream goblet + dizzy spiral on pub-green, with
/// speed streaks (drinking, but make it cardio). Matches the app icon and
/// the dashboard / share-card logo. Canvas-drawn so it renders crisply into
/// ImageRenderer at any size.
struct GobletLogo: View {
    var body: some View {
        Canvas { ctx, size in
            GobletLogo.draw(in: &ctx, rect: CGRect(origin: .zero, size: size))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    static let green = Color(red: 0.29, green: 0.39, blue: 0.31)
    static let cream = Color(red: 0.95, green: 0.94, blue: 0.89)

    /// Draw the mark filling `rect`. Shared by the SwiftUI view and the
    /// share-card renderer so branding is identical everywhere.
    static func draw(in ctx: inout GraphicsContext, rect: CGRect) {
        let s = min(rect.width, rect.height)
        let u = s / 40
        let ox = rect.minX, oy = rect.minY
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * u, y: oy + y * u) }

        // tile
        ctx.fill(Path(roundedRect: CGRect(x: ox + u, y: oy + u, width: 38 * u, height: 38 * u),
                      cornerRadius: 10.5 * u), with: .color(green))
        // speed streaks
        var streaks = Path()
        streaks.move(to: P(4.5, 14.5)); streaks.addLine(to: P(10, 14.5))
        streaks.move(to: P(3.5, 19.5)); streaks.addLine(to: P(10.5, 19.5))
        streaks.move(to: P(5.5, 24.5)); streaks.addLine(to: P(9.5, 24.5))
        ctx.stroke(streaks, with: .color(cream.opacity(0.6)),
                   style: StrokeStyle(lineWidth: 1.9 * u, lineCap: .round))

        // goblet, leaning forward ~6°, anchored at design point (24,20)
        var inner = ctx
        inner.translateBy(x: ox + 24 * u, y: oy + 20 * u)
        inner.rotate(by: .degrees(6))
        func G(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }

        var bowl = Path()
        bowl.move(to: G(-8.2, -13)); bowl.addLine(to: G(8.2, -13))
        bowl.addCurve(to: G(0, 1.6), control1: G(8.2, -4.5), control2: G(4.4, 0.2))
        bowl.addCurve(to: G(-8.2, -13), control1: G(-4.4, 0.2), control2: G(-8.2, -4.5))
        bowl.closeSubpath()
        inner.fill(bowl, with: .color(cream))
        inner.fill(Path(CGRect(x: -1.15 * u, y: 1 * u, width: 2.3 * u, height: 9.2 * u)), with: .color(cream))
        inner.fill(Path(ellipseIn: CGRect(x: -5.6 * u, y: 9.5 * u, width: 11.2 * u, height: 3.4 * u)), with: .color(cream))

        var spiral = Path()
        let cx: CGFloat = 0, cy: CGFloat = -7.2
        var a: CGFloat = 0
        spiral.move(to: G(cx, cy))
        while a <= .pi * 5 {
            let r = 0.42 * a
            spiral.addLine(to: G(cx + r * cos(a - 1.2), cy + r * sin(a - 1.2)))
            a += 0.12
        }
        inner.stroke(spiral, with: .color(green), style: StrokeStyle(lineWidth: 1.5 * u, lineCap: .round))
    }
}
