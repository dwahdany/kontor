import SwiftUI
import KontorUI

extension PortfolioStore {
    /// One undoable edit of one taxonomy.
    @discardableResult
    func editTaxonomy(_ id: UUID, _ actionName: String, _ body: (inout Taxonomy) -> Void) -> Bool {
        mutate(actionName) { file in
            guard let i = file.taxonomies.firstIndex(where: { $0.id == id }) else { return }
            body(&file.taxonomies[i])
        }
    }
}

/// What is held right now — orders the "to assign" list (held positions first, with their value).
struct HeldValues: Sendable {
    var currency: CurrencyCode
    var values: [AllocationVehicle: Int64]

    init(_ analysis: Analysis) {
        let snapshot = analysis.snapshot
        currency = snapshot.currency
        var values: [AllocationVehicle: Int64] = [:]
        for p in snapshot.positions { values[.security(p.securityID)] = p.value.minor }
        for c in snapshot.cash where c.value.minor != 0 { values[.account(c.accountID)] = c.value.minor }
        self.values = values
    }
}

/// Tab 2: the taxonomy editor — the classification tree with targets on the left, the securities
/// and accounts that still need a home on the right.
struct EditTab: View {
    let taxonomy: Taxonomy
    @Bindable var session: AllocationSession

    @Environment(PortfolioStore.self) private var store
    @State private var selection = Set<String>()
    @State private var collapsed = Set<UUID>()
    /// Targets being typed (not committed yet) — so the sums validate live.
    @State private var draftTargets: [UUID: Int?] = [:]
    @State private var dropTarget: String?
    @State private var pool = Set<String>()
    @State private var filter = ""
    @State private var showsAssigned = false
    @FocusState private var focusedName: UUID?

    // MARK: Rows

    enum Row: Identifiable {
        case node(Classification, depth: Int, parent: UUID?, absoluteTarget: Double?)
        case assignment(classification: UUID, vehicle: AllocationVehicle, name: String, weight: Int, total: Int, depth: Int)
        case status(parent: UUID?, status: TargetGroupStatus, depth: Int)

        var id: String {
            switch self {
            case .node(let c, _, _, _): c.id.uuidString
            case .assignment(let classification, let vehicle, _, _, _, _): "\(classification.uuidString)/\(vehicle.token)"
            case .status(let parent, _, _): "status/\(parent?.uuidString ?? "root")"
            }
        }
    }

    private var rows: [Row] {
        var result: [Row] = []
        let totals = taxonomy.assignedWeights
        func visit(_ nodes: [Classification], parent: UUID?, depth: Int, parentTarget: Double?) {
            // Validation of this sibling group, right under its parent where it cannot be missed.
            let status = taxonomy.targetStatus(ofParent: parent, overrides: draftTargets)
            if !nodes.isEmpty, !status.isComplete {
                result.append(.status(parent: parent, status: status, depth: depth))
            }
            for node in nodes {
                let target = draftTargets[node.id] ?? node.targetWeight
                let absolute = parentTarget.flatMap { p in target.map { p * Double($0) / 10_000 } }
                result.append(.node(node, depth: depth, parent: parent, absoluteTarget: absolute))
                guard !collapsed.contains(node.id) else { continue }
                visit(node.children, parent: node.id, depth: depth + 1, parentTarget: absolute)
                for a in node.assignments {
                    guard let vehicle = AllocationVehicle(a) else { continue }
                    result.append(.assignment(
                        classification: node.id, vehicle: vehicle, name: name(of: vehicle), weight: a.weight,
                        total: totals[vehicle] ?? a.weight, depth: depth + 1))
                }
            }
        }
        visit(taxonomy.root, parent: nil, depth: 0, parentTarget: 1)
        return result
    }

    private func name(of vehicle: AllocationVehicle) -> String {
        switch vehicle {
        case .security(let id): store.security(id)?.name ?? "Deleted security"
        case .account(let id): store.account(id)?.name ?? "Deleted account"
        }
    }

    /// The single selected classification, if any.
    private var selectedNode: UUID? {
        guard selection.count == 1, let id = selection.first.flatMap(UUID.init(uuidString:)), taxonomy.contains(id) else { return nil }
        return id
    }

    private var selectedNodes: [UUID] {
        selection.compactMap(UUID.init(uuidString:)).filter(taxonomy.contains)
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                commandBar
                Divider()
                if taxonomy.root.isEmpty {
                    EmptyState(
                        "No Classifications Yet", symbol: "square.stack.3d.up",
                        message: "Add a classification for every group you want to track — for example Equity, Bonds and Cash — then drag securities and accounts onto them."
                    ) {
                        Button("Add Classification") { addClassification(asChild: false) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    columnHeader
                    Divider()
                    tree
                }
            }
            .frame(minWidth: 540)
            .layoutPriority(1)
            Divider()
            AssignmentPool(
                taxonomy: taxonomy, selection: $pool, filter: $filter, showsAssigned: $showsAssigned,
                assign: { vehicles, classification in assign(vehicles, to: classification) },
                split: presentSplit)
                .frame(minWidth: 240, idealWidth: 310, maxWidth: 310)
        }
        .onAppear {
            if let id = session.editSelection, taxonomy.contains(id) {
                selection = [id.uuidString]
                session.editSelection = nil
            } else if let name = store.launchValue("select"),
                      let match = taxonomy.flattened.first(where: { $0.classification.name.caseInsensitiveCompare(name) == .orderedSame }) {
                selection = [match.classification.id.uuidString]
            }
        }
        // Typing in a row's name selects the row, so the toolbar commands apply to it.
        .onChange(of: focusedName) { _, id in
            if let id, selection != [id.uuidString] { selection = [id.uuidString] }
        }
        .onChange(of: selection) { _, _ in
            if let id = selectedNode {
                store.setFocus(.classification(taxonomy: taxonomy.id, id: id))
            } else {
                store.setFocus(.taxonomy(taxonomy.id))
            }
        }
    }

    // MARK: Command bar

    private var commandBar: some View {
        HStack(spacing: DS.Spacing.s) {
            ViewThatFits(in: .horizontal) {
                addButtons.labelStyle(.titleAndIcon)
                addButtons.labelStyle(.iconOnly)
            }
            Divider().frame(height: 16)
            ControlGroup {
                Button("Outdent", systemImage: "decrease.indent") { restructure("Outdent Classification") { $0.outdent($1) } }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                    .disabled(selectedNode.map { !taxonomy.canOutdent($0) } ?? true)
                    .help("Move one level up (⌃⌘←)")
                Button("Indent", systemImage: "increase.indent") { restructure("Indent Classification") { $0.indent($1) } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                    .disabled(selectedNode.map { !taxonomy.canIndent($0) } ?? true)
                    .help("Nest inside the classification above (⌃⌘→)")
                Button("Move Up", systemImage: "arrow.up") { restructure("Move Classification") { $0.shift($1, by: -1) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                    .disabled(selectedNode == nil)
                    .help("Move up among its siblings (⌃⌘↑)")
                Button("Move Down", systemImage: "arrow.down") { restructure("Move Classification") { $0.shift($1, by: 1) } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                    .disabled(selectedNode == nil)
                    .help("Move down among its siblings (⌃⌘↓)")
            }
            .controlGroupStyle(.navigation)
            .labelStyle(.iconOnly)
            Button("Delete", systemImage: "trash", role: .destructive) { deleteSelection() }
                .labelStyle(.iconOnly)
                .disabled(selection.isEmpty)
                .help("Delete the selection (⌫) — undo with ⌘Z")
            Spacer(minLength: DS.Spacing.s)
            targetsMenu
                .labelStyle(.titleAndIcon)
        }
        .controlSize(.regular)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
    }

    private var addButtons: some View {
        HStack(spacing: DS.Spacing.s) {
            Button("Classification", systemImage: "plus") { addClassification(asChild: false) }
                .keyboardShortcut("n", modifiers: [.command, .control, .shift])
                .help("Add a classification after the selected one (⌃⇧⌘N)")
            Button("Sub-classification", systemImage: "arrow.turn.down.right") { addClassification(asChild: true) }
                .disabled(selectedNode == nil)
                .help("Add a classification inside the selected one")
        }
        .fixedSize()
    }

    /// Target tools for the sibling group of the selection (or the top level).
    private var targetsMenu: some View {
        let parent: UUID? = selectedNode.flatMap { taxonomy.parentID(of: $0) } ?? nil
        let groupName = parent.flatMap { taxonomy.classification($0)?.name }.map { "in “\($0)”" } ?? "on the Top Level"
        return Menu {
            Section("Targets \(groupName)") {
                Button("Normalize to 100%") { store.editTaxonomy(taxonomy.id, "Normalize Targets") { $0.normalizeTargets(ofParent: parent) } }
                Button("Distribute Remainder") { store.editTaxonomy(taxonomy.id, "Distribute Remainder") { $0.distributeRemainder(ofParent: parent) } }
                Button("Equal Weights") { store.editTaxonomy(taxonomy.id, "Set Equal Targets") { $0.equalizeTargets(ofParent: parent) } }
                Divider()
                Button("Clear Targets") { store.editTaxonomy(taxonomy.id, "Clear Targets") { $0.clearTargets(ofParent: parent) } }
            }
        } label: {
            Label("Targets", systemImage: "scope")
        }
        .fixedSize()
        .disabled(taxonomy.root.isEmpty)
        .help("Normalize, distribute or clear the target weights of the selected group")
    }

    private var columnHeader: some View {
        HStack(spacing: DS.Spacing.s) {
            Text("Classification")
            Spacer()
            HelpLabel("Target", topic: .targetWeight)
                .frame(width: EditMetrics.target, alignment: .trailing)
            Text("Of Total")
                .frame(width: EditMetrics.absolute, alignment: .trailing)
                .help("The target as a share of the whole portfolio: the product of the targets along the path")
            Color.clear.frame(width: EditMetrics.actions, height: 1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.xs)
    }

    // MARK: Tree

    private var tree: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                rowView(row)
                    .listRowInsets(EdgeInsets(top: 2, leading: DS.Spacing.s, bottom: 2, trailing: DS.Spacing.s))
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 30)
        .onDeleteCommand(perform: deleteSelection)
        .contextMenu(forSelectionType: String.self) { ids in
            treeMenu(ids)
        }
        // Dropping a classification on the empty area (not on a row) moves it to the top level.
        .dropDestination(for: String.self) { items, _ in
            drop(items.filter { $0.hasPrefix("c:") }, on: nil)
        } isTargeted: { targeted in
            if targeted { dropTarget = "root" } else if dropTarget == "root" { dropTarget = nil }
        }
        .overlay(alignment: .bottom) {
            if dropTarget == "root" {
                Label("Drop on a classification to nest it — or here to move it to the top level", systemImage: "arrow.up.to.line")
                    .font(.callout)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.s)
                    .glassPanel(radius: DS.Radius.control)
                    .padding(DS.Spacing.m)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .node(let node, let depth, _, let absolute):
            ClassificationEditRow(
                node: node, depth: depth, absoluteTarget: absolute, isCollapsed: collapsed.contains(node.id),
                isDropTarget: dropTarget == node.id.uuidString, focusedName: $focusedName,
                toggleCollapsed: { if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) } },
                rename: { name in store.editTaxonomy(taxonomy.id, "Rename Classification") { $0.update(node.id) { $0.name = name } } },
                recolor: { hex in store.editTaxonomy(taxonomy.id, "Change Color") { $0.update(node.id) { $0.color = hex } } },
                draftTarget: { draftTargets[node.id] = $0 },
                commitTarget: { target in
                    draftTargets[node.id] = nil
                    store.editTaxonomy(taxonomy.id, target == nil ? "Remove Target" : "Change Target") { $0.update(node.id) { $0.targetWeight = target } }
                },
                select: { if selection != [node.id.uuidString] { selection = [node.id.uuidString] } })
                .draggable("c:\(node.id.uuidString)")
                .dropDestination(for: String.self) { items, _ in
                    drop(items, on: node.id)
                } isTargeted: { targeted in
                    if targeted { dropTarget = node.id.uuidString } else if dropTarget == node.id.uuidString { dropTarget = nil }
                }
        case .assignment(let classification, let vehicle, let name, let weight, let total, let depth):
            AssignmentEditRow(
                vehicle: vehicle, name: name, weight: weight, total: total, depth: depth,
                commitWeight: { value in
                    store.editTaxonomy(taxonomy.id, "Change Assignment Weight") { $0.setWeight(value, of: vehicle, in: classification) }
                },
                split: { presentSplit(vehicle) },
                remove: { store.editTaxonomy(taxonomy.id, "Remove Assignment") { $0.unassign(vehicle, from: classification) } })
                .draggable("m:\(classification.uuidString)/\(vehicle.token)")
        case .status(let parent, let status, let depth):
            TargetStatusRow(
                status: status, depth: depth,
                distribute: { store.editTaxonomy(taxonomy.id, "Distribute Remainder") { $0.distributeRemainder(ofParent: parent) } },
                normalize: { store.editTaxonomy(taxonomy.id, "Normalize Targets") { $0.normalizeTargets(ofParent: parent) } })
                .selectionDisabled()
        }
    }

    @ViewBuilder
    private func treeMenu(_ ids: Set<String>) -> some View {
        let nodes = ids.compactMap(UUID.init(uuidString:)).filter(taxonomy.contains)
        if let id = nodes.first, nodes.count == 1 {
            Button("Add Sub-classification") {
                selection = [id.uuidString]
                addClassification(asChild: true)
            }
            Button("Use as Scope") { store.scopeSelection = .classification(taxonomy: taxonomy.id, id: id) }
            Divider()
        }
        if ids.isEmpty {
            Button("Add Classification") { addClassification(asChild: false) }
        } else {
            Button("Delete", role: .destructive) {
                selection = ids
                deleteSelection()
            }
        }
    }

    // MARK: Actions

    private func addClassification(asChild: Bool) {
        var newID: UUID?
        let anchor = selectedNode
        store.editTaxonomy(taxonomy.id, "Add Classification") { taxonomy in
            if asChild, let anchor {
                newID = taxonomy.addClassification(parent: anchor)
            } else {
                newID = taxonomy.addClassification(after: anchor)
            }
        }
        guard let newID else { return }
        if asChild, let anchor { collapsed.remove(anchor) }
        selection = [newID.uuidString]
        Task { @MainActor in focusedName = newID }
    }

    private func restructure(_ actionName: String, _ body: (inout Taxonomy, UUID) -> Bool) {
        guard let id = selectedNode else { return }
        store.editTaxonomy(taxonomy.id, actionName) { taxonomy in _ = body(&taxonomy, id) }
    }

    private func deleteSelection() {
        let nodes = Set(selectedNodes)
        let assignments: [(UUID, AllocationVehicle)] = selection.compactMap { id in
            let parts = id.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, let classification = UUID(uuidString: String(parts[0])),
                  let vehicle = AllocationVehicle(token: String(parts[1])) else { return nil }
            return (classification, vehicle)
        }
        guard !nodes.isEmpty || !assignments.isEmpty else { return }
        let name = nodes.isEmpty
            ? (assignments.count == 1 ? "Remove Assignment" : "Remove \(assignments.count) Assignments")
            : (nodes.count == 1 ? "Delete Classification" : "Delete \(nodes.count) Classifications")
        store.editTaxonomy(taxonomy.id, name) { taxonomy in
            for (classification, vehicle) in assignments { taxonomy.unassign(vehicle, from: classification) }
            taxonomy.remove(nodes)
        }
        selection = []
    }

    private func assign(_ vehicles: [AllocationVehicle], to classification: UUID) {
        guard !vehicles.isEmpty, let name = taxonomy.classification(classification)?.name else { return }
        store.editTaxonomy(taxonomy.id, vehicles.count == 1 ? "Assign to \(name)" : "Assign \(vehicles.count) to \(name)") { taxonomy in
            for vehicle in vehicles { taxonomy.assign(vehicle, to: classification) }
        }
        collapsed.remove(classification)
        pool.subtract(vehicles.map(\.token))
    }

    /// Handles a drop on a classification (`target` nil = the top-level zone).
    /// Payloads: `c:<classification>` (nest), `v:<token>,<token>` (assign), `m:<classification>/<token>` (move an assignment).
    private func drop(_ items: [String], on target: UUID?) -> Bool {
        dropTarget = nil
        var handled = false
        for item in items {
            if item.hasPrefix("c:"), let id = UUID(uuidString: String(item.dropFirst(2))) {
                guard id != target else { continue }
                handled = store.editTaxonomy(taxonomy.id, target == nil ? "Move to Top Level" : "Nest Classification") { taxonomy in
                    taxonomy.move(id, toParent: target)
                } || handled
                if let target { collapsed.remove(target) }
            } else if item.hasPrefix("v:"), let target {
                let vehicles = item.dropFirst(2).split(separator: ",").compactMap { AllocationVehicle(token: String($0)) }
                assign(vehicles, to: target)
                handled = handled || !vehicles.isEmpty
            } else if item.hasPrefix("m:"), let target {
                let parts = item.dropFirst(2).split(separator: "/", maxSplits: 1)
                guard parts.count == 2, let source = UUID(uuidString: String(parts[0])),
                      let vehicle = AllocationVehicle(token: String(parts[1])),
                      let name = taxonomy.classification(target)?.name else { continue }
                handled = store.editTaxonomy(taxonomy.id, "Move to \(name)") { $0.moveAssignment(of: vehicle, from: source, to: target) } || handled
            }
        }
        return handled
    }

    private func presentSplit(_ vehicle: AllocationVehicle) {
        store.present(.custom(id: SplitSheet.requestID, payload: ["taxonomy": taxonomy.id.uuidString, "vehicle": vehicle.token]))
    }
}

enum EditMetrics {
    static let target: CGFloat = 86
    static let absolute: CGFloat = 64
    static let actions: CGFloat = 46
    static let indent: CGFloat = 18
}

// MARK: - Rows

private struct ClassificationEditRow: View {
    let node: Classification
    let depth: Int
    let absoluteTarget: Double?
    let isCollapsed: Bool
    let isDropTarget: Bool
    var focusedName: FocusState<UUID?>.Binding
    let toggleCollapsed: () -> Void
    let rename: (String) -> Void
    let recolor: (String) -> Void
    let draftTarget: (Int??) -> Void
    let commitTarget: (Int?) -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Button(action: toggleCollapsed) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(node.children.isEmpty && node.assignments.isEmpty ? 0 : 1)
            .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")
            ColorSwatchButton(hex: node.color, select: recolor)
            CommitTextField("Name", text: node.name, onCommit: rename)
                .focused(focusedName, equals: node.id)
                .fontWeight(depth == 0 ? .medium : .regular)
            if isCollapsed, !node.assignments.isEmpty || !node.children.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: DS.Spacing.s)
            BasisPointField("Target of \(node.name)", value: node.targetWeight, placeholder: "No target", onDraft: draftTarget, onCommit: commitTarget)
                .onFocus(select)
                .frame(width: EditMetrics.target)
            Text(absoluteTarget.map { Fmt.percent($0, decimals: 1) } ?? Fmt.missing)
                .numeric()
                .foregroundStyle(.secondary)
                .frame(width: EditMetrics.absolute, alignment: .trailing)
            Color.clear.frame(width: EditMetrics.actions, height: 1)
        }
        .padding(.leading, CGFloat(depth) * EditMetrics.indent)
        .padding(.vertical, 1)
        .background(isDropTarget ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.small))
        .contentShape(Rectangle())
    }

    private var summary: String {
        var parts: [String] = []
        if !node.children.isEmpty { parts.append("\(node.children.count) sub") }
        if !node.assignments.isEmpty { parts.append("\(node.assignments.count) assigned") }
        return parts.joined(separator: " · ")
    }
}

private struct AssignmentEditRow: View {
    let vehicle: AllocationVehicle
    let name: String
    let weight: Int
    /// Sum of this vehicle's weights across the taxonomy.
    let total: Int
    let depth: Int
    let commitWeight: (Int) -> Void
    let split: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Color.clear.frame(width: 12, height: 1)
            Image(systemName: vehicle.isSecurity ? "chart.line.uptrend.xyaxis" : "banknote")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .accessibilityLabel(vehicle.isSecurity ? "Security" : "Account")
            Text(name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if total > 10_000 {
                Label("Over 100%", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(DS.Colors.warning)
                    .help("This position is assigned \(Fmt.percent(basisPoints: total)) in total. Reduce a weight or use Split.")
            } else if total < 10_000 {
                Text("\(Fmt.percent(basisPoints: 10_000 - total, decimals: 0)) unassigned")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.s)
            BasisPointField("Weight of \(name)", value: weight, placeholder: "0", onDraft: { _ in }, onCommit: { commitWeight($0 ?? 0) })
                .frame(width: EditMetrics.target)
            Color.clear.frame(width: EditMetrics.absolute, height: 1)
            HStack(spacing: DS.Spacing.xs) {
                Button("Split Across Classifications…", systemImage: "rectangle.split.2x1", action: split)
                    .help("Split this position across several classifications")
                Button("Remove Assignment", systemImage: "xmark", action: remove)
                    .help("Remove from this classification")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: EditMetrics.actions, alignment: .trailing)
        }
        .padding(.leading, CGFloat(depth) * EditMetrics.indent)
        .contentShape(Rectangle())
    }
}

/// Live validation of one sibling group: what is missing to 100 % and how to fix it.
private struct TargetStatusRow: View {
    let status: TargetGroupStatus
    let depth: Int
    let distribute: () -> Void
    let normalize: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Spacing.s) {
                label
                Spacer(minLength: DS.Spacing.s)
                buttons
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                label
                buttons.padding(.leading, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.vertical, DS.Spacing.xs)
        .padding(.horizontal, DS.Spacing.s)
        .background(DS.Colors.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .padding(.leading, CGFloat(depth) * EditMetrics.indent + 20)
    }

    private var label: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Colors.warning)
                .accessibilityHidden(true)
            Text(message)
                .numeric()
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var buttons: some View {
        HStack(spacing: DS.Spacing.s) {
            Button("Distribute Remainder", action: distribute)
                .help(status.remainder > 0
                    ? "Give the missing \(Fmt.percent(basisPoints: status.remainder)) to the classifications without a target (or spread it evenly)"
                    : "Take the excess away in proportion to the targets")
            Button("Normalize", action: normalize)
                .help("Scale all targets of this group proportionally so they add up to 100%")
        }
        .fixedSize()
    }

    private var message: String {
        let sum = Fmt.percent(basisPoints: status.sum)
        if status.remainder > 0 {
            let open = status.count - status.targeted
            return "Targets add up to \(sum) — \(Fmt.percent(basisPoints: status.remainder)) missing"
                + (open > 0 ? " (\(open) without target)" : "")
        } else if status.remainder < 0 {
            return "Targets add up to \(sum) — \(Fmt.percent(basisPoints: -status.remainder)) too much"
        }
        return "Targets add up to 100%, but \(status.count - status.targeted) \(status.count - status.targeted == 1 ? "classification has" : "classifications have") no target"
    }
}

// MARK: - Fields

/// A text field that commits on Return or when it loses focus (one undo step per edit).
struct CommitTextField: View {
    private let title: String
    private let text: String
    private let onCommit: (String) -> Void
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: String, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.text = text
        self.onCommit = onCommit
        _draft = State(initialValue: text)
    }

    var body: some View {
        TextField(title, text: $draft)
            .textFieldStyle(.plain)
            .labelsHidden()
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: text) { _, new in draft = new }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .accessibilityLabel(title)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            draft = text
        } else if trimmed != text {
            onCommit(trimmed)
        }
    }
}

/// Edits a weight in basis points as a percentage ("60", "12.5", "12,5 %"). Empty = no value.
/// Reports every keystroke through `onDraft` (for live validation) and commits on Return / blur.
struct BasisPointField: View {
    private let title: String
    private let value: Int?
    private let placeholder: String
    private let onDraft: (Int??) -> Void
    private let onCommit: (Int?) -> Void
    private var onFocus: () -> Void = {}
    @State private var text: String
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool

    init(_ title: String, value: Int?, placeholder: String, onDraft: @escaping (Int??) -> Void, onCommit: @escaping (Int?) -> Void) {
        self.title = title
        self.value = value
        self.placeholder = placeholder
        self.onDraft = onDraft
        self.onCommit = onCommit
        _text = State(initialValue: Self.display(value))
    }

    static func display(_ value: Int?) -> String {
        guard let value else { return "" }
        return Fmt.number(Double(value) / 100, decimals: value % 100 == 0 ? 0 : value % 10 == 0 ? 1 : 2)
    }

    static func parse(_ text: String) -> Int?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let fraction = Fmt.parsePercent(trimmed), fraction >= 0, fraction <= 1 else { return nil }
        return .some(Int((fraction * 10_000).rounded()))
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            TextField(title, text: $text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .numeric()
                .focused($isFocused)
                .onSubmit(commit)
                .accessibilityLabel(title)
            Text("%")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            if isInvalid {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.small)
                    .offset(x: -16)
                    .help("Enter a percentage between 0 and 100")
                    .accessibilityLabel("Invalid percentage")
            }
        }
        .onChange(of: value) { _, new in
            if !isFocused || Self.parse(text) != .some(new) { text = Self.display(new) }
        }
        .onChange(of: text) { _, new in
            guard isFocused else { return }
            if let parsed = Self.parse(new) {
                isInvalid = false
                onDraft(.some(parsed))
            } else {
                isInvalid = true
            }
        }
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } else { commit() } }
    }

    /// Called when the field becomes the first responder (e.g. to select its row).
    func onFocus(_ action: @escaping () -> Void) -> BasisPointField {
        var copy = self
        copy.onFocus = action
        return copy
    }

    private func commit() {
        guard let parsed = Self.parse(text) else {
            isInvalid = false
            text = Self.display(value)
            onDraft(nil)
            return
        }
        isInvalid = false
        if parsed != value {
            onCommit(parsed)
        } else {
            onDraft(nil)
        }
        text = Self.display(parsed)
    }
}

/// The classification's color; a click opens the palette.
private struct ColorSwatchButton: View {
    let hex: String
    let select: (String) -> Void
    @State private var isOpen = false

    private static let extras = ["#8E8E93", "#5E5CE6", "#BF5AF2", "#FF375F", "#A2845E", "#30B0C7", "#64D2FF"]

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(hex: hex))
                .frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change color")
        .accessibilityLabel("Color")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            let colors = (0..<CategoryPalette.count).map(CategoryPalette.hex) + Self.extras
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: DS.Spacing.s), count: 5), spacing: DS.Spacing.s) {
                ForEach(colors, id: \.self) { color in
                    Button {
                        select(color)
                        isOpen = false
                    } label: {
                        Circle()
                            .fill(Color(hex: color))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if color.caseInsensitiveCompare(hex) == .orderedSame {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color)
                }
            }
            .padding(DS.Spacing.m)
        }
    }
}
