import SwiftUI
import KontorUI

/// The lower half of the Plans tab: what one plan has done (executions linked to their
/// transactions, skipped and open dates), what comes next, and — for purchase plans — what the
/// shares bought through it are worth.
struct PlanDetailView: View {
    @Environment(PortfolioStore.self) private var store
    let plan: InvestmentPlan

    @State private var loaded = Loadable<PlanDetail>()
    @State private var pinnedDay: Day?

    /// The detail of *this* plan — never the previous selection's while the new one computes.
    private var detail: PlanDetail? {
        guard let value = loaded.value, value.planID == plan.id else { return nil }
        return value
    }

    var body: some View {
        let key = PlanDetail.Key(planID: plan.id, today: store.today)
        let plan = plan
        let rates = store.file.exchangeRates
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                header
                if let problem = detail?.problem {
                    ProblemNote(message: problem) { store.present(.editPlan(plan.id)) }
                }
                if let detail {
                    tiles(detail)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: DS.Spacing.l) {
                            timeline(detail).frame(minWidth: 540)
                            if detail.hasChart { chart(detail).frame(minWidth: 380) }
                        }
                        VStack(alignment: .leading, spacing: DS.Spacing.l) {
                            if detail.hasChart { chart(detail, height: 180) }
                            timeline(detail)
                        }
                    }
                }
            }
            .padding(DS.Spacing.l)
            .opacity(loaded.isRefreshing && detail != nil ? 0.7 : 1)
        }
        .loadingOverlay(loaded.isLoading && detail == nil)
        .ledgerTask($loaded, id: "plans.detail", variant: key) { ledger in
            PlanDetail(ledger, plan: plan, today: key.today, exchangeRates: rates)
        }
        .onAppear {
            guard let hover = store.launchValue("hover") else { return }
            pinnedDay = Day(iso: hover) ?? store.today.addingMonths(-14)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    Text(plan.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let detail {
                        PlanStateLabel(state: detail.state).font(.callout)
                    }
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: DS.Spacing.m)
            HStack(spacing: DS.Spacing.s) {
                if let detail, !detail.missing.isEmpty {
                    Button("Generate…") { PlanActions.generate(plan.id, in: store) }
                        .buttonStyle(.borderedProminent)
                        .help("Review and add the executions that are due")
                }
                Button("Edit…") { store.present(.editPlan(plan.id)) }
                if PlanActions.isEnded(plan, today: store.today) {
                    Button("Resume") { PlanActions.resume(plan.id, in: store) }
                        .help("Clears the end date. Dates missed while the plan was paused are marked as skipped.")
                } else {
                    let canPause = PlanActions.canPause(plan, today: store.today)
                    Button("Pause") { PlanActions.pause(plan.id, in: store) }
                        .disabled(!canPause)
                        .help(canPause ? PlanActions.pauseHelp : PlanActions.cannotPauseHelp)
                }
                Menu {
                    Button("Duplicate…") { PlanActions.duplicate(plan.id, in: store) }
                    if let securityID = plan.securityID {
                        Button("Show Security") { store.navigate(to: .security(securityID)) }
                    }
                    if let accountID = plan.accountID {
                        Button("Show Account") { store.navigate(to: .account(accountID)) }
                    }
                    Divider()
                    Button("Delete Plan", role: .destructive) { PlanActions.delete([plan.id], in: store) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions. Deleting a plan keeps the transactions it created.")
            }
        }
    }

    /// "€500.00 monthly into Global Equity ETF · Main Depot · paid from Settlement Account · since Jul 2017"
    private var summary: String {
        let amount = "\(Fmt.money(plan.amount)) \(PlanText.interval(plan.intervalMonths).lowercased())"
        var parts: [String] = []
        switch plan.kind {
        case .purchase:
            parts.append("\(amount) into \(store.security(plan.securityID)?.name ?? "no security")")
            if let depot = store.depot(plan.depotID) { parts.append(depot.name) }
            if let account = store.account(plan.accountID) {
                parts.append("paid from \(account.name)")
            } else {
                parts.append("booked as delivery")
            }
            if plan.fees > 0 { parts.append("incl. \(Fmt.money(minor: plan.fees, currency: plan.amount.currency)) fees") }
        case .deposit:
            parts.append("\(amount) to \(store.account(plan.accountID)?.name ?? "no account")")
        case .withdrawal:
            parts.append("\(amount) from \(store.account(plan.accountID)?.name ?? "no account")")
        }
        parts.append("\(plan.start > store.today ? "from" : "since") \(Fmt.day(plan.start, style: .medium))")
        if let end = plan.end { parts.append("\(end > store.today ? "until" : "ended") \(Fmt.day(end, style: .medium))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Tiles

    /// One row of tiles where it fits; wrapped into a grid in narrow windows so no number is cut.
    private func tiles(_ detail: PlanDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                tileViews(detail).frame(minWidth: 176)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: DS.Spacing.m, alignment: .leading)], alignment: .leading, spacing: DS.Spacing.m) {
                tileViews(detail)
            }
        }
    }

    @ViewBuilder private func tileViews(_ detail: PlanDetail) -> some View {
        if let performance = detail.performance {
            PlanTile("Invested via Plan", help: .investedCapital, value: Fmt.money(minor: performance.invested, currency: performance.currency), maxWidth: 264) {
                // Paid in another currency: the tile is in the reporting currency (each execution at
                // its day's rate), the list's "Total So Far" in the plan's — show both.
                if performance.currency == detail.total.currency {
                    Text(Self.executionCount(detail.executions))
                } else {
                    Text("\(Fmt.money(detail.total)) at each day's rate")
                        .help("\(Self.executionCount(detail.executions)) paid in \(detail.total.currency), converted to \(performance.currency) at the exchange rate of each execution day.")
                }
            }
            PlanTile("Value Today", value: performance.isValued ? Fmt.money(minor: performance.value, currency: performance.currency) : Fmt.missing, maxWidth: 264) {
                if performance.isValued {
                    DeltaLabel(fraction: performance.gainFraction, amount: Money(minor: performance.gain, currency: performance.currency))
                } else {
                    Text("No price available")
                }
            }
            PlanTile("Return per Year", help: .irr, value: performance.isValued ? Fmt.percent(performance.irr, signed: true) : Fmt.missing, maxWidth: 264) {
                Text("IRR, money-weighted")
            }
            PlanTile("Shares Bought", value: Fmt.shares(performance.shares), maxWidth: 264) {
                if let average = performance.averagePrice {
                    HStack(spacing: DS.Spacing.xs) {
                        Text("avg. \(Fmt.price(average, currency: performance.priceCurrency))")
                        HelpButton(.purchasePrice)
                    }
                }
            }
        } else {
            PlanTile(totalTitle(detail.kind), value: Fmt.money(detail.total), maxWidth: 264) {
                Text(Self.executionCount(detail.executions))
            }
            // What the plan moves per year — only while it still has dates ahead.
            if detail.nextDue != nil {
                PlanTile("Per Year", value: plan.intervalMonths > 0
                    ? Fmt.money(minor: FixedMath.saturatingInt64(Double(plan.amount.minor) * 12 / Double(plan.intervalMonths)), currency: plan.amount.currency)
                    : Fmt.missing, maxWidth: 264) {
                    Text(plan.intervalMonths > 0 && 12 % plan.intervalMonths == 0
                        ? "\(Fmt.integer(12 / plan.intervalMonths)) × \(Fmt.money(plan.amount))" : "on average")
                }
            }
        }
        PlanTile("Next Execution", help: .savingsPlan, value: detail.nextDue.map { Fmt.day($0, style: .medium) } ?? Fmt.missing, maxWidth: 264) {
            if let next = detail.nextDue {
                Text(PlanText.distance(from: store.today, to: next))
            } else if detail.problem != nil {
                Text("Not until the plan is fixed")
            } else if let end = plan.end {
                Text("Ended \(Fmt.day(end, style: .medium))")
            } else {
                Text("Nothing scheduled")
            }
        }
    }

    private static func executionCount(_ count: Int) -> String {
        "\(Fmt.integer(count)) \(count == 1 ? "execution" : "executions")"
    }

    private func totalTitle(_ kind: InvestmentPlan.Kind) -> String {
        switch kind {
        case .purchase: "Bought via Plan"
        case .deposit: "Deposited via Plan"
        case .withdrawal: "Withdrawn via Plan"
        }
    }

    // MARK: Chart

    @ViewBuilder private func chart(_ detail: PlanDetail, height: CGFloat = 248) -> some View {
        if let performance = detail.performance {
            Card("Invested vs. Value", symbol: "chart.xyaxis.line") {
                TimeSeriesChart([
                    TimeSeries("Value", start: performance.chartStart, values: performance.valueSeries, style: .area),
                    TimeSeries("Invested", start: performance.chartStart, values: performance.investedSeries, style: .step,
                               color: ChartColors.comparison),
                ], format: .money(performance.currency), title: "Value of the shares bought through \(plan.name) compared with the money invested")
                .pinnedHover(pinnedDay)
                .loading(loaded.isRefreshing)
                .emptyMessage("No executions yet")
                .frame(height: height)
                Text("Assumes every share bought through this plan is still held — sales are not tracked per plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Card(detail.kind == .withdrawal ? "Withdrawn per Year" : detail.kind == .deposit ? "Deposited per Year" : "Bought per Year",
                 symbol: "chart.bar") {
                BarSeriesChart(
                    categories: detail.yearly.map { BarCategory.year($0.year) },
                    series: [BarSeries(plan.name, values: detail.yearly.map(\.total), color: ChartColors.series(0))],
                    format: .money(plan.amount.currency), title: "Amount booked by \(plan.name) per calendar year")
                .legendHidden()
                .pinnedHover(pinnedDay.map { String($0.year) })
                .loading(loaded.isRefreshing)
                .emptyMessage("No executions yet")
                .frame(height: height)
            }
        }
    }

    // MARK: Timeline

    private func timeline(_ detail: PlanDetail) -> some View {
        Card("Timeline", symbol: "calendar.day.timeline.left") {
            VStack(alignment: .leading, spacing: 0) {
                if detail.upcoming.isEmpty && detail.history.isEmpty {
                    Text(detail.problem != nil
                        ? "Nothing has happened yet. Dates are scheduled once the plan can be executed."
                        : "Nothing has happened yet and nothing is scheduled.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, DS.Spacing.s)
                }
                if !detail.upcoming.isEmpty {
                    TimelineSectionHeader(title: "Upcoming")
                    ForEach(detail.upcoming) { entry in
                        TimelineRow(entry: entry, planID: plan.id, today: store.today)
                    }
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.years(detail.history), id: \.year) { group in
                        TimelineSectionHeader(title: String(group.year))
                        ForEach(group.entries) { entry in
                            TimelineRow(entry: entry, planID: plan.id, today: store.today)
                        }
                    }
                }
            }
        } accessory: {
            Text(Self.counts(detail))
                .font(.callout)
                .foregroundStyle(.secondary)
                .numeric()
        }
    }

    private static func counts(_ detail: PlanDetail) -> String {
        var parts = ["\(Fmt.integer(detail.executions)) booked"]
        if !detail.missing.isEmpty { parts.append("\(Fmt.integer(detail.missing.count)) due") }
        if !detail.skipped.isEmpty { parts.append("\(Fmt.integer(detail.skipped.count)) skipped") }
        return parts.joined(separator: " · ")
    }

    private static func years(_ entries: [PlanTimelineEntry]) -> [(year: Int, entries: [PlanTimelineEntry])] {
        var groups: [(year: Int, entries: [PlanTimelineEntry])] = []
        for entry in entries {
            let year = entry.due.year
            if groups.last?.year == year {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((year, [entry]))
            }
        }
        return groups
    }
}

private struct TimelineSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.kontorCaption)
            .foregroundStyle(.secondary)
            .numeric()
            .padding(.top, DS.Spacing.m)
            .padding(.bottom, DS.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One date of a plan: booked, due, skipped or upcoming.
private struct TimelineRow: View {
    @Environment(PortfolioStore.self) private var store
    let entry: PlanTimelineEntry
    let planID: UUID
    let today: Day

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(Fmt.day(entry.due, style: .medium))
                .numeric()
                .frame(width: 96, alignment: .leading)
                .foregroundStyle(isDimmed ? .secondary : .primary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(status)
                    .foregroundStyle(statusStyle)
                    .numeric()
                    .lineLimit(1)
                    .layoutPriority(1)
                if let note {
                    Text(note)
                        .foregroundStyle(.secondary)
                        .numeric()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.amount.map { Fmt.money($0) } ?? "")
                .numeric()
                .foregroundStyle(isDimmed ? .secondary : .primary)
                .frame(width: 88, alignment: .trailing)
            actions
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .contentShape(Rectangle())
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Fmt.day(entry.due, style: .medium)), \(status)\(entry.amount.map { ", " + Fmt.money($0) } ?? "")")
    }

    private var isDimmed: Bool {
        switch entry.kind {
        case .upcoming, .skipped: true
        case .executed, .missing: false
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .executed: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .skipped: "slash.circle"
        case .upcoming: "circle.dashed"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .executed: .secondary
        case .missing: DS.Colors.warning
        case .skipped, .upcoming: Color.secondary.opacity(0.7)
        }
    }

    private var statusStyle: Color {
        switch entry.kind {
        case .missing: DS.Colors.warning
        case .executed: .primary
        case .skipped, .upcoming: .secondary
        }
    }

    /// What happened on this date: for purchases the shares and the price paid, otherwise the state.
    private var status: String {
        switch entry.kind {
        case .executed:
            if let shares = entry.shares, let price = entry.price {
                return "\(Fmt.shares(shares)) × \(Fmt.price(price, currency: entry.priceCurrency))"
            }
            return "Booked"
        case .missing: return "Due — not booked"
        case .skipped: return "Skipped"
        case .upcoming: return "Scheduled, \(PlanText.distance(from: today, to: entry.due))"
        }
    }

    /// Set when the booking day differs from the scheduled day (holidays, manual corrections).
    private var note: String? {
        guard case .executed = entry.kind, let booked = entry.booked, booked != entry.due else { return nil }
        return Self.bookingNote(booked, afterShares: entry.shares != nil && entry.price != nil)
    }

    /// "3.7 × 133.81 € · booked 2 Jan" for purchases; for plain bookings the status already reads
    /// "Booked", so only the day follows: "Booked · on 2 Jan".
    static func bookingNote(_ booked: Day, afterShares: Bool) -> String {
        "\(afterShares ? "booked" : "on") \(Fmt.day(booked, style: .dayMonth))"
    }

    @ViewBuilder private var actions: some View {
        switch entry.kind {
        case .executed(let id):
            Button("Show") { store.navigate(to: .transaction(id)) }
                .buttonStyle(.link)
                .help("Show this transaction in the ledger")
        case .missing:
            Button("Skip") { PlanActions.skip(entry.due, of: planID, in: store) }
                .buttonStyle(.link)
                .help("Do not book this date. You can restore it later.")
        case .skipped:
            Button("Restore") { PlanActions.restore(entry.due, of: planID, in: store) }
                .buttonStyle(.link)
                .help(entry.due > today ? "Schedule this date again" : "Make this date due again")
        case .upcoming:
            Button("Skip") { PlanActions.skip(entry.due, of: planID, in: store) }
                .buttonStyle(.link)
                .help("Leave this date out, for example in a month you need the money elsewhere")
        }
    }

    @ViewBuilder private var menu: some View {
        switch entry.kind {
        case .executed(let id):
            Button("Show in Transactions") { store.navigate(to: .transaction(id)) }
            Button("Edit Transaction…") { store.present(.editTransaction(id)) }
        case .missing:
            Button("Generate…") { PlanActions.generate(planID, in: store) }
            Button("Skip This Date") { PlanActions.skip(entry.due, of: planID, in: store) }
        case .skipped:
            Button("Restore This Date") { PlanActions.restore(entry.due, of: planID, in: store) }
        case .upcoming:
            Button("Skip This Date") { PlanActions.skip(entry.due, of: planID, in: store) }
        }
    }
}

/// A stat tile like `StatTile`, with room for a help button and any footnote view.
struct PlanTile<Footnote: View>: View {
    private let label: String
    private let help: HelpTopic?
    private let value: String
    private let footnote: Footnote
    private let maxWidth: CGFloat

    init(_ label: String, help: HelpTopic? = nil, value: String, maxWidth: CGFloat = .infinity, @ViewBuilder footnote: () -> Footnote) {
        self.maxWidth = maxWidth
        self.label = label
        self.help = help
        self.value = value
        self.footnote = footnote()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Text(label)
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let help { HelpButton(help) }
            }
            Text(value)
                .font(.kontorHero)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            footnote
                .font(.callout)
                .foregroundStyle(.secondary)
                .numeric()
                .lineLimit(1)
                .frame(height: 18, alignment: .leading)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

private struct ProblemNote: View {
    let message: String
    let edit: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("This plan cannot be executed").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Spacing.m)
            Button("Edit Plan…", action: edit)
        }
        .padding(DS.Spacing.l)
        .cardBackground()
    }
}
