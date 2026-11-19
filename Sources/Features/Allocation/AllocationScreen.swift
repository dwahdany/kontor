import SwiftUI
import KontorUI

/// The Allocation screen: asset allocation and rebalancing around the file's taxonomies.
///
/// Three tabs — **Allocation** (classification tree with actual vs. target and a visual),
/// **Edit** (tree editing, target weights, assignments) and **Rebalancing** (inputs, live proposal,
/// "Create Transactions…").
///
/// Launch state (`--state key=value`), read once when the screen appears:
///
/// | key | values | meaning |
/// |---|---|---|
/// | `tab` | `allocation` · `edit` · `rebalancing` | the tab |
/// | `taxonomy` | a taxonomy name (case-insensitive) or UUID | which taxonomy to show |
/// | `view` | `donut` · `sunburst` · `treemap` · `bars` | the visual of the Allocation tab |
/// | `expand` | `all` · `none` | disclosure state of the tree tables (default: sub-classifications visible) |
/// | `hover` | a classification name | pins the chart's hover/tooltip on that classification |
/// | `select` | a classification name | Edit tab: the selected classification |
/// | `pool` | `all` | Edit tab: the right-hand list shows every security and account, not only those to assign |
/// | `mode` | `classes` · `orders` | Rebalancing: proposal by classification or by security |
/// | `cash` | an amount, e.g. `5000` or `-2500` | Rebalancing: cash to invest (negative: withdraw) |
/// | `buyonly` | `on` · `off` | Rebalancing: never sell |
/// | `whole` | `on` · `off` | Rebalancing: whole shares |
/// | `exclude` | comma-separated classification names | Rebalancing: classifications left untouched |
/// | `excludevehicle` | comma-separated security / account names | Rebalancing: positions left untouched |
///
/// Routes: `taxonomy:<uuid>` selects the taxonomy (the tab stays), `classification:<taxonomy>/<id>`
/// also selects and reveals the classification — a deep link from another screen switches to the
/// Allocation tab for that (see `AllocationSession.adopt`). Sheets: `custom:allocation.split?taxonomy=<uuid>&vehicle=s:<uuid>`,
/// `custom:allocation.rebalance-review?taxonomy=<uuid>&amount=<minor units>&direction=invest|withdraw&buyOnly=0|1&wholeShares=0|1`.
public struct AllocationScreen: View {
    @Environment(PortfolioStore.self) private var store
    @SceneStorage("allocation.tab") private var storedTab = ""
    @SceneStorage("allocation.visual") private var storedVisual = ""
    @SceneStorage("allocation.taxonomy") private var storedTaxonomy = ""
    @State private var didSeed = false
    @State private var renaming: Taxonomy?
    @State private var newName = ""

    public init() {}

    public var body: some View {
        let session = AllocationSession.session(for: store)
        Group {
            if let taxonomy = session.taxonomy(in: store.file) {
                VStack(spacing: 0) {
                    header(session, taxonomy: taxonomy)
                    Divider()
                    switch session.tab {
                    case .allocation: AllocationTab(taxonomy: taxonomy, session: session)
                    case .edit: EditTab(taxonomy: taxonomy, session: session)
                    case .rebalancing: RebalancingTab(taxonomy: taxonomy, session: session)
                    }
                }
            } else {
                TaxonomyOnboarding { create($0, session: session) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem { ScopePicker(store: store) }
        }
        .onAppear { seed(session) }
        .onChange(of: store.route.focus) { _, focus in session.adopt(route: focus, in: store.file) }
        .onChange(of: session.tab) { _, tab in storedTab = tab.rawValue }
        .onChange(of: session.visual) { _, visual in storedVisual = visual.rawValue }
        .onChange(of: session.taxonomyID) { _, id in storedTaxonomy = id?.uuidString ?? "" }
        .alert("Rename Taxonomy", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let taxonomy = renaming, !name.isEmpty {
                    store.editTaxonomy(taxonomy.id, "Rename Taxonomy") { $0.name = name }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Header

    private func header(_ session: AllocationSession, taxonomy: Taxonomy) -> some View {
        @Bindable var session = session
        return ZStack {
            HStack(spacing: DS.Spacing.s) {
                taxonomyMenu(session, taxonomy: taxonomy)
                Spacer(minLength: DS.Spacing.s)
            }
            Picker("Tab", selection: $session.tab) {
                ForEach(AllocationSession.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    private func taxonomyMenu(_ session: AllocationSession, taxonomy: Taxonomy) -> some View {
        Menu {
            Section("Taxonomies") {
                ForEach(store.file.taxonomies) { item in
                    Toggle(item.name.isEmpty ? "Untitled" : item.name, isOn: Binding(
                        get: { item.id == taxonomy.id },
                        set: { if $0 { select(item.id, session: session) } }))
                }
            }
            Section {
                Menu("New Taxonomy", systemImage: "plus") {
                    ForEach(TaxonomyTemplate.allCases) { template in
                        if template == .empty { Divider() }
                        Button(template.title, systemImage: template.symbol) { create(template, session: session) }
                            .help(template.summary)
                    }
                }
                Button("Rename…", systemImage: "pencil") {
                    newName = taxonomy.name
                    renaming = taxonomy
                }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    let copy = taxonomy.duplicated(named: uniqueName("\(taxonomy.name) Copy", among: store.file.taxonomies.map(\.name)))
                    store.upsertTaxonomy(copy, actionName: "Duplicate Taxonomy")
                    select(copy.id, session: session)
                }
                Button("Delete “\(taxonomy.name)”", systemImage: "trash", role: .destructive) {
                    store.deleteTaxonomy(taxonomy.id)
                    session.taxonomyID = nil
                }
            }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                Text(taxonomy.name.isEmpty ? "Untitled" : taxonomy.name)
                    .font(.headline)
                    .lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Choose, create, rename, duplicate or delete a taxonomy")
        .accessibilityLabel("Taxonomy: \(taxonomy.name)")
    }

    // MARK: Actions

    private func select(_ id: UUID, session: AllocationSession) {
        session.taxonomyID = id
        session.setFocus(.taxonomy(id), in: store)
    }

    private func create(_ template: TaxonomyTemplate, session: AllocationSession) {
        let taxonomy = template.make(in: store.file)
        store.upsertTaxonomy(taxonomy, actionName: "New Taxonomy")
        select(taxonomy.id, session: session)
        if taxonomy.root.isEmpty || template != .currency { session.tab = .edit }
    }

    /// Restores the window's state, then applies `--state` once.
    private func seed(_ session: AllocationSession) {
        guard !didSeed else { return }
        didSeed = true
        // The window's stored state applies once per session. The screen is recreated on every
        // visit, so restoring again would undo what the user (or a command) chose since.
        if !session.isRestored {
            session.isRestored = true
            if session.taxonomyID == nil, let id = UUID(uuidString: storedTaxonomy) { session.taxonomyID = id }
            if let tab = AllocationSession.Tab(rawValue: storedTab), store.launchState.isEmpty, !session.hasExplicitTab { session.tab = tab }
            if let visual = AllocationSession.Visual(rawValue: storedVisual) { session.visual = visual }
            // A focus that was restored with the window (no history yet) is this screen's own
            // selection from last time, not a deep link.
            if !store.canGoBack { session.setFocus(store.route.focus, in: store) }
        }
        session.hasExplicitTab = false
        // Deep links: `taxonomy:<id>` selects the taxonomy, `classification:<t>/<id>` also shows the
        // Allocation tab, which selects and reveals it.
        session.adopt(route: store.route.focus, in: store.file)
        if store.launchState.isEmpty {
            if storedTab != session.tab.rawValue { storedTab = session.tab.rawValue }
            if let id = session.taxonomyID, storedTaxonomy != id.uuidString { storedTaxonomy = id.uuidString }
        }

        if let tab = store.launchValue("tab", as: AllocationSession.Tab.self) { session.tab = tab }
        if let visual = store.launchValue("view", as: AllocationSession.Visual.self) { session.visual = visual }
        if let mode = store.launchValue("mode", as: AllocationSession.ProposalMode.self) { session.proposalMode = mode }
        if let text = store.launchValue("taxonomy") {
            let match = store.file.taxonomies.first { $0.name.caseInsensitiveCompare(text) == .orderedSame || $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame }
            if let match { session.taxonomyID = match.id }
        }
        guard let taxonomy = session.taxonomy(in: store.file) else { return }
        var inputs = session.inputs(for: taxonomy.id)
        if let cash = store.launchValue("cash").flatMap(Fmt.parseMinor) {
            inputs.amount = abs(cash)
            inputs.direction = cash < 0 ? .withdraw : .invest
        }
        if let value = store.launchValue("buyonly") { inputs.buyOnly = value == "on" }
        if let value = store.launchValue("whole") { inputs.wholeShares = value != "off" }
        func names(_ key: String) -> [String]? {
            store.launchValue(key)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        if let wanted = names("exclude") {
            inputs.excludedClassifications = Set(
                taxonomy.flattened.filter { wanted.contains($0.classification.name.lowercased()) }.map(\.classification.id))
        }
        if let wanted = names("excludevehicle") {
            let securities = store.file.securities.filter { wanted.contains($0.name.lowercased()) }.map { AllocationVehicle.security($0.id) }
            let accounts = store.file.accounts.filter { wanted.contains($0.name.lowercased()) }.map { AllocationVehicle.account($0.id) }
            inputs.excludedVehicles = Set(securities + accounts)
        }
        session.setInputs(inputs, for: taxonomy.id)
    }
}

/// Shown when the file has no taxonomy at all: what a taxonomy is, and one click to start.
struct TaxonomyOnboarding: View {
    let create: (TaxonomyTemplate) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                VStack(spacing: DS.Spacing.s) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("See How Your Money Is Spread")
                        .font(.title2.weight(.semibold))
                    Text("A taxonomy groups your securities and accounts — by asset class, region, sector or anything else. Give each group a target weight and Kontor shows how far you are from it and what to buy or sell to get back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: DS.Size.readableWidth)
                    HelpLabel("What is an allocation?", topic: .allocation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: DS.Spacing.m)], spacing: DS.Spacing.m) {
                    ForEach(TaxonomyTemplate.allCases) { template in
                        Button {
                            create(template)
                        } label: {
                            HStack(alignment: .top, spacing: DS.Spacing.m) {
                                Image(systemName: template.symbol)
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                    Text(template.title)
                                        .font(.headline)
                                    Text(template.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(DS.Spacing.m)
                            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .topLeading)
                            .cardBackground()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New taxonomy: \(template.title). \(template.summary)")
                    }
                }
                .frame(maxWidth: 940)
            }
            .screenPadding()
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
