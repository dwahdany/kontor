import SwiftUI
import KontorUI

/// The editor behind `.newPlan(PlanPrefill)` and `.editPlan(id)`.
///
/// Launch state (screenshots): `start=<YYYY-MM-DD>` and `interval=<months>` change the schedule of
/// the plan being edited, `history=due|keep` answers the question that follows.
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
    /// The plan as it was when the editor opened (edit mode).
    @State private var original: InvestmentPlan?
    /// What the schedule in the draft does to the plan's past, compared with `original`.
    @State private var impact = ScheduleImpact()
    /// The user's answer to "what about the past dates?"; nil = the default for this plan.
    @State private var keepsHistoryChoice: Bool?

    private var isEditing: Bool { if case .edit = mode { true } else { false } }
    private var keepsHistory: Bool { keepsHistoryChoice ?? impact.keepsHistoryByDefault }

    /// The inputs of `impact`.
    private struct ScheduleKey: Hashable {
        var start: Day
        var end: Day?
        var intervalMonths: Int
        var revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Plan" : "New Plan")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.l)
                .padding(.top, DS.Spacing.l)
                .padding(.bottom, DS.Spacing.s)
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
                        if store.file.securities.isEmpty {
                            // A savings plan needs something to buy; do not leave a new user stuck here.
                            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
                                Label("This portfolio has no securities yet. Add the fund or share the plan should buy, then come back.",
                                      systemImage: "info.circle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: DS.Spacing.s)
                                Button("New Security…", action: addSecurityFirst)
                            }
                        }
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
        .task(id: ScheduleKey(start: draft.start, end: draft.end, intervalMonths: draft.intervalMonths, revision: store.revision)) {
            await updateImpact()
        }
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
        if isEditing, !impact.newlyDue.isEmpty {
            pastDatesQuestion
        }
    }

    /// Shown when the edited schedule leaves past dates without a matching transaction — moving
    /// the execution day does that to the whole history. Nothing becomes due behind the user's back.
    @ViewBuilder private var pastDatesQuestion: some View {
        let count = impact.newlyDue.count
        let dates = count == 1 ? "1 past date" : "\(Fmt.integer(count)) past dates"
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Label {
                Text(PlanDraft.pastDatesMessage(impact))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
            }
            Picker("Past dates", selection: Binding(get: { keepsHistory }, set: { keepsHistoryChoice = $0 })) {
                Text("Apply from the next execution").tag(true)
                Text("Make \(dates) due").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(keepsHistory
                ? "The \(dates) \(count == 1 ? "is" : "are") marked as skipped. Everything already booked stays as it is, and nothing is proposed again."
                : "Kontor will offer to generate \(count == 1 ? "a transaction for this date" : "transactions for these dates"). Choose this only if \(count == 1 ? "it is" : "they are") really missing in your ledger.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
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
            original = plan
            hasCustomName = true
            // Screenshot mode: a changed schedule, to show the question about past dates.
            if let start = store.launchValue("start").flatMap({ Day(iso: $0) }) { draft.start = start }
            if let months = store.launchValue("interval").flatMap({ Int($0) }), months > 0 { draft.intervalMonths = months }
            switch store.launchValue("history") {
            case "due": keepsHistoryChoice = false
            case "keep": keepsHistoryChoice = true
            default: break
            }
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

    /// Recomputes what the draft's schedule does to the plan's past (off the main actor).
    private func updateImpact() async {
        guard isLoaded, let original else { return }
        let edited = draft.plan(currency: original.amount.currency)
        guard edited.intervalMonths > 0 else {
            impact = ScheduleImpact()
            return
        }
        let today = store.today
        struct Key: Hashable, Sendable {
            var old: InvestmentPlan
            var new: InvestmentPlan
            var today: Day
        }
        if let result = try? await store.compute(Key(old: original, new: edited, today: today), { ledger in
            ScheduleImpact(ledger, old: original, new: edited, today: today)
        }) {
            impact = result
        }
    }

    /// Leaves the editor for the security editor and comes back to a new plan afterwards.
    private func addSecurityFirst() {
        let prefill = PlanPrefill(
            kind: draft.kind, depotID: draft.depotID, accountID: draft.accountID,
            amount: draft.amountMinor > 0 ? Money(minor: draft.amountMinor, currency: currency) : nil, start: draft.start)
        store.dismissSheet()
        store.present(.newSecurity)
        if !isEditing { store.present(.newPlan(prefill)) }
    }

    private func save() {
        var plan = draft.plan(currency: currency)
        if plan.name.trimmingCharacters(in: .whitespaces).isEmpty { plan.name = suggestedName }
        switch mode {
        case .edit:
            if let original {
                // Decided on the plan exactly as it is saved (the displayed impact may lag a keystroke).
                let impact = ScheduleImpact(store.ledger, old: original, new: plan, today: store.today)
                if keepsHistoryChoice ?? impact.keepsHistoryByDefault { impact.keepHistory(in: &plan) }
            }
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
    ///
    /// `currency` is the currency of a stored plan's amount (the editor derives it from the account,
    /// so there it cannot differ).
    func validate(security: Security?, depot: Depot?, account: Account?, currency: CurrencyCode? = nil) -> String? {
        switch kind {
        case .purchase:
            if security == nil { return "Choose the security to buy." }
            if depot == nil { return "Choose the depot the shares go to." }
        case .deposit, .withdrawal:
            if account == nil { return "Choose the account." }
        }
        if kind == .purchase, accountID != nil, account == nil { return "Choose the account the purchase is paid from." }
        if let currency, let account, account.currency != currency { return "The amount must be in \(account.currency), the currency of the account." }
        if amountMinor <= 0 { return "Enter the amount." }
        if kind == .purchase, fees >= amountMinor { return "The fees must be smaller than the amount." }
        if intervalMonths <= 0 { return "Choose how often the plan repeats." }
        if let end, end < start { return "The end is before the first execution." }
        return nil
    }

    /// The editor's warning when a schedule change leaves past dates open.
    static func pastDatesMessage(_ impact: ScheduleImpact) -> String {
        guard let first = impact.newlyDue.first else { return "" }
        let count = impact.newlyDue.count
        let dates = count == 1
            ? "1 past date (\(Fmt.day(first, style: .medium))) has"
            : "\(Fmt.integer(count)) past dates since \(Fmt.day(first, style: .medium)) have"
        var text = "With this schedule, \(dates) no matching transaction."
        if impact.unmatched > 0 {
            text += " \(impact.unmatched == 1 ? "1 booked execution no longer falls" : "\(Fmt.integer(impact.unmatched)) booked executions no longer fall") on a scheduled day."
        }
        return text
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
