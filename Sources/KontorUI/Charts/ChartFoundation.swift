import AppKit
import SwiftUI
import KontorModel
import KontorEngine

// The chart kit — shared building blocks.
//
// Every chart in `Sources/KontorUI/Charts` is drawn with `Canvas` in a single pass (no view per
// mark), takes plain `Sendable` value types computed off the main actor, formats through
// `ChartValueFormat` (which wraps `Fmt`) and takes its colors from `ChartColors`.

// MARK: - Value format

/// How a chart turns its `Double` values into text. Wraps `Fmt`, so charts follow the user's locale.
///
/// ```swift
/// .money("EUR")        // values are MINOR units (Int64 from the engine, converted with Double(_:))
/// .percent()           // values are fractions: 0.0734 → "7.34%"
/// .percent(signed: true)
/// .number(decimals: 1) // plain numbers
/// .count               // integers
/// ```
public struct ChartValueFormat: Sendable {
    /// Labels for a whole set of axis ticks at once (so a format can pick one precision for all).
    public var axisLabels: @Sendable (_ ticks: [Double]) -> [String]
    /// The exact value, for tooltips, legends and value labels.
    public var value: @Sendable (Double) -> String
    /// The change between two values (range selection, waterfall deltas), e.g. "+€1,200.00 (+3.40%)".
    public var change: @Sendable (_ from: Double, _ to: Double) -> String
    /// A short form for labels inside marks (bar caps, treemap cells).
    public var compact: @Sendable (Double) -> String

    public init(
        axisLabels: @escaping @Sendable ([Double]) -> [String],
        value: @escaping @Sendable (Double) -> String,
        change: @escaping @Sendable (Double, Double) -> String,
        compact: (@Sendable (Double) -> String)? = nil
    ) {
        self.axisLabels = axisLabels
        self.value = value
        self.change = change
        self.compact = compact ?? value
    }

    /// Money in **minor units** of `currency` (what the engine returns as `Int64`).
    /// Axis: whole units below 10,000 (`€2,500`), compact above (`€1.2M`); values: exact (`€1,234.56`).
    public static func money(_ currency: CurrencyCode) -> ChartValueFormat {
        @Sendable func money(_ v: Double) -> Money { Money(minor: FixedMath.saturatingInt64(v), currency: currency) }
        @Sendable func short(_ v: Double) -> String {
            abs(v) < 1_000_000 ? Fmt.moneyRounded(money(v)) : Fmt.compactMoney(money(v))
        }
        return ChartValueFormat(
            axisLabels: { ticks in
                let rounded = { ticks.map { Fmt.moneyRounded(money($0)) } }
                guard (ticks.map(abs).max() ?? 0) >= 1_000_000 else { return rounded() }
                let compact = ticks.map { Fmt.compactMoney(money($0)) }
                return Set(compact).count == compact.count ? compact : rounded()
            },
            value: { $0.isFinite ? Fmt.money(money($0)) : Fmt.missing },
            change: { from, to in
                guard from.isFinite, to.isFinite else { return Fmt.missing }
                let delta = Fmt.money(money(to - from), signed: true)
                guard from > 0 else { return delta }
                return "\(delta) (\(Fmt.percent(to / from - 1, signed: true)))"
            },
            compact: { $0.isFinite ? short($0) : Fmt.missing }
        )
    }

    /// Quotes in **major units** of `currency` (`Double`s such as the engine's `priceLevels`):
    /// values with price precision (`€101.50`, up to four decimals), axis in whole units when the
    /// ticks allow.
    public static func price(_ currency: CurrencyCode) -> ChartValueFormat {
        @Sendable func minor(_ v: Double) -> Int64 { FixedMath.saturatingInt64(v * 100) }
        return ChartValueFormat(
            axisLabels: { ticks in
                let step = ticks.count > 1 ? abs(ticks[1] - ticks[0]) : 1
                return ticks.map { step >= 0.999 ? Fmt.moneyRounded(Money(minor: minor($0), currency: currency)) : Fmt.price(Price($0), currency: currency) }
            },
            value: { $0.isFinite ? Fmt.price(Price($0), currency: currency) : Fmt.missing },
            change: { from, to in
                guard from.isFinite, to.isFinite else { return Fmt.missing }
                let delta = Fmt.money(minor: minor(to - from), currency: currency, signed: true)
                guard from > 0 else { return delta }
                return "\(delta) (\(Fmt.percent(to / from - 1, signed: true)))"
            }
        )
    }

    /// Fractions shown as percentages (`0.0734` → `7.34%`).
    /// - Parameter compounding: how `change` combines two values — `true` for cumulative returns
    ///   (`(1 + to) / (1 + from) − 1`), `false` for plain differences in percentage points.
    public static func percent(decimals: Int = 2, signed: Bool = false, compounding: Bool = true) -> ChartValueFormat {
        ChartValueFormat(
            axisLabels: { ticks in
                // The fewest decimals that print every tick exactly — "12,5 %" for a 2.5 % step,
                // "-0,005 %" for a nearly flat series — so that no two ticks share a label and no
                // label is rounded away from its grid line.
                for digits in 0...4 {
                    let scale = 100 * pow(10, Double(digits))
                    if ticks.allSatisfy({ abs($0 * scale - ($0 * scale).rounded()) < 1e-6 }) {
                        return ticks.map { Fmt.percent($0, decimals: digits) }
                    }
                }
                return ticks.map { Fmt.percent($0, decimals: 4) }
            },
            value: { Fmt.percent($0, decimals: decimals, signed: signed) },
            change: { from, to in
                guard from.isFinite, to.isFinite else { return Fmt.missing }
                if compounding, from > -1 { return Fmt.percent((1 + to) / (1 + from) - 1, decimals: decimals, signed: true) }
                return Fmt.percentagePoints(to - from, decimals: decimals)
            },
            compact: { Fmt.percent($0, decimals: abs($0) >= 0.1 ? 0 : 1, signed: signed) }
        )
    }

    /// Plain numbers with a fixed number of decimals.
    public static func number(decimals: Int = 2) -> ChartValueFormat {
        ChartValueFormat(
            axisLabels: { ticks in
                let step = ticks.count > 1 ? abs(ticks[1] - ticks[0]) : 1
                let d = step >= 0.999 ? 0 : step >= 0.0999 ? 1 : 2
                return ticks.map { Fmt.number($0, decimals: min(d, max(decimals, d))) }
            },
            value: { Fmt.number($0, decimals: decimals) },
            change: { from, to in Fmt.number(to - from, decimals: decimals, signed: true) }
        )
    }

    /// Whole numbers (counts of trades, days, …).
    public static let count = ChartValueFormat.number(decimals: 0)
}

// MARK: - Colors

/// Linear-light helpers for the few places where charts must compute with colors (diverging scales,
/// legible ink on a fill, adjusting user-chosen classification colors).
public struct ChartRGB: Sendable, Hashable {
    public var r: Double, g: Double, b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#RRGGBB` / `#RGB`; nil if malformed.
    public init?(hex: String) {
        guard let c = hexComponents(hex) else { return nil }
        self.init(r: c.r, g: c.g, b: c.b)
    }

    /// The sRGB components of any SwiftUI color as it resolves in `environment` (light/dark, contrast).
    public init(_ color: Color, in environment: EnvironmentValues) {
        let c = color.resolve(in: environment)
        let a = Double(c.opacity)
        // Composite translucent colors over the chart surface so luminance reflects what is seen.
        if a < 0.999 {
            let s = DS.Colors.cardFill.resolve(in: environment)
            self.init(r: Double(c.red) * a + Double(s.red) * (1 - a), g: Double(c.green) * a + Double(s.green) * (1 - a),
                      b: Double(c.blue) * a + Double(s.blue) * (1 - a))
        } else {
            self.init(r: Double(c.red), g: Double(c.green), b: Double(c.blue))
        }
    }

    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// WCAG relative luminance (0 = black, 1 = white).
    public var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio (1…21).
    public func contrast(with other: ChartRGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Straight interpolation towards `other` (`t` 0…1).
    public func mixed(with other: ChartRGB, _ t: Double) -> ChartRGB {
        let t = max(0, min(1, t))
        return ChartRGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// Black or white — whichever reads better on this fill (always ≥ 4.5 : 1).
    public var ink: Color { prefersDarkInk ? .black : .white }
    public var prefersDarkInk: Bool { contrast(with: .black) >= contrast(with: .white) }

    public static let black = ChartRGB(r: 0, g: 0, b: 0)
    public static let white = ChartRGB(r: 1, g: 1, b: 1)

    /// The chart surfaces the kit is tuned for (cards on the window background).
    static let lightSurface = ChartRGB(r: 1, g: 1, b: 1)
    static let darkSurface = ChartRGB(r: 0.118, g: 0.118, b: 0.118)
}

/// Colors for charts. Color carries meaning only: identity (series / category), polarity
/// (gain / loss, honouring the user's "red = up" preference) or interaction (accent).
public enum ChartColors {
    /// The color of the n-th series or category: `CategoryPalette` in its validated order; past
    /// eight everything is the neutral "Other" gray — fold instead of cycling.
    public static func series(_ index: Int) -> Color { CategoryPalette.color(index) }

    /// Comparison series (benchmarks, "invested capital", targets): neutral gray.
    public static var comparison: Color { DS.Colors.benchmark }

    /// Totals and other marks without polarity (waterfall start/end, histogram bars).
    public static let neutral = Color(light: "#8A8A8E", dark: "#8E8E93")

    /// "Other" / unclassified.
    public static var other: Color { CategoryPalette.other }

    /// A classification's stored `#RRGGBB`, adjusted so it stays visible on the chart surface in
    /// both appearances: colors too close to white are darkened in light mode, colors too close to
    /// black are lightened in dark mode. Malformed or empty strings fall back to the palette slot
    /// `fallbackIndex`.
    ///
    /// ```swift
    /// ChartColors.classification(node.color, fallbackIndex: index)
    /// ```
    public static func classification(_ hex: String?, fallbackIndex: Int = Int.max) -> Color {
        guard let hex, let rgb = ChartRGB(hex: hex) else { return series(fallbackIndex) }
        let light = legible(rgb, on: .lightSurface).nsColor, dark = legible(rgb, on: .darkSurface).nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil ? dark : light
        })
    }

    /// Moves a color away from the surface until a mark of that color is clearly visible
    /// (contrast ≥ `minimum` : 1); colors that already are stay untouched.
    public static func legible(_ rgb: ChartRGB, on surface: ChartRGB, minimum: Double = 1.6) -> ChartRGB {
        guard rgb.contrast(with: surface) < minimum else { return rgb }
        let target: ChartRGB = surface.luminance > 0.5 ? .black : .white
        var result = rgb
        var t = 0.0
        while result.contrast(with: surface) < minimum, t < 1 {
            t += 0.04
            result = rgb.mixed(with: target, t)
        }
        return result
    }

    /// Tints for the children of a category (sunburst rings, treemap groups): the parent's color,
    /// stepping lighter towards the surface so siblings stay distinguishable without new hues.
    public static func shade(of color: Color, index: Int, count: Int) -> Color {
        guard count > 1 else { return color.opacity(0.82) }
        let t = Double(index) / Double(count - 1)
        return color.opacity(0.88 - 0.5 * t)
    }
}

extension ChartRGB {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// A diverging gain/loss color scale with a neutral midpoint, honouring the user's "red = up"
/// preference. Used by `HeatmapGrid` and by `TreemapChart` when colored by performance.
///
/// ```swift
/// let scale = DivergingScale(limit: 0.08, gainStyle: gainStyle)     // ±8 % = full intensity
/// scale.color(for: 0.031, scheme: colorScheme)                       // fill
/// scale.ink(for: 0.031, scheme: colorScheme)                         // black or white, ≥ 4.5 : 1
/// ```
public struct DivergingScale: Sendable, Hashable {
    /// The magnitude that maps to full intensity; larger values are clamped.
    public var limit: Double
    public var gainStyle: GainStyle

    public init(limit: Double, gainStyle: GainStyle) {
        self.limit = limit.isFinite && limit > 0 ? limit : 1
        self.gainStyle = gainStyle
    }

    /// A scale whose limit covers `values` robustly: the 95th percentile of the magnitudes (so one
    /// outlier month does not wash out all others), at least `minimum`.
    public init(covering values: some Sequence<Double>, minimum: Double = 0, gainStyle: GainStyle) {
        let magnitudes = values.filter(\.isFinite).map(abs).sorted()
        let p95 = magnitudes.isEmpty ? 0 : magnitudes[min(magnitudes.count - 1, Int((Double(magnitudes.count) * 0.95).rounded(.down)))]
        self.init(limit: max(p95, minimum, .leastNonzeroMagnitude), gainStyle: gainStyle)
    }

    // Poles and midpoints per appearance (sRGB). Light: deep poles, pale midpoint; dark: bright
    // poles, dim midpoint. The midpoint is a gray — never a hue.
    private static let greenLight = ChartRGB(hex: "#1A8F3C")!, redLight = ChartRGB(hex: "#D32F2F")!
    private static let greenDark = ChartRGB(hex: "#30D158")!, redDark = ChartRGB(hex: "#FF5A52")!
    private static let midLight = ChartRGB(hex: "#EDEDEA")!, midDark = ChartRGB(hex: "#38383A")!

    /// 0 (neutral) … 1 (full) — eased so small values are already visibly tinted.
    public func intensity(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return 0 }
        let t = min(1, abs(value) / limit)
        return 0.14 + 0.86 * pow(t, 0.75)
    }

    /// The fill as components (for tests and custom drawing).
    public func rgb(for value: Double?, scheme: ColorScheme) -> ChartRGB {
        let dark = scheme == .dark
        let mid = dark ? Self.midDark : Self.midLight
        guard let value, value.isFinite, value != 0 else { return mid }
        let up = value > 0
        let green = dark ? Self.greenDark : Self.greenLight, red = dark ? Self.redDark : Self.redLight
        let pole = (up == (gainStyle == .greenUp)) ? green : red
        return mid.mixed(with: pole, intensity(value))
    }

    /// The fill color of a value; `nil` (no data) gives the neutral midpoint.
    public func color(for value: Double?, scheme: ColorScheme) -> Color { rgb(for: value, scheme: scheme).color }

    /// Black or white text for a label on top of `color(for:)`.
    public func ink(for value: Double?, scheme: ColorScheme) -> Color { rgb(for: value, scheme: scheme).ink }
}

// MARK: - Environment

extension EnvironmentValues {
    /// The color behind a chart — used for the rings around markers and the gaps between marks.
    /// Defaults to the card fill; set it when a chart sits on another background.
    @Entry public var chartSurface: Color = DS.Colors.cardFill
}

extension EnvironmentValues {
    /// Forces the textures and dash patterns charts otherwise use only under "Differentiate
    /// Without Color" (for print-like output or a user preference).
    @Entry public var chartPatternsForced: Bool = false
}

// MARK: - Fonts and measuring

enum ChartFont {
    /// Axis ticks.
    static let axisSize: CGFloat = 10
    static let axis = Font.system(size: axisSize).monospacedDigit()
    /// Labels inside or next to marks.
    static let labelSize: CGFloat = 11
    static let label = Font.system(size: labelSize, weight: .medium).monospacedDigit()
    static let small = Font.system(size: 9.5, weight: .medium).monospacedDigit()

    /// Width of a string in the monospaced-digit system font — for layout before drawing.
    @MainActor static func width(_ string: String, size: CGFloat = axisSize, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Resolved, appearance-dependent chart chrome.
struct ChartChrome {
    var grid: Color
    var baseline: Color
    var axisLabel: Color
    var surface: Color
    var crosshair: Color

    init(contrast: ColorSchemeContrast, surface: Color) {
        let strong = contrast == .increased
        grid = Color.primary.opacity(strong ? 0.22 : 0.08)
        baseline = Color.primary.opacity(strong ? 0.55 : 0.28)
        axisLabel = strong ? Color.primary : Color.secondary
        crosshair = Color.primary.opacity(strong ? 0.7 : 0.38)
        self.surface = surface
    }
}

extension GraphicsContext {
    /// Draws a text label and returns the rectangle it covers.
    @discardableResult
    func label(_ string: String, at point: CGPoint, anchor: UnitPoint = .center, font: Font = ChartFont.axis, color: Color = .secondary) -> CGRect {
        let text = resolve(Text(string).font(font).foregroundStyle(color))
        let size = text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        draw(text, at: point, anchor: anchor)
        return CGRect(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y, width: size.width, height: size.height)
    }

    func textSize(_ string: String, font: Font = ChartFont.axis) -> CGSize {
        resolve(Text(string).font(font)).measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
    }

    /// A horizontal hairline on pixel boundaries.
    func hline(y: CGFloat, from x0: CGFloat, to x1: CGFloat, color: Color, width: CGFloat = 1) {
        var path = Path()
        let y = y.rounded() + 0.5
        path.move(to: CGPoint(x: x0, y: y))
        path.addLine(to: CGPoint(x: x1, y: y))
        stroke(path, with: .color(color), lineWidth: width)
    }

    func vline(x: CGFloat, from y0: CGFloat, to y1: CGFloat, color: Color, width: CGFloat = 1, dash: [CGFloat] = []) {
        var path = Path()
        let x = x.rounded() + 0.5
        path.move(to: CGPoint(x: x, y: y0))
        path.addLine(to: CGPoint(x: x, y: y1))
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
    }
}

// MARK: - Patterns (Differentiate Without Color)

/// Fill textures that carry identity when color cannot (Differentiate Without Color). Slot 0 is
/// plain; the others are diagonal hatches and dots, assigned in series order.
public enum ChartPattern: Int, Sendable, CaseIterable {
    case solid, diagonal, reverseDiagonal, crosshatch, dots, denseDiagonal, denseReverseDiagonal

    /// The pattern of the n-th series (cycles after seven — beyond that labels must carry identity).
    public static func slot(_ index: Int) -> ChartPattern {
        allCases[((index % allCases.count) + allCases.count) % allCases.count]
    }

    /// Dash pattern for lines of the n-th series.
    public static func dash(_ index: Int) -> [CGFloat] {
        switch ((index % 4) + 4) % 4 {
        case 0: []
        case 1: [6, 3]
        case 2: [2, 3]
        default: [8, 3, 2, 3]
        }
    }
}

extension GraphicsContext {
    /// Overlays `pattern` inside `path` (already filled by the caller) in `ink`.
    func overlay(_ pattern: ChartPattern, in path: Path, ink: Color, strength: Double = 0.55) {
        guard pattern != .solid else { return }
        var context = self
        context.clip(to: path)
        let box = path.boundingRect
        let shading = GraphicsContext.Shading.color(ink.opacity(strength))
        func hatch(spacing: CGFloat, reversed: Bool) {
            var lines = Path()
            var offset = -box.height
            while offset < box.width {
                if reversed {
                    lines.move(to: CGPoint(x: box.minX + offset + box.height, y: box.minY))
                    lines.addLine(to: CGPoint(x: box.minX + offset, y: box.maxY))
                } else {
                    lines.move(to: CGPoint(x: box.minX + offset, y: box.minY))
                    lines.addLine(to: CGPoint(x: box.minX + offset + box.height, y: box.maxY))
                }
                offset += spacing
            }
            context.stroke(lines, with: shading, lineWidth: 1)
        }
        switch pattern {
        case .solid: break
        case .diagonal: hatch(spacing: 6, reversed: false)
        case .reverseDiagonal: hatch(spacing: 6, reversed: true)
        case .crosshatch:
            hatch(spacing: 7, reversed: false)
            hatch(spacing: 7, reversed: true)
        case .denseDiagonal: hatch(spacing: 3.5, reversed: false)
        case .denseReverseDiagonal: hatch(spacing: 3.5, reversed: true)
        case .dots:
            var dots = Path()
            var y = box.minY + 2.5
            var row = 0
            while y < box.maxY {
                var x = box.minX + (row.isMultiple(of: 2) ? 2.5 : 5)
                while x < box.maxX {
                    dots.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                    x += 5
                }
                y += 5
                row += 1
            }
            context.fill(dots, with: shading)
        }
    }
}

// MARK: - Small geometry helpers

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}

extension Path {
    /// A bar whose data end is rounded and whose baseline end is square.
    static func bar(_ rect: CGRect, radius: CGFloat, roundedEdge: Edge) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var radii = RectangleCornerRadii()
        switch roundedEdge {
        case .top: radii = RectangleCornerRadii(topLeading: r, bottomLeading: 0, bottomTrailing: 0, topTrailing: r)
        case .bottom: radii = RectangleCornerRadii(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0)
        case .leading: radii = RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: 0, topTrailing: 0)
        case .trailing: radii = RectangleCornerRadii(topLeading: 0, bottomLeading: 0, bottomTrailing: r, topTrailing: r)
        }
        return Path(roundedRect: rect, cornerRadii: radii, style: .continuous)
    }
}
