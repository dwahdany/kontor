import SwiftUI
import KontorModel
import KontorUI

/// When each security pays, and what the next twelve months would bring if every dividend of the
/// last twelve months were paid again for the shares held today.
struct EarningsCalendarView: View {
    @Environment(PortfolioStore.self) private var store
    let model: EarningsModel
    let pinnedMonth: String?
    /// Width of the screen's content area: the month columns are sized from it.
    let width: CGFloat

    @State private var selection: UUID?

    private var calendar: EarningsModel.Calendar { model.calendar }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.l) {
                if calendar.isEmpty {
                    Card {
                        EmptyState("No Dividends in the Last Three Years", symbol: "calendar",
                                   message: "The calendar shows the months in which your securities paid. Record a dividend to start it.") {
                            Button("Record Dividend…") {
                                store.present(.newTransaction(EarningsActions.prefill(.dividend, store: store)))
                            }
                        }
                        .frame(minHeight: 260)
                    }
                } else {
                    projectionCard
                    calendarCard
                }
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.xl)
        }
    }

    // MARK: Projection

    private var projectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    Text("Expected Dividends, Next 12 Months")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    EstimateBadge()
                    Spacer(minLength: DS.Spacing.s)
                    Text("≈ \(Fmt.money(minor: calendar.expectedTotal, currency: model.currency))")
                        .font(.kontorValue)
                        .numeric()
                    Text("gross, \(Fmt.interval(calendar.interval, style: .medium))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .numeric()
                }
                BarSeriesChart(
                    categories: calendar.months,
                    series: [BarSeries(id: "expected", "Expected dividends (estimate)", values: calendar.expected, color: EarningsKind.dividends.color)],
                    format: .money(model.currency), title: "Expected dividends per month, estimate")
                    .valueLabels()
                    .legendHidden()
                    .pinnedHover(pinnedMonth)
                    .emptyMessage("Nothing to project: no dividends in the last twelve months for shares you still hold")
                    .frame(height: 190)
                Text("An estimate, not a forecast: each dividend paid in the last 12 months (\(Fmt.interval(calendar.basisInterval, style: .medium))) is assumed to be paid again a year later, at the same amount per share, for the shares held today\(model.isAccountScope ? " in the whole portfolio" : ""). Before fees and taxes; dividend changes, special dividends and future trades are not considered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Dot matrix

    private var innerWidth: CGFloat { width - 2 * DS.Spacing.xl - 2 * DS.Spacing.l - 16 }
    private var nameWidth: CGFloat { max(150, min(320, (innerWidth * 0.27).rounded(.down))) }
    private var dotWidth: CGFloat {
        max(24, min(72, ((innerWidth - nameWidth - perYearWidth - sharesWidth - expectedWidth) / 12).rounded(.down)))
    }
    private var perYearWidth: CGFloat { innerWidth < 800 ? 52 : 64 }
    private var sharesWidth: CGFloat { innerWidth < 800 ? 64 : 84 }
    private let expectedWidth: CGFloat = 104

    private var calendarCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.l) {
                    Text("Payment Months")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    legend(filled: true, "paid in the last 12 months")
                    legend(filled: false, "paid in the two years before")
                }
                .lineLimit(1)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Security").frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(0..<12, id: \.self) { month in
                            Text(ChartLabels.shortMonth(month + 1)).frame(width: dotWidth)
                        }
                        Text("Per Year")
                            .frame(width: perYearWidth, alignment: .trailing)
                            .help("Months with a dividend in the last twelve months")
                        Text("Shares")
                            .frame(width: sharesWidth, alignment: .trailing)
                            .help(model.isAccountScope ? "Shares held today in the whole portfolio" : "Shares held today (a classification counts its part of the expected amount, not of the shares)")
                        HStack(spacing: DS.Spacing.xs) {
                            Text("Expected")
                            EstimateBadge(compact: true)
                        }
                        .frame(width: expectedWidth, alignment: .trailing)
                    }
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, DS.Spacing.s)

                    ForEach(calendar.rows) { row in
                        Divider()
                        HStack(spacing: 0) {
                            Text(row.name)
                                .help(row.detail.isEmpty ? row.name : "\(row.name) · \(row.detail)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(0..<12, id: \.self) { month in
                                dot(recent: row.recent[month], earlier: row.earlier[month])
                                    .frame(width: dotWidth)
                            }
                            Text(row.paymentsPerYear == 0 ? Fmt.missing : "\(Fmt.integer(row.paymentsPerYear))×")
                                .foregroundStyle(row.paymentsPerYear == 0 ? .tertiary : .secondary)
                                .frame(width: perYearWidth, alignment: .trailing)
                            Text(row.shares.isZero ? "sold" : EarningsFormat.shares(row.shares))
                                .foregroundStyle(row.shares.isZero ? .tertiary : .secondary)
                                .frame(width: sharesWidth, alignment: .trailing)
                            Text(row.expectedTotal == 0 ? Fmt.missing : Fmt.money(minor: row.expectedTotal, currency: model.currency))
                                .foregroundStyle(row.expectedTotal == 0 ? .tertiary : .primary)
                                .frame(width: expectedWidth, alignment: .trailing)
                        }
                        .frame(height: 30)
                        .background {
                            if selection == row.id {
                                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.14))
                                    .padding(.horizontal, -DS.Spacing.s)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.navigate(to: .security(row.id)) }
                        .onTapGesture {
                            selection = row.id
                            store.setFocus(.security(row.id))
                        }
                        .contextMenu {
                            Button("Show Security") { store.navigate(to: .security(row.id)) }
                            Button("Record Dividend…") {
                                store.present(.newTransaction(EarningsActions.prefill(.dividend, securityID: row.id, store: store)))
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityLabel(row))
                        .accessibilityAddTraits(.isButton)
                    }

                    Divider()
                    HStack(spacing: 0) {
                        Text("Expected per month").fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(0..<12, id: \.self) { month in
                            // Columns are calendar months; the projection covers the twelve months after today.
                            let value = calendar.expectedByCalendarMonth[month]
                            Text(value == 0 ? Fmt.missing : Fmt.moneyRounded(Money(minor: value, currency: model.currency), symbol: false))
                                .font(.callout)
                                .foregroundStyle(value == 0 ? .tertiary : .secondary)
                                .frame(width: dotWidth)
                                .help("\(ChartLabels.shortMonth(month + 1)), within \(Fmt.interval(calendar.interval, style: .medium)): \(Fmt.money(minor: value, currency: model.currency)) expected")
                        }
                        Color.clear.frame(width: perYearWidth + sharesWidth, height: 1)
                        Text(Fmt.money(minor: calendar.expectedTotal, currency: model.currency))
                            .fontWeight(.semibold)
                            .frame(width: expectedWidth, alignment: .trailing)
                    }
                    .frame(height: 34)
                }
                .numeric()
                .lineLimit(1)
            }
        }
    }

    private func dot(recent: Bool, earlier: Bool) -> some View {
        ZStack {
            if recent {
                Circle().fill(EarningsKind.dividends.color).frame(width: 11, height: 11)
            } else if earlier {
                Circle().strokeBorder(EarningsKind.dividends.color.opacity(0.8), lineWidth: 1.5).frame(width: 11, height: 11)
            } else {
                Circle().fill(.quaternary.opacity(0.6)).frame(width: 3, height: 3)
            }
        }
        .frame(width: 22, height: 20)
    }

    private func legend(filled: Bool, _ text: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            dot(recent: filled, earlier: !filled).frame(width: 14)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func accessibilityLabel(_ row: EarningsModel.CalendarRow) -> String {
        let months = (0..<12).filter { row.recent[$0] || row.earlier[$0] }.map { ChartLabels.shortMonth($0 + 1) }
        return "\(row.name), pays in \(months.joined(separator: ", ")), expected \(Fmt.money(minor: row.expectedTotal, currency: model.currency))"
    }
}

/// Marks projected figures so they are never mistaken for booked ones.
struct EstimateBadge: View {
    var compact = false

    var body: some View {
        Text(compact ? "est." : "Estimate")
            .font(.caption2.weight(.semibold))
            .textCase(compact ? nil : .uppercase)
            .foregroundStyle(DS.Colors.warning)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 2)
            .background(DS.Colors.warning.opacity(0.14), in: Capsule())
            .help("A simple projection from past payments, not a booked amount")
    }
}
