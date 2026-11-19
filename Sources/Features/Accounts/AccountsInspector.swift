import SwiftUI
import KontorUI

/// Inspector of the Accounts screen: master data and usage of the open account or depot, or a
/// summary of all of them on the overview.
struct AccountsInspector: View {
    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<AccountsOverview>()
    /// What refers to the open entity; computed once per document revision and entity, not per body.
    @State private var references = EntityReferences()

    private struct ReferencesKey: Equatable {
        var revision: Int
        var focus: Route.Focus?
    }

    var body: some View {
        let today = store.today
        Form {
            if let id = store.route.accountID, let account = store.account(id) {
                accountSections(account)
            } else if let id = store.route.depotID, let depot = store.depot(id) {
                depotSections(depot)
            } else {
                overviewSections
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .analysisTask($model, id: "accounts.overview", scope: .portfolio, variant: today) { analysis in
            AccountsOverview(analysis, today: today)
        }
        .onChange(of: ReferencesKey(revision: store.revision, focus: store.route.focus), initial: true) { _, key in
            switch key.focus {
            case .account(let id): references = .account(id, in: store.file)
            case .depot(let id): references = .depot(id, in: store.file)
            default: references = EntityReferences()
            }
        }
    }

    @ViewBuilder
    private func accountSections(_ account: Account) -> some View {
        let row = model.value?.accounts.first { $0.id == account.id }
        Section("Cash Account") {
            KeyValueRow("Name", account.name)
            KeyValueRow("Currency", "\(account.currency) – \(Currencies.name(account.currency))")
            KeyValueRow("Status", account.isRetired ? "Retired" : "Active")
            if !account.note.isEmpty { KeyValueRow("Note", account.note) }
        }
        Section("Today") {
            KeyValueRow("Balance", Fmt.money(row?.balance))
            if let row, row.balance.currency != row.value.currency {
                KeyValueRow("Value") {
                    HStack(spacing: DS.Spacing.xs) {
                        if row.isValued {
                            Text(Fmt.money(row.value)).numeric()
                        } else {
                            Text("No exchange rate").foregroundStyle(DS.Colors.warning)
                        }
                        HelpButton(.exchangeRates)
                    }
                }
            }
        }
        activitySection(count: row?.transactionCount, first: row?.firstActivity, last: row?.lastActivity)
        Section("Used By") {
            KeyValueRow("Depots", references.depots.isEmpty ? "None" : references.depots.joined(separator: ", "))
            KeyValueRow("Investment Plans", Fmt.integer(references.plans))
            KeyValueRow("Classifications", Fmt.integer(references.classifications))
        }
        actions(.account(account.id))
    }

    @ViewBuilder
    private func depotSections(_ depot: Depot) -> some View {
        let row = model.value?.depots.first { $0.id == depot.id }
        Section("Depot") {
            KeyValueRow("Name", depot.name)
            KeyValueRow("Reference Account") {
                if let account = store.account(depot.referenceAccountID) {
                    Button(account.name) { store.navigate(to: .account(account.id)) }.buttonStyle(.link)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
            KeyValueRow("Status", depot.isRetired ? "Retired" : "Active")
            if !depot.note.isEmpty { KeyValueRow("Note", depot.note) }
        }
        Section("Today") {
            KeyValueRow("Market Value", Fmt.money(row?.value))
            KeyValueRow("Positions", row.map { Fmt.integer($0.positionCount) } ?? Fmt.missing)
            if let row, row.unvaluedPositions > 0 {
                gapNote("\(Fmt.integer(row.unvaluedPositions)) position\(row.unvaluedPositions == 1 ? "" : "s") without a price or exchange rate count\(row.unvaluedPositions == 1 ? "s" : "") as zero.")
            }
        }
        Section("Period · \(store.period.shortTitle)") {
            KeyValueRow("TTWROR") {
                HStack(spacing: DS.Spacing.xs) {
                    if let ttwror = row?.ttwror { GainText(percent: ttwror) } else { Text(Fmt.missing).foregroundStyle(.secondary) }
                    HelpButton(.ttwror)
                }
            }
            KeyValueRow("Gain") {
                if let row, row.ttwror != nil { GainText(money: row.gain) } else { Text(Fmt.missing).foregroundStyle(.secondary) }
            }
        }
        activitySection(count: row?.transactionCount, first: row?.firstActivity, last: row?.lastActivity)
        Section("Used By") {
            KeyValueRow("Investment Plans", Fmt.integer(references.plans))
        }
        actions(.depot(depot.id))
    }

    @ViewBuilder
    private var overviewSections: some View {
        let accounts = store.file.accounts, depots = store.file.depots
        Section("Accounts") {
            KeyValueRow("Cash Accounts", Fmt.integer(accounts.count))
            KeyValueRow("Depots", Fmt.integer(depots.count))
            KeyValueRow("Retired", Fmt.integer(accounts.filter(\.isRetired).count + depots.filter(\.isRetired).count))
            KeyValueRow("Currencies", Array(Set(accounts.map(\.currency))).sorted().joined(separator: ", "))
        }
        Section("Today") {
            KeyValueRow("Cash", Fmt.money(model.value?.cashTotal))
            KeyValueRow("Securities", Fmt.money(model.value?.depotTotal))
            KeyValueRow("Net Worth", Fmt.money(model.value?.netWorth))
            if let note = model.value?.gaps.note {
                gapNote("Incomplete: \(note).")
            }
        }
        Section {
            Text("Open an account or depot to see its details here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// A total that leaves something out says so, in the warning color and with its glyph.
    private func gapNote(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func activitySection(count: Int?, first: Day?, last: Day?) -> some View {
        Section("Activity") {
            KeyValueRow("Transactions", count.map { Fmt.integer($0) } ?? Fmt.missing)
            KeyValueRow("First", first.map { Fmt.day($0, style: .medium) } ?? "")
            KeyValueRow("Last", last.map { Fmt.day($0, style: .medium) } ?? "")
        }
    }

    private func actions(_ entity: AccountsEntity) -> some View {
        let retired = AccountsActions.isRetired(entity, in: store)
        return Section {
            Button("Edit…") {
                switch entity {
                case .account(let id): store.present(.editAccount(id))
                case .depot(let id): store.present(.editDepot(id))
                }
            }
            Button("Show in Transactions") { AccountsActions.showTransactions(entity, in: store) }
            Button(retired ? "Reactivate" : "Retire") { AccountsActions.setRetired(!retired, entity, in: store) }
        }
    }
}
