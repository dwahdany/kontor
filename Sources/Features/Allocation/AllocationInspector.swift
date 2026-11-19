import SwiftUI
import KontorUI

/// Inspector of the Allocation screen: the focused classification (value, target, what is assigned)
/// or a summary of the taxonomy.
struct AllocationInspector: View {
    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<AllocationModel>()

    var body: some View {
        let session = AllocationSession.session(for: store)
        Group {
            if let taxonomy = session.taxonomy(in: store.file) {
                content(taxonomy, session: session)
                    .analysisTask($model, id: "allocation.model", variant: taxonomy.id) { analysis in
                        AllocationModel(analysis, taxonomy: taxonomy)
                    }
            } else {
                Form {
                    Section("Allocation") {
                        Text("Create a taxonomy to see how your portfolio is spread.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func content(_ taxonomy: Taxonomy, session: AllocationSession) -> some View {
        let model = model.value.flatMap { $0.taxonomyID == taxonomy.id ? $0 : nil }
        let focused = store.route.classificationID.flatMap { taxonomy.classification($0) }
        let row = focused.flatMap { node in model?.rows.flatMap(\.flattened).first { $0.classificationID == node.id } }
        Form {
            if let node = focused {
                Section {
                    HStack(spacing: DS.Spacing.s) {
                        ColorDot(color: ChartColors.classification(node.color, fallbackIndex: 0))
                        Text(node.name).font(.headline)
                    }
                    KeyValueRow("Path", taxonomy.pathTitle(of: node.id))
                    if !node.note.isEmpty { Text(node.note).foregroundStyle(.secondary) }
                }
                Section("Allocation") {
                    KeyValueRow("Value") { Text(row.map { Fmt.money(minor: $0.value, currency: model?.currency) } ?? Fmt.missing).numeric() }
                    KeyValueRow("Actual") { Text(Fmt.percent(row?.share)).numeric() }
                    KeyValueRow("Target") {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(Fmt.percent(row?.targetShare)).numeric()
                            HelpButton(.targetWeight)
                        }
                    }
                    if let delta = row?.deltaShare {
                        KeyValueRow("Difference") { DriftText(delta: delta) }
                    }
                    if let delta = row?.deltaValue, let currency = model?.currency {
                        KeyValueRow(delta > 0 ? "Above target by" : "Below target by") {
                            Text(Fmt.money(minor: abs(delta), currency: currency)).numeric()
                        }
                    }
                }
                let items = row?.children.filter(\.isItem) ?? []
                if !items.isEmpty {
                    Section("Assigned (\(items.count))") {
                        ForEach(items) { item in
                            KeyValueRow(item.name) {
                                Text(Fmt.money(minor: item.value, currency: model?.currency)).numeric()
                            }
                        }
                    }
                }
                Section {
                    Button("Use as Scope") { store.scopeSelection = .classification(taxonomy: taxonomy.id, id: node.id) }
                    Button("Edit Classification") {
                        session.editSelection = node.id
                        session.tab = .edit
                    }
                }
            } else {
                Section("Taxonomy") {
                    KeyValueRow("Name", taxonomy.name)
                    KeyValueRow("Classifications", Fmt.integer(taxonomy.classificationCount))
                    KeyValueRow("Assigned", Fmt.integer(taxonomy.assignedWeights.count))
                    KeyValueRow("Targets", taxonomy.hasTargets ? "Yes" : "None")
                }
                if let model {
                    Section("Value") {
                        KeyValueRow("Total") { Text(Fmt.money(minor: model.totalValue, currency: model.currency)).numeric() }
                        KeyValueRow("Classified") { Text(Fmt.money(minor: model.classifiedValue, currency: model.currency)).numeric() }
                        KeyValueRow("Unassigned") { Text(Fmt.money(minor: model.unassignedValue, currency: model.currency)).numeric() }
                        KeyValueRow("As of", Fmt.day(model.day, style: .medium))
                        KeyValueRow("Scope", store.scopeTitle)
                    }
                }
                Section {
                    Text("Select a classification to see its details.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
