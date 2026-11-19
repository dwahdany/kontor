import SwiftUI
import KontorInterchange
import KontorUI

/// Step 4: the proposal as a table — status and reason per row, filters by status, checkboxes for
/// what is imported (errors cannot be, duplicates are off by default), and what will be created.
///
/// Keyboard: arrows move, Space ticks/unticks the highlighted rows, ⌘A highlights all, ⌘C copies
/// them as TSV, Return imports.
struct CSVReviewStep: View {
    @Bindable var wizard: CSVWizard

    @Environment(PortfolioStore.self) private var store
    @State private var highlighted = Set<Int>()
    @State private var sortOrder = CSVReviewStep.fileOrder
    @State private var sorted: [ReviewRow] = []
    @State private var showsNewSecurities = false
    /// `--state line=<n>` (screenshots) has been applied.
    @State private var appliedLaunchLine = false

    private struct Query: Hashable {
        var version: Int
        var filter: ReviewStatus?
        var sortOrder: [KeyPathComparator<ReviewRow>]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let output = wizard.output {
                if output.rowCount == 0 {
                    EmptyState("No Data Rows", symbol: "tablecells", message: "The file has column titles but no rows to import. Go back to step 1 and check the format.") {
                        Button("Check the Format") { wizard.step = .file }
                    }
                } else if wizard.filter != nil, count(wizard.filter, output) == 0 {
                    EmptyState("No \(wizard.filter?.pluralTitle ?? "Rows")", symbol: "line.3.horizontal.decrease.circle", message: "No row of this file has that status.") {
                        Button("Show All Rows") { wizard.filter = nil }
                    }
                } else {
                    table(output)
                }
                explanation
                creations(output)
            } else {
                ProgressView("Reading the file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: Query(version: wizard.outputVersion, filter: wizard.filter, sortOrder: sortOrder)) {
            let order = sortOrder
            // The file's own order needs no sorting (`rows` reads the wizard's rows); anything else is
            // sorted off the main actor.
            if order != Self.fileOrder {
                let visible = wizard.visibleRows
                let result = await store.whileBusy { await Background.run { visible.sorted(using: order) } }
                if Task.isCancelled { return }
                sorted = result
            }
            highlightLaunchLine()
        }
    }

    private static let fileOrder = [KeyPathComparator(\ReviewRow.line)]

    /// The rows on display: the wizard's filtered rows in file order, or their sorted copy.
    private var rows: [ReviewRow] { sortOrder == Self.fileOrder ? wizard.visibleRows : sorted }

    private func highlightLaunchLine() {
        guard !appliedLaunchLine, let line = store.launchValue("line").flatMap(Int.init),
              let row = rows.first(where: { $0.line == line }) else { return }
        appliedLaunchLine = true
        highlighted = [row.id]
    }

    /// The full reason for the highlighted row's status — table cells truncate it.
    @ViewBuilder private var explanation: some View {
        if highlighted.count == 1, let id = highlighted.first, let row = rows.first(where: { $0.id == id }), !row.message.isEmpty {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Image(systemName: row.status.symbol)
                    .foregroundStyle(row.status.color)
                    .accessibilityLabel(row.status.title)
                Text("Line \(row.line): \(row.message)")
                    .font(.callout)
                    .numeric()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: DS.Spacing.s)
                if row.status == .error, wizard.output?.typeValues.contains(where: { $0.resolved == nil && $0.text == row.kind }) == true {
                    Button("Say What “\(row.kind)” Means…") { wizard.step = .mapping }
                        .buttonStyle(.link)
                        .font(.callout)
                        .fixedSize()
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
            .background(row.status.color.opacity(0.08))
        }
    }

    private func count(_ status: ReviewStatus?, _ output: CSVPipelineOutput) -> Int {
        switch status {
        case nil: output.rowCount
        case .ok: output.counts.ok
        case .warning: output.counts.warning
        case .error: output.counts.error
        case .duplicate: output.counts.duplicate
        }
    }

    // MARK: Filter bar

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.m) {
            if let output = wizard.output {
                Picker("Show", selection: $wizard.filter) {
                    Text("All \(Fmt.integer(output.rowCount))").tag(ReviewStatus?.none)
                    ForEach(ReviewStatus.allCases, id: \.self) { status in
                        Text("\(status.pluralTitle) \(Fmt.integer(count(status, output)))").tag(ReviewStatus?.some(status))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .numeric()
            }
            if wizard.usedMemory {
                Label("Known layout", systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("This column layout was imported before: the mapping, type synonyms and defaults from that import are applied.")
                Button("Change…") { wizard.step = .mapping }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Spacer(minLength: DS.Spacing.s)
            Text("\(Fmt.integer(wizard.importCount)) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .numeric()
            Menu("Select") {
                Button("Recommended (Ready and Warnings)") { wizard.selectRecommended() }
                Divider()
                Button("All Shown") { wizard.selectShown(true) }
                Button("None Shown") { wizard.selectShown(false) }
            }
            .fixedSize()
            .help("Choose which rows are imported")
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    // MARK: Table

    // Column widths: a Table lays its columns out at their ideal width (plus about 17 pt of cell
    // padding each) and scrolls sideways when they do not fit, so for the ten columns of a
    // transactions file the ideal widths must add up to at most ~775 pt in the 980 pt sheet
    // (which leaves room for an always-visible vertical scroller).
    private func table(_ output: CSVPipelineOutput) -> some View {
        Table(rows, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("") { row in
                Toggle("Import line \(row.line)", isOn: Binding(
                    get: { wizard.selection.contains(row.id) },
                    set: { _ in wizard.toggle([row.id]) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!row.isImportable)
            }
            .width(22)
            TableColumn("Status", value: \.statusRank) { row in
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: row.status.symbol)
                        .foregroundStyle(row.status.color)
                        .imageScale(.small)
                    Text(row.status.title)
                }
                .help(row.message)
            }
            .width(min: 76, ideal: 76, max: 90)
            TableColumn("Line", value: \.line) { row in
                Text("\(row.line)").numeric().foregroundStyle(.secondary)
            }
            .width(min: 28, ideal: 32, max: 50)
            .alignment(.trailing)
            if output.target != .securities {
                TableColumn("Date", value: \.dayValue) { row in
                    Text(row.day.map { Fmt.day($0) } ?? Fmt.missing).numeric()
                }
                .width(min: 72, ideal: 76, max: 90)
            }
            if output.target == .transactions {
                TableColumn("Type", value: \.kind) { row in
                    Text(row.kind.isEmpty ? Fmt.missing : row.kind).lineLimit(1)
                }
                .width(min: 60, ideal: 66, max: 130)
            }
            TableColumn("Security", value: \.security) { row in
                Text(row.security).lineLimit(1).help(row.security)
            }
            .width(min: 90, ideal: output.target == .transactions ? 104 : 220, max: 320)
            if output.target == .transactions {
                // Wide enough for fractional shares ("77,32214568"): a cut-off number is worse than none.
                TableColumn("Shares", value: \.sharesValue) { row in
                    Text(row.shares.map { Fmt.shares($0) } ?? "")
                        .numeric()
                        .lineLimit(1)
                        .help(row.shares.map { Fmt.shares($0) } ?? "")
                }
                .width(min: 64, ideal: 86, max: 120)
                .alignment(.trailing)
            }
            if output.target != .securities {
                TableColumn(output.target == .quotes ? "Quote" : "Amount", value: \.amountValue) { row in
                    Text(amountText(row, currency: output.quoteCurrency))
                        .numeric()
                        .lineLimit(1)
                        .foregroundStyle(row.status == .error ? .secondary : .primary)
                        .help(amountText(row, currency: output.quoteCurrency))
                }
                .width(min: 76, ideal: 92, max: 130)
                .alignment(.trailing)
            }
            if output.target != .quotes {
                TableColumn(output.target == .securities ? "Currency" : "Account", value: \.account) { row in
                    Text(row.account).lineLimit(1).help(row.account)
                }
                .width(min: 60, ideal: 80, max: 180)
            }
            TableColumn("Details", value: \.message) { row in
                Text(row.message.isEmpty ? row.note : row.message)
                    .lineLimit(1)
                    .foregroundStyle(row.message.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(row.status == .error ? DS.Colors.red : Color.primary))
                    .help(row.message.isEmpty ? row.note : row.message)
            }
            // No maximum: Details takes whatever width the other columns leave (more for quotes and securities).
            .width(min: 110, ideal: output.target == .transactions ? 132 : 260)
        }
        .onKeyPress(.space) {
            guard !highlighted.isEmpty else { return .ignored }
            wizard.toggle(highlighted)
            return .handled
        }
        .onCopyCommand { [NSItemProvider(object: tsv(highlighted, currency: output.quoteCurrency) as NSString)] }
        .contextMenu(forSelectionType: Int.self) { ids in
            Button("Import These Rows") { setSelected(ids, true) }
            Button("Leave These Rows Out") { setSelected(ids, false) }
            Divider()
            Button("Copy") { Pasteboard.copy(tsv(ids, currency: output.quoteCurrency)) }
        } primaryAction: { ids in
            wizard.toggle(ids)
        }
        .opacity(wizard.isComputing ? 0.6 : 1)
    }

    private func amountText(_ row: ReviewRow, currency: CurrencyCode?) -> String {
        if let amount = row.amount { return Fmt.money(amount) }
        if let price = row.price { return Fmt.price(price, currency: currency) }
        return ""
    }

    private func setSelected(_ ids: Set<Int>, _ selected: Bool) {
        let importable = Set(rows.lazy.filter { $0.isImportable && ids.contains($0.id) }.map(\.id))
        if selected {
            wizard.selection.formUnion(importable)
        } else {
            wizard.selection.subtract(importable)
        }
    }

    private func tsv(_ ids: Set<Int>, currency: CurrencyCode?) -> String {
        TSV.string(
            header: ["Line", "Status", "Date", "Type", "Security", "Shares", "Amount", "Currency", "Account", "Details"],
            rows: rows.filter { ids.contains($0.id) }.map { row in
                [
                    "\(row.line)", row.status.title, row.day?.iso ?? "", row.kind, row.security,
                    row.shares.map { TSV.number($0.decimalValue) } ?? "",
                    row.amount.map { TSV.number($0.decimalValue) } ?? row.price.map { TSV.number($0.decimalValue) } ?? "",
                    row.amount?.currency ?? currency ?? "", row.account, row.message.isEmpty ? row.note : row.message,
                ]
            })
    }

    // MARK: What will be created

    @ViewBuilder private func creations(_ output: CSVPipelineOutput) -> some View {
        let proposal = output.proposal
        if output.target == .transactions, !(proposal.newSecurities.isEmpty && proposal.newAccounts.isEmpty && proposal.newDepots.isEmpty) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(creationText(proposal))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(creationText(proposal))
                Spacer(minLength: DS.Spacing.s)
                if !proposal.newSecurities.isEmpty {
                    Button(proposal.newSecurities.count == 1 ? "Details…" : "Show All \(Fmt.integer(proposal.newSecurities.count))…") { showsNewSecurities = true }
                        .buttonStyle(.link)
                        .font(.callout)
                        .popover(isPresented: $showsNewSecurities, arrowEdge: .top) { newSecurities(proposal.newSecurities) }
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
        }
    }

    private func creationText(_ proposal: ImportProposal) -> String {
        var parts: [String] = []
        if !proposal.newSecurities.isEmpty {
            let names = proposal.newSecurities.prefix(3).map(\.name).joined(separator: ", ")
            let more = proposal.newSecurities.count - 3
            parts.append("\(Fmt.integer(proposal.newSecurities.count)) new \(proposal.newSecurities.count == 1 ? "security" : "securities"): \(names)" + (more > 0 ? " and \(Fmt.integer(more)) more" : ""))
        }
        if !proposal.newAccounts.isEmpty {
            parts.append("new cash \(proposal.newAccounts.count == 1 ? "account" : "accounts") " + proposal.newAccounts.map { "“\($0.name)”" }.joined(separator: ", "))
        }
        if !proposal.newDepots.isEmpty {
            parts.append("new \(proposal.newDepots.count == 1 ? "depot" : "depots") " + proposal.newDepots.map { "“\($0.name)”" }.joined(separator: ", "))
        }
        return "Will create " + parts.joined(separator: " · ")
    }

    private func newSecurities(_ securities: [Security]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Securities")
                .font(.headline)
                .padding(DS.Spacing.m)
            Divider()
            List(securities) { security in
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(security.name.isEmpty ? "Unnamed" : security.name)
                    Text(([security.isin, security.wkn, security.ticker].filter { !$0.isEmpty } + [security.currency]).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .numeric()
                }
            }
            .listStyle(.inset)
            Divider()
            Text("Created only if a row that uses them is imported. Add quotes or a quote feed in Securities afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Spacing.m)
        }
        .frame(width: 380, height: 340)
    }
}
