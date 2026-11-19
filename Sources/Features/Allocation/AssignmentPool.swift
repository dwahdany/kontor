import SwiftUI
import KontorUI

/// The right-hand pane of the Edit tab: securities and accounts that are not (fully) assigned yet.
/// Drag rows onto a classification, or select several and use "Assign To".
struct AssignmentPool: View {
    let taxonomy: Taxonomy
    @Binding var selection: Set<String>
    @Binding var filter: String
    @Binding var showsAssigned: Bool
    let assign: ([AllocationVehicle], UUID) -> Void
    let split: (AllocationVehicle) -> Void

    @Environment(PortfolioStore.self) private var store
    @State private var heldValues = Loadable<HeldValues>()

    private var held: HeldValues? { heldValues.value }

    struct Entry: Identifiable {
        var vehicle: AllocationVehicle
        var name: String
        var detail: String
        /// Basis points not assigned yet.
        var open: Int
        var value: Int64?
        var id: String { vehicle.token }
    }

    private var entries: (held: [Entry], other: [Entry], openCount: Int) {
        let weights = taxonomy.assignedWeights
        let query = QuickFilter(filter)
        var held: [Entry] = []
        var other: [Entry] = []
        var openCount = 0
        func add(_ vehicle: AllocationVehicle, name: String, detail: String, keywords: [String], isRetired: Bool) {
            let assigned = weights[vehicle] ?? 0
            let value = self.held?.values[vehicle]
            // Retired entries only matter while they are still held.
            guard !isRetired || value != nil else { return }
            let open = max(0, 10_000 - assigned)
            if open > 0, value != nil { openCount += 1 }
            guard showsAssigned || open > 0 else { return }
            guard query.matches([name, detail] + keywords) else { return }
            let entry = Entry(vehicle: vehicle, name: name, detail: detail, open: open, value: value)
            if value != nil { held.append(entry) } else { other.append(entry) }
        }
        for s in store.file.securities {
            add(.security(s.id), name: s.name, detail: s.ticker.isEmpty ? s.currency : s.ticker, keywords: [s.isin, s.wkn], isRetired: s.isRetired)
        }
        for a in store.file.accounts {
            add(.account(a.id), name: a.name, detail: a.currency, keywords: ["account", "cash"], isRetired: a.isRetired)
        }
        held.sort { ($0.value ?? 0) > ($1.value ?? 0) }
        return (held, other, openCount)
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Securities & Accounts")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                }
                Picker("Show", selection: $showsAssigned) {
                    Text("To Assign").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                QuickFilterField(text: $filter, prompt: "Filter")
            }
            .padding(DS.Spacing.m)
            Divider()
            if entries.held.isEmpty && entries.other.isEmpty {
                emptyState
            } else {
                // A single-column `Table` rather than a `List`: with a few hundred securities a
                // `List`'s lazy row-height estimation re-enters the table view's delegate (AppKit
                // warns, and announces an assert). See `EditTab.tree`.
                Table(of: Entry.self, selection: $selection) {
                    TableColumn("Security / Account") { entry in
                        row(entry)
                    }
                } rows: {
                    if !entries.held.isEmpty {
                        Section("Held") {
                            ForEach(entries.held) { TableRow($0) }
                        }
                    }
                    if !entries.other.isEmpty {
                        Section(entries.held.isEmpty ? "Securities & Accounts" : "Not Held") {
                            ForEach(entries.other) { TableRow($0) }
                        }
                    }
                }
                .tableColumnHeaders(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { ids in
                    menu(ids.compactMap(AllocationVehicle.init(token:)))
                } primaryAction: { ids in
                    if let vehicle = ids.first.flatMap(AllocationVehicle.init(token:)) { split(vehicle) }
                }
            }
            Divider()
            footer(openCount: entries.openCount)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .analysisTask($heldValues, id: "allocation.held", scope: .portfolio, interval: store.interval(for: .ytd)) { HeldValues($0) }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: entry.vehicle.isSecurity ? "chart.line.uptrend.xyaxis" : "banknote")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityLabel(entry.vehicle.isSecurity ? "Security" : "Account")
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name)
                    .lineLimit(1)
                HStack(spacing: DS.Spacing.xs) {
                    Text(entry.detail)
                    if let value = entry.value, let currency = held?.currency {
                        Text("·")
                        Text(Fmt.money(minor: value, currency: currency)).numeric()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.xs)
            if entry.open == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .help("Fully assigned")
                    .accessibilityLabel("Fully assigned")
            } else if entry.open < 10_000 {
                Text("\(Fmt.percent(basisPoints: entry.open, decimals: entry.open % 100 == 0 ? 0 : 2)) left")
                    .font(.caption.weight(.medium))
                    .numeric()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .draggable(dragPayload(for: entry))
    }

    /// Dragging a selected row drags the whole selection.
    private func dragPayload(for entry: Entry) -> String {
        let tokens = selection.contains(entry.id) ? selection.sorted() : [entry.id]
        return "v:" + tokens.joined(separator: ",")
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS.Spacing.s) {
            if !filter.isEmpty {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                Text("No matches").font(.headline)
                Button("Clear Filter") { filter = "" }.buttonStyle(.link)
            } else if store.file.securities.isEmpty && store.file.accounts.isEmpty {
                Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                Text("Nothing to assign yet").font(.headline)
                Text("Securities and accounts appear here once you add them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("New Security") { store.present(.newSecurity) }
            } else {
                Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.secondary)
                Text("Everything is assigned").font(.headline)
                Text("Every security and account has a place in “\(taxonomy.name)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Show All") { showsAssigned = true }.buttonStyle(.link)
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(openCount: Int) -> some View {
        let vehicles = selection.sorted().compactMap(AllocationVehicle.init(token:))
        return HStack(spacing: DS.Spacing.s) {
            Menu(vehicles.count > 1 ? "Assign \(vehicles.count) To" : "Assign To") {
                classificationItems { assign(vehicles, $0) }
            }
            .fixedSize()
            .disabled(vehicles.isEmpty || taxonomy.root.isEmpty)
            .help("Assign the selected rows to a classification — or drag them onto it")
            Button("Split…") { if let vehicle = vehicles.first { split(vehicle) } }
                .disabled(vehicles.count != 1 || taxonomy.root.isEmpty)
                .help("Split one position across several classifications, e.g. 60 / 40")
            Spacer(minLength: 0)
            if openCount > 0 {
                Text("\(openCount) to assign")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .lineLimit(1)
                    .fixedSize()
                    .help("\(openCount) held \(openCount == 1 ? "position is" : "positions are") not fully assigned")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
    }

    @ViewBuilder
    private func menu(_ vehicles: [AllocationVehicle]) -> some View {
        if !vehicles.isEmpty {
            Menu("Assign To") {
                classificationItems { assign(vehicles, $0) }
            }
            if vehicles.count == 1, let vehicle = vehicles.first {
                Button("Split Across Classifications…") { split(vehicle) }
                Divider()
                Button(vehicle.isSecurity ? "Show Security" : "Show Account") {
                    switch vehicle {
                    case .security(let id): store.navigate(to: .security(id))
                    case .account(let id): store.navigate(to: .account(id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func classificationItems(_ action: @escaping (UUID) -> Void) -> some View {
        ForEach(taxonomy.flattened, id: \.classification.id) { entry in
            Button(String(repeating: "    ", count: entry.depth) + entry.classification.name) { action(entry.classification.id) }
        }
    }
}

// MARK: - Split editor

/// Splits one security or account across several classifications with weights (e.g. 60 / 40).
/// Request: `.custom(id: "allocation.split", payload: ["taxonomy": <uuid>, "vehicle": "s:<uuid>" | "a:<uuid>"])`.
struct SplitSheet: View {
    static let requestID = "allocation.split"

    let payload: [String: String]

    @Environment(PortfolioStore.self) private var store
    @State private var parts: [Part] = []
    @State private var didLoad = false

    struct Part: Identifiable {
        let id = UUID()
        var classification: UUID?
        var weight: Int
    }

    private var taxonomy: Taxonomy? {
        payload["taxonomy"].flatMap(UUID.init(uuidString:)).flatMap { id in store.file.taxonomies.first { $0.id == id } }
    }

    private var vehicle: AllocationVehicle? { payload["vehicle"].flatMap(AllocationVehicle.init(token:)) }

    private var name: String {
        switch vehicle {
        case .security(let id): store.security(id)?.name ?? "Security"
        case .account(let id): store.account(id)?.name ?? "Account"
        case nil: ""
        }
    }

    private var total: Int { parts.reduce(0) { $0 + max($1.weight, 0) } }
    private var isValid: Bool { total <= 10_000 && parts.allSatisfy { $0.weight == 0 || $0.classification != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Split “\(name)”")
                    .font(.title3.weight(.semibold))
                Text("Count parts of this position in different classifications of “\(taxonomy?.name ?? "")” — a 60/40 fund, for example, as 60% Equity and 40% Bonds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.xl)

            Divider()
            if let taxonomy {
                ScrollView {
                    VStack(spacing: DS.Spacing.s) {
                        ForEach($parts) { $part in
                            HStack(spacing: DS.Spacing.s) {
                                Picker("Classification", selection: $part.classification) {
                                    Text("Choose…").tag(UUID?.none)
                                    ForEach(taxonomy.flattened, id: \.classification.id) { entry in
                                        Text(String(repeating: "    ", count: entry.depth) + entry.classification.name)
                                            .tag(UUID?.some(entry.classification.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                BasisPointField("Weight", value: part.weight, placeholder: "0", onDraft: { draft in
                                    if case .some(let value) = draft { part.weight = value ?? 0 }
                                }, onCommit: { part.weight = $0 ?? 0 })
                                    .frame(width: 96)
                                Button("Remove", systemImage: "minus.circle") { parts.removeAll { $0.id == part.id } }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help("Remove this part")
                            }
                        }
                        HStack {
                            Button("Add Classification", systemImage: "plus") {
                                let used = Set(parts.compactMap(\.classification))
                                let next = taxonomy.flattened.first { !used.contains($0.classification.id) }?.classification.id
                                parts.append(Part(classification: next, weight: max(0, 10_000 - total)))
                            }
                            .disabled(parts.count >= taxonomy.classificationCount)
                            Spacer()
                            Button("Split Evenly") {
                                let shares = apportion(10_000, weights: [Int](repeating: 1, count: parts.count))
                                for i in parts.indices { parts[i].weight = shares[i] }
                            }
                            .disabled(parts.count < 2)
                        }
                        .controlSize(.small)
                        .padding(.top, DS.Spacing.xs)
                    }
                    .padding(DS.Spacing.xl)
                }
                .frame(minHeight: 150, maxHeight: 280)
            }
            Divider()

            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                TargetActualBar(actual: Double(total) / 10_000, target: 1, maximum: max(1, Double(total) / 10_000), showsLabel: false)
                HStack {
                    if total > 10_000 {
                        Label("\(Fmt.percent(basisPoints: total)) assigned — \(Fmt.percent(basisPoints: total - 10_000)) too much", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Colors.warning)
                    } else if total < 10_000 {
                        Text("\(Fmt.percent(basisPoints: total)) assigned · \(Fmt.percent(basisPoints: 10_000 - total)) stays unassigned")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("100% assigned", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { store.dismissSheet() }
                        .keyboardShortcut(.cancelAction)
                    Button("Done", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
                .font(.callout)
                .numeric()
            }
            .padding(DS.Spacing.xl)
        }
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let taxonomy, let vehicle else {
            store.dismissSheet()
            return
        }
        parts = taxonomy.assignments(of: vehicle).map { Part(classification: $0.classification, weight: $0.weight) }
        if parts.isEmpty {
            parts = [Part(classification: nil, weight: 6_000), Part(classification: nil, weight: 4_000)]
        } else if parts.count == 1 {
            parts.append(Part(classification: nil, weight: max(0, 10_000 - total)))
        }
    }

    private func apply() {
        guard let taxonomy, let vehicle else { return }
        let result = parts.compactMap { part in part.classification.map { (classification: $0, weight: part.weight) } }
        store.editTaxonomy(taxonomy.id, "Split \(name)") { $0.setSplit(of: vehicle, parts: result) }
        store.dismissSheet()
    }
}
