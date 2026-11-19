import Foundation
import KontorUI

// The projection panel's arithmetic: a deliberately simple illustration, not a forecast. A constant
// annual return, compounded monthly; contributions are added in the month they are scheduled; no
// taxes, costs or inflation. Three scenarios: the expected return and that return ± a spread.

/// Inputs of a projection. Money is in minor units of one currency.
struct ProjectionInput: Hashable, Sendable {
    /// Value at month 0 (today).
    var startValue: Int64
    /// Net contribution scheduled for each future month: `flows[0]` belongs to month 1 (the month
    /// starting today), `flows[1]` to month 2, … Negative = withdrawals. Missing months count as 0.
    var flows: [Int64]
    /// Expected annual return as a fraction (0.05 = 5 %).
    var annualReturn: Double
    /// The pessimistic and optimistic scenarios use `annualReturn ∓ spread`.
    var spread: Double
    var years: Int

    var months: Int { max(years, 0) * 12 }
    var pessimisticReturn: Double { annualReturn - abs(spread) }
    var optimisticReturn: Double { annualReturn + abs(spread) }

    /// What the panel accepts as expected return and as spread — the limits of its steppers. Typed
    /// values, launch state and restored window state are clamped to these (`clampedReturn`,
    /// `clampedSpread`), so that a typo such as 500 % cannot produce absurd numbers.
    static let returnRange = -0.5...0.5
    static let spreadRange = 0.0...0.25

    static func clampedReturn(_ value: Double) -> Double {
        value.isFinite ? min(max(value, returnRange.lowerBound), returnRange.upperBound) : 0
    }

    static func clampedSpread(_ value: Double) -> Double {
        value.isFinite ? min(max(abs(value), spreadRange.lowerBound), spreadRange.upperBound) : 0
    }

    /// Nothing to draw: no money at the start and none ever paid in (withdrawals from nothing
    /// stay at zero).
    var isEmpty: Bool { startValue <= 0 && flows.allSatisfy { $0 <= 0 } }
}

/// Monthly series, index 0 = today, index `m` = after `m` months. `count == months + 1`.
struct ProjectionResult: Equatable, Sendable {
    /// Start value plus everything paid in (or taken out) so far — what the value would be at 0 %.
    var contributions: [Double]
    var pessimistic: [Double]
    var expected: [Double]
    var optimistic: [Double]
    /// First month in which the expected scenario ran out of money (withdrawals), if it did.
    var depletedMonth: Int?

    var months: Int { expected.count - 1 }
}

enum PlanProjection {
    /// Smallest annual return the model accepts: a value cannot lose more than everything.
    static let minimumReturn = -0.99

    static func project(_ input: ProjectionInput) -> ProjectionResult {
        let months = input.months
        var contributions = [Double](repeating: 0, count: months + 1)
        contributions[0] = Double(input.startValue)
        for month in stride(from: 1, through: months, by: 1) {
            contributions[month] = contributions[month - 1] + flow(input.flows, month: month)
        }
        let expected = path(start: input.startValue, flows: input.flows, annualReturn: input.annualReturn, months: months)
        return ProjectionResult(
            contributions: contributions,
            pessimistic: path(start: input.startValue, flows: input.flows, annualReturn: input.pessimisticReturn, months: months),
            expected: expected,
            optimistic: path(start: input.startValue, flows: input.flows, annualReturn: input.optimisticReturn, months: months),
            depletedMonth: depletion(of: expected, start: input.startValue, flows: input.flows))
    }

    /// One scenario: every month the value grows by the monthly equivalent of `annualReturn`
    /// (`(1 + r)^(1/12) − 1`), then that month's contribution is added. The value never drops
    /// below zero — once the money is gone, withdrawals stop.
    static func path(start: Int64, flows: [Int64], annualReturn: Double, months: Int) -> [Double] {
        let factor = monthlyFactor(annualReturn)
        var values = [Double](repeating: 0, count: max(months, 0) + 1)
        values[0] = max(Double(start), 0)
        for month in stride(from: 1, through: months, by: 1) {
            values[month] = max(values[month - 1] * factor + flow(flows, month: month), 0)
        }
        return values
    }

    /// `(1 + r)^(1/12)`: twelve of these compound to exactly one year of `annualReturn`.
    static func monthlyFactor(_ annualReturn: Double) -> Double {
        pow(1 + max(annualReturn, minimumReturn), 1.0 / 12.0)
    }

    private static func flow(_ flows: [Int64], month: Int) -> Double {
        month >= 1 && month <= flows.count ? Double(flows[month - 1]) : 0
    }

    private static func depletion(of values: [Double], start: Int64, flows: [Int64]) -> Int? {
        guard start > 0 || flows.contains(where: { $0 > 0 }) else { return nil }
        guard flows.contains(where: { $0 < 0 }) else { return nil }
        return values.indices.dropFirst().first { values[$0] <= 0 }
    }

    /// The month (1-based) a future day belongs to: month 1 covers `today + 1 day … today + 1 month`.
    static func monthIndex(of day: Day, today: Day) -> Int? {
        guard day > today else { return nil }
        var month = max((day.year - today.year) * 12 + day.month - today.month, 1)
        while today.addingMonths(month) < day { month += 1 }
        while month > 1, today.addingMonths(month - 1) >= day { month -= 1 }
        return month
    }
}

// MARK: - What the panel needs from the document

/// One plan as a source of contributions.
struct ProjectionPlan: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var kind: InvestmentPlan.Kind
    var detail: String
    /// Signed amount per execution in the reporting currency (withdrawals negative); nil if it
    /// cannot be converted.
    var amount: Int64?
    var intervalMonths: Int
    /// Signed contribution per future month (index 0 = month 1), up to `ProjectionBase.maximumYears`.
    var flows: [Int64]
    /// A purchase paid from a cash account moves money inside the portfolio; it adds nothing new.
    var isInternal: Bool
    var isActive: Bool
}

/// Everything document-dependent for the projection, computed off the main actor.
struct ProjectionBase: Sendable {
    static let maximumYears = 50

    var currency: CurrencyCode
    /// The portfolio's value today (engine snapshot, whole portfolio).
    var currentValue: Int64
    var plans: [ProjectionPlan]
    var today: Day

    init(_ ledger: Ledger, plans: [InvestmentPlan], today: Day) {
        self.today = today
        currency = ledger.reportingCurrency
        currentValue = ledger.snapshot(on: today).totalValue.minor
        let horizon = today.addingYears(Self.maximumYears)
        self.plans = plans.map { plan in
            let status = ledger.planStatus(plan, through: today)
            let converted = ledger.converter.convert(
                minor: plan.amount.minor, from: plan.amount.currency, to: ledger.reportingCurrency, on: today)
            // Withdrawals count negative (`max` keeps the negation of a damaged amount from trapping).
            let signed = converted.map { plan.kind == .withdrawal ? -max($0, -Int64.max) : $0 }
            var flows = [Int64](repeating: 0, count: Self.maximumYears * 12)
            var isActive = false
            if status.problem == nil, status.nextDue != nil, let signed {
                for due in plan.dueDates(through: horizon) where due > today {
                    guard let month = PlanProjection.monthIndex(of: due, today: today), month <= flows.count else { continue }
                    flows[month - 1] = Self.saturatingSum(flows[month - 1], signed)
                    isActive = true
                }
            }
            let target: String = switch plan.kind {
            case .purchase: plan.securityID.flatMap { ledger.security($0)?.name } ?? ""
            case .deposit, .withdrawal: plan.accountID.flatMap { ledger.account($0)?.name } ?? ""
            }
            return ProjectionPlan(
                id: plan.id, name: plan.name, kind: plan.kind, detail: target, amount: signed,
                intervalMonths: plan.intervalMonths, flows: flows,
                isInternal: plan.kind == .purchase && plan.accountID != nil, isActive: isActive)
        }
    }

    /// The plans counted by default: new money only. If the file has deposit or withdrawal plans
    /// (or purchases booked as deliveries), purchases paid from cash are left out — the money they
    /// invest is already counted when it is deposited. If there are only such purchases, they are
    /// taken as the contributions.
    var defaultSelection: Set<UUID> {
        let active = plans.filter(\.isActive)
        let external = active.filter { !$0.isInternal }
        return Set((external.isEmpty ? active : external).map(\.id))
    }

    /// Net contributions per month of the chosen plans.
    func flows(including selection: Set<UUID>, years: Int) -> [Int64] {
        var total = [Int64](repeating: 0, count: max(min(years, Self.maximumYears), 0) * 12)
        for plan in plans where selection.contains(plan.id) {
            for index in total.indices { total[index] = Self.saturatingSum(total[index], plan.flows[index]) }
        }
        return total
    }

    /// `a + b`, clamped to the `Int64` range: absurd amounts in a damaged file must not trap.
    static func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b < 0 ? .min : .max) : sum
    }
}
