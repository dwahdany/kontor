import SwiftUI
import KontorInterchange
import KontorModel
import KontorUI

/// The Import screen: the hub for getting data in and out.
///
/// * A drop zone (the whole screen accepts file drops) and one card per way in: Portfolio
///   Performance, transactions CSV, quotes CSV, securities CSV.
/// * Recent imports, reconstructed from the ledger's source tags — show them or take one back.
/// * Every export format, one click away.
///
/// The work happens in sheets this feature owns: `.importFile(url)` (`ImportSheet`) and `.export`
/// (`ExportSheet`). The screen ignores scope and period (it lists document-level actions).
///
/// Launch state (`--state key=value`):
///
/// | key | values | effect |
/// |---|---|---|
/// | `drop` | `on` | shows the drop zone in its "release to import" state |
/// | `step` | `file` `content` `mapping` `review` `done` | CSV wizard step (with `--sheet import:<file.csv>`); `done` performs the import on the in-memory document |
/// | `target` | `transactions` `quotes` `securities` | what the CSV contains (default: guessed from the titles) |
/// | `filter` | `ok` `warning` `error` `duplicate` | status filter of the review step |
/// | `line` | a file line number | review step: highlights that row and shows its full message |
/// | `remembered` | `on` | wizard as on the second import of a known layout (mapping remembered, opens at review) |
/// | `notes` | `collapsed` | Portfolio Performance summary with the "left out on purpose" list folded |
/// | `format` | `transactions` `holdings` `quotes` `securities` `pp` `json` | export sheet format (with `--sheet export`) |
/// | `preset` | `international` `german` | CSV notation of the export sheet |
public struct ImportScreen: View {
    @Environment(PortfolioStore.self) private var store
    @State private var recent = Loadable<[RecentImport]>()
    @State private var isDropTargeted = false
    @State private var pinsDropState = false

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                Group {
                    if proxy.size.width >= 1_040 {
                        HStack(alignment: .top, spacing: DS.Spacing.l) {
                            VStack(spacing: DS.Spacing.l) { intake }
                                .frame(maxWidth: .infinity)
                            VStack(spacing: DS.Spacing.l) { outflow }
                                .frame(width: min(440, proxy.size.width * 0.38))
                        }
                    } else {
                        VStack(spacing: DS.Spacing.l) {
                            intake
                            outflow
                        }
                    }
                }
                .frame(maxWidth: 1_360)
                .frame(maxWidth: .infinity)
                .screenPadding()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            store.present(.importFile(url))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .ledgerTask($recent, id: "import.recent") { ledger in RecentImport.list(ledger.transactions) }
        .onAppear { pinsDropState = store.launchValue("drop") == "on" }
    }

    // MARK: Getting data in

    @ViewBuilder private var intake: some View {
        if store.file.isBlank {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Bring your portfolio to Kontor")
                    .font(.title2.weight(.semibold))
                Text("Coming from Portfolio Performance? Drop your file and everything moves over — securities, quotes, accounts, every transaction. Have statements from a broker? Drop the CSV. Or start fresh and record a first transaction.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        DropZone(isTargeted: isDropTargeted || pinsDropState) { ImportFeature.chooseFile(store, target: nil) }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: DS.Spacing.l, alignment: .top)], spacing: DS.Spacing.l) {
            PathCard(
                symbol: "shippingbox", title: "Portfolio Performance",
                text: "Move a whole portfolio: securities with their quotes, accounts, all transactions, taxonomies and savings plans. Open it as a new portfolio or merge it into this one.",
                detail: "Use an .xml file. For password-protected or binary files choose File › Save As › XML in Portfolio Performance first."
            ) {
                Button("Choose File…") { ImportFeature.chooseFile(store, target: nil) }
            }
            PathCard(
                symbol: "tablecells", title: "Transactions from a Broker or Bank",
                text: "Any CSV export. Kontor detects delimiter, encoding, number and date format, matches the columns and shows every row before it is imported.",
                detail: "Duplicates are recognized, and the column layout is remembered for the next file."
            ) {
                Button("Choose CSV…") { ImportFeature.chooseFile(store, target: .transactions) }
            }
            PathCard(
                symbol: "chart.line.uptrend.xyaxis", title: "Quotes",
                text: "Historical prices for one security — a date and a price per row, for example a download from a quote website.",
                detail: store.file.securities.isEmpty ? "Add the security first; then import its history." : "Existing days are kept; new days are added."
            ) {
                Button("Choose CSV…") { ImportFeature.chooseFile(store, target: .quotes) }
                    .disabled(store.file.securities.isEmpty)
            }
            PathCard(
                symbol: "building.columns", title: "Securities",
                text: "A list of securities with name, ISIN, WKN, ticker and currency — to set up a watchlist or prepare a portfolio.",
                detail: "Securities you already have are skipped."
            ) {
                Button("Choose CSV…") { ImportFeature.chooseFile(store, target: .securities) }
            }
        }

        if store.file.isBlank {
            HStack(spacing: DS.Spacing.s) {
                Text("Starting from scratch?")
                    .foregroundStyle(.secondary)
                Button("Record a Transaction") { store.present(.newTransaction) }
                    .buttonStyle(.link)
                Spacer()
            }
            .font(.callout)
        }
    }

    // MARK: Recent imports and export

    @ViewBuilder private var outflow: some View {
        Card("Recent Imports", symbol: "clock.arrow.circlepath") {
            if let imports = recent.value, !imports.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(imports.prefix(8).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        RecentImportRow(entry: entry)
                    }
                    if imports.count > 8 {
                        Divider()
                        Text("and \(Fmt.integer(imports.count - 8)) earlier \(imports.count - 8 == 1 ? "import" : "imports")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.Spacing.s)
                    }
                }
                .opacity(recent.isRefreshing ? 0.6 : 1)
            } else if recent.isInitialLoad {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Nothing imported yet. Each import is listed here, so you can look at what came in — or take it back in one step.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !store.file.isBlank {
            Card("Export", symbol: "square.and.arrow.up") {
                VStack(spacing: 0) {
                    ForEach(Array(ExportFormat.allCases.enumerated()), id: \.element) { index, format in
                        if index > 0 { Divider() }
                        ExportRow(format: format)
                    }
                }
            } accessory: {
                Button("Options…") { store.present(.export) }
                    .buttonStyle(.link)
                    .help("Open the export sheet (⇧⌘E)")
            }
        }
    }
}

/// One way of getting data in.
private struct PathCard<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
            }
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.xs)
            HStack { actions }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
        .cardBackground()
        .accessibilityElement(children: .contain)
    }
}

private struct RecentImportRow: View {
    let entry: RecentImport
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: entry.tag.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(entry.tag.fileName ?? "\(entry.tag.kind.title) import")
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .numeric()
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.s)
            Button("Show") { store.navigate(to: .transaction(entry.firstTransactionID)) }
                .buttonStyle(.link)
                .help("Opens Transactions at the first entry of this import. Filter by “\(entry.source)” to see all of them.")
                .accessibilityLabel("Show the transactions imported from \(entry.tag.fileName ?? "this import")")
            Menu {
                Button("Show in Transactions") { store.navigate(to: .transaction(entry.firstTransactionID)) }
                Button("Copy Source Tag") { Pasteboard.copy(entry.source) }
                Divider()
                Button("Remove These \(Fmt.integer(entry.count)) Transactions", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .padding(.vertical, DS.Spacing.s)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let day = entry.tag.day { parts.append(Fmt.relativeDay(day, today: store.today)) }
        parts.append("\(Fmt.integer(entry.count)) \(entry.count == 1 ? "transaction" : "transactions")")
        parts.append(entry.firstDay == entry.lastDay
            ? Fmt.day(entry.firstDay, style: .medium)
            : "\(Fmt.day(entry.firstDay, style: .shortMonthYear)) – \(Fmt.day(entry.lastDay, style: .shortMonthYear))")
        return parts.joined(separator: " · ")
    }

    private func remove() {
        let source = entry.source
        let changed = store.mutate("Remove Imported Transactions") { file in
            file.transactions.removeAll { $0.source == source }
        }
        if changed {
            store.toast("Removed \(Fmt.integer(entry.count)) imported \(entry.count == 1 ? "transaction" : "transactions")", message: "Undo with ⌘Z.", style: .info)
        }
    }
}

private struct ExportRow: View {
    let format: ExportFormat
    @Environment(PortfolioStore.self) private var store

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: format.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(format.title).fontWeight(.medium)
                Text(format.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.s)
            Button("Export…") {
                store.present(.custom(id: ImportFeature.exportSheetID, payload: ["format": format.rawValue]))
            }
            .accessibilityLabel("Export \(format.title)")
        }
        .padding(.vertical, DS.Spacing.s)
    }
}
