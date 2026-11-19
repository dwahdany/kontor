import SwiftUI
import KontorUI

/// Tab 1: where the money is — the classification tree with actual vs. target, and a visual.
struct AllocationTab: View {
    let taxonomy: Taxonomy
    @Bindable var session: AllocationSession

    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<AllocationModel>()
    @State private var returns = Loadable<ClassificationReturns>()
    @State private var selection = Set<String>()
    /// Disclosure overrides; rows without an entry follow `defaultExpansion`.
    @State private var expansion: [String: Bool] = [:]

    var body: some View {
        let taxonomy = taxonomy
        let key = store.allocationKey(for: taxonomy)
        Group {
            if taxonomy.root.isEmpty {
                EmptyState(
                    "No Classifications Yet", symbol: "square.stack.3d.up",
                    message: "“\(taxonomy.name)” is empty. Add classifications such as Equity or Bonds, then assign your securities and accounts to them."
                ) {
                    Button("Add Classifications") { session.tab = .edit }
                        .buttonStyle(.borderedProminent)
                }
            } else if let model = model.value {
                if model.hasValue {
                    content(model)
                } else {
                    EmptyState(
                        "Nothing to Allocate Yet", symbol: "chart.pie",
                        message: store.file.transactions.isEmpty
                            ? "Record a purchase or a deposit, or import your history — the allocation of your holdings appears here."
                            : "There is no value in \(store.scopeTitle) on \(Fmt.day(model.day, style: .medium))."
                    ) {
                        Button("New Transaction…") { store.present(.newTransaction) }
                            .buttonStyle(.borderedProminent)
                        Button("Import…") { store.present(.importFile(nil)) }
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingOverlay(model.isInitialLoad && !taxonomy.root.isEmpty)
        .analysisTask($model, id: "allocation.model", variant: key) { analysis in
            AllocationModel(analysis, taxonomy: taxonomy, scopeRoot: key.scopeRoot)
        }
        .analysisTask($returns, id: "allocation.returns", variant: taxonomy.id) { analysis in
            ClassificationReturns(analysis, taxonomy: taxonomy)
        }
        .onChange(of: store.route.classificationID, initial: true) { _, id in reveal(id) }
        .onChange(of: selection) { _, ids in
            if ids.count == 1, let id = ids.first.flatMap(UUID.init(uuidString:)), taxonomy.contains(id) {
                session.setFocus(.classification(taxonomy: taxonomy.id, id: id), in: store)
            } else {
                session.setFocus(.taxonomy(taxonomy.id), in: store)
            }
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ model: AllocationModel) -> some View {
        GeometryReader { proxy in
            if proxy.size.width >= 1_040 {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        scopeBanner(model)
                        table(model, compact: false)
                    }
                    Divider()
                    ScrollView {
                        VStack(spacing: DS.Spacing.l) {
                            visualCard(model, height: 280)
                            summaryCard(model)
                            if model.hasTargets, session.visual != .bars {
                                Card("Target vs. Actual", symbol: "chart.bar.xaxis") {
                                    bars(model, scrolls: false)
                                }
                            }
                        }
                        .padding(DS.Spacing.l)
                    }
                    .frame(width: 400)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: DS.Spacing.m) {
                        visualCard(model, height: 190)
                        summaryCard(model)
                            .frame(width: 250)
                    }
                    .padding(DS.Spacing.m)
                    Divider()
                    scopeBanner(model)
                    table(model, compact: true)
                }
            }
        }
    }

    /// Shown while the scope is a classification of this very taxonomy: the whole-portfolio targets
    /// do not apply to such a scope, so targets are relative to that classification.
    @ViewBuilder
    private func scopeBanner(_ model: AllocationModel) -> some View {
        if let name = model.scopeRootName {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "scope")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Showing only “\(name)”. Targets are relative to it; the rest of “\(taxonomy.name)” is outside the scope.")
                    .lineLimit(2)
                Spacer(minLength: DS.Spacing.s)
                Button("Show Whole Portfolio") { store.scopeSelection = .portfolio }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
            .background(.quaternary.opacity(0.5))
            Divider()
        }
    }

    // MARK: Visual

    private func visualCard(_ model: AllocationModel, height: CGFloat) -> some View {
        Card(session.visual.title, symbol: session.visual.symbol) {
            Group {
                switch session.visual {
                case .donut:
                    DonutChart(model.slices, format: .money(model.currency), centerTitle: "Total", title: "\(taxonomy.name), top level")
                        .selection(chartSelection) { select(chart: $0) }
                        .loading(self.model.isRefreshing)
                        .emptyMessage("Nothing is allocated yet")
                        .pinnedHover(pinnedChartID(model))
                case .sunburst:
                    SunburstChart(model.sunburst, format: .money(model.currency), centerTitle: "Total", title: "\(taxonomy.name), all levels")
                        .levels(3)
                        .selection(chartSelection) { select(chart: $0) }
                        .loading(self.model.isRefreshing)
                        .emptyMessage("Nothing is allocated yet")
                        .pinnedHover(pinnedChartID(model))
                case .treemap:
                    TreemapChart(model.treemap, format: .money(model.currency), title: "\(taxonomy.name), holdings by classification")
                        .selection(chartSelection) { select(chart: $0) }
                        .loading(self.model.isRefreshing)
                        .emptyMessage("Nothing is allocated yet")
                        .pinnedHover(pinnedChartID(model))
                case .bars:
                    bars(model, scrolls: true)
                }
            }
            .frame(height: height)
        } accessory: {
            Picker("Visual", selection: $session.visual) {
                ForEach(AllocationSession.Visual.allCases) { visual in
                    Image(systemName: visual.symbol)
                        .accessibilityLabel(visual.title)
                        .help(visual.title)
                        .tag(visual)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func bars(_ model: AllocationModel, scrolls: Bool) -> some View {
        if model.hasTargets {
            let grid = Grid(alignment: .leading, horizontalSpacing: DS.Spacing.s, verticalSpacing: DS.Spacing.s) {
                ForEach(model.bars) { bar in
                    GridRow {
                        Text(bar.name)
                            .font(bar.depth == 0 ? .callout.weight(.medium) : .callout)
                            .foregroundStyle(bar.depth == 0 ? .primary : .secondary)
                            .lineLimit(1)
                            .padding(.leading, CGFloat(bar.depth) * DS.Spacing.m)
                            .frame(maxWidth: 130, alignment: .leading)
                        TargetActualBar(actual: bar.actual, target: bar.target, maximum: model.barMaximum, color: bar.color, tolerance: Self.tolerance)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .opacity(self.model.isRefreshing ? 0.6 : 1)
            if scrolls {
                ScrollView { grid.padding(.trailing, DS.Spacing.xs) }
            } else {
                grid
            }
        } else {
            VStack(spacing: DS.Spacing.s) {
                Text("No target weights yet")
                    .font(.headline)
                Text("Set a target for each classification to compare it with what you actually hold.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Set Targets") { session.tab = .edit }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Deviation (in share points) that is called out as "off target".
    static let tolerance = 0.05

    private var chartSelection: String? {
        selection.count == 1 ? selection.first : nil
    }

    private func select(chart id: String?) {
        guard let id else {
            selection = []
            return
        }
        // Chart ids: classification UUID, "<classification>/<vehicle uuid>", "chart.unassigned".
        if id == "chart.unassigned" {
            selection = [AllocationRow.unassignedID]
        } else if let classification = id.split(separator: "/").first.map(String.init), UUID(uuidString: classification) != nil {
            selection = [classification]
            expandAncestors(of: classification)
        }
    }

    private func pinnedChartID(_ model: AllocationModel) -> String? {
        guard let name = store.launchValue("hover") else { return nil }
        return model.rows.flatMap(\.flattened).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    // MARK: Summary

    private func summaryCard(_ model: AllocationModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(store.isWholePortfolioScope ? "Portfolio Value" : store.scopeTitle)
                        .font(.kontorCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(Fmt.money(minor: model.totalValue, currency: model.currency))
                        .font(.kontorHero)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("as of \(Fmt.day(model.day, style: .medium))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .numeric()
                }
                Divider()
                KeyValueRow("Classified") {
                    Text(Fmt.money(minor: model.classifiedValue, currency: model.currency)).numeric()
                }
                KeyValueRow("Unassigned") {
                    HStack(spacing: DS.Spacing.xs) {
                        if model.unassignedValue != 0 {
                            Text(Fmt.percent(model.unassignedShare, decimals: 1))
                                .foregroundStyle(.secondary)
                        }
                        Text(Fmt.money(minor: model.unassignedValue, currency: model.currency))
                    }
                    .numeric()
                }
                if let drift = model.largestDrift {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text("Furthest from target")
                            .foregroundStyle(.secondary)
                        HStack(spacing: DS.Spacing.s) {
                            Text(drift.name).lineLimit(1)
                            Spacer(minLength: 0)
                            DriftText(delta: drift.deltaShare)
                                .fixedSize()
                        }
                    }
                } else {
                    HStack(spacing: DS.Spacing.xs) {
                        HelpLabel("No target weights", topic: .targetWeight)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Targets") { session.tab = .edit }
                            .buttonStyle(.link)
                    }
                }
                if model.unassignedCount > 0 {
                    notice(
                        "\(model.unassignedCount) \(model.unassignedCount == 1 ? "position is" : "positions are") not fully assigned.",
                        action: "Assign…") { session.tab = .edit }
                }
                if !model.overAssigned.isEmpty {
                    notice(
                        "\(model.overAssigned.prefix(2).joined(separator: ", "))\(model.overAssigned.count > 2 ? " and \(model.overAssigned.count - 2) more" : "") assigned over 100% — scaled down.",
                        action: "Fix…") { session.tab = .edit }
                }
            }
            .font(.callout)
        }
    }

    private func notice(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(DS.Colors.warning)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.xs)
            Button(action, action: perform)
                .buttonStyle(.link)
        }
        .font(.caption)
    }

    // MARK: Table

    private func table(_ model: AllocationModel, compact: Bool) -> some View {
        let returns = returns.value
        let index = Dictionary(model.rows.flatMap(\.flattened).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = model.rows.visibleRows(isExpanded: isExpanded)
        return Table(visible, selection: $selection) {
            TableColumn("Classification") { row in
                DisclosureCell(depth: row.depth, hasChildren: !row.children.isEmpty, isExpanded: isExpanded(row)) {
                    expansion[row.id] = !isExpanded(row)
                } content: {
                    AllocationNameCell(row: row)
                }
            }
            .width(min: 160, ideal: compact ? 220 : 260)
            TableColumn("Value") { row in
                Text(Fmt.money(minor: row.value, currency: model.currency))
                    .numericCell()
                    .foregroundStyle(row.isItem ? .secondary : .primary)
            }
            .width(min: 100, ideal: compact ? 110 : 140, max: 190)
            .alignment(.trailing)
            TableColumn("Actual") { row in
                if row.share != nil || model.classifiedValue <= 0 {
                    Text(Fmt.percent(row.share))
                        .numericCell()
                        .foregroundStyle(row.isItem ? .secondary : .primary)
                } else {
                    // The unassigned bucket is outside the base of the shares.
                    Text(Fmt.missing)
                        .foregroundStyle(.tertiary)
                        .help("Not classified: shares and targets refer to the classified value")
                }
            }
            .width(min: 62, ideal: 76, max: 96)
            .alignment(.trailing)
            TableColumn("Target") { row in
                if row.classificationID != nil {
                    Text(Fmt.percent(row.targetShare))
                        .numericCell()
                        .foregroundStyle(row.targetShare == nil ? .tertiary : .primary)
                }
            }
            .width(min: 62, ideal: 76, max: 96)
            .alignment(.trailing)
            TableColumn("Δ Target") { row in
                if let delta = row.deltaShare {
                    DriftText(delta: delta)
                }
            }
            .width(min: 88, ideal: 92, max: 120)
            .alignment(.trailing)
            TableColumn("Δ Value") { row in
                if let delta = row.deltaValue {
                    Text(Fmt.money(minor: delta, currency: model.currency, signed: true))
                        .numericCell()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: compact ? 110 : 140, max: 190)
            .alignment(.trailing)
            TableColumn("Return") { row in
                if let id = row.classificationID {
                    if let value = returns?.ttwror[id] {
                        GainText(percent: value)
                    } else if returns?.isAvailable == false {
                        Text(Fmt.missing)
                            .foregroundStyle(.tertiary)
                            .help("Returns per classification are measured on the whole portfolio. Switch the scope to Whole Portfolio to see them.")
                    }
                }
            }
            .width(min: 66, ideal: 72, max: 100)
            .alignment(.trailing)
        }
        .opacity(self.model.isRefreshing ? 0.6 : 1)
        .onKeyPress(.rightArrow) { setExpansion(true, index: index) }
        .onKeyPress(.leftArrow) { setExpansion(false, index: index) }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids.compactMap { index[$0] }, model: model)
        } primaryAction: { ids in
            guard let row = ids.first.flatMap({ index[$0] }) else { return }
            primaryAction(row)
        }
        .onCopyCommand { [NSItemProvider(object: model.tsv(only: selection, returns: returns?.ttwror ?? [:]) as NSString)] }
        .onDeleteCommand { unassign(selection.compactMap { index[$0] }) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: model.classificationCount, noun: "classification", selected: selection.count) {
                HStack(spacing: DS.Spacing.m) {
                    if model.unassignedValue != 0 {
                        Text("Actual and Target: share of the classified value")
                            .help("\(Fmt.money(minor: model.unassignedValue, currency: model.currency)) is not assigned in this taxonomy. It is listed as “Unassigned” and is outside the base of the shares — the same base the Rebalancing tab uses.")
                    }
                    HelpLabel("Target", topic: .targetWeight)
                    HStack(spacing: DS.Spacing.xs) {
                        Text("Return: TTWROR, \(store.period.shortTitle)")
                        HelpButton(.ttwror)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ rows: [AllocationRow], model: AllocationModel) -> some View {
        if rows.count == 1, let row = rows.first {
            switch row.kind {
            case .classification(let id):
                Button("Edit Classification") {
                    session.editSelection = id
                    session.tab = .edit
                }
                Button("Use as Scope") { store.scopeSelection = .classification(taxonomy: taxonomy.id, id: id) }
                Button("Show Performance") {
                    store.scopeSelection = .classification(taxonomy: taxonomy.id, id: id)
                    store.navigate(to: .performance)
                }
            case .item(let classification, let vehicle):
                Button(vehicle.isSecurity ? "Show Security" : "Show Account") { show(vehicle) }
                Button("Split Across Classifications…") { presentSplit(vehicle) }
                Menu(classification == nil ? "Assign To" : "Move To") {
                    ForEach(taxonomy.flattened, id: \.classification.id) { entry in
                        Button(String(repeating: "    ", count: entry.depth) + entry.classification.name) {
                            move(vehicle, from: classification, to: entry.classification)
                        }
                        .disabled(entry.classification.id == classification)
                    }
                }
                if let classification, let name = taxonomy.classification(classification)?.name {
                    Divider()
                    Button("Remove from “\(name)”", role: .destructive) { unassign([row]) }
                }
            case .unassigned:
                Button("Assign in Edit Tab") { session.tab = .edit }
            }
            Divider()
        }
        Button(rows.isEmpty ? "Copy Table" : "Copy") {
            Pasteboard.copy(model.tsv(only: Set(rows.map(\.id)), returns: returns.value?.ttwror ?? [:]))
        }
        if rows.isEmpty {
            Divider()
            Button("Expand All") { setAll(true, model) }
            Button("Collapse All") { setAll(false, model) }
        }
    }

    // MARK: Actions

    private func primaryAction(_ row: AllocationRow) {
        switch row.kind {
        case .item(_, let vehicle):
            show(vehicle)
        case .classification, .unassigned:
            expansion[row.id] = !isExpanded(row)
        }
    }

    private func show(_ vehicle: AllocationVehicle) {
        switch vehicle {
        case .security(let id): store.navigate(to: .security(id))
        case .account(let id): store.navigate(to: .account(id))
        }
    }

    private func presentSplit(_ vehicle: AllocationVehicle) {
        store.present(.custom(id: SplitSheet.requestID, payload: ["taxonomy": taxonomy.id.uuidString, "vehicle": vehicle.token]))
    }

    private func move(_ vehicle: AllocationVehicle, from source: UUID?, to target: Classification) {
        let taxonomyID = taxonomy.id
        store.mutate("Assign to \(target.name)") { file in
            guard let i = file.taxonomies.firstIndex(where: { $0.id == taxonomyID }) else { return }
            if let source {
                file.taxonomies[i].moveAssignment(of: vehicle, from: source, to: target.id)
            } else {
                file.taxonomies[i].assign(vehicle, to: target.id)
            }
        }
    }

    /// Delete on assignment rows removes the assignment (undoable); other rows are ignored.
    private func unassign(_ rows: [AllocationRow]) {
        let pairs: [(UUID, AllocationVehicle)] = rows.compactMap { row in
            if case .item(let classification?, let vehicle) = row.kind { (classification, vehicle) } else { nil }
        }
        guard !pairs.isEmpty else { return }
        let taxonomyID = taxonomy.id
        store.mutate(pairs.count == 1 ? "Remove Assignment" : "Remove \(pairs.count) Assignments") { file in
            guard let i = file.taxonomies.firstIndex(where: { $0.id == taxonomyID }) else { return }
            for (classification, vehicle) in pairs { file.taxonomies[i].unassign(vehicle, from: classification) }
        }
    }

    // MARK: Expansion and deep links

    /// Sub-classifications are visible, assigned securities one click away (`--state expand=all|none`).
    private func defaultExpansion(_ row: AllocationRow) -> Bool {
        switch store.launchValue("expand") {
        case "all": true
        case "none": false
        default: row.children.contains { $0.classificationID != nil }
        }
    }

    private func isExpanded(_ row: AllocationRow) -> Bool {
        expansion[row.id] ?? defaultExpansion(row)
    }

    /// → expands, ← collapses the selected rows (like an outline view).
    private func setExpansion(_ value: Bool, index: [String: AllocationRow]) -> KeyPress.Result {
        let rows = selection.compactMap { index[$0] }.filter { !$0.children.isEmpty && isExpanded($0) != value }
        guard !rows.isEmpty else { return .ignored }
        for row in rows { expansion[row.id] = value }
        return .handled
    }

    private func setAll(_ value: Bool, _ model: AllocationModel) {
        for row in model.rows.flatMap(\.flattened) where !row.children.isEmpty { expansion[row.id] = value }
    }

    private func reveal(_ id: UUID?) {
        guard let id, taxonomy.contains(id) else { return }
        expandAncestors(of: id.uuidString)
        if selection != [id.uuidString] { selection = [id.uuidString] }
    }

    private func expandAncestors(of rowID: String) {
        guard let id = UUID(uuidString: rowID), let path = taxonomy.path(to: id) else { return }
        for ancestor in path.dropLast() where expansion[ancestor.uuidString] != true { expansion[ancestor.uuidString] = true }
    }
}

// MARK: - Cells

/// A tree whose rows are shown flat in a `Table` (the name cell draws indentation and the
/// disclosure chevron).
protocol TreeRow: Identifiable {
    var children: [Self] { get }
}

extension AllocationRow: TreeRow {}

extension Array where Element: TreeRow {
    /// Depth-first, skipping the children of collapsed rows.
    func visibleRows(isExpanded: (Element) -> Bool) -> [Element] {
        var result: [Element] = []
        func visit(_ rows: [Element]) {
            for row in rows {
                result.append(row)
                if !row.children.isEmpty, isExpanded(row) { visit(row.children) }
            }
        }
        visit(self)
        return result
    }
}

/// Indentation + disclosure chevron in front of a tree row's name.
struct DisclosureCell<Content: View>: View {
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)
            .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            .accessibilityHidden(!hasChildren)
            HStack(spacing: DS.Spacing.s) { content }
        }
        .padding(.leading, CGFloat(depth) * 16)
    }
}

struct AllocationNameCell: View {
    let row: AllocationRow

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            switch row.kind {
            case .classification, .unassigned:
                ColorDot(color: row.color ?? ChartColors.other, dashed: row.kind == .unassigned)
                Text(row.name)
                    .fontWeight(row.depth == 0 ? .medium : .regular)
                    .lineLimit(1)
            case .item(_, let vehicle):
                Image(systemName: vehicle.isSecurity ? "chart.line.uptrend.xyaxis" : "banknote")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                    .accessibilityLabel(vehicle.isSecurity ? "Security" : "Account")
                Text(row.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let weight = row.weight, weight != 10_000 {
                    WeightBadge(weight: weight)
                }
            }
        }
    }
}

/// The classification's color as a small mark next to its name.
struct ColorDot: View {
    let color: Color
    var dashed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(dashed ? AnyShapeStyle(color.opacity(0.35)) : AnyShapeStyle(color))
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

/// "60%" — the part of a split vehicle that counts in this classification.
struct WeightBadge: View {
    let weight: Int

    var body: some View {
        Text(Fmt.percent(basisPoints: weight, decimals: weight % 100 == 0 ? 0 : 2))
            .font(.caption2.weight(.medium))
            .numeric()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help("\(Fmt.percent(basisPoints: weight)) of this position counts here")
            .accessibilityLabel("\(Fmt.percent(basisPoints: weight)) assigned here")
    }
}

/// "▲ +2.10 pp" — over (▲) or under (▼) the target. Not a gain or a loss, so it is not colored
/// like one; deviations beyond the tolerance are called out in the warning color.
struct DriftText: View {
    let delta: Double

    var body: some View {
        let isOff = abs(delta) >= AllocationTab.tolerance
        let isZero = abs(delta) < 0.00005
        HStack(spacing: DS.Spacing.xs) {
            if !isZero {
                Text(delta > 0 ? "▲" : "▼")
                    .font(.caption2)
                    .accessibilityLabel(delta > 0 ? "over target by" : "under target by")
            }
            Text(Fmt.percentagePoints(delta))
        }
        .numeric()
        .foregroundStyle(isOff ? AnyShapeStyle(DS.Colors.warning) : AnyShapeStyle(.secondary))
        .fontWeight(isOff ? .medium : .regular)
        .help(isZero ? "On target" : delta > 0 ? "Above its target weight" : "Below its target weight")
    }
}
