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
    /// Set when the ledger already holds a transaction of this plan that very likely *is* this
    /// execution, booked on another day (moved in the ledger, or booked under an earlier schedule).
    var bookedOn: Day?

    var canCreate: Bool { transaction != nil }

    /// Booking is the default — except where it would probably duplicate a transaction that already
    /// exists: there the date is settled (skipped) unless the user decides otherwise.
    var defaultChoice: GenerationChoice {
        if bookedOn != nil { return .skip }
        return canCreate ? .create : .later
    }

    /// Whether the share count of the proposal can be adjusted before booking.
    var hasShares: Bool { transaction.map { !$0.shares.isZero } ?? false }

    /// The proposal as it will be booked, with the user's share count if one was entered (the amount
    /// stays what the plan pays; the price per share follows).
    func transaction(shares: Shares?) -> Transaction? {
        guard var transaction else { return nil }
        if let shares, shares.raw > 0, hasShares { transaction.shares = shares }
        return transaction
    }

    /// Price per share implied by a share count, in the security's currency.
    func impliedPrice(shares: Shares?) -> Price? {
        guard let shares, shares.raw > 0, let transaction, hasShares, shares != transaction.shares else { return price }
        let gross = transaction.securityGross?.minor ?? (transaction.amount.minor - transaction.fees)
        return Price(minor: gross, per: shares) ?? price
    }
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

    /// How far from a due date a plan transaction that is not matched to any date (the engine
    /// matches within 7 days) is still taken for that execution: a little more than half an interval.
    static func nearbyDays(intervalMonths: Int) -> Int {
        min(max(intervalMonths, 1), 12) * 31 / 2 + 3
    }

    init(_ ledger: Ledger, plans: [InvestmentPlan], today: Day) {
        let proposals = ledger.planTransactions(plans, through: today)
        // Only needed when something is open at all.
        let hasOpen = proposals.contains { !$0.status.missing.isEmpty && $0.status.problem == nil }
        let tagged = hasOpen ? PlanExecutions(ledger) : nil
        var usedIDs = hasOpen ? Set(ledger.transactions.map(\.id)) : []
        for proposal in proposals {
            guard let plan = plans.first(where: { $0.id == proposal.id }) else { continue }
            let security = plan.securityID.flatMap { ledger.security($0) }
            if let problem = proposal.status.problem {
                if !proposal.status.missing.isEmpty {
                    problems.append(Problem(id: plan.id, planName: plan.name, message: PlanText.problem(problem, security: security?.name)))
                }
                continue
            }
            let booked = Self.bookedElsewhere(
                plan: plan, status: proposal.status, executions: tagged?.transactions(of: plan) ?? [])
            for var transaction in proposal.transactions {
                let due = transaction.date
                // The engine's id for this date is taken when its transaction was moved away; a
                // second booking, if the user insists on one, needs an id of its own.
                while usedIDs.contains(transaction.id) {
                    transaction.id = InvestmentPlan.executionID(plan: transaction.id, due: due)
                }
                usedIDs.insert(transaction.id)
                var item = GenerationItem(
                    id: "\(plan.id.uuidString)/\(due.iso)", planID: plan.id, planName: plan.name, kind: plan.kind,
                    due: due, transaction: transaction, security: security?.name, amount: transaction.amount)
                if let security, plan.kind == .purchase, let quote = ledger.price(of: security.id, on: transaction.date) {
                    item.price = quote.price
                    item.priceCurrency = security.currency
                    item.priceDay = quote.day
                    if quote.day < transaction.date.advanced(by: -Self.stalePriceDays) {
                        item.warning = "Uses the last known price, from \(Fmt.day(quote.day, style: .medium)). Check the share count."
                    }
                }
                if let day = booked[due] {
                    item.bookedOn = day
                    item.warning = Self.bookedNote(day)
                }
                items.append(item)
            }
            for skipped in proposal.skipped {
                var item = GenerationItem(
                    id: "\(plan.id.uuidString)/\(skipped.due.iso)", planID: plan.id, planName: plan.name, kind: plan.kind,
                    due: skipped.due, transaction: nil, security: security?.name, amount: plan.amount,
                    warning: PlanText.problem(skipped.reason, security: security?.name))
                if let day = booked[skipped.due] {
                    item.bookedOn = day
                    item.warning = Self.bookedNote(day)
                }
                items.append(item)
            }
        }
        items.sort { ($0.due, $0.planName, $0.id) < ($1.due, $1.planName, $1.id) }
    }

    static func bookedNote(_ day: Day) -> String {
        "A transaction of this plan is already booked on \(Fmt.day(day, style: .medium)). Skip settles this date; Create would add a second one."
    }

    /// Open dates of `plan` for which the ledger very likely holds the execution already, with the
    /// day it is booked on.
    static func bookedElsewhere(plan: InvestmentPlan, status: PlanStatus, executions: [Transaction]) -> [Day: Day] {
        settled(plan: plan, dates: status.missing, status: status, executions: executions).mapValues(\.date)
    }

    /// Pairs `dates` of the plan's schedule (ascending) that have no matched execution with the
    /// plan's transactions the engine could not match to any due date: the one generated for
    /// exactly that date (it carries the date's deterministic id, wherever it was moved to),
    /// otherwise the nearest one within `nearbyDays`. Each transaction accounts for one date only.
    static func settled(
        plan: InvestmentPlan, dates: [Day], status: PlanStatus, executions: [Transaction]
    ) -> [Day: Transaction] {
        guard !dates.isEmpty, !executions.isEmpty else { return [:] }
        let matched = Set(status.executions.map(\.transactionID))
        var unmatched = executions.filter { !matched.contains($0.id) }
        guard !unmatched.isEmpty else { return [:] }
        var result: [Day: Transaction] = [:]
        let idToDue = Dictionary(
            dates.map { (InvestmentPlan.executionID(plan: plan.id, due: $0), $0) }, uniquingKeysWith: { a, _ in a })
        unmatched.removeAll { transaction in
            guard let due = idToDue[transaction.id], result[due] == nil else { return false }
            result[due] = transaction
            return true
        }
        let tolerance = nearbyDays(intervalMonths: plan.intervalMonths)
        var first = 0   // dates before this index are too early for every remaining transaction
        for transaction in unmatched.sorted(by: { $0.date < $1.date }) {
            while first < dates.count, dates[first] < transaction.date.advanced(by: -tolerance) { first += 1 }
            var best: Day?
            for due in dates[first...] {
                if due > transaction.date.advanced(by: tolerance) { break }
                guard result[due] == nil else { continue }
                let distance = abs(due.distance(to: transaction.date))
                if best.map({ abs($0.distance(to: transaction.date)) > distance }) ?? true { best = due }
            }
            if let best { result[best] = transaction }
        }
        return result
    }
}

struct GenerationOutcome: Equatable, Sendable {
    var created = 0
    var skipped = 0
    /// Chosen for creation, but the ledger already holds that very transaction (the proposal was
    /// out of date). Nothing is added twice — and the caller can say so.
    var alreadyBooked = 0

    var isEmpty: Bool { created == 0 && skipped == 0 }
}

enum PlanGeneration {
    /// Applies the decisions to the file: appends the transactions chosen with `.create` and records
    /// the dates chosen with `.skip` in their plan's `skippedDates`. Items without a decision use
    /// their default; `shares` holds the share counts the user corrected. Pure; call it inside one
    /// `store.mutate`.
    @discardableResult
    static func apply(
        _ items: [GenerationItem], choices: [GenerationItem.ID: GenerationChoice], shares: [GenerationItem.ID: Shares] = [:],
        to file: inout PortfolioFile
    ) -> GenerationOutcome {
        var outcome = GenerationOutcome()
        var existing = Set(file.transactions.map(\.id))
        for item in items {
            switch choices[item.id] ?? item.defaultChoice {
            case .create:
                guard let transaction = item.transaction(shares: shares[item.id]) else { continue }
                guard existing.insert(transaction.id).inserted else {
                    outcome.alreadyBooked += 1
                    continue
                }
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

    // MARK: Pause and resume

    /// A plan can be paused once it has run at least once and still has dates ahead. (A plan that
    /// has not started is simply edited or deleted: "ending" it before its start is not a pause.)
    static func canPause(_ plan: InvestmentPlan, today: Day) -> Bool {
        !plan.dueDates(through: today, includingSkipped: true).isEmpty && plan.nextDueDate(after: today) != nil
    }

    /// Pausing a plan = ending it today: the schedule keeps its history and nothing new comes due.
    /// The model has no separate pause state, so an end date the plan already had is replaced —
    /// it is returned so the caller can tell the user.
    ///
    /// The engine compares the *nominal* date with `end`; if a weekend date's Monday execution is
    /// still ahead, the plan ends the day before that nominal date so the Monday does not come due.
    @discardableResult
    static func pause(_ plan: inout InvestmentPlan, today: Day) -> Day? {
        guard canPause(plan, today: today) else { return nil }
        let replaced = plan.end
        let executed = plan.dueDates(through: today, includingSkipped: true).count
        let nominal = plan.dueDates(through: today, moveToWeekday: false, includingSkipped: true)
        plan.end = nominal.count > executed ? min(today, nominal[executed].advanced(by: -1)) : today
        return replaced
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

    // MARK: Duplicate

    /// A copy that starts fresh: no end, nothing skipped, and — if the original is already running —
    /// starting on the next date of the original's rhythm, so it keeps the day of the month and
    /// brings no backlog along.
    static func duplicate(_ plan: InvestmentPlan, today: Day) -> InvestmentPlan {
        var copy = plan
        copy.id = UUID()
        copy.name += " Copy"
        copy.end = nil
        copy.skippedDates = nil
        guard copy.start <= today, let first = copy.nextDueDate(after: today, moveToWeekday: false) else { return copy }
        // Short months clamp the day (31st → 28 Feb); prefer a date that falls on the original day.
        var candidate = first
        for _ in 0..<12 where candidate.dayOfMonth != plan.start.dayOfMonth {
            guard let next = copy.nextDueDate(after: candidate, moveToWeekday: false) else { break }
            candidate = next
        }
        copy.start = candidate.dayOfMonth == plan.start.dayOfMonth ? candidate : first
        return copy
    }
}

/// What changing a plan's schedule (first execution, interval, end) does to its past: which dates
/// up to today would newly count as due, and how many booked executions no longer fall on a
/// scheduled day. The engine recognises an execution only within 7 days of a due date, so moving
/// the execution day un-matches the whole history.
struct ScheduleImpact: Equatable, Sendable {
    /// Dates up to today that are open with the new schedule and were not open before.
    var newlyDue: [Day] = []
    /// Booked executions that matched a date of the old schedule and match none of the new one.
    var unmatched = 0
    /// Whether the plan has booked anything at all.
    var hasHistory = false

    init() {}

    init(_ ledger: Ledger, old: InvestmentPlan, new: InvestmentPlan, today: Day) {
        guard old.start != new.start || old.intervalMonths != new.intervalMonths || old.end != new.end else { return }
        let before = ledger.planStatus(old, through: today)
        let after = ledger.planStatus(new, through: today)
        hasHistory = !before.executions.isEmpty || !after.executions.isEmpty
        let wasOpen = Set(before.missing)
        newlyDue = after.missing.filter { !wasOpen.contains($0) }
        let stillMatched = Set(after.executions.map(\.transactionID))
        unmatched = before.executions.filter { !stillMatched.contains($0.transactionID) }.count
    }

    /// A plan that has already booked executions keeps its history by default: a schedule change
    /// then applies from the next execution. A plan that never booked anything behaves like a new
    /// one — its past dates are a backlog to review.
    var keepsHistoryByDefault: Bool { hasHistory }

    /// Applies the change "from the next execution on": the newly open past dates are recorded as
    /// skipped, so nothing that is already booked gets proposed again.
    func keepHistory(in plan: inout InvestmentPlan) {
        guard !newlyDue.isEmpty else { return }
        plan.skippedDates = Array(Set((plan.skippedDates ?? []) + newlyDue)).sorted()
    }
}
