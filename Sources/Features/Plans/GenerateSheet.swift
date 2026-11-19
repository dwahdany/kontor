import SwiftUI
import KontorUI

/// "Generate Due Transactions…": a review list of everything the plans would book up to today. Each
/// date can be created, skipped for good (recorded in the plan's `skippedDates`) or left open; the
/// share count of a purchase can be corrected in place, and "Edit Before Adding…" opens the full
/// transaction editor with the proposal. The result is applied as one undoable step.
///
/// Launch state: `choice=skip|later` pre-sets the last row; `shares=<number>` enters that share
/// count in the first purchase row.
struct GenerateSheet: View {
    @Environment(PortfolioStore.self) private var store
    /// nil = all plans.
    let planID: UUID?

    @State private var proposal: GenerationProposal?
    @State private var choices: [GenerationItem.ID: GenerationChoice] = [:]
    /// Share counts the user corrected (zero while a field is being retyped = use the proposal).
    @State private var shares: [GenerationItem.ID: Shares] = [:]

    private var items: [GenerationItem] { proposal?.items ?? [] }
    private func choice(_ item: GenerationItem) -> GenerationChoice { choices[item.id] ?? item.defaultChoice }

    private var planName: String? { planID.flatMap { store.plan($0)?.name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 860)
        .frame(minHeight: 380, maxHeight: 640)
        .task(id: store.revision) { await load() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Generate Due Transactions")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Spacing.m)
            if items.count > 1 {
                Menu("Set All") {
                    Button("Create All") { setAll(.create) }
                    Button("Skip All") { setAll(.skip) }
                    Button("Decide Later for All") { setAll(.later) }
                }
                .fixedSize()
                .help("Choose the same action for every date")
            }
        }
        .padding(DS.Spacing.l)
    }

    private var isUpToDate: Bool {
        proposal.map { $0.items.isEmpty && $0.problems.isEmpty } ?? false
    }

    private var subtitle: String {
        let scope = planName.map { "“\($0)”" } ?? "your plans"
        if isUpToDate {
            return "No execution of \(scope) is due as of \(Fmt.day(store.today, style: .medium))."
        }
        if proposal != nil, items.isEmpty {
            return "Nothing can be generated for \(scope) until the plan settings are fixed."
        }
        return "These executions of \(scope) are due up to \(Fmt.day(store.today, style: .medium)) and not booked yet. Nothing is added until you confirm, and you can undo it afterwards."
    }

    @ViewBuilder private var content: some View {
        if let proposal {
            if proposal.items.isEmpty && proposal.problems.isEmpty {
                EmptyState("Everything Is Up to Date", symbol: "checkmark.circle",
                           message: "No executions are due. The next ones appear here once their date has come.")
                    .frame(minHeight: 220)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(proposal.problems) { problem in
                            problemRow(problem)
                            Divider()
                        }
                        if !proposal.items.isEmpty {
                            columnHeader
                            Divider()
                            ForEach(proposal.items) { item in
                                row(item)
                                Divider().padding(.leading, DS.Spacing.l)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        } else {
            Color.clear
                .frame(minHeight: 220)
                .loadingOverlay(true, label: "Preparing…")
        }
    }

    private enum Column {
        static let action: CGFloat = 124
        static let date: CGFloat = 96
        static let shares: CGFloat = 108
        static let price: CGFloat = 96
        static let amount: CGFloat = 104
        static let more: CGFloat = 22
    }

    private var columnHeader: some View {
        HStack(spacing: DS.Spacing.m) {
            Text("Action").frame(width: Column.action, alignment: .leading)
            Text("Date").frame(width: Column.date, alignment: .leading)
            Text("Plan").frame(maxWidth: .infinity, alignment: .leading)
            Text("Shares").frame(width: Column.shares, alignment: .trailing)
            Text("Price").frame(width: Column.price, alignment: .trailing)
            Text("Amount").frame(width: Column.amount, alignment: .trailing)
            Color.clear.frame(width: Column.more, height: 1)
        }
        .font(.kontorCaption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    private func row(_ item: GenerationItem) -> some View {
        let choice = choice(item)
        let isCreated = choice == .create
        let entered = shares[item.id].flatMap { $0.raw > 0 && $0 != item.transaction?.shares ? $0 : nil }
        return HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            Picker("Action for \(Fmt.day(item.due, style: .medium))", selection: binding(item)) {
                if item.canCreate { Text(GenerationChoice.create.title).tag(GenerationChoice.create) }
                Text(GenerationChoice.skip.title).tag(GenerationChoice.skip)
                Text(GenerationChoice.later.title).tag(GenerationChoice.later)
            }
            .labelsHidden()
            .frame(width: Column.action, alignment: .leading)

            Text(Fmt.day(item.due, style: .medium))
                .numeric()
                .frame(width: Column.date, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(item.planName).lineLimit(1)
                    Text(item.transaction?.kind.title ?? item.kind.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let warning = item.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if choice == .skip {
                    Text("Will be marked as skipped — you can restore it in the plan's timeline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if entered != nil {
                    Text("Shares adjusted — the price per share follows from the amount. Clear the field to reset.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if choice == .later {
                    Text("Stays due.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if isCreated, item.hasShares, let proposed = item.transaction?.shares {
                    // Real executions rarely match the closing quote: the share count can be corrected here.
                    SharesCell(date: item.due, proposed: proposed, shares: $shares[item.id])
                        .frame(width: Column.shares, alignment: .trailing)
                } else {
                    Text(item.transaction.flatMap { $0.shares.isZero ? nil : Fmt.shares($0.shares) } ?? (item.kind == .purchase ? Fmt.missing : ""))
                        .frame(width: Column.shares, alignment: .trailing)
                }
                Text(item.impliedPrice(shares: isCreated ? entered : nil).map { Fmt.price($0, currency: item.priceCurrency) } ?? (item.kind == .purchase ? Fmt.missing : ""))
                    .frame(width: Column.price, alignment: .trailing)
                Text(Fmt.money(item.amount))
                    .frame(width: Column.amount, alignment: .trailing)
            }
            .numeric()
            .foregroundStyle(isCreated ? .primary : .secondary)
            .strikethrough(choice == .skip, color: .secondary)

            Menu {
                Button("Edit Before Adding…") { editBeforeAdding(item) }
                    .disabled(!item.canCreate)
                Button("Show Plan") {
                    store.dismissSheet()
                    store.navigate(to: .plan(item.planID))
                }
            } label: {
                Label("More actions for \(Fmt.day(item.due, style: .medium))", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Column.more)
            .help("Edit Before Adding… opens the transaction editor with this proposal, to change the date, price, fees or anything else.")
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .accessibilityElement(children: .contain)
    }

    private func problemRow(_ problem: GenerationProposal.Problem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("“\(problem.planName)” cannot be executed")
                Text(problem.message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Spacing.m)
            Button("Edit Plan…") {
                store.dismissSheet()
                store.present(.editPlan(problem.id))
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
    }

    private var footer: some View {
        let summary = Summary(items: items, choice: choice)
        return HStack(spacing: DS.Spacing.m) {
            Text(summary.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .numeric()
                .lineLimit(2)
            Spacer(minLength: DS.Spacing.m)
            if items.isEmpty, proposal != nil {
                // Nothing to confirm or cancel.
                Button("Done") { store.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(summary.hasChanges || items.isEmpty ? "Cancel" : "Close", role: .cancel) { store.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
            }
            if !items.isEmpty {
                Button(summary.confirmTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!summary.hasChanges)
            }
        }
        .padding(DS.Spacing.l)
    }

    /// What confirming would do: how many transactions per kind (deposits, withdrawals and
    /// purchases are different things — they are never added into one figure), how many dates
    /// skipped and left open.
    struct Summary {
        struct Group: Equatable {
            var kind: InvestmentPlan.Kind
            var currency: CurrencyCode
            var count = 0
            var total: Int64 = 0

            var text: String {
                let noun: String = switch kind {
                case .deposit: count == 1 ? "deposit" : "deposits"
                case .withdrawal: count == 1 ? "withdrawal" : "withdrawals"
                case .purchase: count == 1 ? "purchase" : "purchases"
                }
                return "\(Fmt.integer(count)) \(noun) (\(Fmt.money(minor: total, currency: currency)))"
            }
        }

        var created = 0
        var skipped = 0
        var later = 0
        /// Per kind and currency: deposits, withdrawals, purchases.
        var groups: [Group] = []

        init(items: [GenerationItem], choice: (GenerationItem) -> GenerationChoice) {
            for item in items {
                switch choice(item) {
                case .create:
                    created += 1
                    let index = groups.firstIndex { $0.kind == item.kind && $0.currency == item.amount.currency } ?? {
                        groups.append(Group(kind: item.kind, currency: item.amount.currency))
                        return groups.count - 1
                    }()
                    groups[index].count += 1
                    groups[index].total = ProjectionBase.saturatingSum(groups[index].total, item.amount.minor)
                case .skip: skipped += 1
                case .later: later += 1
                }
            }
            let order: [InvestmentPlan.Kind] = [.deposit, .withdrawal, .purchase]
            groups.sort {
                (order.firstIndex(of: $0.kind) ?? 0, $0.currency) < (order.firstIndex(of: $1.kind) ?? 0, $1.currency)
            }
        }

        var hasChanges: Bool { created + skipped > 0 }

        var confirmTitle: String {
            if created == 0 { return skipped == 1 ? "Skip 1 Date" : "Skip \(Fmt.integer(skipped)) Dates" }
            return created == 1 ? "Add 1 Transaction" : "Add \(Fmt.integer(created)) Transactions"
        }

        var text: String {
            var parts: [String] = []
            if created > 0 { parts.append("Adding " + groups.map(\.text).joined(separator: ", ")) }
            if skipped > 0 { parts.append("\(Fmt.integer(skipped)) skipped") }
            if later > 0 { parts.append("\(Fmt.integer(later)) left open") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Actions

    private func binding(_ item: GenerationItem) -> Binding<GenerationChoice> {
        Binding(get: { choice(item) }, set: { choices[item.id] = $0 })
    }

    private func setAll(_ choice: GenerationChoice) {
        for item in items {
            choices[item.id] = choice == .create && !item.canCreate ? .later : choice
        }
    }

    private func load() async {
        let plans = planID.map { id in store.file.plans.filter { $0.id == id } } ?? store.file.plans
        let today = store.today
        let key = GenerationProposal.Key(planID: planID, today: today)
        if let result = try? await store.compute(key, { ledger in GenerationProposal(ledger, plans: plans, today: today) }) {
            proposal = result
            if let preset = store.launchValue("choice", as: GenerationChoice.self), choices.isEmpty, let last = result.items.last {
                choices[last.id] = preset == .create && !last.canCreate ? .later : preset
            }
            if let value = store.launchValue("shares").flatMap(Fmt.parseDouble), shares.isEmpty,
               let first = result.items.first(where: \.hasShares) {
                shares[first.id] = Shares(raw: FixedMath.saturatingInt64(value * Double(Scale.shares)))
            }
        }
    }

    /// Hands the proposal to the transaction editor (owned by the Transactions feature), tagged as
    /// this plan's execution, and comes back to this sheet afterwards: saved within a week of the
    /// due date, the transaction settles the date and the row is gone.
    private func editBeforeAdding(_ item: GenerationItem) {
        guard let transaction = item.transaction(shares: shares[item.id]) else { return }
        var prefill = TransactionPrefill(copying: transaction)
        prefill.source = transaction.source
        store.dismissSheet()
        store.present(.newTransaction(prefill))
        PlanActions.generate(planID, in: store)
    }

    private func apply() {
        let items = items, choices = choices, shares = shares
        var outcome = GenerationOutcome()
        let summary = Summary(items: items, choice: choice)
        let name = summary.created == 0 ? "Skip Plan Executions" : "Generate Plan Transactions"
        store.mutate(name) { file in
            outcome = PlanGeneration.apply(items, choices: choices, shares: shares, to: &file)
        }
        store.dismissSheet()
        if outcome.isEmpty {
            // Never close silently after "Add n Transactions".
            store.toast(
                "Nothing was added",
                message: outcome.alreadyBooked > 0
                    ? "\(outcome.alreadyBooked == 1 ? "This transaction is" : "These \(Fmt.integer(outcome.alreadyBooked)) transactions are") already in your ledger."
                    : "The plans changed in the meantime. Open Generate… again to review what is due now.",
                style: .info)
            return
        }
        if outcome.created > 0 {
            store.toast(
                outcome.created == 1 ? "Added 1 transaction" : "Added \(Fmt.integer(outcome.created)) transactions",
                message: outcome.skipped > 0 ? "\(Fmt.integer(outcome.skipped)) skipped. Undo with ⌘Z." : "Undo with ⌘Z.",
                style: .success)
        } else if outcome.skipped > 0 {
            store.toast(outcome.skipped == 1 ? "Skipped 1 execution" : "Skipped \(Fmt.integer(outcome.skipped)) executions", style: .info)
        }
    }
}

/// The share count of one proposed purchase, editable. An empty field means "as proposed".
private struct SharesCell: View {
    let date: Day
    let proposed: Shares
    @Binding var shares: Shares?
    @FocusState private var isFocused: Bool

    var body: some View {
        SharesField("Shares on \(Fmt.day(date, style: .medium))", shares: Binding(
            get: { shares ?? proposed },
            // Zero is kept while the field is being retyped; it counts as "as proposed".
            set: { shares = $0 == proposed ? nil : $0 }
        ))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if !focused, let value = shares, value.raw <= 0 { shares = nil }
        }
        .help("The proposal uses the last quote. Enter the shares you actually received; the amount stays as the plan pays it.")
    }
}
