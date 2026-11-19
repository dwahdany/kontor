import SwiftUI
import KontorUI

/// The main chart: cumulative return against benchmarks and ad-hoc comparisons, value against
/// invested capital, or the underwater curve. Dragging across it measures a sub-range with the
/// engine (TTWROR, IRR, gain, drawdown of exactly those days).
struct PerformanceChartCard: View {
    @Environment(PortfolioStore.self) private var store
    @Environment(\.gainStyle) private var gainStyle

    let model: Loadable<OverviewModel>
    @Binding var mode: PerformanceChartMode
    let pinnedHover: Day?
    /// The selected sub-range: dragged here, or pinned by the screen (launch state, "Show in
    /// Chart" of a drawdown). Owned by the screen so that either side can replace it.
    @Binding var range: ChartRangeState
    let compare: [UUID]
    let addComparison: (UUID) -> Void
    let removeComparison: (UUID) -> Void

    @State private var figures: RangeFigures?
    @State private var pickedSecurity: UUID?

    private var activeRange: DayInterval? { range.active }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                header
                chart
                    .id(range.generation)
                    .frame(height: 300)
                if let range = activeRange {
                    RangeStrip(range: range, figures: figures?.interval == range ? figures : nil,
                               usePeriod: { usePeriod(range) }, clear: clearRange)
                        .transition(.opacity)
                } else {
                    Text("Drag across the chart to measure any stretch of the period.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: RangeKey(range: activeRange, revision: store.revision, scope: store.scope)) {
            guard let range = activeRange else {
                figures = nil
                return
            }
            if let result = try? await store.analyze("performance.range", interval: range, { RangeFigures($0) }) {
                figures = result
            }
        }
        .onChange(of: store.periodInterval) { _, _ in clearRange() }
        .onChange(of: store.scope) { _, _ in clearRange() }
    }

    private struct RangeKey: Hashable {
        var range: DayInterval?
        var revision: Int
        var scope: Scope
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Spacing.s) {
            Picker("Chart", selection: $mode) {
                ForEach(PerformanceChartMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch the chart with ⌃⌥1 – ⌃⌥3")
            HelpButton(helpTopic)
            Spacer(minLength: DS.Spacing.s)
            if mode != .value {
                comparisonMenu
                SearchablePicker("Compare with", selection: $pickedSecurity, items: pickerItems, placeholder: "Compare with…")
                    .frame(maxWidth: 190)
                    .onChange(of: pickedSecurity) { _, id in
                        guard let id else { return }
                        addComparison(id)
                        pickedSecurity = nil
                    }
                    .help("Add a security or index to the chart")
            }
        }
    }

    private var helpTopic: HelpTopic {
        switch mode {
        case .returns: .benchmark
        case .value: .investedCapital
        case .drawdown: .maxDrawdown
        }
    }

    /// The ad-hoc comparisons, removable — every one that was asked for, also those the chart
    /// cannot draw. (Benchmarks from the settings are toggled in the legend.)
    @ViewBuilder private var comparisonMenu: some View {
        let drawn = Dictionary(uniqueKeysWithValues: (model.value?.comparisons ?? []).map { ($0.id, $0) })
        let benchmarks = Set(store.file.settings.benchmarkSecurityIDs)
        let adHoc = compare.filter { !benchmarks.contains($0) }
        if !adHoc.isEmpty {
            Menu {
                ForEach(adHoc, id: \.self) { id in
                    let name = store.security(id)?.name ?? "Unknown Security"
                    if let item = drawn[id] {
                        Menu("\(name)  \(Fmt.percent(item.total, signed: true))") {
                            Button("Remove from Chart") { removeComparison(id) }
                            Button("Keep as Benchmark") { keepAsBenchmark(item) }
                            Divider()
                            Button("Open Security") { store.navigate(to: .security(id)) }
                        }
                    } else {
                        // Asked for, but not in the chart: no prices, or the model is still loading.
                        Menu(model.isLoading ? name : "\(name)  (cannot be drawn)") {
                            Button("Remove from Chart") { removeComparison(id) }
                            Divider()
                            Button("Open Security") { store.navigate(to: .security(id)) }
                        }
                    }
                }
                Divider()
                Button("Remove All Comparisons") { adHoc.forEach(removeComparison) }
            } label: {
                Text("Comparing \(adHoc.count)")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Securities you added to this chart")
        }
    }

    /// Securities that can be added: not shown yet, and with prices the chart can draw.
    private var pickerItems: [PickerItem<UUID>] {
        let benchmarks = Set(store.file.settings.benchmarkSecurityIDs)
        let shown = Set(compare).union(benchmarks)
        let ledger = store.ledger
        let day = store.periodInterval.start
        return store.file.securities
            .filter { !shown.contains($0.id) && ComparisonRules.canDraw($0.id, ledger: ledger, on: day) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { PickerItem(id: $0.id, title: $0.name, detail: $0.ticker.isEmpty ? $0.isin : $0.ticker,
                              keywords: [$0.isin, $0.wkn, $0.ticker], isDimmed: $0.isRetired) }
    }

    private func keepAsBenchmark(_ item: ComparisonInfo) {
        let changed = store.mutate("Add Benchmark") { file in
            if !file.settings.benchmarkSecurityIDs.contains(item.id) { file.settings.benchmarkSecurityIDs.append(item.id) }
        }
        if changed {
            removeComparison(item.id)
            store.toast("\(item.name) is now a benchmark", style: .success)
        }
    }

    // MARK: Chart

    private var chart: TimeSeriesChart {
        let m = model.value
        let base: TimeSeriesChart
        switch mode {
        case .returns:
            base = TimeSeriesChart(m?.returnSeries ?? [], format: .percent(signed: true), title: "Cumulative return")
        case .value:
            base = TimeSeriesChart(m?.valueSeries ?? [], format: .money(m?.currency ?? store.baseCurrency), title: "Value and invested capital")
        case .drawdown:
            var series = m?.drawdownSeries ?? []
            if !series.isEmpty { series[0].color = gainStyle.loss }
            base = TimeSeriesChart(series, format: .percent(), title: "Drawdown from the previous peak")
        }
        return base
            .timeDomain(m?.interval)
            .rangeSelection { selection in
                range.drag(selection?.interval)
            }
            .pinnedHover(activeRange == nil ? pinnedHover : nil)
            .pinnedRange(range.dragged == nil ? range.pinned : nil)
            .loading(model.isLoading)
            .emptyMessage("Nothing to chart in this period")
    }

    private func clearRange() {
        range.clear()      // a new chart identity drops the chart's own selection
    }

    private func usePeriod(_ range: DayInterval) {
        store.period = .custom(from: range.start, to: range.end)
    }
}

/// The engine's figures for the selected sub-range.
private struct RangeStrip: View {
    let range: DayInterval
    let figures: RangeFigures?
    let usePeriod: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                // The days the figures cover, like the screen's heading: the range's first day is
                // the baseline (its close opens the measurement), so the label starts the day after.
                Text(Fmt.interval(range))
                    .font(.callout.weight(.medium))
                    .numeric()
                Text("\(Fmt.duration(days: range.dayCount)) · from the close of \(Fmt.day(range.start, style: .medium))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            figure("TTWROR") { SignedPercent(value: figures?.ttwror) }
            figure((figures?.isAnnualized ?? ReturnHorizon.isAnnualized(days: range.dayCount)) ? "IRR per year" : "IRR, not annualized") {
                SignedPercent(value: figures?.moneyWeightedReturn)
            }
            figure("Gain") {
                if let figures {
                    GainText(money: Money(minor: figures.absolutePerformance, currency: figures.currency))
                } else {
                    Text(Fmt.missing).foregroundStyle(.tertiary)
                }
            }
            figure("Max Drawdown") {
                Text(figures.map { Fmt.percent(-($0.maxDrawdown ?? 0)) } ?? Fmt.missing).numeric()
            }
            Spacer(minLength: 0)
            Button("Use as Period", action: usePeriod)
                .help("Set the reporting period to the selected range")
            Button("Clear", systemImage: "xmark", action: clear)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Clear the selection")
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected range")
    }

    private func figure(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            value().font(.callout.weight(.medium))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}
