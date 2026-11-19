import SwiftUI
import KontorUI

/// The editor behind `.newPlan(PlanPrefill)` and `.editPlan(id)`.
struct PlanEditor: View {
    enum Mode: Hashable {
        case new(PlanPrefill)
        case edit(UUID)
    }

    @Environment(PortfolioStore.self) private var store
    let mode: Mode

    @State private var draft = PlanDraft()
    @State private var isLoaded = false
    /// Until the user types a name, new plans are named after what they do.
    @State private var hasCustomName = false
    @FocusState private var nameFocused: Bool

    private var isEditing: Bool { if case .edit = mode { true } else { false } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(InvestmentPlan.Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Name") {
                        TextField("Name", text: $draft.name, prompt: Text(suggestedName))
                            .labelsHidden()
                            .focused($nameFocused)
                            .onChange(of: draft.name) { _, name in
                                if nameFocused { hasCustomName = !name.isEmpty }
                            }
                    }
                } footer: {
                    Text(kindExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    if draft.kind == .purchase {
                        LabeledContent("Security") { SecurityPicker(selection: $draft.securityID) }
                        LabeledContent("Depot") { DepotPicker(selection: $draft.depotID) }
                        LabeledContent("Paid From") {
                            AccountPicker(selection: $draft.accountID, allowsNone: true)
                        }
                        if draft.accountID == nil {
                            Text("Without a cash account the shares are booked as inbound deliveries: they arrive without touching any cash balance.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        LabeledContent("Account") { AccountPicker(selection: $draft.accountID) }
                    }
                }

                Section {
                    LabeledContent(draft.kind == .purchase ? "Amount per Execution" : "Amount") {
                        MoneyField("Amount", minor: $draft.amountMinor, currency: currency).frame(width: 150)
                    }
                    if draft.kind == .purchase {
                        LabeledContent("Of Which Fees") {
                            MoneyField("Fees", minor: $draft.fees, currency: currency).frame(width: 150)
                        }
                    }
                    Picker("Repeats", selection: $draft.intervalMonths) {
                        ForEach(intervalOptions, id: \.self) { months in
                            Text(PlanText.interval(months)).tag(months)
                        }
                    }
                    LabeledContent("First Execution") { DayField("First Execution", day: $draft.start) }
                    LabeledContent {
                        DayField("End", day: endBinding, placeholder: "No End")
                    } label: {
                        Text("Ends")
                        Text("Set an end date to pause or finish the plan.")
                    }
                }

                Section("Next Executions") {
                    schedulePreview
                }

                Section {
                    LabeledContent("Note") {
                        TextField("Note", text: $draft.note, prompt: Text("Optional"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(1...3)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            footer
        }
        .frame(width: 540)
        .frame(minHeight: 560, idealHeight: 720, maxHeight: 760)
        .onAppear(perform: load)
        .onChange(of: draft.kind) { _, _ in applyDefaults() }
        .onChange(of: draft.depotID) { old, new in depotChanged(from: old, to: new) }
    }

    // MARK: Parts

    private var footer: some View {
        HStack(spacing: DS.Spacing.s) {
            if case .edit(let id) = mode {
                Button("Delete Plan", role: .destructive) {
                    PlanActions.delete([id], in: store)
                    store.dismissSheet()
                }
                .help("Removes the plan. Transactions it already created stay in your ledger. You can undo this.")
            }
            if let message = validationMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: DS.Spacing.s)
            Button("Cancel", role: .cancel) { store.dismissSheet() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save" : "Add Plan") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
        }
        .padding(DS.Spacing.l)
    }

    @ViewBuilder private var schedulePreview: some View {
        let preview = draft.preview(today: store.today, currency: currency)
        if preview.dates.isEmpty {
            Text(preview.isEnded ? "This plan has ended — nothing more will come due." : "No executions with these settings.")
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                ForEach(preview.dates, id: \.self) { day in
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(Fmt.day(day, style: .medium)).numeric()
                        Text(weekdayName(day))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            if preview.movedFromWeekend {
                Label("Dates that fall on a weekend move to the following Monday.", systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        if !isEditing, preview.backlog > 0, let first = preview.firstBacklog {
            Label {
                Text("The start is in the past: \(Fmt.integer(preview.backlog)) \(preview.backlog == 1 ? "execution" : "executions") since \(Fmt.day(first, style: .medium)) \(preview.backlog == 1 ? "is" : "are") not booked yet. Kontor will offer to generate \(preview.backlog == 1 ? "it" : "them") — you review every one first.")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func weekdayName(_ day: Day) -> String {
        Calendar.current.weekdaySymbols[day.weekday % 7]
    }

    // MARK: Derived

    private var currency: CurrencyCode {
        if let account = store.account(draft.accountID) { return account.currency }
        if draft.kind == .purchase, let security = store.security(draft.securityID) { return security.currency }
        return store.baseCurrency
    }

    private var intervalOptions: [Int] {
        let standard = [1, 2, 3, 6, 12]
        return standard.contains(draft.intervalMonths) || draft.intervalMonths <= 0
            ? standard : (standard + [draft.intervalMonths]).sorted()
    }

    private var endBinding: Binding<Day?> {
        Binding(get: { draft.end }, set: { newValue in
            // The shared field sets the system date when switched on; this window's "today" is the reference.
            draft.end = newValue.map { draft.end == nil ? max(store.today, draft.start) : $0 }
        })
    }

    private var kindExplanation: String {
        switch draft.kind {
        case .purchase: "Buys a security for a fixed amount at a regular interval — a savings plan. The number of shares follows from the price on each execution day."
        case .deposit: "Books a regular deposit on a cash account, for example your monthly transfer to the broker."
        case .withdrawal: "Books a regular withdrawal from a cash account, for example a payout plan."
        }
    }

    private var suggestedName: String {
        draft.suggestedName(security: store.security(draft.securityID)?.name)
    }

    private var validationMessage: String? {
        guard isLoaded else { return nil }
        return draft.validate(
            security: store.security(draft.securityID), depot: store.depot(draft.depotID), account: store.account(draft.accountID))
    }

    // MARK: Actions

    private func load() {
        guard !isLoaded else { return }
        switch mode {
        case .edit(let id):
            guard let plan = store.plan(id) else {
                store.dismissSheet()
                return
            }
            draft = PlanDraft(plan)
            hasCustomName = true
        case .new(let prefill):
            draft = PlanDraft(prefill: prefill, file: store.file, today: store.today)
        }
        isLoaded = true
    }

    /// Fills what the chosen type needs and the user has not picked yet.
    private func applyDefaults() {
        guard isLoaded else { return }
        draft.fillDefaults(file: store.file)
    }

    private func depotChanged(from old: UUID?, to new: UUID?) {
        guard isLoaded, draft.kind == .purchase else { return }
        // Follow the depot's reference account as long as the account was not chosen independently.
        let previousReference = store.depot(old)?.referenceAccountID
        if draft.accountID == nil || draft.accountID == previousReference,
           let reference = store.depot(new)?.referenceAccountID {
            draft.accountID = reference
        }
    }

    private func save() {
        var plan = draft.plan(currency: currency)
        if plan.name.trimmingCharacters(in: .whitespaces).isEmpty { plan.name = suggestedName }
        switch mode {
        case .edit:
            store.updatePlan(plan)
        case .new:
            store.addPlan(plan)
            store.navigate(to: .plan(plan.id))
        }
        store.dismissSheet()
    }
}

/// The editor's working copy of a plan.
struct PlanDraft: Hashable {
    var id = UUID()
    var name = ""
    var kind = InvestmentPlan.Kind.purchase
    var securityID: UUID?
    var depotID: UUID?
    var accountID: UUID?
    var amountMinor: Int64 = 0
    var fees: Int64 = 0
    var start = Day(year: 2000, month: 1, day: 1)
    var end: Day?
    var intervalMonths = 1
    var note = ""
    var skippedDates: [Day]?

    init() {}

    init(_ plan: InvestmentPlan) {
        id = plan.id
        name = plan.name
        kind = plan.kind
        securityID = plan.securityID
        depotID = plan.depotID
        accountID = plan.accountID
        amountMinor = plan.amount.minor
        fees = plan.fees
        start = plan.start
        end = plan.end
        intervalMonths = plan.intervalMonths
        note = plan.note
        skippedDates = plan.skippedDates
    }

    /// A new plan: the prefill where given, sensible defaults elsewhere — the first depot with its
    /// reference account, monthly, starting on the first of next month.
    init(prefill: PlanPrefill, file: PortfolioFile, today: Day) {
        kind = prefill.kind ?? .purchase
        securityID = prefill.securityID
        depotID = prefill.depotID
        accountID = prefill.accountID
        amountMinor = prefill.amount?.minor ?? 0
        start = prefill.start ?? today.startOfMonth.addingMonths(1)
        fillDefaults(file: file)
    }

    mutating func fillDefaults(file: PortfolioFile) {
        switch kind {
        case .purchase:
            if depotID == nil { depotID = (file.depots.first { !$0.isRetired } ?? file.depots.first)?.id }
            if accountID == nil { accountID = file.depot(depotID)?.referenceAccountID }
        case .deposit, .withdrawal:
            break
        }
        if accountID == nil { accountID = (file.accounts.first { !$0.isRetired } ?? file.accounts.first)?.id }
    }

    func plan(currency: CurrencyCode) -> InvestmentPlan {
        InvestmentPlan(
            id: id, name: name.trimmingCharacters(in: .whitespaces), kind: kind,
            securityID: kind == .purchase ? securityID : nil, depotID: kind == .purchase ? depotID : nil,
            accountID: accountID, amount: Money(minor: amountMinor, currency: currency),
            fees: kind == .purchase ? fees : 0, start: start, end: end, intervalMonths: intervalMonths,
            note: note, skippedDates: skippedDates)
    }

    func suggestedName(security: String?) -> String {
        switch kind {
        case .purchase: security.map { "\($0) Savings Plan" } ?? "Savings Plan"
        case .deposit: "\(PlanText.interval(intervalMonths)) Deposit"
        case .withdrawal: "\(PlanText.interval(intervalMonths)) Withdrawal"
        }
    }

    /// The first thing that keeps the plan from being saved, in plain language; nil if it is fine.
    /// Mirrors the engine's `PlanProblem`s so that a saved plan can always be executed.
    func validate(security: Security?, depot: Depot?, account: Account?) -> String? {
        switch kind {
        case .purchase:
            if security == nil { return "Choose the security to buy." }
            if depot == nil { return "Choose the depot the shares go to." }
        case .deposit, .withdrawal:
            if account == nil { return "Choose the account." }
        }
        if amountMinor <= 0 { return "Enter the amount." }
        if kind == .purchase, fees >= amountMinor { return "The fees must be smaller than the amount." }
        if intervalMonths <= 0 { return "Choose how often the plan repeats." }
        if let end, end < start { return "The end is before the first execution." }
        return nil
    }

    struct Preview: Equatable {
        var dates: [Day] = []
        var movedFromWeekend = false
        /// Executions between the start and today (they would be due immediately).
        var backlog = 0
        var firstBacklog: Day?
        var isEnded = false
    }

    static let previewCount = 4

    /// The next execution days after today, from the engine's schedule.
    func preview(today: Day, currency: CurrencyCode) -> Preview {
        guard intervalMonths > 0 else { return Preview() }
        let plan = plan(currency: currency)
        var preview = Preview()
        let horizon = max(today, start).addingMonths(intervalMonths * (Self.previewCount + 1))
        let upcoming = plan.dueDates(through: horizon).filter { $0 > today }.prefix(Self.previewCount)
        preview.dates = Array(upcoming)
        let nominal = Set(plan.dueDates(through: horizon, moveToWeekday: false))
        preview.movedFromWeekend = upcoming.contains { !nominal.contains($0) }
        let past = plan.dueDates(through: today)
        preview.backlog = past.count
        preview.firstBacklog = past.first
        preview.isEnded = plan.nextDueDate(after: today) == nil
        return preview
    }
}
