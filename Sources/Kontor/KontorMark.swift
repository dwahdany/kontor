import SwiftUI

/// The Kontor mark: a rising line across ledger rules. The app icon (`Scripts/make-icon.swift`)
/// draws the same geometry with Core Graphics.
struct KontorMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (1 - y) * s) }

            let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerRadius: s * 0.225, style: .continuous)
            context.fill(tile, with: .linearGradient(
                Gradient(colors: [Color(hex: "#1F5A94"), Color(hex: "#0C2744")]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: s)
            ))

            for y in [0.30, 0.43, 0.56, 0.69] as [CGFloat] {
                var rule = Path()
                rule.move(to: p(0.20, y))
                rule.addLine(to: p(0.80, y))
                context.stroke(rule, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: s * 0.022, lineCap: .round))
            }

            var line = Path()
            line.addLines([p(0.20, 0.34), p(0.36, 0.47), p(0.49, 0.40), p(0.65, 0.60), p(0.80, 0.71)])
            context.stroke(line, with: .linearGradient(
                Gradient(colors: [Color(hex: "#7CE7C0"), Color(hex: "#FFFFFF")]),
                startPoint: p(0.2, 0.3), endPoint: p(0.8, 0.7)
            ), style: StrokeStyle(lineWidth: s * 0.062, lineCap: .round, lineJoin: .round))

            let dot = CGRect(x: p(0.80, 0.71).x - s * 0.055, y: p(0.80, 0.71).y - s * 0.055, width: s * 0.11, height: s * 0.11)
            context.fill(Path(ellipseIn: dot), with: .color(.white))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
