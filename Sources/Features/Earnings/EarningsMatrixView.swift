import SwiftUI
import KontorUI

/// The year × month table with row and column totals and the change against the year before,
/// plus the yearly totals as bars.
struct EarningsMatrixView: View {
    @Environment(\.gainStyle) private var gainStyle
    let model: EarningsModel
    /// Width of the screen's content area: the columns are sized from it.
    let width: CGFloat
    /// Show the dividend payments of one month (`year × 12 + month − 1`).
    let showPayments: (Int) -> Void

    private let yearWidth: CGFloat = 62
    private let growthWidth: CGFloat = 74
    private let gap: CGFloat = 2
    /// Sets the Total column apart from December.
    private let totalGap: CGFloat = 10

    /// Twelve months and the total share what is left of the card.
    private var columnWidth: CGFloat {
        let inner = width - 2 * DS.Spacing.xl - 2 * DS.Spacing.l - 16
        return max(30, ((inner - yearWidth - growthWidth - totalGap - 14 * gap) / 13).rounded(.down))
    }

    /// The Payments view lists dividend payments, so a month leads there only for dividends.
    private var drillsDown: Bool { model.kind == .dividends }

    private var isCompact: Bool { columnWidth < 52 }
    /// Cents only where the columns are wide enough for them.
    private var showsCents: Bool { columnWidth >= 84 && model.matrixMaximum < 10_000_000 }
    private var inset: CGFloat { isCompact ? 4 : 6 }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.l) {
                Card {
                    VStack(alignment: .leading, spacing: DS.Spacing.m) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(model.kind.title) by Month")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text("in \(model.currency)\(showsCents ? "" : ", rounded")")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if drillsDown {
                                Text("Click a month to see its payments")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else if model.kind.isCost {
                                Text("Negative: more was refunded than charged")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .lineLimit(1)
                        if model.matrix.isEmpty || model.matrixMaximum == 0 {
                            Text("No \(model.kind.title.lowercased()) in this period.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            table
                        }
                    }
                }
                if let years = model.charts[.year], years.categories.count > 1, !years.isEmpty {
                    Card("\(model.kind.title) per Year", symbol: "chart.bar") {
                        BarSeriesChart(
                            categories: years.categories, series: years.plain, format: .money(model.currency),
                            layout: .stacked, coloring: model.kind == .net ? .gainLoss : .series,
                            title: "\(model.kind.title) per year")
                            .valueLabels()
                            .legendHidden(years.plain.count < 2)
                            .frame(height: 200)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.xl)
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                Text("Year").frame(width: yearWidth, alignment: .leading)
                ForEach(0..<12, id: \.self) { month in
                    Text(ChartLabels.shortMonth(month + 1)).padding(.trailing, inset).frame(width: columnWidth, alignment: .trailing)
                }
                Text("Total").padding(.trailing, inset).frame(width: columnWidth, alignment: .trailing).padding(.leading, totalGap)
                Text(isCompact ? "vs. Prior" : "vs. Prior Year")
                    .frame(width: growthWidth, alignment: .trailing)
                    .help("Change against the year before. For the current year: against the same days of last year. Shown only while both amounts are positive.")
            }
            .font(.kontorCaption)
            .foregroundStyle(.secondary)
            .padding(.bottom, DS.Spacing.xs)

            ForEach(model.matrix) { row in
                HStack(spacing: gap) {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(String(row.year)).fontWeight(.medium)
                        if row.growthIsSamePeriod || (row.year == model.today.year && row.isPartial) {
                            Text("YTD").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: yearWidth, alignment: .leading)
                    ForEach(0..<12, id: \.self) { month in
                        cell(row, month)
                    }
                    Text(amount(row.total))
                        .fontWeight(.semibold)
                        .foregroundStyle(style(for: row.total))
                        .padding(.trailing, inset)
                        .frame(width: columnWidth, height: 26, alignment: .trailing)
                        .padding(.leading, totalGap)
                        .help(Fmt.money(minor: row.total, currency: model.currency))
                    growth(row)
                }
            }

            Divider().padding(.vertical, DS.Spacing.xs)

            HStack(spacing: gap) {
                Text("Total").fontWeight(.semibold).frame(width: yearWidth, alignment: .leading)
                ForEach(0..<12, id: \.self) { month in
                    let value = model.matrixColumnTotals[month]
                    Text(value == 0 ? Fmt.missing : amount(value))
                        .fontWeight(.medium)
                        .foregroundStyle(value == 0 ? .tertiary : .primary)
                        .padding(.trailing, inset)
                        .frame(width: columnWidth, alignment: .trailing)
                        .help(Fmt.money(minor: value, currency: model.currency))
                }
                Text(amount(model.totalValue))
                    .fontWeight(.bold)
                    .padding(.trailing, inset)
                    .frame(width: columnWidth, alignment: .trailing)
                    .padding(.leading, totalGap)
                    .help(Fmt.money(minor: model.totalValue, currency: model.currency))
            }
            // Shares of a total only while every month pulls in the same direction.
            if model.matrixSharesAreMeaningful, model.totalValue != 0 {
                HStack(spacing: gap) {
                    Text("Share")
                        .frame(width: yearWidth, alignment: .leading)
                        .help("How much of the total falls into each calendar month.")
                    ForEach(0..<12, id: \.self) { month in
                        let value = model.matrixColumnTotals[month]
                        Text(value != 0 ? Fmt.percent(Double(value) / Double(model.totalValue), decimals: 0) : Fmt.missing)
                            .padding(.trailing, inset)
                            .frame(width: columnWidth, alignment: .trailing)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .font(isCompact ? .callout : .body)
        .numeric()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func amount(_ minor: Int64) -> String {
        let money = Money(minor: minor, currency: model.currency)
        return showsCents ? Fmt.money(money, symbol: false) : Fmt.moneyRounded(money, symbol: false)
    }

    @ViewBuilder private func cell(_ row: EarningsModel.MatrixRow, _ month: Int) -> some View {
        let value = row.values[month]
        if !row.covered[month] {
            Color.clear.frame(width: columnWidth, height: 26)
        } else if value == 0 {
            Text(Fmt.missing)
                .foregroundStyle(.quaternary)
                .padding(.trailing, inset)
                .frame(width: columnWidth, height: 26, alignment: .trailing)
        } else {
            let intensity = model.matrixMaximum > 0 ? Double(abs(value)) / Double(model.matrixMaximum) : 0
            let name = Fmt.month(year: row.year, month: month + 1, long: true)
            let exact = Fmt.money(minor: value, currency: model.currency)
            let label = Text(amount(value))
                .foregroundStyle(style(for: value))
                .padding(.trailing, inset)
                .frame(width: columnWidth, height: 26, alignment: .trailing)
                .background(tint(for: value).opacity(0.06 + 0.26 * intensity), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
            if drillsDown {
                Button {
                    showPayments(row.year * 12 + month)
                } label: {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(name): \(exact) — click to see the payments")
                .accessibilityLabel("\(name), \(exact)")
                .accessibilityHint("Shows the dividend payments of this month")
            } else {
                label
                    .help(model.kind.isCost && value < 0 ? "\(name): \(exact) (net refund)" : "\(name): \(exact)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name), \(exact)")
            }
        }
    }

    /// Text color of an amount. A negative fee or tax figure is a net refund — good news, not a
    /// loss; negative income (Net, Interest after charges) is one.
    private func style(for value: Int64) -> AnyShapeStyle {
        guard value < 0 else { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(model.kind.isCost ? gainStyle.gain : gainStyle.loss)
    }

    private func tint(for value: Int64) -> Color {
        guard value < 0 else { return model.kind.color }
        return model.kind.isCost ? gainStyle.gain : gainStyle.loss
    }

    @ViewBuilder private func growth(_ row: EarningsModel.MatrixRow) -> some View {
        Group {
            if let growth = row.growth {
                if model.kind.isCost {
                    Text(Fmt.percent(growth, decimals: 1, signed: true))
                } else {
                    GainText(percent: growth, decimals: 1)
                }
            } else {
                Text(Fmt.missing).foregroundStyle(.quaternary)
            }
        }
        .frame(width: growthWidth, alignment: .trailing)
        .help(row.growthIsSamePeriod
              ? "\(String(row.year)) so far against the same days of \(String(row.year - 1))"
              : row.growth == nil ? "Not comparable: needs two complete years with positive amounts"
              : "\(String(row.year)) against \(String(row.year - 1))")
    }
}
