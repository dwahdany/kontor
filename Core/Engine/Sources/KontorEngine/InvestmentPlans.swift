import Foundation
import KontorModel

extension InvestmentPlan {
    /// The `Transaction.source` value that marks a transaction as an execution of the plan `id`.
    public static func sourceTag(for id: UUID) -> String { "plan:\(id.uuidString)" }

    /// The `Transaction.source` value of this plan's executions.
    public var sourceTag: String { Self.sourceTag(for: id) }

    /// Execution days of the plan up to and including `day`, ascending.
    ///
    /// The k-th nominal date is `start + k × intervalMonths` calendar months, with the day of month
    /// clamped to the length of the target month (a plan started on the 31st runs on Feb 28/29,
    /// Mar 31, Apr 30, …). With `moveToWeekday`, dates falling on a Saturday or Sunday move to the
    /// following Monday. The plan stops after `end` (compared against the nominal date). A plan
    /// with a non-positive interval has no due dates.
    ///
    /// Dates the user skipped (`skippedDates`, see ``isSkipped(_:moveToWeekday:)``) are left out
    /// unless `includingSkipped` is true.
    public func dueDates(through day: Day, moveToWeekday: Bool = true, includingSkipped: Bool = false) -> [Day] {
        guard intervalMonths > 0 else { return [] }
        let step = min(intervalMonths, Self.maximumIntervalMonths)
        let skipped = includingSkipped ? [] : Set(skippedDates ?? [])
        var out: [Day] = []
        var k = 0
        while true {
            let nominal = start.addingMonths(k * step)
            if let end, nominal > end { break }
            let due = Self.execution(nominal, moveToWeekday: moveToWeekday)
            if due > day { break }
            if skipped.isEmpty || !(skipped.contains(due) || skipped.contains(nominal)) { out.append(due) }
            k += 1
        }
        return out
    }

    /// Scheduled execution days up to and including `day` that the user skipped, ascending.
    public func skippedDueDates(through day: Day, moveToWeekday: Bool = true) -> [Day] {
        guard let skippedDates, !skippedDates.isEmpty else { return [] }
        let kept = Set(dueDates(through: day, moveToWeekday: moveToWeekday))
        return dueDates(through: day, moveToWeekday: moveToWeekday, includingSkipped: true).filter { !kept.contains($0) }
    }

    /// Whether the execution falling on `due` was skipped by the user. `skippedDates` may hold the
    /// execution day (weekends moved to Monday) or the nominal day of the schedule; both count.
    public func isSkipped(_ due: Day, moveToWeekday: Bool = true) -> Bool {
        guard let skippedDates, !skippedDates.isEmpty else { return false }
        if skippedDates.contains(due) { return true }
        guard moveToWeekday, due.weekday == 1 else { return false }
        // A Monday execution may stand for a nominal Saturday or Sunday.
        return skippedDates.contains { ($0 == due.advanced(by: -1) || $0 == due.advanced(by: -2)) && isNominal($0) }
    }

    private func isNominal(_ day: Day) -> Bool {
        guard intervalMonths > 0, day >= start else { return false }
        let step = min(intervalMonths, Self.maximumIntervalMonths)
        let monthsApart = (day.year - start.year) * 12 + day.month - start.month
        guard monthsApart % step == 0 else { return false }
        return start.addingMonths(monthsApart) == day
    }

    /// The first execution day after `day` that is not skipped; nil if the plan has ended (or is invalid).
    public func nextDueDate(after day: Day, moveToWeekday: Bool = true) -> Day? {
        guard intervalMonths > 0 else { return nil }
        let step = min(intervalMonths, Self.maximumIntervalMonths)
        let skipped = Set(skippedDates ?? [])
        // Jump close to `day`, then walk forward.
        let monthsApart = (day.year - start.year) * 12 + day.month - start.month
        var k = max(monthsApart / step - 1, 0)
        while true {
            let nominal = start.addingMonths(k * step)
            if let end, nominal > end { return nil }
            let due = Self.execution(nominal, moveToWeekday: moveToWeekday)
            if due > day, !(skipped.contains(due) || skipped.contains(nominal)) { return due }
            k += 1
        }
    }

    /// Intervals are capped at 100 years so that absurd values in a damaged file cannot overflow
    /// the date arithmetic.
    private static let maximumIntervalMonths = 1_200

    private static func execution(_ nominal: Day, moveToWeekday: Bool) -> Day {
        guard moveToWeekday else { return nominal }
        switch nominal.weekday {
        case 6: return nominal.advanced(by: 2)
        case 7: return nominal.advanced(by: 1)
        default: return nominal
        }
    }

    /// A deterministic transaction id for the execution of plan `plan` due on `day`, so that
    /// generating the same execution twice yields the same transaction.
    public static func executionID(plan: UUID, due day: Day) -> UUID {
        func mix(_ x: UInt64) -> UInt64 {
            var z = x &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let (hi, lo) = withUnsafeBytes(of: plan.uuid) { raw in
            (
                UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
                UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            )
        }
        let d = UInt64(UInt32(bitPattern: day.rawValue))
        let a = mix(hi ^ mix(d))
        let b = mix(lo ^ a ^ (d << 32))
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: a >> UInt64(56 - 8 * i))
            bytes[8 + i] = UInt8(truncatingIfNeeded: b >> UInt64(56 - 8 * i))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4 layout
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Why a plan (or one of its executions) cannot be turned into a transaction.
public enum PlanProblem: Sendable, Hashable {
    /// `intervalMonths` is not positive.
    case invalidInterval
    /// The amount is not positive, or the fees are negative or not smaller than the amount of a purchase.
    case invalidAmount
    /// A deposit or withdrawal without (or with an unknown) account.
    case missingAccount
    /// A purchase without (or with an unknown) depot.
    case missingDepot
    /// A purchase without (or with an unknown) security.
    case missingSecurity
    /// The plan amount is not in the account's currency.
    case currencyMismatch(expected: CurrencyCode)
    /// The security has no price on or before the execution day.
    case noPrice
    /// The plan amount cannot be converted into the security's currency.
    case noExchangeRate(from: CurrencyCode, to: CurrencyCode)
}

/// Due dates of a plan compared with the executions recorded in the ledger.
public struct PlanStatus: Sendable, Hashable, Identifiable {
    /// An execution found in the ledger.
    public struct Execution: Sendable, Hashable, Identifiable {
        public var id: Day { due }
        /// The due date it was matched to.
        public let due: Day
        public let transactionID: UUID
        /// The transaction's actual date.
        public let date: Day
    }

    public var id: UUID { planID }
    public let planID: UUID
    /// All execution days up to the requested day, without the skipped ones.
    public let dueDates: [Day]
    /// Due dates for which the ledger contains a transaction of this plan.
    public let executions: [Execution]
    /// Due dates without a transaction, ascending.
    public let missing: [Day]
    /// Scheduled dates the user skipped (`InvestmentPlan.skippedDates`), ascending. They are neither
    /// in `dueDates` nor in `missing`, and no transaction is generated for them.
    public let skipped: [Day]
    /// The first execution day after the requested day; nil once the plan has ended.
    public let nextDue: Day?
    /// A configuration problem that prevents the plan from being executed at all.
    public let problem: PlanProblem?
}

/// The transactions that bring a plan up to date.
public struct PlanProposal: Sendable, Identifiable {
    /// A due date for which no transaction could be generated.
    public struct Skipped: Sendable, Hashable, Identifiable {
        public var id: Day { due }
        public let due: Day
        public let reason: PlanProblem
    }

    public var id: UUID { status.planID }
    public let status: PlanStatus
    /// New transactions for the missing executions, ascending by date. Append them to
    /// `PortfolioFile.transactions`; nothing is modified by the engine.
    public let transactions: [Transaction]
    public let skipped: [Skipped]
}

extension Ledger {
    /// Executions of all plans found in the ledger, keyed by the lowercased source tag.
    private func planExecutions() -> [String: [(date: Day, id: UUID)]] {
        var out: [String: [(date: Day, id: UUID)]] = [:]
        for t in transactions {
            guard let source = t.source, source.hasPrefix("plan:") else { continue }
            out[source.lowercased(), default: []].append((t.date, t.id))
        }
        return out
    }

    private func configurationProblem(_ plan: InvestmentPlan) -> PlanProblem? {
        if plan.intervalMonths <= 0 { return .invalidInterval }
        if plan.amount.minor <= 0 || plan.fees < 0 { return .invalidAmount }
        let account = plan.accountID.flatMap { self.account($0) }
        switch plan.kind {
        case .deposit, .withdrawal:
            guard let account else { return .missingAccount }
            if account.currency != plan.amount.currency { return .currencyMismatch(expected: account.currency) }
        case .purchase:
            guard plan.securityID.flatMap({ security($0) }) != nil else { return .missingSecurity }
            guard plan.depotID.flatMap({ depot($0) }) != nil else { return .missingDepot }
            if plan.accountID != nil {
                guard let account else { return .missingAccount }
                if account.currency != plan.amount.currency { return .currencyMismatch(expected: account.currency) }
            }
            if plan.fees >= plan.amount.minor { return .invalidAmount }
        }
        return nil
    }

    private func status(
        _ plan: InvestmentPlan, through day: Day, moveToWeekday: Bool, toleranceDays: Int,
        executions: [String: [(date: Day, id: UUID)]]
    ) -> PlanStatus {
        let due = plan.dueDates(through: day, moveToWeekday: moveToWeekday)
        var matched = [PlanStatus.Execution?](repeating: nil, count: due.count)
        // Each recorded execution claims the nearest due date (exact dates first).
        let recorded = (executions[plan.sourceTag.lowercased()] ?? []).sorted { $0.date < $1.date }
        func nearest(_ date: Day) -> Int? {
            guard !due.isEmpty else { return nil }
            var lo = 0, hi = due.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if due[mid] < date { lo = mid + 1 } else { hi = mid }
            }
            var best: Int?
            for i in [lo - 1, lo] where i >= 0 && i < due.count {
                if best == nil || abs(due[i].distance(to: date)) < abs(due[best!].distance(to: date)) { best = i }
            }
            return best
        }
        for exactPass in [true, false] {
            for r in recorded {
                guard let i = nearest(r.date), matched[i] == nil else { continue }
                let distance = abs(due[i].distance(to: r.date))
                if exactPass ? distance == 0 : (distance > 0 && distance <= toleranceDays) {
                    matched[i] = PlanStatus.Execution(due: due[i], transactionID: r.id, date: r.date)
                }
            }
        }
        return PlanStatus(
            planID: plan.id, dueDates: due, executions: matched.compactMap { $0 },
            missing: due.indices.filter { matched[$0] == nil }.map { due[$0] },
            skipped: plan.skippedDueDates(through: day, moveToWeekday: moveToWeekday),
            nextDue: plan.nextDueDate(after: day, moveToWeekday: moveToWeekday),
            problem: configurationProblem(plan))
    }

    /// Compares the due dates of `plan` up to `day` with the ledger. A transaction counts as an
    /// execution if its `source` is the plan's `sourceTag` and its date is the due date — or, to
    /// tolerate manual corrections, within `toleranceDays` of it.
    public func planStatus(
        _ plan: InvestmentPlan, through day: Day, moveToWeekday: Bool = true, toleranceDays: Int = 7
    ) -> PlanStatus {
        status(plan, through: day, moveToWeekday: moveToWeekday, toleranceDays: toleranceDays, executions: planExecutions())
    }

    /// Generates the transactions for all executions of `plan` that are due up to `day` and missing
    /// in the ledger. Pure: the ledger is not modified.
    ///
    /// * purchase → `buy` of `amount` (including `fees`) with the share count computed from the
    ///   security's price on the execution day (last known quote on or before it); without an
    ///   account an inbound delivery is generated instead. If the security is quoted in another
    ///   currency the gross amount is converted at the day's rate and stored as `securityGross`.
    /// * deposit / withdrawal → a booking of `amount` on the plan's account.
    ///
    /// Generated transactions carry `source == plan.sourceTag` and a deterministic id
    /// (`InvestmentPlan.executionID`). Due dates without a price or rate are reported in `skipped`.
    public func planTransactions(
        _ plan: InvestmentPlan, through day: Day, moveToWeekday: Bool = true, toleranceDays: Int = 7
    ) -> PlanProposal {
        proposal(plan, through: day, moveToWeekday: moveToWeekday, toleranceDays: toleranceDays, executions: planExecutions())
    }

    /// `planTransactions(_:through:)` for several plans (the ledger is scanned once).
    public func planTransactions(
        _ plans: [InvestmentPlan], through day: Day, moveToWeekday: Bool = true, toleranceDays: Int = 7
    ) -> [PlanProposal] {
        let executions = planExecutions()
        return plans.map {
            proposal($0, through: day, moveToWeekday: moveToWeekday, toleranceDays: toleranceDays, executions: executions)
        }
    }

    private func proposal(
        _ plan: InvestmentPlan, through day: Day, moveToWeekday: Bool, toleranceDays: Int,
        executions: [String: [(date: Day, id: UUID)]]
    ) -> PlanProposal {
        let status = status(
            plan, through: day, moveToWeekday: moveToWeekday, toleranceDays: toleranceDays, executions: executions)
        guard status.problem == nil else { return PlanProposal(status: status, transactions: [], skipped: []) }
        var transactions: [Transaction] = []
        var skipped: [PlanProposal.Skipped] = []
        for due in status.missing {
            let id = InvestmentPlan.executionID(plan: plan.id, due: due)
            switch plan.kind {
            case .deposit, .withdrawal:
                transactions.append(Transaction(
                    id: id, kind: plan.kind == .deposit ? .deposit : .withdrawal, date: due, accountID: plan.accountID,
                    amount: plan.amount, note: plan.name, source: plan.sourceTag))
            case .purchase:
                guard let securityID = plan.securityID, let security = security(securityID) else { continue }
                guard let quote = price(of: securityID, on: due), quote.day <= due, quote.price.raw > 0 else {
                    skipped.append(.init(due: due, reason: .noPrice))
                    continue
                }
                let gross = plan.amount.minor - plan.fees
                var grossInSecurityCurrency = gross
                var securityGross: Money?
                if security.currency != plan.amount.currency {
                    guard let converted = converter.convert(
                        minor: gross, from: plan.amount.currency, to: security.currency, on: due)
                    else {
                        skipped.append(.init(
                            due: due, reason: .noExchangeRate(from: plan.amount.currency, to: security.currency)))
                        continue
                    }
                    grossInSecurityCurrency = converted
                    securityGross = Money(minor: converted, currency: security.currency)
                }
                let shares = Shares(raw: mulDiv(
                    grossInSecurityCurrency, Scale.price * Scale.shares / Scale.amount, quote.price.raw))
                transactions.append(Transaction(
                    id: id, kind: plan.accountID == nil ? .deliveryIn : .buy, date: due, accountID: plan.accountID,
                    depotID: plan.depotID, securityID: securityID, shares: shares, amount: plan.amount,
                    fees: plan.fees, securityGross: securityGross, note: plan.name, source: plan.sourceTag))
            }
        }
        return PlanProposal(status: status, transactions: transactions, skipped: skipped)
    }
}
