import SwiftUI
import KontorInterchange
import KontorUI

/// What a Portfolio Performance file contains, what could not be carried over exactly, and the
/// choice of where it goes: a new portfolio window, or into the open one — as its content while
/// nothing has been recorded there yet (`PortfolioFile.isUntouched`), merged otherwise. Before a
/// merge the sheet lists which securities and accounts were recognised as existing ones.
///
/// Launch state (screenshots): `notes=collapsed`, `matches=expanded|collapsed`.
struct PortfolioPerformanceSummary: View {
    let result: PortfolioPerformanceResult
    var chooseAnother: () -> Void

    @Environment(PortfolioStore.self) private var store
    @State private var isWorking = false
    @State private var showsNotes = true
    @State private var showsMatches = false

    private var counts: ImportReport.Counts { result.report.counts }
    /// Nothing recorded in the open portfolio yet: the file may simply become its content.
    private var isUntouched: Bool { store.file.isUntouched }
    private var mergePreview: PortfolioMerge.Summary? { isUntouched ? nil : result.mergePreview }

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
                    mergeLine
                    matches
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
        .onAppear {
            showsNotes = store.launchValue("notes") != "collapsed"
            // Matches found by anything weaker than an ISIN deserve a look before merging.
            let weak = result.mergePreview?.securityMatches.contains { $0.rule != .isin } == true
            showsMatches = store.launchValue("matches").map { $0 == "expanded" } ?? weak
        }
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
            tile("Securities", counts.securities, footnote: ImportText.count(counts.prices, "quote", "quotes"))
            tile("Transactions", counts.transactions, footnote: dateRange)
            tile("Cash Accounts", counts.accounts, footnote: currencies)
            tile("Depots", counts.depots, footnote: nil)
            tile("Taxonomies", counts.taxonomies, footnote: counts.taxonomies == 0 ? nil : ImportText.count(counts.classifications, "classification", "classifications"))
            tile("Savings Plans", counts.plans, footnote: nil)
            tile("Watchlists", counts.watchlists, footnote: nil)
            textTile("Base Currency", result.file.settings.baseCurrency, footnote: Currencies.name(result.file.settings.baseCurrency))
        }
    }

    private var dateRange: String? {
        guard let first = result.firstDay, let last = result.lastDay else { return nil }
        return ImportText.months(first, last)
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

    // MARK: Merge preview

    /// What "Merge into This Portfolio" would do, in words.
    @ViewBuilder private var mergeLine: some View {
        if let preview = mergePreview {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Merging into this portfolio")
                    .font(.kontorCaption)
                    .foregroundStyle(.secondary)
                Text(preview.changesNothing
                    ? "Everything in this file is already here — merging would change nothing."
                    : "Adds " + Self.describe(preview) + ".")
                    .font(.callout)
                    .numeric()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Matches

    /// Which incoming securities, accounts and depots a merge treats as ones the portfolio already
    /// has — the only chance to catch a wrong match before it happens.
    @ViewBuilder private var matches: some View {
        if let preview = mergePreview, preview.matchedSecurities + preview.matchedAccounts + preview.matchedDepots > 0 {
            let weak = preview.securityMatches.count { $0.rule != .isin }
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Button {
                    showsMatches.toggle()
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .rotationEffect(.degrees(showsMatches ? 90 : 0))
                        Text("Matched to what you already have (\(Fmt.integer(preview.matchedSecurities + preview.matchedAccounts + preview.matchedDepots)))")
                            .font(.headline)
                        if weak > 0 {
                            Label("\(Fmt.integer(weak)) without ISIN", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(DS.Colors.warning)
                                .help("Matched by ticker, WKN or name only — check that these really are the same securities")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(showsMatches ? "Collapses the list" : "Expands the list")
                if showsMatches {
                    Text("Merging books the file's transactions on these and adds only the quotes they are missing. A security is matched within its currency only; anything else in the file is added as new.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        let shown = preview.securityMatches.prefix(Self.shownMatches)
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, match in
                            if index > 0 { Divider() }
                            matchRow(match)
                        }
                        if preview.securityMatches.count > shown.count {
                            Divider()
                            matchLine("ellipsis", "and \(ImportText.count(preview.securityMatches.count - shown.count, "more security", "more securities")), all with the same ISIN and currency")
                        }
                        if !preview.accountMatches.isEmpty {
                            if !preview.securityMatches.isEmpty { Divider() }
                            matchLine("banknote", "Cash \(preview.accountMatches.count == 1 ? "account" : "accounts") with the same name and currency: " + preview.accountMatches.formatted(.list(type: .and)))
                        }
                        if !preview.depotMatches.isEmpty {
                            if !(preview.securityMatches.isEmpty && preview.accountMatches.isEmpty) { Divider() }
                            matchLine("briefcase", "\(preview.depotMatches.count == 1 ? "Depot" : "Depots") with the same name: " + preview.depotMatches.formatted(.list(type: .and)))
                        }
                    }
                    .cardBackground(radius: DS.Radius.control)
                }
            }
        }
    }

    /// Weak matches come first (the list is sorted); ISIN matches beyond this are summed up.
    private static let shownMatches = 40

    private func matchRow(_ match: PortfolioMerge.SecurityMatch) -> some View {
        let isWeak = match.rule != .isin
        return HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: isWeak ? "exclamationmark.triangle.fill" : "equal.circle")
                .foregroundStyle(isWeak ? AnyShapeStyle(DS.Colors.warning) : AnyShapeStyle(.secondary))
                .imageScale(.small)
                .accessibilityLabel(isWeak ? "Check this match" : "Match")
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                if PortfolioMerge.sameName(match.incomingName, match.existingName) {
                    Text(match.existingName)
                } else {
                    Text("\(match.incomingName)  →  \(match.existingName)")
                }
                Text("\(match.rule.title) · \(match.rule == .name ? match.currency : "\(match.identifier) · \(match.currency)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numeric()
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .help("“\(match.incomingName)” in the file is treated as “\(match.existingName)” in this portfolio (\(match.rule.title), \(match.currency))")
    }

    private func matchLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
    }

    // MARK: Warnings

    /// Says that exchange rates are still to come (they are not part of the file).
    @ViewBuilder private var ratesNotice: some View {
        let currencies = result.currenciesWithoutRates
        if !currencies.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Exchange rates for \(currencies.formatted(.list(type: .and))) are not part of the file")
                        .fontWeight(.medium)
                    Text("Portfolio Performance downloads them itself. Kontor does the same right after the import; until they have arrived — or while you are offline — amounts in \(currencies.count == 1 ? "this currency" : "these currencies") count as zero.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "arrow.left.arrow.right.circle.fill").foregroundStyle(DS.Colors.warning)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var findings: some View {
        let warnings = result.warnings, notes = result.notes
        ratesNotice
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
            if isUntouched {
                Button("Open as New Portfolio") { openAsNew() }
                Button("Import into This Portfolio") { importHere() }
                    .keyboardShortcut(.defaultAction)
                    .help("The file becomes the content of this portfolio, which keeps its name")
            } else {
                Button("Merge into This Portfolio") { merge() }
                    .disabled(mergePreview?.changesNothing == true)
                    .help("Adds what is new; securities, accounts and transactions that already exist are not duplicated")
                Button("Open as New Portfolio") { openAsNew() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.l)
    }

    private var footnote: String {
        if isUntouched {
            return "Nothing is recorded in this portfolio yet, so the file can simply become its content. Undo takes it back."
        }
        if mergePreview?.changesNothing == true { return "Everything in this file is already in the open portfolio." }
        return "Merging adds what is new and is one undo step. The file itself is not touched."
    }

    /// "12 securities, 240 transactions and 1 depot, plus 24 assignments in 2 existing taxonomies;
    /// 18 transactions already exist and are skipped"
    nonisolated static func describe(_ summary: PortfolioMerge.Summary) -> String {
        func part(_ count: Int, _ singular: String, _ plural: String) -> String? {
            count > 0 ? ImportText.count(count, singular, plural) : nil
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
        if summary.mergedTaxonomies > 0 {
            let target = ImportText.count(summary.mergedTaxonomies, "existing taxonomy", "existing taxonomies")
            text += summary.addedAssignments > 0
                ? ", plus \(ImportText.count(summary.addedAssignments, "assignment", "assignments")) in \(target)"
                : ", plus new classifications in \(target)"
        }
        var skipped: [String] = []
        if summary.skippedTransactions > 0 {
            skipped.append("\(Fmt.integer(summary.skippedTransactions)) \(summary.skippedTransactions == 1 ? "transaction already exists and is" : "transactions already exist and are") skipped")
        }
        if summary.skippedTaxonomies > 0 {
            skipped.append("\(Fmt.integer(summary.skippedTaxonomies)) \(summary.skippedTaxonomies == 1 ? "taxonomy already has" : "taxonomies already have") everything the file classifies")
        }
        if !skipped.isEmpty { text += "; " + skipped.joined(separator: "; ") }
        return text
    }

    /// "Import into This Portfolio": the file becomes the content of the (untouched) document, as
    /// one undo step. Also driven by the app's self-test.
    @discardableResult
    static func importHere(_ result: PortfolioPerformanceResult, in store: PortfolioStore) -> Bool {
        let imported = result.file
        let changed = store.mutate("Import Portfolio Performance File") { file in
            file = PortfolioReplace.apply(imported, to: file)
        }
        if changed { fetchExchangeRatesIfNeeded(in: store) }
        return changed
    }

    /// Portfolio Performance files carry no exchange-rate history (the app downloads it itself).
    /// Without rates everything foreign would be valued at zero, so a portfolio with more than one
    /// currency fetches them right after the import, whatever its quote feeds.
    static func fetchExchangeRatesIfNeeded(in store: PortfolioStore) {
        guard store.needsExchangeRates, !store.isUpdatingQuotes else { return }
        store.updateQuotes(interactive: false)
    }

    private func importHere() {
        let changed = Self.importHere(result, in: store)
        store.dismissSheet()
        if changed {
            store.navigate(to: .dashboard)
            store.toast(
                "Imported \(ImportText.count(counts.transactions, "transaction", "transactions")) and \(ImportText.count(counts.securities, "security", "securities"))",
                message: "From “\(result.fileName)”. Undo with ⌘Z.", style: .success)
        }
    }

    private func merge() {
        let incoming = result.file
        let source = result.tag.source
        let fileName = result.fileName
        isWorking = true
        Task {
            // The merge is computed off the main actor from a snapshot. If the portfolio changes
            // meanwhile (an automatic quote update, say), it is computed again from the new state.
            for _ in 0..<3 {
                let current = store.file
                let revision = store.revision
                let merged = await store.whileBusy {
                    await Background.run { PortfolioMerge.merge(incoming, into: current, recordAs: source) }
                }
                guard store.revision == revision else { continue }
                isWorking = false
                let changed = store.mutate("Merge Portfolio Performance File") { $0 = merged.file }
                if changed { Self.fetchExchangeRatesIfNeeded(in: store) }
                store.dismissSheet()
                if changed {
                    store.toast("Merged “\(fileName)”", message: "Added " + Self.describe(merged.summary) + ".", style: .success)
                } else {
                    store.toast("Nothing to merge", message: "Everything in “\(fileName)” is already here.", style: .info)
                }
                return
            }
            isWorking = false
            store.toast("Merge canceled", message: "The portfolio kept changing in the meantime. Please try again.", style: .warning)
        }
    }

    private func openAsNew() {
        do {
            try ImportPanels.openAsNewDocument(result.file, name: result.file.name)
            store.dismissSheet()
            // A document that was only created to receive this import (Welcome ▸ Import, a file
            // opened without a window) would stay behind as an empty untitled window.
            if isUntouched, store.undoManager?.canUndo != true, store.undoManager?.canRedo != true {
                store.services.closeDocument?()
            }
        } catch {
            store.show(Toast("The new portfolio could not be opened", message: error.localizedDescription, style: .error, duration: 6))
        }
    }
}
