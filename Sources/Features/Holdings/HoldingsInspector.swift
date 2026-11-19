import SwiftUI
import KontorUI

/// What the inspector shows about the focused holding. Built off the main actor.
struct HoldingDetail: Sendable {
    struct Query: Hashable, Sendable {
        var securityID: UUID?
        var accountID: UUID?
        /// The statement day; nil = the end of the analysis interval (see `HoldingsQuery.day`).
        var day: Day?
        var hasPeriodFigures = true
    }

    struct DepotLine: Sendable, Identifiable {
        var id: UUID
        var name: String
        var shares: Shares
        var value: Int64
        var costBasis: Int64
        var share: Double?
    }

    struct Lot: Sendable, Identifiable {
        var id: Int
        var acquired: Day
        var depotName: String
        var shares: Shares
        var cost: Int64
        var value: Int64
        var holdingDays: Int
        var gain: Int64 { value - cost }
        var gainFraction: Double? { cost > 0 ? Double(value - cost) / Double(cost) : nil }
    }

    enum Subject: Sendable { case none, security, account }

    var subject = Subject.none
    var day: Day
    var reportingCurrency: CurrencyCode
    var name = ""
    var detail = ""
    var currency: CurrencyCode = ""
    var isHeld = false
    var isValued = true
    var isClassificationScope = false
    /// Part of the position inside the scope in basis points; nil = all of it.
    var assignedWeight: Int?
    var valuationIssue: HoldingRow.ValuationIssue?
    var hasPeriodFigures = true
    /// The part of the position inside the scope (scaled like its value in a classification scope).
    var shares: Shares?
    var price: Price?
    var priceDay: Day?
    var localValue: Int64?
    var value: Int64 = 0
    var weight: Double?
    var costBasis: Int64?
    var purchasePrice: Price?
    var gain: Int64?
    var gainFraction: Double?
    var ttwror: Double?
    var irr: Double?
    var dividends: Int64?
    var realized: Int64?
    var depots: [DepotLine] = []
    var lots: [Lot] = []
    var costMethod = CostMethod.fifo
    /// Daily price levels in the reporting currency, starting at `chartStart`.
    var chartStart: Day
    var levels: [Double] = []
    var purchaseLevel: Double?
    var markers: [ChartMarker] = []
    // Statement summary (no focus).
    var totalValue: Int64 = 0
    var positionCount = 0
    var cashCount = 0

    init(_ analysis: Analysis, query: Query) {
        let ledger = analysis.ledger
        let statementDay = query.day ?? analysis.interval.end
        let snapshot = statementDay == analysis.interval.end ? analysis.snapshot : ledger.snapshot(on: statementDay, scope: analysis.scope)
        hasPeriodFigures = query.hasPeriodFigures
        day = snapshot.day
        reportingCurrency = analysis.currency
        chartStart = snapshot.day.advanced(by: -365)
        totalValue = snapshot.totalValue.minor
        positionCount = snapshot.positions.count
        cashCount = snapshot.cash.count { $0.balance.minor != 0 }
        costMethod = ledger.settings.costMethod
        if case .weighted = analysis.scope { isClassificationScope = true }

        if let id = query.securityID, let security = ledger.security(id) {
            subject = .security
            name = security.name
            detail = [security.ticker, security.isin, security.wkn].filter { !$0.isEmpty }.joined(separator: " · ")
            currency = security.currency
            let quote = ledger.price(of: id, on: day)
            price = quote?.price
            priceDay = quote?.day
            let chartInterval = DayInterval(start: chartStart, end: day)
            levels = ledger.priceLevels(securityID: id, in: chartInterval) ?? []
            markers = ChartMarker.markers(for: ledger.transactions(forSecurity: id).filter { chartInterval.contains($0.date) })
            if query.hasPeriodFigures, let record = analysis.security(id) {
                ttwror = record.ttwror
                irr = record.irr
                dividends = record.dividends
                realized = record.realizedGain
            }
            if let position = snapshot.position(id) {
                // In a classification scope every share count is the assigned part, like the money.
                let scopeWeight = Int32(clamping: position.weight)
                func inScope(_ shares: Shares) -> Shares {
                    position.weight == 10_000 ? shares : Shares(raw: FixedMath.weighted(shares.raw, scopeWeight))
                }
                isHeld = true
                isValued = position.isValued
                if !position.isValued { valuationIssue = position.price == nil ? .noPrice : .noExchangeRate }
                // Value and cost of a classification scope are the assigned part; so are the shares.
                if position.weight != 10_000 { assignedWeight = position.weight }
                shares = inScope(position.shares)
                localValue = position.valueInSecurityCurrency.minor
                value = position.value.minor
                weight = snapshot.share(of: position)
                costBasis = position.costBasis.minor
                purchasePrice = position.purchasePrice
                gain = position.unrealizedGain.minor
                gainFraction = position.unrealizedGainFraction
                purchaseLevel = position.purchasePrice?.doubleValue
                depots = position.holdings.map { holding in
                    DepotLine(
                        id: holding.depotID, name: ledger.depot(holding.depotID)?.name ?? "Depot", shares: inScope(holding.shares),
                        value: holding.value.minor, costBasis: holding.costBasis.minor,
                        share: position.value.minor > 0 ? Double(holding.value.minor) / Double(position.value.minor) : nil)
                }
                // Each lot's value is its share of the position's value, so lots add up to the row.
                let open = ledger.openLots(on: day, scope: analysis.scope).filter { $0.securityID == id }
                lots = open.sorted { $0.acquired < $1.acquired }.enumerated().map { index, lot in
                    Lot(
                        id: index, acquired: lot.acquired, depotName: ledger.depot(lot.depotID)?.name ?? "Depot", shares: inScope(lot.shares),
                        cost: lot.cost,
                        value: position.shares.raw != 0 ? mulDiv(position.value.minor, lot.shares.raw, position.shares.raw) : 0,
                        holdingDays: lot.acquired.distance(to: day))
                }
            }
        } else if let id = query.accountID, let account = ledger.account(id) {
            subject = .account
            name = account.name
            detail = "Cash account"
            currency = account.currency
            if let cash = snapshot.cash(id) {
                isHeld = true
                isValued = cash.isValued
                if !cash.isValued { valuationIssue = .noExchangeRate }
                localValue = cash.balance.minor
                value = cash.value.minor
                weight = snapshot.totalValue.minor > 0 ? Double(cash.value.minor) / Double(snapshot.totalValue.minor) : nil
            }
        }
    }
}

/// The trailing inspector of the Holdings screen: tax lots, depots and a price chart with the
/// purchase price for the selected position.
struct HoldingsInspector: View {
    @Environment(PortfolioStore.self) private var store
    @State private var detail = Loadable<HoldingDetail>()

    var body: some View {
        let state = HoldingsViewState.of(store)
        let period = state.statementPeriod(in: store)
        let query = HoldingDetail.Query(
            securityID: store.route.securityID, accountID: store.route.accountID, day: period.day, hasPeriodFigures: period.hasFigures)
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                if let detail = detail.value {
                    switch detail.subject {
                    case .security: security(detail)
                    case .account: account(detail)
                    case .none: overview(detail)
                    }
                }
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(detail.isRefreshing ? 0.7 : 1)
        }
        .loadingOverlay(detail.isInitialLoad)
        .analysisTask($detail, id: "holdings.detail", interval: period.interval, variant: query) { analysis in
            HoldingDetail(analysis, query: query)
        }
    }

    // MARK: Security

    @ViewBuilder private func security(_ d: HoldingDetail) -> some View {
        header(d)

        if d.isHeld {
            HStack(spacing: DS.Spacing.s) {
                Button("Buy…") { HoldingsActions.buy(row(d), in: store) }
                Button("Sell…") { HoldingsActions.sell(row(d), in: store) }
                Button("Dividend…") { HoldingsActions.recordDividend(row(d), in: store) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }

        if d.levels.count >= 2 {
            section("Price, 1 Year") {
                TimeSeriesChart(chartSeries(d), format: .price(d.reportingCurrency), baseline: .data, title: "Price of \(d.name) over one year")
                    .markers(d.markers)
                    .legendHidden(d.purchaseLevel == nil)
                    .loading(detail.isRefreshing)
                    .emptyMessage("No prices yet")
                    .frame(height: 170)
                    .environment(\.chartSurface, Color.clear)
                if d.currency != d.reportingCurrency {
                    Text("Converted to \(d.reportingCurrency) at each day's rate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if d.isHeld {
            section("Position") {
                kv("Shares", d.shares.map { Fmt.shares($0) } ?? "")
                if let weight = d.assignedWeight {
                    Text("\(Fmt.percent(basisPoints: weight, decimals: weight % 100 == 0 ? 0 : 2)) of the position is in \(store.scopeTitle). Shares, value and cost are that part.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                kv("Price", d.price.map { Fmt.price($0, currency: d.currency) } ?? "")
                if d.isValued {
                    kv("Market Value", Fmt.money(minor: d.value, currency: d.reportingCurrency))
                } else {
                    kv("Market Value", d.valuationIssue == .noExchangeRate ? "No \(d.currency) rate" : "No price")
                }
                if d.currency != d.reportingCurrency, let local = d.localValue {
                    kv("in \(d.currency)", Fmt.money(minor: local, currency: d.currency))
                }
                kv("Weight", Fmt.percent(d.weight, decimals: 1))
                labeled("Cost Basis", topic: .costBasis) {
                    Text(d.costBasis.map { Fmt.money(minor: $0, currency: d.reportingCurrency) } ?? Fmt.missing)
                }
                labeled("Purchase Price", topic: .purchasePrice) {
                    Text(d.purchasePrice.map { Fmt.price($0, currency: d.reportingCurrency) } ?? Fmt.missing)
                }
                labeled("Unrealized Gain", topic: .unrealizedGains) {
                    if let gain = d.gain {
                        VStack(alignment: .trailing, spacing: 1) {
                            GainText(money: Money(minor: gain, currency: d.reportingCurrency))
                            if let fraction = d.gainFraction {
                                Text(Fmt.percent(fraction, signed: true)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(Fmt.missing)
                    }
                }
            }
        } else {
            Text("Not held on \(Fmt.day(d.day, style: .medium)) in \(store.scopeTitle).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        let period = HoldingsViewState.of(store).statementPeriod(in: store)
        section("Period · \(period.title(of: store.period))") {
            if let note = period.note(of: store.period) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            labeled("TTWROR", topic: .ttwror) {
                if let value = d.ttwror { GainText(percent: value) } else { Text(Fmt.missing) }
            }
            labeled("IRR", topic: .irr) {
                if let value = d.irr { GainText(percent: value) } else { Text(Fmt.missing) }
            }
            kv("Dividends", d.dividends.map { Fmt.money(minor: $0, currency: d.reportingCurrency) } ?? "")
            if let realized = d.realized, realized != 0 {
                labeled("Realized Gain", topic: .realizedGains) {
                    GainText(money: Money(minor: realized, currency: d.reportingCurrency))
                }
            }
        }

        if d.depots.count > 1 {
            section("Depots") {
                ForEach(d.depots) { depot in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(depot.name).lineLimit(1)
                            Spacer(minLength: DS.Spacing.s)
                            Text(Fmt.money(minor: depot.value, currency: d.reportingCurrency)).numeric()
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(Fmt.shares(depot.shares)) sh · \(Fmt.percent(depot.share, decimals: 1))")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: DS.Spacing.s)
                            GainText(money: Money(minor: depot.value - depot.costBasis, currency: d.reportingCurrency))
                        }
                        .font(.caption)
                        .numeric()
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else if let depot = d.depots.first {
            section("Depot") {
                kv("Held in", depot.name)
            }
        }

        if !d.lots.isEmpty {
            lots(d)
        }

        HStack(spacing: DS.Spacing.l) {
            Button("Open Security") { HoldingsActions.open(row(d), in: store) }
            Button("Show Transactions") { HoldingsActions.showTransactions(row(d), in: store) }
        }
        .buttonStyle(.link)
    }

    private func chartSeries(_ d: HoldingDetail) -> [TimeSeries] {
        var series = [TimeSeries("Price", start: d.chartStart, values: d.levels, style: .area)]
        if let level = d.purchaseLevel {
            series.append(TimeSeries(
                "Purchase price", days: [d.chartStart, d.day], values: [level, level], color: ChartColors.comparison, dashed: true))
        }
        return series
    }

    @ViewBuilder private func lots(_ d: HoldingDetail) -> some View {
        let shown = d.lots.prefix(60)
        section(d.costMethod == .average ? "Open Lots · Average Cost" : "Open Tax Lots · \(Fmt.integer(d.lots.count))", topic: .costMethod) {
            ForEach(shown) { lot in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.day(lot.acquired, style: .medium)).numeric()
                        Text(Fmt.duration(days: lot.holdingDays, style: .compact))
                            .font(.caption)
                            .numeric()
                            .foregroundStyle(.secondary)
                            .help("Holding period: \(Fmt.duration(days: lot.holdingDays))")
                        Spacer(minLength: DS.Spacing.s)
                        GainText(money: Money(minor: lot.gain, currency: d.reportingCurrency))
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Fmt.shares(lot.shares)) sh · \(Fmt.money(minor: lot.cost, currency: d.reportingCurrency)) → \(Fmt.money(minor: lot.value, currency: d.reportingCurrency))")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: DS.Spacing.s)
                        Text(Fmt.percent(lot.gainFraction, signed: true))
                    }
                    .font(.caption)
                    .numeric()
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Acquired \(Fmt.day(lot.acquired, style: .medium)), held \(Fmt.duration(days: lot.holdingDays)), \(Fmt.shares(lot.shares)) shares, cost \(Fmt.money(minor: lot.cost, currency: d.reportingCurrency)), value \(Fmt.money(minor: lot.value, currency: d.reportingCurrency)), gain \(Fmt.money(minor: lot.gain, currency: d.reportingCurrency))")
                if lot.id != shown.last?.id { Divider() }
            }
            if d.lots.count > shown.count {
                Text("and \(Fmt.integer(d.lots.count - shown.count)) newer lots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if d.depots.count > 1 || d.isClassificationScope {
                Text(d.isClassificationScope ? "Amounts are the part assigned to the selected classification." : "Lots of all depots, oldest first.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Account

    @ViewBuilder private func account(_ d: HoldingDetail) -> some View {
        header(d)
        if d.isHeld {
            HStack(spacing: DS.Spacing.s) {
                Button("Deposit…") { HoldingsActions.deposit(row(d), in: store) }
                Button("Withdraw…") { HoldingsActions.withdraw(row(d), in: store) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            section("Balance") {
                kv("Balance", d.localValue.map { Fmt.money(minor: $0, currency: d.currency) } ?? "")
                if d.currency != d.reportingCurrency {
                    kv("in \(d.reportingCurrency)", Fmt.money(minor: d.value, currency: d.reportingCurrency))
                }
                kv("Weight", Fmt.percent(d.weight, decimals: 1))
            }
        } else {
            Text("Not part of \(store.scopeTitle).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        HStack(spacing: DS.Spacing.l) {
            Button("Open Account") { HoldingsActions.open(row(d), in: store) }
            Button("Show Transactions") { HoldingsActions.showTransactions(row(d), in: store) }
        }
        .buttonStyle(.link)
    }

    // MARK: Nothing selected

    @ViewBuilder private func overview(_ d: HoldingDetail) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Statement of Assets").font(.headline)
            Text("\(store.scopeTitle) · \(Fmt.day(d.day, style: .medium))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        section("Summary") {
            kv("Total Value", Fmt.money(minor: d.totalValue, currency: d.reportingCurrency))
            kv("Positions", Fmt.integer(d.positionCount))
            kv("Cash Accounts", Fmt.integer(d.cashCount))
            kv("Cost Method", d.costMethod.title)
        }
        Label("Select a position to see its tax lots, depots and price chart.", systemImage: "cursorarrow.click")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: Building blocks

    private func header(_ d: HoldingDetail) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(d.name).font(.headline).lineLimit(2)
            if !d.detail.isEmpty {
                Text(d.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if d.isHeld {
                Text(Fmt.money(minor: d.value, currency: d.reportingCurrency))
                    .font(.kontorHero)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("as of \(Fmt.day(d.day, style: .medium))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(_ title: String, topic: HelpTopic? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.xs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if let topic { HelpButton(topic) }
            }
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                content()
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(radius: DS.Radius.control)
        }
    }

    private func labeled<Value: View>(_ title: String, topic: HelpTopic? = nil, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            if let topic { HelpButton(topic) }
            Spacer(minLength: DS.Spacing.s)
            value()
                .numeric()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Label left, value right; "–" for empty values.
    private func kv(_ title: String, _ value: String) -> some View {
        labeled(title) { Text(value.isEmpty ? Fmt.missing : value).textSelection(.enabled) }
    }

    /// A row stand-in for the shared actions.
    private func row(_ d: HoldingDetail) -> HoldingRow {
        var row = HoldingRow(
            id: "inspector", kind: d.subject == .account ? .cash : d.isHeld ? .position : .closed,
            securityID: store.route.securityID, accountID: store.route.accountID, name: d.name, detail: d.detail,
            searchText: "", currency: d.currency)
        row.shares = d.shares
        row.depotID = d.depots.max { $0.value < $1.value }?.id
        return row
    }
}
