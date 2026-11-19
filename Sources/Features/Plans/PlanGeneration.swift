import Foundation
import KontorUI

// "Generate due transactions": what the engine proposes for the open executions of one or all
// plans, the user's decision per date, and the single edit that applies them.

/// What to do with one open execution.
enum GenerationChoice: String, Hashable, Sendable, CaseIterable {
    /// Book the proposed transaction.
    case create
    /// Never book it: the date goes to the plan's `skippedDates`.
    case skip
    /// Leave it open; it stays due.
    case later

    var title: String {
        switch self {
        case .create: "Create"
        case .skip: "Skip"
        case .later: "Decide Later"
        }
    }
}

/// One open execution in the review list.
struct GenerationItem: Identifiable, Hashable, Sendable {
    var id: String
    var planID: UUID
    var planName: String
    var kind: InvestmentPlan.Kind
    var due: Day
    /// The engine's proposal; nil if none can be made (no price, no exchange rate).
    var transaction: Transaction?
    var security: String?
    /// Price the share count is based on, with the day of that quote.
    var price: Price?
    var priceCurrency: CurrencyCode?
    var priceDay: Day?
    var amount: Money
    /// Why there is no proposal, or what to double-check.
    var warning: String?

    var canCreate: Bool { transaction != nil }
    var defaultChoice: GenerationChoice { canCreate ? .create : .later }
}

struct GenerationProposal: Sendable {
    /// A plan that cannot be executed as configured.
    struct Problem: Identifiable, Hashable, Sendable {
        var id: UUID
        var planName: String
        var message: String
    }

    var items: [GenerationItem] = []
    var problems: [Problem] = []

    struct Key: Hashable, Sendable {
        /// nil = every plan.
        var planID: UUID?
        var today: Day
    }

    /// A quote older than this many days before the execution day is flagged.
    static let stalePriceDays = 7

    init() {}

    init(_ ledger: Ledger, plans: [InvestmentPlan], today: Day) {
        for proposal in ledger.planTransactions(plans, through: today) {
            guard let plan = plans.first(where: { $0.id == proposal.id }) else { continue }
            let security = plan.securityID.flatMap { ledger.security($0) }
            if let problem = proposal.status.problem {
                if !proposal.status.missing.isEmpty {
                    problems.append(Problem(id: plan.id, planName: plan.name, message: PlanText.problem(problem, security: security?.name)))
                }
                continue
            }
            for transaction in proposal.transactions {
                var item = GenerationItem(
                    id: "\(plan.id.uuidString)/\(transaction.date.iso)", planID: plan.id, planName: plan.name, kind: plan.kind,
                    due: transaction.date, transaction: transaction, security: security?.name, amount: transaction.amount)
                if let security, plan.kind == .purchase, let quote = ledger.price(of: security.id, on: transaction.date) {
                    item.price = quote.price
                    item.priceCurrency = security.currency
                    item.priceDay = quote.day
                    if quote.day < transaction.date.advanced(by: -Self.stalePriceDays) {
                        item.warning = "Uses the last known price, from \(Fmt.day(quote.day, style: .medium)). Check the share count."
                    }
                }
                items.append(item)
            }
            for skipped in proposal.skipped {
                items.append(GenerationItem(
                    id: "\(plan.id.uuidString)/\(skipped.due.iso)", planID: plan.id, planName: plan.name, kind: plan.kind,
                    due: skipped.due, transaction: nil, security: security?.name, amount: plan.amount,
                    warning: PlanText.problem(skipped.reason, security: security?.name)))
            }
        }
        items.sort { ($0.due, $0.planName, $0.id) < ($1.due, $1.planName, $1.id) }
    }
}

struct GenerationOutcome: Equatable, Sendable {
    var created = 0
    var skipped = 0
}

enum PlanGeneration {
    /// Applies the decisions to the file: appends the transactions chosen with `.create` and records
    /// the dates chosen with `.skip` in their plan's `skippedDates`. Items without a decision use
    /// their default. Pure; call it inside one `store.mutate`.
    @discardableResult
    static func apply(
        _ items: [GenerationItem], choices: [GenerationItem.ID: GenerationChoice], to file: inout PortfolioFile
    ) -> GenerationOutcome {
        var outcome = GenerationOutcome()
        var existing = Set(file.transactions.map(\.id))
        for item in items {
            switch choices[item.id] ?? item.defaultChoice {
            case .create:
                guard let transaction = item.transaction, existing.insert(transaction.id).inserted else { continue }
                file.transactions.append(transaction)
                outcome.created += 1
            case .skip:
                guard let index = file.plans.firstIndex(where: { $0.id == item.planID }) else { continue }
                if skip(item.due, in: &file.plans[index]) { outcome.skipped += 1 }
            case .later:
                continue
            }
        }
        return outcome
    }

    /// Marks `day` as skipped. Returns false if it already was.
    @discardableResult
    static func skip(_ day: Day, in plan: inout InvestmentPlan) -> Bool {
        guard !plan.isSkipped(day) else { return false }
        plan.skippedDates = ((plan.skippedDates ?? []) + [day]).sorted()
        return true
    }

    /// Makes a skipped execution day due again. `skippedDates` may hold the execution day or the
    /// nominal (weekend) day of the schedule; both are removed.
    @discardableResult
    static func restore(_ day: Day, in plan: inout InvestmentPlan) -> Bool {
        guard let dates = plan.skippedDates else { return false }
        let kept = dates.filter { date in
            var probe = plan
            probe.skippedDates = [date]
            return !probe.isSkipped(day)
        }
        guard kept.count != dates.count else { return false }
        plan.skippedDates = kept.isEmpty ? nil : kept
        return true
    }

    /// Pausing a plan = ending it today. The schedule keeps its history; nothing new comes due.
    static func pause(_ plan: inout InvestmentPlan, today: Day) {
        plan.end = today
    }

    /// Resumes a paused (ended) plan: clears the end date and marks the dates that fell into the
    /// pause as skipped, so resuming does not make months of executions due at once.
    static func resume(_ plan: inout InvestmentPlan, today: Day) {
        guard let end = plan.end else { return }
        plan.end = nil
        let before = Set(plan.dueDates(through: end, includingSkipped: true))
        let missed = plan.dueDates(through: today).filter { !before.contains($0) && $0 > end }
        if !missed.isEmpty {
            plan.skippedDates = Array(Set((plan.skippedDates ?? []) + missed)).sorted()
        }
    }
}
