import SwiftUI
import KontorUI

/// The Projection tab: where the active plans could lead. Today's portfolio value plus the plans'
/// contributions, grown at an adjustable annual return — pessimistic, expected and optimistic —
/// against the money paid in. A simple illustration (see `PlanProjection`), clearly labelled as such.
struct ProjectionPanel: View {
    @Environment(PortfolioStore.self) private var store
    @State private var annualReturn = 0.05
    @State private var spread = 0.02
    @State private var years = 20
    @State private var startsFromCurrent = true
    // Remembered per window.
    @SceneStorage("plans.projection.return") private var storedReturn = 0.05
    @SceneStorage("plans.projection.spread") private var storedSpread = 0.02
    @SceneStorage("plans.projection.years") private var storedYears = 20
    @SceneStorage("plans.projection.fromCurrent") private var storedFromCurrent = true

    @State private var base = Loadable<ProjectionBase>()
    /// nil = the default selection (new money only).
    @State private var included: Set<UUID>?
    @State private var outcome: ProjectionOutcome?
    @State private var pinnedDay: Day?
    @State private var didApplyLaunchState = false

    /// Everything the projection depends on; a change recomputes it.
    private struct Inputs: Hashable {
        var annualReturn: Double
        var spread: Double
        var years: Int
        var startsFromCurrent: Bool
        var included: Set<UUID>?
        var revision: Int?
        var today: Day
    }

    var body: some View {
        let plans = store.file.plans
        let today = store.today
        let inputs = Inputs(
            annualReturn: annualReturn, spread: spread, years: years, startsFromCurrent: startsFromCurrent,
            included: included, revision: base.revision, today: today)
        ScrollView {
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                VStack(spacing: DS.Spacing.l) {
                    assumptions
                    contributions
                }
                .frame(width: 304)
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    if let outcome {
                        results(outcome)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .opacity(base.isRefreshing ? 0.7 : 1)
            }
            .screenPadding()
        }
        .loadingOverlay(base.isInitialLoad)
        .ledgerTask($base, id: "plans.projection.base", variant: today) { ledger in
            ProjectionBase(ledger, plans: plans, today: today)
        }
        .onAppear(perform: applyLaunchState)
        .onChange(of: inputs, initial: true) { _, _ in
            recompute()
            guard didApplyLaunchState else { return }
            storedReturn = annualReturn
            storedSpread = spread
            storedYears = years
            storedFromCurrent = startsFromCurrent
        }
    }

    // MARK: Controls

    private var assumptions: some View {
        Card("Assumptions", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                controlRow("Expected Return", detail: "per year") {
                    PercentField("Expected return per year", fraction: $annualReturn, decimals: 1).frame(width: 72)
                    Stepper("Expected return", value: $annualReturn, in: -0.5...0.5, step: 0.005).labelsHidden()
                }
                controlRow("Range", detail: "± around it") {
                    PercentField("Range around the expected return", fraction: $spread, decimals: 1).frame(width: 72)
                    Stepper("Range", value: $spread, in: 0...0.25, step: 0.005).labelsHidden()
                }
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack {
                        Text("Horizon")
                        Spacer()
                        Text(years == 1 ? "1 year" : "\(Fmt.integer(years)) years").numeric().foregroundStyle(.secondary)
                        Stepper("Horizon in years", value: $years, in: 1...ProjectionBase.maximumYears).labelsHidden()
                    }
                    Slider(value: yearsSlider, in: 1...Double(ProjectionBase.maximumYears)) {
                        Text("Horizon in years")
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                Divider()
                Toggle(isOn: $startsFromCurrent) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text("Start from today's portfolio")
                        Text(base.value.map { Fmt.money(minor: $0.currentValue, currency: $0.currency) } ?? Fmt.missing)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .numeric()
                    }
                }
                .help("Off: the projection starts at zero and shows only what the plans build up.")
            }
        }
    }

    private func controlRow(_ title: String, detail: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Spacing.s)
            control()
        }
    }

    private var yearsSlider: Binding<Double> {
        Binding(get: { Double(years) }, set: { years = Int($0.rounded()) })
    }

    private var contributions: some View {
        Card("Contributions", symbol: "calendar.badge.plus") {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                if let base = base.value {
                    let selection = included ?? base.defaultSelection
                    if base.plans.isEmpty {
                        Text("No plans yet. The projection shows today's portfolio growing on its own.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("New Plan…") { store.present(.newPlan) }
                    } else {
                        ForEach(base.plans) { plan in
                            contributionRow(plan, isOn: selection.contains(plan.id), currency: base.currency)
                        }
                        if base.plans.contains(where: { $0.isInternal && $0.isActive && !selection.contains($0.id) }) {
                            Text("Purchases paid from a cash account are left out by default: they move money you have already counted when it was deposited.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if included != nil {
                            Button("Reset to Default") { included = nil }
                                .buttonStyle(.link)
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func contributionRow(_ plan: ProjectionPlan, isOn: Bool, currency: CurrencyCode) -> some View {
        Toggle(isOn: Binding(
            get: { isOn && plan.isActive },
            set: { on in
                var selection = included ?? base.value?.defaultSelection ?? []
                if on { selection.insert(plan.id) } else { selection.remove(plan.id) }
                included = selection
            }
        )) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(plan.name).lineLimit(1)
                Text(Self.caption(plan, currency: currency))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .lineLimit(1)
            }
        }
        .disabled(!plan.isActive)
        .help(plan.isActive ? plan.detail : "This plan has ended or cannot be executed, so it contributes nothing.")
    }

    private static func caption(_ plan: ProjectionPlan, currency: CurrencyCode) -> String {
        guard plan.isActive, let amount = plan.amount else { return "Not active" }
        return "\(Fmt.money(minor: amount, currency: currency, signed: true)) \(PlanText.interval(plan.intervalMonths).lowercased())"
    }

    // MARK: Results

    @ViewBuilder private func results(_ outcome: ProjectionOutcome) -> some View {
        SectionHeader(years == 1 ? "In 1 Year" : "In \(Fmt.integer(outcome.years)) Years", subtitle: Fmt.day(outcome.endDay, style: .monthYear))

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: DS.Spacing.m)], alignment: .leading, spacing: DS.Spacing.m) {
            PlanTile("Paid In", help: .investedCapital, value: Fmt.moneyRounded(outcome.money(outcome.end.paidIn))) {
                Text(outcome.paidInCaption)
            }
            scenarioTile("Pessimistic", rate: outcome.input.pessimisticReturn, value: outcome.end.pessimistic, outcome: outcome)
            scenarioTile("Expected", rate: outcome.input.annualReturn, value: outcome.end.expected, outcome: outcome)
            scenarioTile("Optimistic", rate: outcome.input.optimisticReturn, value: outcome.end.optimistic, outcome: outcome)
        }

        Card("Projected Value", symbol: "chart.line.uptrend.xyaxis") {
            TimeSeriesChart(outcome.series, format: .money(outcome.currency), title: "Projected portfolio value for three return assumptions, compared with the money paid in")
                .pinnedHover(pinnedDay)
                .loading(base.isRefreshing)
                .emptyMessage("Nothing to project yet")
                .frame(height: 300)
            Label {
                Text("A simple illustration, not a forecast. It assumes the same return every year (compounded monthly) and that your plans run unchanged; real markets fluctuate, and taxes, costs and inflation are not included.\(outcome.depletionNote)")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Card("Milestones", symbol: "flag") {
            Grid(alignment: .trailing, horizontalSpacing: DS.Spacing.l, verticalSpacing: DS.Spacing.s) {
                GridRow {
                    Text("Year").gridColumnAlignment(.leading)
                    Text("Paid In").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Pessimistic").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Expected").frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Optimistic").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.kontorCaption)
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(outcome.milestones) { milestone in
                    GridRow {
                        HStack(spacing: DS.Spacing.s) {
                            Text(String(milestone.day.year))
                            Text(milestone.years == 1 ? "in 1 year" : "in \(Fmt.integer(milestone.years)) years")
                                .foregroundStyle(.secondary)
                        }
                        Text(Fmt.moneyRounded(outcome.money(milestone.paidIn))).foregroundStyle(.secondary)
                        Text(Fmt.moneyRounded(outcome.money(milestone.pessimistic)))
                        Text(Fmt.moneyRounded(outcome.money(milestone.expected))).fontWeight(.medium)
                        Text(Fmt.moneyRounded(outcome.money(milestone.optimistic)))
                    }
                    .numeric()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scenarioTile(_ title: String, rate: Double, value: Double, outcome: ProjectionOutcome) -> some View {
        PlanTile("\(title) · \(Fmt.percent(rate, decimals: 1))", value: Fmt.moneyRounded(outcome.money(value))) {
            let growth = outcome.money(value - outcome.end.paidIn)
            Text("\(growth.minor < 0 ? "" : "+")\(Fmt.moneyRounded(growth)) growth")
        }
    }

    // MARK: State

    private func recompute() {
        guard let base = base.value else { return }
        let selection = included ?? base.defaultSelection
        let input = ProjectionInput(
            startValue: startsFromCurrent ? max(base.currentValue, 0) : 0,
            flows: base.flows(including: selection, years: years),
            annualReturn: annualReturn, spread: spread, years: years)
        outcome = ProjectionOutcome(input: input, base: base)
    }

    private func applyLaunchState() {
        guard !didApplyLaunchState else { return }
        didApplyLaunchState = true
        annualReturn = storedReturn
        spread = storedSpread
        years = min(max(storedYears, 1), ProjectionBase.maximumYears)
        startsFromCurrent = storedFromCurrent
        if let value = store.launchValue("return").flatMap(Fmt.parseDouble) { annualReturn = value / 100 }
        if let value = store.launchValue("spread").flatMap(Fmt.parseDouble) { spread = abs(value) / 100 }
        if let value = store.launchValue("years").flatMap({ Int($0) }) { years = min(max(value, 1), ProjectionBase.maximumYears) }
        if store.launchValue("start") == "zero" { startsFromCurrent = false }
        switch store.launchValue("include") {
        case "all": included = Set(store.file.plans.map(\.id))
        case "none": included = []
        default: break
        }
        if let hover = store.launchValue("hover") {
            pinnedDay = Day(iso: hover) ?? store.today.addingMonths(years * 12 * 2 / 3)
        }
    }
}

/// The projection prepared for display: chart series, the numbers at the horizon and milestones.
struct ProjectionOutcome {
    struct Point: Identifiable {
        var id: Int { years }
        var years: Int
        var day: Day
        var paidIn: Double
        var pessimistic: Double
        var expected: Double
        var optimistic: Double
    }

    var input: ProjectionInput
    var currency: CurrencyCode
    var years: Int
    var endDay: Day
    var end: Point
    var milestones: [Point]
    var series: [TimeSeries]
    var paidInCaption: String
    var depletionNote: String

    init(input: ProjectionInput, base: ProjectionBase) {
        self.input = input
        currency = base.currency
        years = input.years
        let result = PlanProjection.project(input)
        let today = base.today
        endDay = today.addingMonths(result.months)

        func point(_ year: Int) -> Point {
            let month = min(year * 12, result.months)
            return Point(
                years: year, day: today.addingMonths(month), paidIn: result.contributions[month],
                pessimistic: result.pessimistic[month], expected: result.expected[month], optimistic: result.optimistic[month])
        }
        end = point(input.years)
        let step = input.years <= 10 ? 1 : input.years <= 25 ? 5 : 10
        var marks = Array(stride(from: step, to: input.years, by: step))
        marks.append(input.years)
        milestones = marks.map(point)

        let days = (0...result.months).map { today.addingMonths($0) }
        let hue = ChartColors.series(0)
        series = [
            TimeSeries("Expected", days: days, values: result.expected, style: .area, color: hue),
            TimeSeries("Optimistic", days: days, values: result.optimistic, color: hue, dashed: true),
            TimeSeries("Pessimistic", days: days, values: result.pessimistic, color: hue, dashed: true),
            TimeSeries("Paid in", days: days, values: result.contributions, style: .step, color: ChartColors.comparison),
        ]

        let contributed = end.paidIn - Double(input.startValue)
        let start = Fmt.moneyRounded(Money(minor: input.startValue, currency: currency))
        let added = Fmt.moneyRounded(Money(minor: Int64(abs(contributed).rounded()), currency: currency))
        if input.startValue == 0 {
            paidInCaption = contributed == 0 ? "No contributions" : "Contributions only"
        } else if contributed == 0 {
            paidInCaption = "Today's value"
        } else {
            paidInCaption = "\(start) \(contributed < 0 ? "−" : "+") \(added)"
        }
        if let month = result.depletedMonth {
            depletionNote = " With these withdrawals the expected scenario runs out of money in \(Fmt.day(today.addingMonths(month), style: .monthYear))."
        } else {
            depletionNote = ""
        }
    }

    func money(_ value: Double) -> Money {
        Money(minor: Int64(value.rounded()), currency: currency)
    }
}
