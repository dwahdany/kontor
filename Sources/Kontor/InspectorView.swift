import SwiftUI
import KontorModel
import KontorUI

/// The trailing inspector: the active feature's inspector if it provides one, otherwise a generic
/// summary of the focused entity (or of the portfolio when nothing is focused).
struct InspectorView: View {
    @Environment(PortfolioStore.self) private var store
    let registry: FeatureRegistry

    var body: some View {
        Group {
            if let custom = registry.inspector(for: store.route.screen) {
                custom
            } else {
                DefaultInspector()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct DefaultInspector: View {
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        Form {
            switch store.route.focus {
            case .security(let id): if let s = store.security(id) { security(s) } else { portfolio }
            case .account(let id): if let a = store.account(id) { account(a) } else { portfolio }
            case .depot(let id): if let d = store.depot(id) { depot(d) } else { portfolio }
            case .transaction(let id): if let t = store.transaction(id) { transaction(t) } else { portfolio }
            case .plan(let id): if let p = store.plan(id) { plan(p) } else { portfolio }
            default: portfolio
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var portfolio: some View {
        Section("Portfolio") {
            KeyValueRow("Name", store.file.name.isEmpty ? "Untitled" : store.file.name)
            KeyValueRow("Base Currency", store.baseCurrency)
            KeyValueRow("Cost Method", store.file.settings.costMethod == .fifo ? "FIFO" : "Average")
            KeyValueRow("Since", store.inception.map { Fmt.day($0, style: .medium) } ?? "")
        }
        Section("Contents") {
            KeyValueRow("Securities", Fmt.integer(store.file.securities.count))
            KeyValueRow("Accounts", Fmt.integer(store.file.accounts.count))
            KeyValueRow("Depots", Fmt.integer(store.file.depots.count))
            KeyValueRow("Transactions", Fmt.integer(store.file.transactions.count))
            KeyValueRow("Plans", Fmt.integer(store.file.plans.count))
        }
        Section("Reporting Period") {
            KeyValueRow("Period", store.period.title)
            KeyValueRow("From", Fmt.day(store.periodInterval.lowerBound, style: .medium))
            KeyValueRow("To", Fmt.day(store.periodInterval.upperBound, style: .medium))
        }
        Section {
            Button("Portfolio Settings…") { store.present(.portfolioSettings) }
        }
    }

    @ViewBuilder private func security(_ s: Security) -> some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(s.name).font(.headline)
                if let latest = s.prices.latest {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.price(latest.price, currency: s.currency)).font(.kontorValue)
                        Spacer()
                        Text(Fmt.relativeDay(latest.day, today: store.today)).font(.caption).foregroundStyle(.secondary)
                    }
                    Sparkline(raw: s.prices.values.suffix(260)).frame(height: 44)
                }
            }
        }
        Section("Identifiers") {
            KeyValueRow("ISIN", s.isin)
            KeyValueRow("WKN", s.wkn)
            KeyValueRow("Ticker", s.ticker)
            KeyValueRow("Currency", s.currency)
        }
        Section("Data") {
            KeyValueRow("Quotes", Fmt.integer(s.prices.count))
            KeyValueRow("Transactions", Fmt.integer(store.transactions(forSecurity: s.id).count))
            KeyValueRow("Feed", s.feed?.provider ?? "")
        }
        Section {
            Button("Edit Security…") { store.present(.editSecurity(s.id)) }
        }
    }

    @ViewBuilder private func account(_ a: Account) -> some View {
        Section("Account") {
            KeyValueRow("Name", a.name)
            KeyValueRow("Currency", a.currency)
            KeyValueRow("Transactions", Fmt.integer(store.transactions(forAccount: a.id).count))
            KeyValueRow("Status", a.isRetired ? "Retired" : "Active")
        }
        if !a.note.isEmpty { Section("Note") { Text(a.note) } }
        Section { Button("Edit Account…") { store.present(.editAccount(a.id)) } }
    }

    @ViewBuilder private func depot(_ d: Depot) -> some View {
        Section("Depot") {
            KeyValueRow("Name", d.name)
            KeyValueRow("Reference Account", store.account(d.referenceAccountID)?.name ?? "")
            KeyValueRow("Transactions", Fmt.integer(store.transactions(forDepot: d.id).count))
            KeyValueRow("Status", d.isRetired ? "Retired" : "Active")
        }
        if !d.note.isEmpty { Section("Note") { Text(d.note) } }
        Section { Button("Edit Depot…") { store.present(.editDepot(d.id)) } }
    }

    @ViewBuilder private func transaction(_ t: Transaction) -> some View {
        Section("Transaction") {
            KeyValueRow("Type", t.kind.rawValue.capitalized)
            KeyValueRow("Date", Fmt.day(t.date, style: .medium))
            KeyValueRow("Security", store.security(t.securityID)?.name ?? "")
            KeyValueRow("Account", store.account(t.accountID)?.name ?? "")
            KeyValueRow("Depot", store.depot(t.depotID)?.name ?? "")
        }
        Section("Amounts") {
            if !t.shares.isZero { KeyValueRow("Shares", Fmt.shares(t.shares)) }
            KeyValueRow("Amount", Fmt.money(t.amount))
            if t.fees != 0 { KeyValueRow("Fees", Fmt.money(minor: t.fees, currency: t.amount.currency)) }
            if t.taxes != 0 { KeyValueRow("Taxes", Fmt.money(minor: t.taxes, currency: t.amount.currency)) }
        }
        if !t.note.isEmpty { Section("Note") { Text(t.note) } }
        Section { Button("Edit Transaction…") { store.present(.editTransaction(t.id)) } }
    }

    @ViewBuilder private func plan(_ p: InvestmentPlan) -> some View {
        Section("Plan") {
            KeyValueRow("Name", p.name)
            KeyValueRow("Amount", Fmt.money(p.amount))
            KeyValueRow("Every", p.intervalMonths == 1 ? "Month" : "\(p.intervalMonths) months")
            KeyValueRow("Start", Fmt.day(p.start, style: .medium))
            KeyValueRow("Security", store.security(p.securityID)?.name ?? "")
        }
        Section { Button("Edit Plan…") { store.present(.editPlan(p.id)) } }
    }
}
