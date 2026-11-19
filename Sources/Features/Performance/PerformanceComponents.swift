import SwiftUI
import KontorUI

/// The sections below the main chart.
enum PerformanceTab: String, CaseIterable, Identifiable, Sendable {
    case calculation, returns, risk, securities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calculation: "Calculation"
        case .returns: "Returns"
        case .risk: "Risk"
        case .securities: "Securities"
        }
    }

    var symbol: String {
        switch self {
        case .calculation: "list.bullet.indent"
        case .returns: "calendar"
        case .risk: "waveform.path.ecg"
        case .securities: "tablecells"
        }
    }
}

/// What the main chart shows.
enum PerformanceChartMode: String, CaseIterable, Identifiable, Sendable {
    case returns, value, drawdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .returns: "Return"
        case .value: "Value"
        case .drawdown: "Drawdown"
        }
    }
}

/// Requests from palette commands to the visible Performance screen of a window. Commands only
/// get the store, so the request is parked here until the screen (which may have to be navigated
/// to first) picks it up.
@MainActor @Observable final class PerformanceCommandCenter {
    static let shared = PerformanceCommandCenter()

    struct Request {
        var store: ObjectIdentifier
        var tab: PerformanceTab?
        var chart: PerformanceChartMode?
    }

    private(set) var pending: Request?
    private(set) var token = 0

    func show(tab: PerformanceTab? = nil, chart: PerformanceChartMode? = nil, in store: PortfolioStore) {
        pending = Request(store: ObjectIdentifier(store), tab: tab, chart: chart)
        token += 1
        store.navigate(to: .performance)
    }

    func take(for store: PortfolioStore) -> Request? {
        guard let request = pending, request.store == ObjectIdentifier(store) else { return nil }
        pending = nil
        return request
    }
}

/// A key figure with its ⓘ: caption, value, footnote. Like `StatTile`, plus the help button and a
/// polarity color for signed performance figures.
struct MetricTile: View {
    @Environment(\.gainStyle) private var gainStyle
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let label: String
    let topic: HelpTopic?
    let value: String
    var trend: Trend?
    var footnote: String?
    var detail: String?

    init(_ label: String, topic: HelpTopic? = nil, value: String, trend: Trend? = nil, footnote: String? = nil, detail: String? = nil) {
        self.label = label
        self.topic = topic
        self.value = value
        self.trend = trend
        self.footnote = footnote
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(label)
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let topic { HelpButton(topic) }
                Spacer(minLength: 0)
            }
            Text(displayValue)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .numeric()
                .foregroundStyle(trend.map { $0 == .flat ? Color.primary : $0.color(gainStyle) } ?? Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .contentTransition(.numericText())
                .help(detail ?? "")
            Text(footnote ?? " ")
                .font(.caption)
                .numeric()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label): \(value)\(footnote.map { ", \($0)" } ?? "")")
    }

    private var displayValue: String {
        guard differentiateWithoutColor, let trend, trend != .flat else { return value }
        return "\(trend.arrow) \(value)"
    }
}

extension Trend {
    /// Polarity of an optional engine value; nil stays neutral.
    init(optional value: Double?) {
        self = value.map { $0.isFinite ? Trend($0) : .flat } ?? .flat
    }
}

/// A signed amount in the reporting currency, colored by polarity; "–" for zero when asked.
struct SignedMoney: View {
    let minor: Int64
    let currency: CurrencyCode
    var dashForZero = false
    var symbol = true

    var body: some View {
        if minor == 0, dashForZero {
            Text(Fmt.missing).foregroundStyle(.tertiary)
        } else {
            GainText(money: Money(minor: minor, currency: currency), symbol: symbol)
        }
    }
}

/// An optional return, colored by polarity; "–" when undefined.
struct SignedPercent: View {
    let value: Double?
    var decimals = 2

    var body: some View {
        if let value, value.isFinite {
            GainText(percent: value, decimals: decimals)
        } else {
            Text(Fmt.missing).foregroundStyle(.tertiary)
        }
    }
}

/// Small uppercase-free column caption used by the hand-laid grids.
struct ColumnCaption: View {
    let text: String
    var topic: HelpTopic?

    init(_ text: String, topic: HelpTopic? = nil) {
        self.text = text
        self.topic = topic
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            Text(text)
            if let topic { HelpButton(topic) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
