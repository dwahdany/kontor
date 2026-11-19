import SwiftUI
import KontorInterchange
import KontorUI

/// What a Portfolio Performance file contains, what could not be carried over exactly, and the
/// choice of where it goes: a new portfolio window, or merged into the open one.
struct PortfolioPerformanceSummary: View {
    let result: PortfolioPerformanceResult
    var chooseAnother: () -> Void

    @Environment(PortfolioStore.self) private var store
    @State private var isWorking = false
    @State private var showsNotes = true

    private var counts: ImportReport.Counts { result.report.counts }
    private var isBlank: Bool { store.file.isBlank }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle(symbol: "shippingbox", title: "Portfolio Performance File", subtitle: subtitle) {
                Button("Choose Another…", action: chooseAnother)
                    .buttonStyle(.link)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    contents
                    ledgerLine
                    findings
                }
                .padding(DS.Spacing.xl)
            }
            .frame(height: 430)
            Divider()
            footer
        }
        .frame(width: 720)
        .disabled(isWorking)
        .onAppear { showsNotes = store.launchValue("notes") != "collapsed" }
    }

    private var subtitle: String {
        var parts = [result.fileName]
        if let version = result.report.sourceVersion { parts.append("format version \(version)") }
        parts.append(ByteText.string(result.byteCount))
        return parts.joined(separator: " · ")
    }

    // MARK: Contents

    private var contents: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.s), count: 4), spacing: DS.Spacing.s) {
            tile("Securities", counts.securities, footnote: "\(Fmt.integer(counts.prices)) \(counts.prices == 1 ? "quote" : "quotes")")
            tile("Transactions", counts.transactions, footnote: dateRange)
            tile("Cash Accounts", counts.accounts, footnote: currencies)
            tile("Depots", counts.depots, footnote: nil)
            tile("Taxonomies", counts.taxonomies, footnote: counts.taxonomies == 0 ? nil : "\(Fmt.integer(counts.classifications)) classifications")
            tile("Savings Plans", counts.plans, footnote: nil)
            tile("Watchlists", counts.watchlists, footnote: nil)
            textTile("Base Currency", result.file.settings.baseCurrency, footnote: Currencies.name(result.file.settings.baseCurrency))
        }
    }

    private var dateRange: String? {
        guard let first = result.firstDay, let last = result.lastDay else { return nil }
        return "\(Fmt.day(first, style: .shortMonthYear)) – \(Fmt.day(last, style: .shortMonthYear))"
    }

    private var currencies: String? {
        let codes = Array(Set(result.file.accounts.map(\.currency))).sorted()
        return codes.isEmpty ? nil : codes.prefix(4).joined(separator: ", ") + (codes.count > 4 ? "…" : "")
    }

    private func tile(_ label: String, _ value: Int, footnote: String?) -> some View {
        textTile(label, Fmt.integer(value), footnote: footnote, isDimmed: value == 0)
    }

    private func textTile(_ label: String, _ value: String, footnote: String?, isDimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(label)
                .font(.kontorCaption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.kontorValue)
                .foregroundStyle(isDimmed ? .tertiary : .primary)
            Text(footnote ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .numeric()
                .lineLimit(1)
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(radius: DS.Radius.control)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var ledgerLine: some View {
        if !result.kinds.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Transactions by type")
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                Text(result.kinds.map { "\($0.kind.title) \(Fmt.integer($0.count))" }.joined(separator: "  ·  "))
                    .font(.callout)
                    .numeric()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Warnings

    @ViewBuilder private var findings: some View {
        let warnings = result.warnings, notes = result.notes
        if warnings.isEmpty {
            Label {
                Text(notes.isEmpty ? "Everything was converted exactly." : "All portfolio data was converted exactly.")
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.Colors.green)
            }
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Label {
                    Text("\(Fmt.integer(warnings.count)) \(warnings.count == 1 ? "thing was" : "things were") approximated or left out")
                        .font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
                }
                Text("The import still works. Check these after importing — the original file is not touched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(warnings.enumerated()), id: \.element.id) { index, warning in
                        if index > 0 { Divider() }
                        row(warning)
                    }
                }
                .cardBackground(radius: DS.Radius.control)
            }
        }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Button {
                    showsNotes.toggle()
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .rotationEffect(.degrees(showsNotes ? 90 : 0))
                        Text("Left out on purpose (\(Fmt.integer(notes.count)))")
                            .font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(showsNotes ? "Collapses the list" : "Expands the list")
                if showsNotes {
                    Text("Parts of a Portfolio Performance file that have no place in Kontor, such as its dashboards and table layouts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            if index > 0 { Divider() }
                            row(note)
                        }
                    }
                    .cardBackground(radius: DS.Radius.control)
                }
            }
        }
    }

    private func row(_ warning: ImportWarning) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: warning.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(warning.severity == .warning ? AnyShapeStyle(DS.Colors.warning) : AnyShapeStyle(.secondary))
                .imageScale(.small)
                .accessibilityLabel(warning.severity == .warning ? "Warning" : "Note")
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(warning.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !warning.examples.isEmpty {
                    Text("For example: " + warning.examples.joined(separator: "; "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: DS.Spacing.s)
            if warning.count > 1 {
                Text("\(Fmt.integer(warning.count))×")
                    .font(.callout)
                    .numeric()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(warning.count) times")
            }
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
    }

    // MARK: Actions

    private var footer: some View {
        HStack(alignment: .center, spacing: DS.Spacing.m) {
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .numeric()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.l)
            if isWorking { ProgressView().controlSize(.small) }
            Button("Cancel") { store.dismissSheet() }
                .keyboardShortcut(.cancelAction)
            if isBlank {
                Button("Open as New Portfolio") { openAsNew() }
                Button("Import into This Portfolio") { importHere() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Merge into This Portfolio") { merge() }
                    .disabled(result.mergePreview?.changesNothing == true)
                    .help("Adds what is new; securities, accounts and transactions that already exist are not duplicated")
                Button("Open as New Portfolio") { openAsNew() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.l)
    }

    private var footnote: String {
        guard !isBlank, let preview = result.mergePreview else {
            return "This portfolio is empty, so the file can simply become its content. Undo takes it back."
        }
        if preview.changesNothing { return "Everything in this file is already in the open portfolio — merging would change nothing." }
        return "Merging adds " + Self.describe(preview) + ". One undo step."
    }

    /// "12 securities, 240 transactions and 1 depot; 18 transactions already exist and are skipped"
    static func describe(_ summary: PortfolioMerge.Summary) -> String {
        func part(_ count: Int, _ singular: String, _ plural: String) -> String? {
            count > 0 ? "\(Fmt.integer(count)) \(count == 1 ? singular : plural)" : nil
        }
        let added = [
            part(summary.addedSecurities, "security", "securities"),
            part(summary.addedAccounts, "cash account", "cash accounts"),
            part(summary.addedDepots, "depot", "depots"),
            part(summary.addedTransactions, "transaction", "transactions"),
            part(summary.addedTaxonomies, "taxonomy", "taxonomies"),
            part(summary.addedPlans, "savings plan", "savings plans"),
            part(summary.addedWatchlists, "watchlist", "watchlists"),
        ].compactMap { $0 }
        var text = added.isEmpty
            ? (part(summary.addedPrices, "quote", "quotes") ?? "nothing")
            : added.formatted(.list(type: .and))
        if summary.skippedTransactions > 0 {
            text += "; \(Fmt.integer(summary.skippedTransactions)) \(summary.skippedTransactions == 1 ? "transaction already exists and is" : "transactions already exist and are") skipped"
        }
        return text
    }

    private func importHere() {
        let imported = result.file
        let existingName = store.file.name
        let changed = store.mutate("Import Portfolio Performance File") { file in
            file = imported
            if !existingName.isEmpty { file.name = existingName }
        }
        store.dismissSheet()
        if changed {
            store.navigate(to: .dashboard)
            store.toast(
                "Imported \(Fmt.integer(counts.transactions)) transactions and \(Fmt.integer(counts.securities)) securities",
                message: "From “\(result.fileName)”. Undo with ⌘Z.", style: .success)
        }
    }

    private func merge() {
        let incoming = result.file
        let current = store.file
        let revision = store.revision
        isWorking = true
        Task {
            let merged = await store.whileBusy { await Background.run { PortfolioMerge.merge(incoming, into: current) } }
            isWorking = false
            guard store.revision == revision else { return }
            let changed = store.mutate("Merge Portfolio Performance File") { $0 = merged.file }
            store.dismissSheet()
            if changed {
                store.toast("Merged “\(result.fileName)”", message: "Added " + Self.describe(merged.summary) + ".", style: .success)
            } else {
                store.toast("Nothing to merge", message: "Everything in “\(result.fileName)” is already here.", style: .info)
            }
        }
    }

    private func openAsNew() {
        do {
            try ImportPanels.openAsNewDocument(result.file, name: result.file.name)
            store.dismissSheet()
        } catch {
            store.show(Toast("The new portfolio could not be opened", message: error.localizedDescription, style: .error, duration: 6))
        }
    }
}
