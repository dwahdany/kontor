import SwiftUI

/// A tiny line chart for table cells and tiles. Drawn with `Canvas` in a single pass (no view per
/// point); series longer than twice the pixel width are reduced to a min/max envelope first, so
/// even ten years of daily prices render in microseconds.
///
/// ```swift
/// Sparkline(prices)                         // colored by net change (gain/loss)
/// Sparkline(prices, tint: .secondary)       // fixed color
///     .frame(width: 72, height: 20)
/// ```
public struct Sparkline: View {
    @Environment(\.gainStyle) private var gainStyle

    private let values: [Double]
    private let tint: Color?
    private let showsArea: Bool
    private let lineWidth: CGFloat

    /// - Parameters:
    ///   - values: The series, oldest first. Non-finite values are skipped.
    ///   - tint: Line color; `nil` colors the line by net change using the gain/loss colors.
    ///   - showsArea: Fills a faint gradient below the line.
    public init(_ values: [Double], tint: Color? = nil, showsArea: Bool = true, lineWidth: CGFloat = 1.25) {
        self.values = values
        self.tint = tint
        self.showsArea = showsArea
        self.lineWidth = lineWidth
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let points = Self.points(values, in: size, inset: lineWidth)
            guard points.count >= 2 else { return }
            let color = tint ?? gainStyle.color(for: (values.last ?? 0) - (values.first ?? 0))
            var line = Path()
            line.addLines(points)
            if showsArea {
                var area = line
                area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
                area.addLine(to: CGPoint(x: points[0].x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.22), color.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                ))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    /// Maps the series into view coordinates, downsampling to at most ~2 points per pixel.
    nonisolated static func points(_ values: [Double], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        let series = reduced(values, maxBuckets: max(8, Int(size.width)))
        guard series.count >= 2 else { return [] }
        var lo = Double.infinity, hi = -Double.infinity
        for v in series {
            lo = Swift.min(lo, v)
            hi = Swift.max(hi, v)
        }
        let span = hi - lo
        let height = Swift.max(size.height - inset * 2, 1)
        let step = (size.width - inset * 2) / CGFloat(series.count - 1)
        var points = [CGPoint]()
        points.reserveCapacity(series.count)
        for (i, v) in series.enumerated() {
            let t = span > 0 ? (v - lo) / span : 0.5
            points.append(CGPoint(x: inset + CGFloat(i) * step, y: inset + height * (1 - t)))
        }
        return points
    }

    /// Min/max bucket reduction that preserves the visual envelope and the first/last values.
    nonisolated static func reduced(_ values: [Double], maxBuckets: Int) -> [Double] {
        let finite = values.contains { !$0.isFinite } ? values.filter(\.isFinite) : values
        guard finite.count > maxBuckets * 2, maxBuckets > 0 else { return finite }
        var result = [Double]()
        result.reserveCapacity(maxBuckets * 2)
        let n = finite.count
        for b in 0..<maxBuckets {
            let start = b * n / maxBuckets, end = Swift.max(start + 1, (b + 1) * n / maxBuckets)
            var lo = finite[start], hi = finite[start], loIndex = start, hiIndex = start
            for i in start..<end {
                if finite[i] < lo { lo = finite[i]; loIndex = i }
                if finite[i] > hi { hi = finite[i]; hiIndex = i }
            }
            if loIndex <= hiIndex {
                result.append(lo)
                result.append(hi)
            } else {
                result.append(hi)
                result.append(lo)
            }
        }
        result[0] = finite[0]
        result[result.count - 1] = finite[n - 1]
        return result
    }
}

extension Sparkline {
    /// Convenience for raw fixed-point prices (`PriceSeries.values`).
    public init(raw values: some Sequence<Int64>, tint: Color? = nil, showsArea: Bool = true) {
        self.init(values.map(Double.init), tint: tint, showsArea: showsArea)
    }
}
