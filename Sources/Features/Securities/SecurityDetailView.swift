import SwiftUI
import KontorUI
import KontorMarketData

/// The detail of one security: header, tab strip and the selected tab.
struct SecurityDetailView: View {
    @Environment(PortfolioStore.self) private var store
    let securityID: UUID
    /// The pane is narrow: tighter margins, flexible controls.
    var compact = false
    @Bindable var view: SecurityViewState

    var body: some View {
        if let security = store.security(securityID) {
            VStack(spacing: 0) {
                SecurityHeader(security: security)
                    .padding(.horizontal, compact ? DS.Spacing.l : DS.Spacing.xl)
                    .padding(.top, DS.Spacing.l)
                    .padding(.bottom, DS.Spacing.m)
                DetailTabStrip(selection: $view.tab, inset: compact ? DS.Spacing.l : DS.Spacing.xl, counts: [
                    .transactions: store.transactions(forSecurity: securityID).count,
                    .prices: security.prices.count,
                    .events: security.events.count,
                ])
                Divider()
                Group {
                    switch view.tab {
                    case .overview: SecurityOverview(security: security, compact: compact, view: view).id(securityID)
                    case .transactions: SecurityTransactionsTab(securityID: securityID).id(securityID)
                    case .prices: SecurityPricesTab(security: security, view: view).id(securityID)
                    case .events: SecurityEventsTab(security: security, view: view).id(securityID)
                    case .source: SecurityFeedTab(security: security).id(securityID)
                    case .notes: SecurityNotesTab(security: security).id(securityID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - Header

private struct SecurityHeader: View {
    @Environment(PortfolioStore.self) private var store
    let security: Security

    var body: some View {
        let latest = security.prices.latest
        let previous = security.prices.count >= 2 ? security.prices[security.prices.count - 2] : nil
        HStack(alignment: .top, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(security.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                identifiers
                HStack(spacing: DS.Spacing.s) {
                    Button("Edit…") { store.present(.editSecurity(security.id)) }
                        .keyboardShortcut("e", modifiers: .command)
                        .help("Edit master data (⌘E)")
                    Menu {
                        ForEach([Transaction.Kind.buy, .sell, .dividend, .deliveryIn, .deliveryOut], id: \.self) { kind in
                            Button(kind.title) { store.presentNewTransaction(kind, securityID: security.id) }
                        }
                    } label: {
                        Label("Transaction", systemImage: "plus")
                    } primaryAction: {
                        store.presentNewTransaction(.buy, securityID: security.id)
                    }
                    .fixedSize()
                    .help("Record a purchase — hold for sale, dividend or delivery")
                    Menu {
                        SecurityContextMenu(store: store, ids: [security.id])
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }
                .controlSize(.small)
                .padding(.top, DS.Spacing.xs)
            }
            Spacer(minLength: DS.Spacing.s)
            VStack(alignment: .trailing, spacing: DS.Spacing.xxs) {
                Text(latest.map { Fmt.price($0.price, currency: security.currency) } ?? Fmt.missing)
                    .font(.kontorHero)
                    .lineLimit(1)
                    .fixedSize()
                if let latest, let previous, previous.price.raw > 0 {
                    let delta = latest.price.raw - previous.price.raw
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        DeltaLabel(fraction: Double(latest.price.raw) / Double(previous.price.raw) - 1)
                        GainText((delta > 0 ? "+" : "") + Fmt.price(Price(raw: delta), currency: security.currency, maxDecimals: 4),
                                 trend: Trend(Double(delta)))
                    }
                    .font(.callout)
                    .fixedSize()
                    .help("Change against the previous quote (\(Fmt.day(previous.day, style: .medium)))")
                }
                Text(quoteLine(latest))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var identifiers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.s) { identifierItems(short: false) }
            HStack(spacing: DS.Spacing.s) { identifierItems(short: true) }
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) { identifierItems(short: true) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func identifierItems(short: Bool) -> some View {
        if !security.ticker.isEmpty { Text(security.ticker).fontWeight(.medium).foregroundStyle(.primary).textSelection(.enabled) }
        if !security.isin.isEmpty { Text(short ? security.isin : "ISIN \(security.isin)").textSelection(.enabled) }
        if !security.wkn.isEmpty, !short { Text("WKN \(security.wkn)").textSelection(.enabled) }
        Text(short ? security.currency : "\(security.currency) · \(Currencies.name(security.currency))").lineLimit(1)
        if security.isRetired { StatusBadge(title: "Retired", symbol: "archivebox") }
        if store.isBenchmark(security.id) { StatusBadge(title: "Benchmark", symbol: "flag", tint: .accentColor) }
    }

    private func quoteLine(_ latest: PricePoint?) -> String {
        guard let latest else { return "No quotes yet" }
        let feed = security.feed.flatMap { MarketAccess.providerNames(store)[$0.provider] }
        return [Fmt.relativeDay(latest.day, today: store.today), feed].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Tab strip

private struct DetailTabStrip: View {
    @Binding var selection: DetailTab
    var inset = DS.Spacing.xl
    let counts: [DetailTab: Int]

    var body: some View {
        // Every tab stays reachable: first tighter spacing without the counts, and only when even
        // that does not fit a scrolling strip whose trailing edge fades out to show there is more.
        ViewThatFits(in: .horizontal) {
            strip(spacing: DS.Spacing.l, showsCounts: true)
            strip(spacing: DS.Spacing.m, showsCounts: false)
            ScrollView(.horizontal) { strip(spacing: DS.Spacing.m, showsCounts: false) }
                .scrollIndicators(.never)
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func strip(spacing: CGFloat, showsCounts: Bool) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(tab.title)
                            .fontWeight(selection == tab ? .semibold : .regular)
                            .foregroundStyle(selection == tab ? .primary : .secondary)
                        if showsCounts, let count = counts[tab], count > 0 {
                            Text(Fmt.integer(count)).font(.caption).numeric().foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selection == tab ? Color.accentColor : .clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                .help("\(tab.title) (⌃\(index + 1))")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, inset)
    }
}

// MARK: - Overview

struct SecurityOverview: View {
    @Environment(PortfolioStore.self) private var store
    let security: Security
    var compact = false
    @Bindable var view: SecurityViewState

    @State private var chart = Loadable<SecurityChartModel>()
    @State private var figures = Loadable<SecurityFigures>()

    private var chartQuery: ChartQuery {
        ChartQuery(securityID: security.id, showsPurchasePrice: view.showsPurchasePrice, showsAverage50: view.showsAverage50,
                   showsAverage200: view.showsAverage200, compareID: view.compareID)
    }

    var body: some View {
        let query = chartQuery
        let id = security.id
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                chartCard
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DS.Spacing.l) {
                        positionCard.frame(minWidth: 300)
                        performanceCard.frame(minWidth: 300)
                    }
                    VStack(spacing: DS.Spacing.l) {
                        positionCard
                        performanceCard
                    }
                }
            }
            .padding(compact ? DS.Spacing.m : DS.Spacing.xl)
        }
        .analysisTask($chart, id: "securities.chart", scope: .security(id),
                      interval: view.range.interval(for: security, today: store.today), variant: query) { analysis in
            SecurityChartModel(analysis, query: query)
        }
        .analysisTask($figures, id: "securities.figures", scope: .security(id), variant: id) { analysis in
            SecurityFigures(analysis, securityID: id)
        }
    }

    // MARK: Chart

    /// The loaded model, unless it still belongs to the previously selected security.
    private var chartModel: SecurityChartModel? { chart.value }

    private var chartCard: some View {
        Card(padding: compact ? DS.Spacing.m : DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Spacing.m) {
                        rangePicker
                        Spacer(minLength: DS.Spacing.s)
                        chartOptions
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        rangePicker
                        chartOptions
                    }
                }
                if security.prices.isEmpty {
                    EmptyState("No Quotes Yet", symbol: "chart.xyaxis.line",
                               message: "Set up a data source to download the price history, or add quotes by hand.") {
                        Button("Set Up Data Source") { view.tab = .source }
                        Button("Add Quotes") { view.tab = .prices }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                } else {
                    TimeSeriesChart(chartModel?.series ?? [], format: chartModel?.format ?? .price(security.currency),
                                    baseline: chartModel?.isComparison == true ? .zero : .data,
                                    title: "Price of \(security.displayName)")
                        .markers(chartModel?.markers ?? [])
                        .timeDomain(chartModel?.interval)
                        .pinnedHover(view.pinnedHover)
                        .legendHidden((chartModel?.series.count ?? 0) < 2)
                        .loading(chart.isLoading)
                        .emptyMessage("No quotes in this period")
                        .frame(height: compact ? 220 : 260)
                    chartSummary
                }
            }
        }
    }

    private var rangePicker: some View {
        Picker("Chart period", selection: $view.range) {
            ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: !compact, vertical: false)
        .help("Period of this chart — independent of the reporting period in the toolbar")
    }

    private var chartOptions: some View {
        HStack(spacing: DS.Spacing.s) {
            Menu {
                Toggle("Purchase Price", isOn: $view.showsPurchasePrice)
                Toggle("50-Day Average", isOn: $view.showsAverage50)
                Toggle("200-Day Average", isOn: $view.showsAverage200)
            } label: {
                Label(indicatorTitle, systemImage: "chart.line.uptrend.xyaxis")
            }
            .fixedSize()
            .disabled(view.compareID != nil)
            .help(view.compareID != nil
                  ? "Lines are hidden while comparing — both securities are shown as percentage change."
                  : "Purchase price is your average cost per share; moving averages smooth the last 50 or 200 quotes.")
            comparePicker
        }
        .controlSize(.small)
    }

    private var indicatorTitle: String {
        let count = [view.showsPurchasePrice, view.showsAverage50, view.showsAverage200].filter { $0 }.count
        return count == 0 ? "Lines" : "Lines (\(count))"
    }

    private var comparePicker: some View {
        Menu {
            Button("No Comparison") { view.compareID = nil }
            let benchmarks = store.file.settings.benchmarkSecurityIDs.compactMap { store.security($0) }.filter { $0.id != security.id }
            if !benchmarks.isEmpty {
                Section("Benchmarks") {
                    ForEach(benchmarks) { other in compareButton(other) }
                }
            }
            Section("Securities") {
                ForEach(store.file.securities.filter { $0.id != security.id && !$0.isRetired && !benchmarks.contains($0) }.prefix(40)) { other in
                    compareButton(other)
                }
            }
        } label: {
            Label(view.compareID.flatMap { store.security($0)?.displayName }.map { "vs. \($0)" } ?? "Compare", systemImage: "arrow.left.arrow.right")
                .lineLimit(1)
        }
        .frame(maxWidth: 220)
        .fixedSize()
        .help("Compare the price development with another security (percentage change since the start of the period)")
    }

    private func compareButton(_ other: Security) -> some View {
        Button {
            view.compareID = other.id
        } label: {
            if view.compareID == other.id { Label(other.displayName, systemImage: "checkmark") } else { Text(other.displayName) }
        }
    }

    @ViewBuilder private var chartSummary: some View {
        if let model = chartModel, !model.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Spacing.l) { summaryItems(model, compact: false, note: true) }
                HStack(spacing: DS.Spacing.m) { summaryItems(model, compact: true, note: true) }
                HStack(spacing: DS.Spacing.m) { summaryItems(model, compact: true, note: false) }
            }
            .font(.callout)
            .numeric()
            .lineLimit(1)
        }
    }

    @ViewBuilder private func summaryItems(_ model: SecurityChartModel, compact: Bool, note: Bool) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(compact ? view.range.title : "Change (\(view.range.title))").foregroundStyle(.secondary)
            if let change = model.change { GainText(percent: change) } else { Text(Fmt.missing) }
        }
        if let problem = model.comparisonProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Colors.warning)
                .lineLimit(1)
        }
        if let name = model.comparisonName, let change = model.comparisonChange {
            HStack(spacing: DS.Spacing.xs) {
                Text(name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                GainText(percent: change)
            }
        }
        if let high = model.high {
            HStack(spacing: DS.Spacing.xs) {
                Text("High").foregroundStyle(.secondary)
                Text(Fmt.price(high.price, currency: model.currency))
                if !compact { Text(Fmt.day(high.day, style: .medium)).foregroundStyle(.tertiary) }
            }
        }
        if let low = model.low {
            HStack(spacing: DS.Spacing.xs) {
                Text("Low").foregroundStyle(.secondary)
                Text(Fmt.price(low.price, currency: model.currency))
                if !compact { Text(Fmt.day(low.day, style: .medium)).foregroundStyle(.tertiary) }
            }
        }
        if model.markersHidden, note {
            Text(compact ? "\(Fmt.integer(model.markerCount)) transactions hidden" : "\(Fmt.integer(model.markerCount)) transactions — shorten the period to see them")
                .foregroundStyle(.tertiary)
                .help("Markers for purchases, sales and dividends are shown for up to \(SecurityChartModel.markerLimit) transactions.")
        }
        if model.interval.end < store.today, let last = security.prices.lastDay {
            Text(compact ? "ends \(Fmt.day(last, style: .medium))" : "Quotes end \(Fmt.day(last, style: .medium))")
                .foregroundStyle(.tertiary)
                .help("There are no newer quotes, so the chart periods end on the latest quote instead of today.")
        }
        Spacer(minLength: 0)
    }

    // MARK: Key figures

    private let figureColumns = [GridItem(.adaptive(minimum: 128), spacing: DS.Spacing.l, alignment: .topLeading)]

    /// Why figures show "–": a missing quote or exchange rate.
    @ViewBuilder private func problemNote(_ model: SecurityFigures) -> some View {
        if let note = model.problemNote {
            Label(note, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(DS.Colors.warning)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("Figures that depend on it cannot be calculated and show “–”. Add quotes on the Prices tab; exchange rates come with the quote update.")
        }
    }

    private var positionCard: some View {
        Card("Position", symbol: "briefcase") {
            if let model = figures.value {
                if model.isHeld {
                    LazyVGrid(columns: figureColumns, alignment: .leading, spacing: DS.Spacing.m) {
                        Figure(label: "Shares") { Text(Fmt.shares(model.shares)).numeric() }
                        Figure(label: "Market Value", footnote: foreignValue(model)) {
                            Text(Fmt.money(model.value)).numeric()
                        }
                        Figure(label: "Cost Basis", topic: .costBasis) { Text(Fmt.money(model.costBasis)).numeric() }
                        Figure(label: "Purchase Price", topic: .purchasePrice,
                               footnote: model.purchasePriceInSecurityCurrency.map { Fmt.price($0, currency: model.securityCurrency, maxDecimals: 4) }) {
                            Text(model.purchasePrice.map { Fmt.price($0, currency: model.currency) } ?? Fmt.missing).numeric()
                        }
                        Figure(label: "Unrealized Gain", topic: .unrealizedGains,
                               footnote: model.unrealizedGainFraction.map { Fmt.percent($0, signed: true) }) {
                            if let gain = model.unrealizedGain { GainText(money: gain) } else { Text(Fmt.missing) }
                        }
                    }
                    problemNote(model)
                    if model.holdings.count > 1 {
                        Divider()
                        VStack(spacing: DS.Spacing.xs) {
                            ForEach(model.holdings) { holding in
                                HStack {
                                    Button(holding.depot) { store.navigate(to: .depot(holding.id)) }
                                        .buttonStyle(.link)
                                    Spacer()
                                    Text(Fmt.shares(holding.shares)).foregroundStyle(.secondary)
                                    Text(Fmt.money(holding.value)).frame(minWidth: 90, alignment: .trailing)
                                }
                                .font(.callout)
                                .numeric()
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text(notHeldText(model))
                            .foregroundStyle(.secondary)
                        if !security.isRetired {
                            Button("Record a Purchase…") { store.presentNewTransaction(.buy, securityID: security.id) }
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                figuresPlaceholder
            }
        } accessory: {
            Text("as of \(Fmt.day(store.periodInterval.end, style: .medium))").font(.caption).foregroundStyle(.secondary).numeric()
        }
        .opacity(figures.isRefreshing ? 0.6 : 1)
    }

    private func foreignValue(_ model: SecurityFigures) -> String? {
        guard model.securityCurrency != model.currency, let value = model.valueInSecurityCurrency, model.isValued else { return nil }
        return Fmt.money(value)
    }

    private func notHeldText(_ model: SecurityFigures) -> String {
        if model.transactionCount == 0 { return "Not held — on your watchlist only." }
        // The card is as of the end of the reporting period, which may lie in the past.
        return model.interval.end < store.today ? "Not held on \(Fmt.day(model.interval.end, style: .medium))." : "Not held at the moment."
    }

    private var performanceCard: some View {
        Card("Performance", symbol: "chart.line.uptrend.xyaxis") {
            if let model = figures.value {
                if model.hasActivity {
                    let money = { (minor: Int64) in Money(minor: minor, currency: model.currency) }
                    LazyVGrid(columns: figureColumns, alignment: .leading, spacing: DS.Spacing.m) {
                        Figure(label: "TTWROR", topic: .ttwror,
                               footnote: model.ttwrorAnnualized.map { "\(Fmt.percent($0, signed: true)) per year" }) {
                            if let value = model.ttwror { GainText(percent: value) } else { Text(Fmt.missing) }
                        }
                        Figure(label: "IRR", topic: .irr, footnote: "per year") {
                            if let value = model.irr { GainText(percent: value) } else { Text(Fmt.missing) }
                        }
                        Figure(label: "Realized Gain", topic: .realizedGains) {
                            if model.isCostKnown, model.arePeriodAmountsKnown { GainText(money: money(model.realizedGain)) } else { Text(Fmt.missing) }
                        }
                        Figure(label: "Dividends", topic: .grossVersusNet,
                               footnote: model.dividendCount == 0 ? "none" : "\(model.dividendCount) payment\(model.dividendCount == 1 ? "" : "s"), gross") {
                            Text(model.arePeriodAmountsKnown ? Fmt.money(money(model.dividends)) : Fmt.missing).numeric()
                        }
                        Figure(label: "Fees & Taxes", footnote: model.arePeriodAmountsKnown ? "fees \(Fmt.money(money(model.fees)))" : nil) {
                            Text(model.arePeriodAmountsKnown ? Fmt.money(money(model.fees + model.taxes)) : Fmt.missing).numeric()
                        }
                    }
                    problemNote(model)
                } else {
                    Text("No position or transactions in this period.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                figuresPlaceholder
            }
        } accessory: {
            HStack(spacing: DS.Spacing.xs) {
                Text(Fmt.interval(store.periodInterval)).font(.caption).foregroundStyle(.secondary).numeric().lineLimit(1)
                HelpButton(.reportingPeriod)
            }
        }
        .opacity(figures.isRefreshing ? 0.6 : 1)
    }

    private var figuresPlaceholder: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
    }
}
