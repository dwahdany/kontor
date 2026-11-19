import SwiftUI
import KontorModel
import KontorUI

/// The Plans screen: savings plans, regular deposits and withdrawals — what is due, what they have
/// done so far, and where they could lead.
///
/// Launch state (`--state key=value`, screenshot mode):
///
/// | key | values | effect |
/// |---|---|---|
/// | `tab` | `plans` (default), `projection` | which tab is shown |
/// | `plan` | `first`, `last`, a 1-based index, a plan UUID, `none` | the selected plan (default: the first; `--route plan:<uuid>` works too) |
/// | `sheet` | `generate` | opens "Generate Due Transactions…" for all plans (also `--sheet custom:plans.generate[?plan=<uuid>]`) |
/// | `choice` | `skip`, `later` | in the generate sheet: pre-sets the last row to that action |
/// | `hover` | `on`, or a date `YYYY-MM-DD` | pins the tooltip of the chart on the visible tab |
/// | `return`, `spread` | percent, e.g. `6`, `2.5` | projection: expected annual return and ± spread |
/// | `years` | 1…50 | projection: horizon |
/// | `start` | `zero` | projection: start from nothing instead of the current portfolio value |
/// | `include` | `all`, `none` | projection: which plans contribute (default: new money only) |
public struct PlansScreen: View {
    @Environment(PortfolioStore.self) private var store
    @State private var tab = Tab.plans
    @SceneStorage("plans.tab") private var storedTab = Tab.plans
    @SceneStorage("plans.columns") private var columns: TableColumnCustomization<PlanRow>
    @State private var model = Loadable<PlansModel>()
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\PlanRow.stateRank), KeyPathComparator(\PlanRow.name)]
    @State private var didApplyLaunchState = false

    enum Tab: String, CaseIterable {
        case plans, projection

        var title: String {
            switch self {
            case .plans: "Plans"
            case .projection: "Projection"
            }
        }
    }

    public init() {}

    private var rows: [PlanRow] { model.value?.rows ?? [] }

    public var body: some View {
        let plans = store.file.plans
        let query = PlansModel.Query(today: store.today, sortOrder: sortOrder)
        Group {
            switch tab {
            case .plans: plansTab
            case .projection: ProjectionPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show the plans or a projection of where they lead")
            }
            ToolbarItem {
                Button("Generate…", systemImage: "calendar.badge.plus") { PlanActions.generate(in: store) }
                    .disabled((model.value?.dueCount ?? 0) == 0)
                    .help("Review and add the plan executions that are due (⇧⌘G)")
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
        // The list: rebuilt off the main actor whenever the document, "today" or the sort order change.
        .ledgerTask($model, id: "plans.model", variant: query) { ledger in
            PlansModel(ledger, plans: plans, query: query)
        }
        .onAppear(perform: applyLaunchState)
        .onChange(of: store.route.planID, initial: true) { _, id in
            if let id, selection != [id] {
                selection = [id]
                tab = .plans
            }
        }
        .onChange(of: tab) { _, tab in storedTab = tab }
        .onChange(of: selection) { _, ids in
            store.setFocus(ids.count == 1 ? .plan(ids.first!) : nil)
        }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in reconcileSelection(ids) }
    }

    // MARK: Plans tab

    @ViewBuilder private var plansTab: some View {
        if store.file.plans.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if let model = model.value, model.dueCount > 0 {
                    DueBanner(count: model.dueCount, names: model.dueSummary) { PlanActions.generate(in: store) }
                        .padding(.horizontal, DS.Spacing.l)
                        .padding(.top, DS.Spacing.m)
                        .padding(.bottom, DS.Spacing.s)
                }
                table
                    .frame(height: tableHeight)
                Divider()
                detail
            }
            .loadingOverlay(model.isInitialLoad)
        }
    }

    private var tableHeight: CGFloat {
        let visibleRows = CGFloat(min(max(store.file.plans.count, 3), 8))
        return 30 + visibleRows * 24 + 48
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.l) {
            EmptyState(
                "No Plans Yet", symbol: "calendar.badge.clock",
                message: "A plan repeats a transaction for you: buy a fund every month, book your regular deposit, or pay yourself out. When a date comes due, Kontor shows what it would add — you review it and confirm."
            ) {
                Button("New Savings Plan…") { store.present(.newPlan(PlanPrefill(kind: .purchase))) }
                    .keyboardShortcut(.defaultAction)
                Button("New Deposit Plan…") { store.present(.newPlan(PlanPrefill(kind: .deposit))) }
                Button("New Withdrawal Plan…") { store.present(.newPlan(PlanPrefill(kind: .withdrawal))) }
            }
            .frame(maxHeight: 320)
            HStack(spacing: DS.Spacing.xs) {
                Text("What is a savings plan?").foregroundStyle(.secondary)
                HelpButton(.savingsPlan)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name) { row in
                Label {
                    Text(row.name).lineLimit(1)
                } icon: {
                    Image(systemName: PlanText.symbol(row.kind)).foregroundStyle(.secondary)
                }
                .help(row.name)
            }
            .width(min: 130, ideal: 150)
            .customizationID("name")
            TableColumn("Status", value: \.stateRank) { PlanStateLabel(state: $0.state) }
                .width(min: 120, ideal: 140)
                .customizationID("status")
            TableColumn("Type", value: \.kindTitle) { Text($0.kindTitle).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 66)
                .customizationID("type")
            TableColumn("Security / Account", value: \.target) { row in
                Text(row.target.isEmpty ? Fmt.missing : row.target).lineLimit(1).help(row.target)
            }
            .width(min: 110, ideal: 130)
            .customizationID("target")
            TableColumn("Amount", value: \.amountMinor) { Text(Fmt.money($0.amount)).numeric() }
                .width(min: 76, ideal: 82)
                .alignment(.trailing)
                .customizationID("amount")
            TableColumn("Interval", value: \.intervalMonths) { Text(PlanText.interval($0.intervalMonths)) }
                .width(min: 64, ideal: 100)
                .customizationID("interval")
            TableColumn("Next Due", value: \.nextDueKey) { row in
                Text(row.nextDue.map { Fmt.day($0, style: .medium) } ?? Fmt.missing)
                    .numeric()
                    .foregroundStyle(row.nextDue == nil ? .secondary : .primary)
            }
            .width(min: 84, ideal: 88)
            .customizationID("next")
            TableColumn("Executions", value: \.executions) { Text(Fmt.integer($0.executions)).numeric() }
                .width(min: 50, ideal: 66)
                .alignment(.trailing)
                .customizationID("executions")
            TableColumn("Total So Far", value: \.total) { row in
                Text(Fmt.money(minor: row.total, currency: row.amount.currency)).numeric()
            }
            .width(min: 84, ideal: 92)
            .alignment(.trailing)
            .customizationID("total")
        }
        .contextMenu(forSelectionType: PlanRow.ID.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first { store.present(.editPlan(id)) }
        }
        .onCopyCommand { [NSItemProvider(object: PlanActions.tsv(selectedRows) as NSString)] }
        .onDeleteCommand { PlanActions.delete(selection, in: store) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "plan", selected: selection.count > 1 ? selection.count : 0) {
                if let model = model.value { Text(Self.cadence(model)).numeric() }
            }
        }
        .opacity(model.isRefreshing ? 0.85 : 1)
    }

    /// "Buying €500.00 and depositing €1,500.00 per month".
    static func cadence(_ model: PlansModel) -> String {
        var parts: [String] = []
        if model.monthlyPurchases > 0 { parts.append("buying \(Fmt.money(minor: model.monthlyPurchases, currency: model.currency))") }
        if model.monthlyDeposits > 0 { parts.append("depositing \(Fmt.money(minor: model.monthlyDeposits, currency: model.currency))") }
        if model.monthlyWithdrawals > 0 { parts.append("withdrawing \(Fmt.money(minor: model.monthlyWithdrawals, currency: model.currency))") }
        guard !parts.isEmpty else { return "No active plans" }
        let sentence = parts.count > 1
            ? parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
            : parts[0]
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + " per month"
    }

    private var selectedRows: [PlanRow] { rows.filter { selection.contains($0.id) } }

    @ViewBuilder private func contextMenu(_ ids: Set<UUID>) -> some View {
        let single = ids.count == 1 ? ids.first.flatMap { store.plan($0) } : nil
        Button("Edit…") { if let single { store.present(.editPlan(single.id)) } }
            .disabled(single == nil)
        Button("Generate Due Transactions…") { PlanActions.generate(single?.id, in: store) }
            .disabled(single.map { plan in rows.first { $0.id == plan.id }?.missing.isEmpty ?? true } ?? true)
        if let single {
            if PlanActions.isEnded(single, today: store.today) {
                Button("Resume") { PlanActions.resume(single.id, in: store) }
            } else {
                Button("Pause") { PlanActions.pause(single.id, in: store) }
            }
            Button("Duplicate") { PlanActions.duplicate(single.id, in: store) }
            Divider()
            if let securityID = single.securityID {
                Button("Show Security") { store.navigate(to: .security(securityID)) }
            }
            if let accountID = single.accountID {
                Button("Show Account") { store.navigate(to: .account(accountID)) }
            }
        }
        Divider()
        Button("Copy") { Pasteboard.copy(PlanActions.tsv(rows.filter { ids.contains($0.id) })) }
            .disabled(ids.isEmpty)
        Button(ids.count > 1 ? "Delete \(Fmt.integer(ids.count)) Plans" : "Delete", role: .destructive) {
            PlanActions.delete(ids, in: store)
        }
        .disabled(ids.isEmpty)
    }

    @ViewBuilder private var detail: some View {
        if selection.count == 1, let plan = store.plan(selection.first) {
            PlanDetailView(plan: plan)
        } else if selection.count > 1 {
            EmptyState("\(Fmt.integer(selection.count)) Plans Selected", symbol: "square.stack",
                       message: "Select a single plan to see its timeline, or press Delete to remove the selected plans.")
        } else {
            EmptyState("No Plan Selected", symbol: "calendar.badge.clock", message: "Select a plan to see its timeline and what it has achieved.")
        }
    }

    // MARK: Selection and launch state

    private func reconcileSelection(_ ids: [UUID]) {
        let known = Set(ids)
        let kept = selection.intersection(known)
        if kept != selection { selection = kept }
        guard selection.isEmpty, !ids.isEmpty, model.value != nil else { return }
        if let requested = store.route.planID, known.contains(requested) {
            selection = [requested]
            return
        }
        switch store.launchValue("plan") {
        case "none": break
        case "last": selection = [store.file.plans.last?.id ?? ids[0]]
        case let value?:
            if let id = UUID(uuidString: value), known.contains(id) {
                selection = [id]
            } else if let index = Int(value), store.file.plans.indices.contains(index - 1) {
                selection = [store.file.plans[index - 1].id]
            } else {
                selection = [store.file.plans.first?.id ?? ids[0]]
            }
        case nil: selection = [ids[0]]
        }
    }

    private func applyLaunchState() {
        guard !didApplyLaunchState else { return }
        didApplyLaunchState = true
        tab = store.launchValue("tab", as: Tab.self) ?? (store.route.planID == nil ? storedTab : .plans)
        if store.launchValue("sheet") == "generate" { PlanActions.generate(in: store) }
    }
}

/// The banner offered while executions are due.
private struct DueBanner: View {
    let count: Int
    let names: [String]
    let action: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(DS.Colors.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(count == 1 ? "1 plan execution is due" : "\(Fmt.integer(count)) plan executions are due")
                    .font(.headline)
                Text("\(names.joined(separator: ", ")). Review what would be added — nothing is booked without you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: DS.Spacing.m)
            Button("Review and Generate…", action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
        .cardBackground()
        .accessibilityElement(children: .contain)
    }
}

/// Status as icon + text; the icon shape differs per state so color is never the only cue.
struct PlanStateLabel: View {
    let state: PlanState

    var body: some View {
        Label {
            Text(state.title).lineLimit(1)
        } icon: {
            Image(systemName: state.symbol)
        }
        .foregroundStyle(color)
        .help(help)
    }

    private var color: Color {
        switch state {
        case .problem, .due: DS.Colors.warning
        case .upToDate: .primary
        case .scheduled, .ended: .secondary
        }
    }

    private var help: String {
        switch state {
        case .problem(let text): text
        case .due: "Executions are due and not booked yet. Use Generate… to review and add them."
        case .upToDate: "Every execution up to today is booked or skipped."
        case .scheduled: "The first execution lies in the future."
        case .ended: "The end date has passed. Resume the plan to continue it."
        }
    }
}
