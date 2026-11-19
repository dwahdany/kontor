import SwiftUI
import KontorUI

/// Everything the proposal depends on besides the document and the scope.
struct RebalancingKey: Hashable, Sendable {
    var taxonomy: UUID
    var inputs: RebalancingInputs
    var today: Day
}

/// Tab 3: how to get back to the targets — inputs, the live proposal, and "Create Transactions…".
struct RebalancingTab: View {
    let taxonomy: Taxonomy
    @Bindable var session: AllocationSession

    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<RebalancingModel>()
    @State private var selection = Set<String>()
    /// Disclosure overrides; rows without an entry show their sub-classifications.
    @State private var expansion: [String: Bool] = [:]
    @State private var onlyOrders = false
    @State private var showsAllWarnings = false

    /// The inputs of this taxonomy (cash, options, exclusions are kept per taxonomy).
    private var inputs: Binding<RebalancingInputs> {
        let id = taxonomy.id
        let session = session
        return Binding(get: { session.inputs(for: id) }, set: { session.setInputs($0, for: id) })
    }

    /// Why no proposal can be made for the window's scope, if so.
    private var scopeProblem: String? {
        switch store.scopeSelection {
        case .portfolio, .depot:
            nil
        case .account:
            "“\(store.scopeTitle)” is a single cash account. Rebalancing buys and sells securities, so it needs the whole portfolio or a depot."
        case .classification(let id, _):
            id == taxonomy.id
                ? "“\(store.scopeTitle)” is one classification of this taxonomy — there is nothing to balance it against. Rebalance the whole portfolio or a depot instead."
                : "“\(store.scopeTitle)” is a weighted slice of your positions, which cannot be bought or sold on its own. Rebalance the whole portfolio or a depot instead."
        }
    }

    var body: some View {
        let taxonomy = taxonomy
        let key = RebalancingKey(taxonomy: taxonomy.id, inputs: inputs.wrappedValue.sanitized(for: taxonomy), today: store.today)
        Group {
            if let scopeProblem, !store.isWholePortfolioScope {
                EmptyState("Rebalancing Needs a Wider Scope", symbol: "scope", message: scopeProblem) {
                    Button("Show Whole Portfolio") { store.scopeSelection = .portfolio }
                        .buttonStyle(.borderedProminent)
                }
            } else if taxonomy.root.isEmpty {
                EmptyState(
                    "No Classifications Yet", symbol: "scalemass",
                    message: "Rebalancing compares what you hold with target weights. Add classifications to “\(taxonomy.name)” and give them targets first."
                ) {
                    Button("Add Classifications") { session.tab = .edit }
                        .buttonStyle(.borderedProminent)
                }
            } else if let model = model.value, model.isScopeSupported {
                if !model.hasTargets {
                    EmptyState(
                        "No Target Weights", symbol: "scope",
                        message: "“\(taxonomy.name)” has no targets yet. Set a target weight for each classification — for example 60% Equity, 40% Bonds — and Kontor proposes the trades that get you there."
                    ) {
                        Button("Set Targets") { session.tab = .edit }
                            .buttonStyle(.borderedProminent)
                        HelpButton(.targetWeight)
                    }
                } else if !model.hasVehicles && model.valueBefore == 0 {
                    EmptyState(
                        "Nothing Assigned Yet", symbol: "tray",
                        message: "Assign your securities and accounts to the classifications of “\(taxonomy.name)” so there is something to rebalance."
                    ) {
                        Button("Assign Securities") { session.tab = .edit }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    content(model)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingOverlay(model.isInitialLoad && !taxonomy.root.isEmpty)
        // Always "as of today", whatever the window's reporting period is.
        .analysisTask($model, id: "allocation.rebalancing", interval: store.interval(for: .ytd), variant: key) { analysis in
            RebalancingModel(analysis, taxonomy: taxonomy, inputs: key.inputs, today: key.today)
        }
    }

    private func isExpanded(_ row: ProposalRow) -> Bool {
        expansion[row.id] ?? (store.launchValue("expand") == "all" || row.children.contains { $0.classificationID != nil })
    }

    private func setExpansion(_ value: Bool, rows: [ProposalRow]) -> KeyPress.Result {
        let targets = rows.filter { selection.contains($0.id) && !$0.children.isEmpty && isExpanded($0) != value }
        guard !targets.isEmpty else { return .ignored }
        for row in targets { expansion[row.id] = value }
        return .handled
    }

    private func content(_ model: RebalancingModel) -> some View {
        VStack(spacing: 0) {
            inputs(model)
            Divider()
            summary(model)
            if !model.warnings.isEmpty {
                warnings(model)
            }
            Divider()
            GeometryReader { proxy in
                // Narrow windows get tighter columns so the whole proposal stays in view.
                let compact = proxy.size.width < 900
                switch session.proposalMode {
                case .classes: classTable(model, compact: compact)
                case .orders: orderTable(model, compact: compact)
                }
            }
            .opacity(self.model.isRefreshing ? 0.6 : 1)
            Divider()
            actionBar(model)
        }
    }

    // MARK: Inputs

    private func inputs(_ model: RebalancingModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.l) {
                cashInput(model)
                toggles(model)
                Spacer(minLength: DS.Spacing.s)
                modePicker
            }
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.l) {
                    cashInput(model)
                    Spacer(minLength: DS.Spacing.s)
                    modePicker
                }
                HStack(spacing: DS.Spacing.l) { toggles(model) }
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
    }

    private func cashInput(_ model: RebalancingModel) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Picker("Direction", selection: inputs.direction) {
                ForEach(RebalancingInputs.Direction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Invest fresh money, or take money out of the portfolio. Leave the amount empty to rebalance in place.")
            MoneyField(inputs.wrappedValue.direction == .invest ? "Cash to invest" : "Cash to withdraw", minor: inputs.amount, currency: model.currency)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
        }
    }

    @ViewBuilder
    private func toggles(_ model: RebalancingModel) -> some View {
        let direction = inputs.wrappedValue.direction
        Toggle(direction == .invest ? "Buy only" : "Sell only", isOn: inputs.buyOnly)
            .help(direction == .invest
                ? "Never sell: the new money goes to the most underweight classifications first."
                : "Never buy: the money is taken from the most overweight classifications first.")
        Toggle("Whole shares", isOn: inputs.wholeShares)
            .help("Round every order down to whole shares at the latest price. Purchases never exceed the money that is available; what cannot be placed stays as leftover cash.")
        // Only exclusions that exist in this taxonomy count.
        if model.exclusionCount > 0 {
            Button("Include All (\(model.exclusionCount) excluded)") {
                inputs.wrappedValue.excludedClassifications = []
                inputs.wrappedValue.excludedVehicles = []
            }
            .buttonStyle(.link)
            .help("Clear all exclusions")
        }
    }

    private var modePicker: some View {
        Picker("Proposal", selection: $session.proposalMode) {
            ForEach(AllocationSession.ProposalMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: Summary

    private func summary(_ model: RebalancingModel) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.xl) {
            figure("Buy", Fmt.money(minor: model.securityBuys, currency: model.currency), help: "Purchases of securities")
            figure("Sell", Fmt.money(minor: model.securitySells, currency: model.currency), help: "Sales of securities")
            if model.hasAccountOrders {
                figure("Cash accounts", Fmt.money(minor: model.accountChange, currency: model.currency, signed: true),
                       help: "Cash accounts that are part of this taxonomy should hold this much more (+) or less (−). The purchases are paid from them and the sales credited to them; no extra transaction is needed.")
            }
            if model.unraisedCash > 0 {
                figure("Shortfall", Fmt.money(minor: model.unraisedCash, currency: model.currency),
                       help: "This much of the requested amount cannot be raised — there is not enough to sell.")
            } else if model.residualCash < 0 {
                figure("Extra from cash", Fmt.money(minor: -model.residualCash, currency: model.currency),
                       help: "Sales were rounded down to whole shares (or there was too little to sell), so the cash accounts provide this much more than planned.")
            } else {
                figure("Leftover cash", Fmt.money(minor: model.residualCash, currency: model.currency),
                       help: "Money that is not placed — because of whole-share rounding, or because nothing suitable can be bought. It stays on the cash accounts.")
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HelpLabel("Furthest from target", topic: .rebalancing)
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                HStack(spacing: DS.Spacing.xs) {
                    Text(Fmt.percentagePoints(model.driftBefore).replacingOccurrences(of: "+", with: ""))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("becomes")
                    Text(Fmt.percentagePoints(model.driftAfter).replacingOccurrences(of: "+", with: ""))
                }
                .font(.kontorValue)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            if model.orderCount == 0 {
                Text(idleMessage(model))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
        .opacity(self.model.isRefreshing ? 0.6 : 1)
    }

    private func idleMessage(_ model: RebalancingModel) -> String {
        if inputs.wrappedValue.buyOnly, model.cash == 0 {
            return "Nothing to do: without new cash and without sales there is nothing to trade. Enter an amount, or turn off “Buy only”."
        }
        return "No orders needed — the allocation is as close to its targets as these settings allow."
    }

    private func figure(_ label: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(label)
                .font(.kontorCaption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.kontorValue)
                .lineLimit(1)
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }

    private func warnings(_ model: RebalancingModel) -> some View {
        let limit = 2
        let shown = showsAllWarnings ? model.warnings : Array(model.warnings.prefix(limit))
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(shown) { warning in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    Image(systemName: warning.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(warning.level == .warning ? AnyShapeStyle(DS.Colors.warning) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                        .accessibilityLabel(warning.level == .warning ? "Warning" : "Note")
                    Text(warning.text)
                        .lineLimit(2)
                        .help(warning.text)
                }
            }
            if model.warnings.count > limit {
                Button(showsAllWarnings ? "Show Fewer" : "Show \(model.warnings.count - limit) More…") { showsAllWarnings.toggle() }
                    .buttonStyle(.link)
                    .padding(.leading, 16 + DS.Spacing.s)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.bottom, DS.Spacing.m)
    }

    // MARK: Tables

    private func classTable(_ model: RebalancingModel, compact: Bool) -> some View {
        let visible = model.classRows.visibleRows(isExpanded: isExpanded)
        return Table(visible, selection: $selection) {
            TableColumn("Classification") { row in
                DisclosureCell(depth: row.depth, hasChildren: !row.children.isEmpty, isExpanded: isExpanded(row)) {
                    expansion[row.id] = !isExpanded(row)
                } content: {
                    includeToggle(row)
                    if let color = row.color {
                        ColorDot(color: color, dashed: row.isUnassigned)
                            .opacity(row.isExcluded ? 0.5 : 1)
                        Text(row.name)
                            .fontWeight(row.depth == 0 ? .medium : .regular)
                            .foregroundStyle(row.isExcluded ? .secondary : .primary)
                            .lineLimit(1)
                    } else {
                        Image(systemName: row.vehicle?.isSecurity == true ? "chart.line.uptrend.xyaxis" : "banknote")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                        Text(row.name)
                            .foregroundStyle(row.isExcluded ? .tertiary : .secondary)
                            .lineLimit(1)
                    }
                    if let badge = row.badge {
                        ExcludedBadge(text: badge)
                    }
                }
            }
            .width(min: 140, ideal: compact ? 150 : 280)
            TableColumn("Current") { row in
                Text(Fmt.money(minor: row.value, currency: model.currency))
                    .numericCell()
                    .foregroundStyle(row.vehicle != nil || row.isUnassigned ? .secondary : .primary)
            }
            .width(min: 92, ideal: compact ? 96 : 140, max: 190)
            .alignment(.trailing)
            TableColumn("Share") { row in
                if !row.isUnassigned {
                    Text(Fmt.percent(row.share)).numericCell().foregroundStyle(.secondary)
                }
            }
            .width(min: 56, ideal: compact ? 60 : 76, max: 96)
            .alignment(.trailing)
            TableColumn("Target") { row in
                if row.classificationID != nil {
                    Text(Fmt.percent(row.targetShare))
                        .numericCell()
                        .foregroundStyle(row.targetShare == nil ? .tertiary : .primary)
                        .help(row.targetShare == nil
                            ? "No target here: this classification is left untouched"
                            : "The share this classification should have, given what is left untouched next to it")
                }
            }
            .width(min: 56, ideal: compact ? 60 : 76, max: 96)
            .alignment(.trailing)
            TableColumn("Buy / Sell") { row in
                if !row.isUnassigned {
                    OrderAmountText(amount: row.amount, currency: model.currency)
                }
            }
            .width(min: 96, ideal: compact ? 100 : 140, max: 190)
            .alignment(.trailing)
            TableColumn("After") { row in
                if let value = row.resultingValue {
                    Text(Fmt.money(minor: value, currency: model.currency))
                        .numericCell()
                        .foregroundStyle(row.vehicle != nil ? .secondary : .primary)
                }
            }
            .width(min: 92, ideal: compact ? 96 : 140, max: 190)
            .alignment(.trailing)
            TableColumn("Share After") { row in
                if row.classificationID != nil {
                    Text(Fmt.percent(row.resultingShare)).numericCell()
                }
            }
            .width(min: 62, ideal: compact ? 66 : 84, max: 100)
            .alignment(.trailing)
        }
        .onKeyPress(.rightArrow) { setExpansion(true, rows: visible) }
        .onKeyPress(.leftArrow) { setExpansion(false, rows: visible) }
        .contextMenu(forSelectionType: String.self) { _ in
            Button("Copy Proposal") { Pasteboard.copy(model.tsv(.classes)) }
        }
        .onCopyCommand { [NSItemProvider(object: model.tsv(.classes) as NSString)] }
    }

    @ViewBuilder
    private func includeToggle(_ row: ProposalRow) -> some View {
        if let id = row.classificationID {
            let taxonomy = taxonomy
            // Shows what really happens: unchecked whenever the classification is left untouched,
            // also below an unchecked parent.
            Toggle("Include \(row.name)", isOn: Binding(
                get: { !row.isExcluded },
                set: { inputs.wrappedValue.setIncluded($0, classification: id, in: taxonomy) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!row.canExclude)
                .help(row.canExclude
                    ? "Uncheck to leave this classification and everything below it untouched: nothing in it is bought or sold"
                    : row.isExcluded
                        ? "Left untouched together with the classification above"
                        : "Only classifications with a target weight take part in rebalancing")
        } else if let vehicle = row.vehicle {
            vehicleToggle(vehicle, name: row.name)
        }
    }

    private func vehicleToggle(_ vehicle: AllocationVehicle, name: String) -> some View {
        Toggle("Include \(name)", isOn: Binding(
            get: { !inputs.wrappedValue.excludedVehicles.contains(vehicle) },
            set: { included in
                if included { inputs.wrappedValue.excludedVehicles.remove(vehicle) } else { inputs.wrappedValue.excludedVehicles.insert(vehicle) }
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Uncheck to keep this position as it is: it is neither bought nor sold, but still counts towards its classification")
    }

    private func orderTable(_ model: RebalancingModel, compact: Bool) -> some View {
        let rows = onlyOrders ? model.vehicleRows.filter { ($0.vehicle.isSecurity && $0.amount != 0) || $0.isExcluded } : model.vehicleRows
        return Table(rows, selection: $selection) {
            TableColumn("") { row in
                vehicleToggle(row.vehicle, name: row.name)
            }
            .width(22)
            TableColumn("Security / Account") { row in
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: row.vehicle.isSecurity ? "chart.line.uptrend.xyaxis" : "banknote")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Text(row.name).lineLimit(1)
                    if row.isExcluded {
                        ExcludedBadge(text: "excluded")
                    }
                }
                .opacity(row.isExcluded ? 0.55 : 1)
                .help(row.classes)
            }
            .width(min: 140, ideal: compact ? 150 : 240)
            if !compact {
                TableColumn("Held") { row in
                    if let shares = row.sharesHeld {
                        Text(Fmt.shares(shares)).numericCell().foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 124, max: 160)
                .alignment(.trailing)
            }
            TableColumn("Current") { row in
                Text(Fmt.money(minor: row.value, currency: model.currency)).numericCell()
            }
            .width(min: 92, ideal: compact ? 96 : 140, max: 190)
            .alignment(.trailing)
            if !compact {
                TableColumn("Weight") { row in
                    Text(Fmt.percent(row.share)).numericCell().foregroundStyle(.secondary)
                }
                .width(min: 62, ideal: 76, max: 96)
                .alignment(.trailing)
            }
            TableColumn("Order") { row in
                if row.amount != 0 {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(row.amount > 0 ? (row.vehicle.isSecurity ? "Buy" : "Add") : (row.vehicle.isSecurity ? "Sell" : "Take"))
                            .foregroundStyle(.secondary)
                        if let shares = row.orderShares {
                            Text(Fmt.shares(Shares(raw: abs(shares.raw)))).numeric().fontWeight(.medium)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .help(row.price.map { "At \(Fmt.money(minor: Int64($0.rounded()), currency: model.currency)) per share" } ?? "")
                }
            }
            .width(min: 66, ideal: compact ? 70 : 104, max: 150)
            .alignment(.trailing)
            TableColumn("Amount") { row in
                OrderAmountText(amount: row.amount, currency: model.currency)
                    .help(row.vehicle.isSecurity || row.amount == 0 ? "" : "What the transactions add to or take from this account — no extra transaction is needed")
            }
            .width(min: 96, ideal: compact ? 100 : 140, max: 190)
            .alignment(.trailing)
            TableColumn("After") { row in
                Text(Fmt.money(minor: row.resultingValue, currency: model.currency)).numericCell()
            }
            .width(min: 92, ideal: compact ? 96 : 140, max: 190)
            .alignment(.trailing)
            TableColumn("Weight After") { row in
                Text(Fmt.percent(row.resultingShare)).numericCell()
            }
            .width(min: 66, ideal: compact ? 70 : 90, max: 110)
            .alignment(.trailing)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let vehicle = ids.first.flatMap(AllocationVehicle.init(token:)) {
                Button(vehicle.isSecurity ? "Show Security" : "Show Account") {
                    switch vehicle {
                    case .security(let id): store.navigate(to: .security(id))
                    case .account(let id): store.navigate(to: .account(id))
                    }
                }
                Divider()
            }
            Button("Copy Proposal") { Pasteboard.copy(model.tsv(.orders)) }
        }
        .onCopyCommand { [NSItemProvider(object: model.tsv(.orders) as NSString)] }
    }

    // MARK: Action bar

    private func actionBar(_ model: RebalancingModel) -> some View {
        let bookable = model.bookableDrafts.count
        return HStack(spacing: DS.Spacing.m) {
            Text(statusLine(model))
                .font(.callout)
                .foregroundStyle(.secondary)
                .numeric()
                .lineLimit(1)
            if session.proposalMode == .orders {
                Toggle("Only orders", isOn: $onlyOrders)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            Spacer(minLength: DS.Spacing.s)
            HelpButton(.rebalancing)
            Button("Create Transactions…") { review() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(bookable == 0)
                .help(bookable == 0
                    ? "There are no orders to book"
                    : "Review \(bookable) draft \(bookable == 1 ? "transaction" : "transactions") before adding them (⌘↩)")
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(.bar)
    }

    private func statusLine(_ model: RebalancingModel) -> String {
        let orders = model.orderCount
        var text = orders == 0 ? "No orders" : "\(orders) \(orders == 1 ? "order" : "orders")"
        text += " · as of \(Fmt.day(model.day, style: .medium)) · \(store.scopeTitle)"
        // The base of every share on this tab (the same one the Allocation tab uses).
        if model.unassignedValue != 0 {
            text += " · shares of the classified \(Fmt.money(minor: model.valueBefore, currency: model.currency)), \(Fmt.money(minor: model.unassignedValue, currency: model.currency)) unassigned"
        }
        return text
    }

    private func review() {
        var payload = inputs.wrappedValue.sanitized(for: taxonomy).payload
        payload["taxonomy"] = taxonomy.id.uuidString
        store.present(.custom(id: RebalancingReviewSheet.requestID, payload: payload))
    }
}

extension ProposalRow: TreeRow {}

/// "excluded" / "not in scope" next to a row that is left untouched.
struct ExcludedBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

extension View {
    /// A number in a table cell: tabular digits, one line, and — before it would be cut off with
    /// an ellipsis — slightly smaller type. Money and percentages must never lose digits.
    func numericCell() -> some View {
        numeric()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// "+€500.00" to buy, "−€300.00" to sell, "–" for nothing. An order is not a gain or a loss, so it
/// carries a sign and weight instead of gain/loss colors.
struct OrderAmountText: View {
    let amount: Int64
    let currency: CurrencyCode

    var body: some View {
        if amount == 0 {
            Text(Fmt.missing)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("No order")
        } else {
            Text(Fmt.money(minor: amount, currency: currency, signed: true))
                .numericCell()
                .fontWeight(.medium)
                .accessibilityLabel("\(amount > 0 ? "Buy" : "Sell") \(Fmt.money(minor: abs(amount), currency: currency))")
        }
    }
}

// MARK: - Review sheet

/// The confirmation list behind "Create Transactions…": every draft can be unchecked, the date can
/// be changed, and everything is added in one undoable step.
/// Request: `.custom(id: "allocation.rebalance-review", payload: RebalancingInputs.payload + ["taxonomy": <uuid>])`.
struct RebalancingReviewSheet: View {
    static let requestID = "allocation.rebalance-review"

    let payload: [String: String]

    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<RebalancingModel>()
    /// Draft ids are stable across recomputations (see `DraftTransaction.id`), so what the user
    /// unchecked stays unchecked when quotes or the document change while the sheet is open.
    @State private var skipped = Set<String>()
    @State private var date: Day?
    @State private var includesCash = false

    private var taxonomy: Taxonomy? {
        let id = payload["taxonomy"].flatMap(UUID.init(uuidString:))
        return store.file.taxonomies.first { $0.id == id } ?? (id == nil ? store.file.taxonomies.first : nil)
    }

    var body: some View {
        let inputs = RebalancingInputs(payload: payload)
        let taxonomy = taxonomy
        let key = RebalancingKey(taxonomy: taxonomy?.id ?? UUID(), inputs: taxonomy.map(inputs.sanitized(for:)) ?? inputs, today: store.today)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let model = model.value {
                if model.drafts.isEmpty && model.cashDraft == nil {
                    EmptyState("No Transactions to Create", symbol: "checkmark.circle", message: "The proposal contains no security orders.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(model)
                }
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 540)
        .loadingOverlay(model.isInitialLoad)
        .analysisTask($model, id: "allocation.rebalancing", interval: store.interval(for: .ytd), variant: key) { analysis in
            guard let taxonomy else { throw CancellationError() }
            return RebalancingModel(analysis, taxonomy: taxonomy, inputs: key.inputs, today: key.today)
        }
        .onAppear {
            if taxonomy == nil { store.dismissSheet() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Review Transactions")
                    .font(.title3.weight(.semibold))
                Text("These drafts come from the rebalancing proposal for “\(taxonomy?.name ?? "")”. Uncheck what you do not want; fees and exact prices can be edited afterwards in Transactions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Spacing.l)
            VStack(alignment: .trailing, spacing: DS.Spacing.xxs) {
                Text("Date")
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                DayField("Date", day: Binding(get: { date ?? store.today }, set: { date = $0 }))
                    .labelsHidden()
                    .fixedSize()
            }
        }
        .padding(DS.Spacing.xl)
    }

    /// A lazy stack in a scroll view, not a `List`: nothing here is selectable, and a `List` with a
    /// few hundred drafts trips AppKit's row-height estimation ("reentrant operation in its
    /// NSTableView delegate").
    private func list(_ model: RebalancingModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                drafts(model)
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.vertical, DS.Spacing.s)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, DS.Spacing.l)
            .padding(.bottom, DS.Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func drafts(_ model: RebalancingModel) -> some View {
            ForEach(model.drafts) { draft in
                HStack(spacing: DS.Spacing.m) {
                    Toggle("Include", isOn: Binding(
                        get: { draft.transaction != nil && !skipped.contains(draft.id) },
                        set: { if $0 { skipped.remove(draft.id) } else { skipped.insert(draft.id) } }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(draft.transaction == nil)
                    Label(draft.kind.title, systemImage: draft.kind.symbol)
                        .labelStyle(.titleAndIcon)
                        .frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(draft.securityName)
                            .lineLimit(1)
                        if let problem = draft.problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(DS.Colors.warning)
                        } else {
                            Text("\(draft.depotName) · \(draft.kind == .buy ? "paid from" : "credited to") \(draft.accountName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: DS.Spacing.s)
                    if let shares = draft.shares {
                        Text("\(Fmt.shares(shares)) sh.")
                            .numeric()
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .trailing)
                    }
                    Text(Fmt.money(draft.amount))
                        .numeric()
                        .fontWeight(.medium)
                        .frame(width: 112, alignment: .trailing)
                }
                .padding(.vertical, DS.Spacing.xs)
                .opacity(draft.transaction == nil || skipped.contains(draft.id) ? 0.55 : 1)
                .accessibilityElement(children: .combine)
                Divider()
            }
            if let cash = model.cashDraft {
                sectionHeader("Cash")
                Group {
                    Toggle(isOn: $includesCash) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(cash.kind == .deposit
                                ? "Also record a deposit of \(Fmt.money(cash.amount)) into \(cash.accountName)"
                                : "Also record a withdrawal of \(Fmt.money(cash.amount)) from \(cash.accountName)")
                            Text(cash.kind == .deposit
                                ? "Leave this off if the money is already on the account."
                                : "Leave this off if you book the withdrawal yourself.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if !model.accounts.isEmpty {
                sectionHeader("Cash accounts after these transactions")
                Group {
                    ForEach(model.accounts) { account in
                        let balance = account.projected(skipping: skipped, includesCash: includesCash)
                        HStack(spacing: DS.Spacing.m) {
                            Label(account.name, systemImage: "banknote")
                                .foregroundStyle(.secondary)
                            if balance < 0 {
                                Label("Overdrawn — \(overdraftAdvice(model))", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(DS.Colors.warning)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: DS.Spacing.s)
                            Text(Fmt.money(minor: account.balance, currency: account.currency))
                                .numeric()
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("becomes")
                            Text(Fmt.money(minor: balance, currency: account.currency))
                                .numeric()
                                .fontWeight(.medium)
                                .foregroundStyle(balance < 0 ? AnyShapeStyle(DS.Colors.warning) : AnyShapeStyle(.primary))
                                .frame(minWidth: 112, alignment: .trailing)
                        }
                        .padding(.vertical, DS.Spacing.xs)
                        .accessibilityElement(children: .combine)
                        Divider()
                    }
                }
            }
    }

    private func overdraftAdvice(_ model: RebalancingModel) -> String {
        if let cash = model.cashDraft, cash.kind == .deposit, !includesCash { return "record the deposit, or transfer money first" }
        if model.cashDraft?.kind == .withdrawal, includesCash { return "transfer money here first, or withdraw less" }
        return "transfer money here first"
    }

    private var selected: [Transaction] {
        guard let model = model.value else { return [] }
        var result: [Transaction] = []
        // The deposit comes first so the purchases are covered; a withdrawal follows the sales.
        var cash = includesCash ? model.cashDraft?.transaction : nil
        if let date { cash?.date = date }
        if let cash, cash.kind == .deposit { result.append(cash) }
        result += model.drafts.compactMap { draft in
            guard var transaction = draft.transaction, !skipped.contains(draft.id) else { return nil }
            if let date { transaction.date = date }
            return transaction
        }
        if let cash, cash.kind == .withdrawal { result.append(cash) }
        return result
    }

    private var footer: some View {
        let transactions = selected
        let buys = transactions.filter { $0.kind == .buy }
        let sells = transactions.filter { $0.kind == .sell }
        return HStack(spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(buys.count) \(buys.count == 1 ? "purchase" : "purchases") · \(sells.count) \(sells.count == 1 ? "sale" : "sales")"
                    + (transactions.count > buys.count + sells.count ? " · 1 cash transaction" : ""))
                Text("Added in one step — undo with ⌘Z.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .numeric()
            Spacer()
            Button("Cancel", role: .cancel) { store.dismissSheet() }
                .keyboardShortcut(.cancelAction)
            Button(transactions.isEmpty ? "Add Transactions" : "Add \(transactions.count) \(transactions.count == 1 ? "Transaction" : "Transactions")") {
                store.addTransactions(transactions, actionName: "Apply Rebalancing")
                store.toast("Added \(transactions.count) \(transactions.count == 1 ? "transaction" : "transactions")", message: "Undo with ⌘Z", style: .success)
                store.dismissSheet()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(transactions.isEmpty)
        }
        .padding(DS.Spacing.xl)
    }
}
