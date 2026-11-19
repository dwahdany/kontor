import SwiftUI
import KontorUI

/// "Returns": month × year heatmap, calendar years, rolling returns, best and worst periods.
struct ReturnsTab: View {
    @Environment(PortfolioStore.self) private var store
    @Binding var model: Loadable<ReturnsModel>
    let isWide: Bool

    /// A heatmap cell the user clicked: offers to make that month the reporting period.
    @State private var pickedMonth: (year: Int, month: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            if isWide {
                HStack(alignment: .top, spacing: DS.Spacing.l) {
                    heatmap
                    VStack(spacing: DS.Spacing.l) {
                        years
                        extremes
                    }
                    .frame(width: 430)
                }
            } else {
                heatmap
                years
                extremes
            }
            rolling
        }
        .analysisTask($model, id: "performance.returns") { ReturnsModel($0) }
        .onAppear {
            if let text = store.launchValue("month"), let day = Day(iso: text + "-01") { pickedMonth = (day.year, day.month) }
        }
    }

    private var heatmap: some View {
        Card("Monthly Returns", symbol: "tablecells") {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                if let map = model.value?.heatmap {
                    HeatmapGrid(map)
                        .selection { rowID, column in
                            guard let year = Int(rowID), (0..<12).contains(column) else { return }
                            pickedMonth = (year, column + 1)
                        }
                        .loading(model.isRefreshing)
                        .emptyMessage("No complete month in this period")
                } else {
                    Color.clear.frame(height: 160)
                }
                if let picked = pickedMonth, let value = model.value?.heatmap.value(year: picked.year, month: picked.month) {
                    HStack(spacing: DS.Spacing.s) {
                        Text(Fmt.month(year: picked.year, month: picked.month, long: true)).font(.callout.weight(.medium))
                        GainText(percent: value).font(.callout)
                        Spacer()
                        Button("Show This Month") {
                            let first = Day(year: picked.year, month: picked.month, day: 1)
                            store.period = .custom(from: first.advanced(by: -1), to: min(first.endOfMonth, store.today))
                        }
                        .controlSize(.small)
                        Button("Show \(String(picked.year))") { store.period = .year(picked.year) }
                            .controlSize(.small)
                    }
                } else {
                    Text("Time-weighted return of each calendar month. Click a month to look at it on its own.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } accessory: {
            HelpButton(.ttwror)
        }
    }

    private var years: some View {
        Card("Calendar Years", symbol: "chart.bar") {
            BarSeriesChart(categories: model.value?.years ?? [], values: model.value?.yearlyReturns ?? [], name: "Return",
                           format: .percent(signed: true), title: "Return per calendar year")
                .valueLabels()
                .selection(nil) { id in
                    if let year = id.flatMap({ Int($0) }) { store.period = .year(year) }
                }
                .loading(model.isLoading)
                .emptyMessage("No returns in this period")
                .frame(height: 210)
        }
    }

    private var extremes: some View {
        Card("Best and Worst", symbol: "arrow.up.arrow.down") {
            if let m = model.value, !m.extremes.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.s) {
                        GridRow {
                            Text("")
                            ColumnCaption("Best").gridColumnAlignment(.trailing)
                            Text("")
                            ColumnCaption("Worst").gridColumnAlignment(.trailing)
                            Text("")
                        }
                        ForEach(m.extremes) { row in
                            GridRow {
                                Text(row.span).foregroundStyle(.secondary)
                                SignedPercent(value: row.best)
                                Text(row.bestLabel).font(.caption).numeric().foregroundStyle(.secondary).lineLimit(1)
                                SignedPercent(value: row.worst)
                                Text(row.worstLabel).font(.caption).numeric().foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .font(.callout)
                    Divider()
                    HStack(spacing: DS.Spacing.l) {
                        if m.monthCount > 0 {
                            share("Months with a gain", "\(Fmt.integer(m.positiveMonths)) of \(Fmt.integer(m.monthCount))",
                                  Fmt.percent(Double(m.positiveMonths) / Double(m.monthCount), decimals: 0))
                        }
                        if let positive = m.positiveYearWindows {
                            share("12-month spans with a gain", Fmt.percent(positive, decimals: 0),
                                  m.averageYearWindow.map { "average \(Fmt.percent($0, decimals: 1, signed: true))" } ?? "")
                        }
                    }
                }
                .opacity(model.isRefreshing ? 0.6 : 1)
            } else {
                Text("No returns in this period").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    private func share(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text(value).font(.callout.weight(.medium)).numeric()
                Text(detail).font(.caption).numeric().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rolling: some View {
        Card("Rolling Returns", symbol: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                TimeSeriesChart(rollingSeries, format: .percent(signed: true, compounding: false), title: "Rolling returns")
                    .timeDomain(model.value?.interval)
                    .loading(model.isLoading)
                    .emptyMessage("Rolling returns need a period longer than one year")
                    .frame(height: 230)
                Text("Each point is the return of the 12 months (or 3 years, per year) that ended on that day — how much the result depends on when you look.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } accessory: {
            HelpButton(.annualizedReturn)
        }
    }

    private var rollingSeries: [TimeSeries] {
        guard let m = model.value, m.hasRollingOneYear else { return [] }
        var series = [TimeSeries(id: "1y", "12 months", start: m.interval.start, values: m.rollingOneYear, color: ChartColors.series(0))]
        if m.hasRollingThreeYears {
            series.append(TimeSeries(id: "3y", "3 years, per year", start: m.interval.start, values: m.rollingThreeYears, color: ChartColors.series(1)))
        }
        return series
    }
}
