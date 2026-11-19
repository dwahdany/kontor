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
            case .export: BasicExportSheet()
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
                    Picker(selection: $settings.costMethod) {
                        ForEach(CostMethod.allCases, id: \.self) { method in
                            Text(method.title).tag(method)
                        }
                    } label: {
                        HelpLabel("Cost Method", topic: .costMethod)
                    }
                    LabeledContent {
                        PercentField("Risk-Free Rate", fraction: $settings.riskFreeRate)
                            .frame(width: 90)
                    } label: {
                        HelpLabel("Risk-Free Rate", topic: .riskFreeRate)
                    }
                } header: {
                    Text("Calculation")
                } footer: {
                    Text("The cost method determines realized gains when selling part of a position. The risk-free rate is used for the Sharpe ratio.")
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
                    HelpLabel("Benchmarks", topic: .benchmark)
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

/// The shell's built-in export (used until the Import feature provides the full export sheet):
/// a readable JSON copy of the portfolio.
struct BasicExportSheet: View {
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Export").font(.title3.weight(.semibold))
            Text("Save a readable JSON copy of this portfolio. It contains everything — securities, quotes, accounts and all transactions — and can be opened by Kontor or processed with other tools.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { store.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Export as JSON…") {
                    store.dismissSheet()
                    ShellContext.exportJSON(store)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.xxl)
        .frame(width: 420)
    }
}

/// Result of Portfolio ▸ Check Consistency (⇧⌘K): the engine's findings grouped by severity. Each
/// row leads to the transaction, security or account it is about.
struct ConsistencyReportSheet: View {
    @Environment(PortfolioStore.self) private var store
    @State private var issues: [ConsistencyIssue]?
    @State private var filter: ConsistencyIssue.Severity?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: summarySymbol)
                    .font(.title)
                    .foregroundStyle(summaryColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    HStack(spacing: DS.Spacing.xs) {
                        Text("Consistency Check").font(.headline)
                        HelpButton(.consistencyCheck)
                    }
                    Text(summary).foregroundStyle(.secondary).numeric()
                }
                Spacer()
                if let issues, Set(issues.map(\.severity)).count > 1 {
                    Picker("Show", selection: $filter) {
                        Text("All").tag(ConsistencyIssue.Severity?.none)
                        ForEach(severities(in: issues), id: \.self) { severity in
                            Text(severity.pluralTitle).tag(ConsistencyIssue.Severity?.some(severity))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(DS.Spacing.l)
            Divider()
            Group {
                if let issues, !issues.isEmpty {
                    List {
                        ForEach(severities(in: issues).filter { filter == nil || filter == $0 }, id: \.self) { severity in
                            let group = issues.filter { $0.severity == severity }
                            Section {
                                ForEach(group) { issue in row(issue) }
                            } header: {
                                Text("\(severity.pluralTitle) (\(Fmt.integer(group.count)))")
                            }
                        }
                    }
                    .listStyle(.inset)
                } else if issues != nil {
                    EmptyState("Everything Adds Up", symbol: "checkmark.seal", message: "No impossible positions, broken references, currency mismatches or stale quotes were found.")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 380)
            Divider()
            HStack {
                Text("Nothing is changed automatically. “Show” takes you to the entry so you can fix it; every edit can be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Spacing.l)
                Button("Done") { store.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 680)
        .task(id: store.revision) {
            if let result = try? await store.consistencyIssues() { issues = result }
        }
    }

    private func row(_ issue: ConsistencyIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: issue.severity.symbol)
                .foregroundStyle(issue.severity.color)
                .accessibilityLabel(issue.severity.title)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(issue.title).font(.body.weight(.medium))
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let context = context(of: issue) {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .numeric()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Spacing.s)
            if let route = issue.route {
                Button("Show") {
                    store.dismissSheet()
                    store.navigate(to: route)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Show: \(issue.message)")
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    /// Names of the entities an issue is about, so the row can be understood without leaving the sheet.
    private func context(of issue: ConsistencyIssue) -> String? {
        var parts: [String] = []
        if let name = store.security(issue.securityID)?.name { parts.append(name) }
        if let name = store.depot(issue.depotID)?.name { parts.append(name) }
        if let name = store.account(issue.accountID)?.name { parts.append(name) }
        if let day = issue.day { parts.append(Fmt.day(day, style: .medium)) }
        if issue.transactionIDs.count > 1 { parts.append("\(issue.transactionIDs.count) transactions") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func severities(in issues: [ConsistencyIssue]) -> [ConsistencyIssue.Severity] {
        ConsistencyIssue.Severity.allCases.reversed().filter { severity in issues.contains { $0.severity == severity } }
    }

    private func count(_ severity: ConsistencyIssue.Severity) -> Int { issues?.count { $0.severity == severity } ?? 0 }

    private var summary: String {
        guard let issues else { return "Checking…" }
        if issues.isEmpty { return "No problems found." }
        func part(_ n: Int, _ noun: String) -> String? { n > 0 ? "\(Fmt.integer(n)) \(noun)\(n == 1 ? "" : "s")" : nil }
        return [part(count(.error), "error"), part(count(.warning), "warning"), part(count(.info), "hint")].compactMap { $0 }.joined(separator: ", ")
    }
    private var summarySymbol: String {
        guard let issues else { return "hourglass" }
        if issues.isEmpty { return "checkmark.seal.fill" }
        return (count(.error) > 0 ? ConsistencyIssue.Severity.error : count(.warning) > 0 ? .warning : .info).symbol
    }
    private var summaryColor: Color {
        guard let issues else { return .secondary }
        if issues.isEmpty { return DS.Colors.green }
        return (count(.error) > 0 ? ConsistencyIssue.Severity.error : count(.warning) > 0 ? .warning : .info).color
    }
}
