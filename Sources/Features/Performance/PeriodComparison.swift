import SwiftUI
import KontorUI

/// The standard periods side by side — TTWROR and IRR each, for the window's scope. Every row
/// computes on its own when it appears (the analysis layer caches it per document revision);
/// clicking a row makes it the reporting period.
struct PeriodComparisonCard: View {
    enum Layout { case column, row }

    @Environment(PortfolioStore.self) private var store
    let layout: Layout

    static let periods: [ReportingPeriod] = [.monthToDate, .ytd, .lastYears(1), .lastYears(3), .lastYears(5), .allTime]

    var body: some View {
        Card("Periods", symbol: "calendar") {
            switch layout {
            case .column:
                VStack(spacing: 0) {
                    HStack(spacing: DS.Spacing.s) {
                        Text("Period").frame(maxWidth: .infinity, alignment: .leading)
                        ColumnCaption("TTWROR", topic: .ttwror).frame(width: 84, alignment: .trailing)
                        ColumnCaption("IRR p.a.", topic: .irr).frame(width: 84, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.s)
                    .padding(.bottom, DS.Spacing.xs)
                    ForEach(Self.periods, id: \.self) { period in
                        PeriodRow(period: period, layout: layout)
                    }
                    Spacer(minLength: DS.Spacing.s)
                    footnote
                }
                .frame(maxHeight: .infinity, alignment: .top)
            case .row:
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    HStack(spacing: DS.Spacing.s) {
                        ForEach(Self.periods, id: \.self) { period in
                            PeriodRow(period: period, layout: layout)
                        }
                    }
                    footnote
                }
            }
        } accessory: {
            HelpButton(.ttwrorVersusIRR)
        }
    }

    private var footnote: some View {
        Text("TTWROR is the total return of the period; IRR is your money-weighted return per year. Click a period to use it.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PeriodRow: View {
    @Environment(PortfolioStore.self) private var store
    let period: ReportingPeriod
    let layout: PeriodComparisonCard.Layout

    @State private var figures = Loadable<PeriodFigures>()
    @State private var isHovered = false

    private var isCurrent: Bool { store.periodInterval == store.interval(for: period) }

    var body: some View {
        Button {
            store.period = period
        } label: {
            label
                .padding(.horizontal, DS.Spacing.s)
                .padding(.vertical, layout == .column ? 7 : DS.Spacing.s)
                .frame(maxWidth: .infinity)
                .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(figures.isRefreshing ? 0.6 : 1)
        .help("\(period.title): \(Fmt.interval(store.interval(for: period)))")
        .accessibilityLabel("\(period.title), TTWROR \(Fmt.percent(figures.value?.ttwror, signed: true)), IRR \(Fmt.percent(figures.value?.irr, signed: true))")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .analysisTask($figures, id: "performance.period", interval: store.interval(for: period)) { PeriodFigures($0) }
    }

    private var background: some ShapeStyle {
        isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.06 : 0))
    }

    @ViewBuilder private var label: some View {
        switch layout {
        case .column:
            HStack(spacing: DS.Spacing.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(period.title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                    if let value = figures.value {
                        Text(Fmt.money(minor: value.absolutePerformance, currency: value.currency, signed: true))
                            .font(.caption)
                            .numeric()
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                SignedPercent(value: figures.value?.ttwror).frame(width: 84, alignment: .trailing)
                SignedPercent(value: figures.value?.irr).frame(width: 84, alignment: .trailing)
            }
            .font(.callout)
        case .row:
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(period.shortTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                SignedPercent(value: figures.value?.ttwror)
                    .font(.callout.weight(.medium))
                HStack(spacing: DS.Spacing.xs) {
                    Text("IRR").foregroundStyle(.tertiary)
                    SignedPercent(value: figures.value?.irr)
                }
                .font(.caption)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
