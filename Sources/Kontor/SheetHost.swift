import SwiftUI
import KontorModel
import KontorUI

/// Presents the sheet for a `SheetRequest`: the owning feature's editor if one is registered,
/// shell-owned sheets (portfolio settings, consistency report) otherwise, and a clearly labelled
/// placeholder for requests whose feature is not built yet.
struct SheetHost: View {
    @Environment(PortfolioStore.self) private var store
    let request: SheetRequest
    let registry: FeatureRegistry

    var body: some View {
        if let custom = registry.sheet(for: request) {
            custom
        } else {
            switch request {
            case .portfolioSettings: PortfolioSettingsSheet()
            case .consistencyReport: ConsistencyReportSheet()
            default: PendingSheet(request: request)
            }
        }
    }
}

/// Stand-in for editors that a feature target will provide.
private struct PendingSheet: View {
    @Environment(PortfolioStore.self) private var store
    let request: SheetRequest

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: request.symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(request.title).font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { store.dismissSheet() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(DS.Spacing.xxl)
        .frame(width: 400)
    }

    private var detail: String {
        switch request {
        case .importFile(let url?): "The importer is not part of this build yet.\n“\(url.lastPathComponent)” was not changed."
        default: "This editor is not part of this build yet."
        }
    }
}

/// Document-level settings stored in the file: name, base currency, cost method, risk-free rate, benchmarks.
struct PortfolioSettingsSheet: View {
    @Environment(PortfolioStore.self) private var store
    @State private var name = ""
    @State private var settings = Settings()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $name, prompt: Text("Untitled"))
                    LabeledContent("Base Currency") {
                        CurrencyPicker(selection: $settings.baseCurrency, preferred: store.file.currencies)
                            .frame(width: 200)
                    }
                }
                Section {
                    Picker("Cost Method", selection: $settings.costMethod) {
                        Text("First In, First Out (FIFO)").tag(CostMethod.fifo)
                        Text("Moving Average").tag(CostMethod.average)
                    }
                    LabeledContent("Risk-Free Rate") {
                        PercentField("Risk-Free Rate", fraction: $settings.riskFreeRate)
                            .frame(width: 90)
                    }
                } header: {
                    Text("Calculation")
                } footer: {
                    Text("The cost method determines realised gains when selling part of a position. The risk-free rate is used for the Sharpe ratio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if store.file.securities.isEmpty {
                        Text("Add a security (for example an index) to use it as a benchmark.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(settings.benchmarkSecurityIDs, id: \.self) { id in
                        HStack {
                            Text(store.security(id)?.name ?? "Missing security")
                            Spacer()
                            Button {
                                settings.benchmarkSecurityIDs.removeAll { $0 == id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove benchmark")
                        }
                    }
                    if !availableBenchmarks.isEmpty {
                        Menu("Add Benchmark") {
                            ForEach(availableBenchmarks) { security in
                                Button(security.name) { settings.benchmarkSecurityIDs.append(security.id) }
                            }
                        }
                        .fixedSize()
                    }
                } header: {
                    Text("Benchmarks")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { store.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 500, height: 580)
        .onAppear {
            name = store.file.name
            settings = store.file.settings
        }
    }

    private var availableBenchmarks: [Security] {
        store.file.securities
            .filter { !settings.benchmarkSecurityIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func save() {
        let newName = name.trimmingCharacters(in: .whitespaces)
        let newSettings = settings
        store.mutate("Change Portfolio Settings") { file in
            file.name = newName
            file.settings = newSettings
        }
        store.dismissSheet()
    }
}

/// Result of Portfolio ▸ Check Consistency.
struct ConsistencyReportSheet: View {
    @Environment(PortfolioStore.self) private var store
    @State private var issues: [ConsistencyChecker.Issue]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: summarySymbol)
                    .font(.title)
                    .foregroundStyle(summaryColor)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Consistency Check").font(.headline)
                    Text(summary).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(DS.Spacing.l)
            Divider()
            Group {
                if let issues, !issues.isEmpty {
                    List(issues) { issue in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? DS.Colors.red : DS.Colors.warning)
                                .accessibilityLabel(issue.severity == .error ? "Error" : "Warning")
                            Text(issue.message)
                                .textSelection(.enabled)
                            Spacer(minLength: DS.Spacing.s)
                            if let route = issue.route {
                                Button("Show") {
                                    store.dismissSheet()
                                    store.navigate(to: route)
                                }
                                .buttonStyle(.link)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.inset)
                } else if issues != nil {
                    EmptyState("Everything Adds Up", symbol: "checkmark.seal", message: "No dangling references, currency mismatches or invalid bookings were found.")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)
            Divider()
            HStack {
                Spacer()
                Button("Done") { store.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 580)
        .task(id: store.revision) {
            let file = store.file
            issues = await store.whileBusy {
                await Task.detached(priority: .userInitiated) { ConsistencyChecker.check(file) }.value
            }
        }
    }

    private var errorCount: Int { issues?.count { $0.severity == .error } ?? 0 }
    private var summary: String {
        guard let issues else { return "Checking…" }
        if issues.isEmpty { return "No problems found." }
        let warnings = issues.count - errorCount
        return [errorCount > 0 ? "\(errorCount) error\(errorCount == 1 ? "" : "s")" : nil,
                warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")
    }
    private var summarySymbol: String {
        guard let issues else { return "hourglass" }
        return issues.isEmpty ? "checkmark.seal.fill" : errorCount > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }
    private var summaryColor: Color {
        guard let issues else { return .secondary }
        return issues.isEmpty ? DS.Colors.green : errorCount > 0 ? DS.Colors.red : DS.Colors.warning
    }
}
