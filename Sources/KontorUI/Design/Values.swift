import SwiftUI
import KontorModel

/// Direction of a change, with the glyph used when color alone must not carry meaning.
public enum Trend: Sendable {
    case up, down, flat

    public init(_ value: Double) { self = value > 0 ? .up : value < 0 ? .down : .flat }
    public init(minor: Int64) { self = minor > 0 ? .up : minor < 0 ? .down : .flat }

    /// ▲ / ▼ / – (text glyphs so they align with digits and scale with Dynamic Type).
    public var arrow: String {
        switch self {
        case .up: "▲"
        case .down: "▼"
        case .flat: "–"
        }
    }

    public func color(_ style: GainStyle) -> Color {
        switch self {
        case .up: style.gain
        case .down: style.loss
        case .flat: DS.Colors.neutral
        }
    }

    var accessibilityWord: String {
        switch self {
        case .up: "up"
        case .down: "down"
        case .flat: "unchanged"
        }
    }
}

/// A signed value colored by polarity: gains in the gain color, losses in the loss color.
/// With "Differentiate Without Color" enabled, a ▲/▼ glyph is shown as well.
///
/// ```swift
/// GainText(money: position.gain)              // +$1,204.10
/// GainText(percent: position.gainFraction)    // +7.34%
/// ```
public struct GainText: View {
    @Environment(\.gainStyle) private var gainStyle
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private let text: String
    private let trend: Trend

    /// A pre-formatted string with an explicit trend.
    public init(_ text: String, trend: Trend) {
        self.text = text
        self.trend = trend
    }

    public init(money: Money, symbol: Bool = true) {
        self.init(Fmt.money(money, symbol: symbol, signed: true), trend: Trend(minor: money.minor))
    }

    public init(percent fraction: Double, decimals: Int = 2) {
        self.init(Fmt.percent(fraction, decimals: decimals, signed: true), trend: fraction.isFinite ? Trend(fraction) : .flat)
    }

    public var body: some View {
        Text(differentiateWithoutColor && trend != .flat ? "\(trend.arrow) \(text)" : text)
            .numeric()
            .foregroundStyle(trend.color(gainStyle))
    }
}

/// A compact change indicator: arrow + percentage and/or amount, e.g. `▲ 1.24%  +$312.40`.
/// The arrow is always shown, so the label works without color.
public struct DeltaLabel: View {
    @Environment(\.gainStyle) private var gainStyle

    private let fraction: Double?
    private let amount: Money?
    private let trend: Trend

    /// - Parameters:
    ///   - fraction: Relative change (0.0124 = 1.24 %).
    ///   - amount: Absolute change.
    public init(fraction: Double? = nil, amount: Money? = nil) {
        self.fraction = fraction.flatMap { $0.isFinite ? $0 : nil }
        self.amount = amount
        if let amount, amount.minor != 0 {
            trend = Trend(minor: amount.minor)
        } else if let f = self.fraction {
            trend = Trend(f)
        } else {
            trend = .flat
        }
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(trend.arrow)
                .font(.system(size: 8))
                .baselineOffset(1)
                .accessibilityHidden(true)
            if let fraction {
                Text(Fmt.percent(abs(fraction)))
            }
            if let amount {
                Text(Fmt.money(amount, signed: true))
                    .opacity(fraction == nil ? 1 : 0.85)
            }
        }
        .numeric()
        .foregroundStyle(trend.color(gainStyle))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [trend.accessibilityWord]
        if let fraction { parts.append(Fmt.percent(abs(fraction))) }
        if let amount { parts.append(Fmt.money(amount)) }
        return parts.joined(separator: " ")
    }
}

/// A key figure: caption, large value, optional change and footnote.
///
/// ```swift
/// StatTile("Net Worth", value: Fmt.money(total), delta: DeltaLabel(fraction: 0.0124, amount: change),
///          footnote: "since yesterday")
/// ```
public struct StatTile: View {
    private let label: String
    private let value: String
    private let delta: DeltaLabel?
    private let footnote: String?
    private let symbol: String?

    public init(_ label: String, value: String, delta: DeltaLabel? = nil, footnote: String? = nil, symbol: String? = nil) {
        self.label = label
        self.value = value
        self.delta = delta
        self.footnote = footnote
        self.symbol = symbol
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
                Text(label)
            }
            .font(.kontorCaption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.kontorHero)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if delta != nil || footnote != nil {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                    if let delta { delta }
                    if let footnote {
                        Text(footnote).foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                .lineLimit(1)
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

/// A small colored dot + name, for legends and category cells.
public struct CategoryTag: View {
    private let name: String
    private let color: Color

    public init(_ name: String, color: Color) {
        self.name = name
        self.color = color
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.xs + 2) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(name).lineLimit(1)
        }
    }
}
