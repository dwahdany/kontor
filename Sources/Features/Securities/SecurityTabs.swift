import SwiftUI
import AppKit
import KontorUI
import KontorMarketData

/// The strip above a tab's table: actions on the left/right, on the bar material.
struct TabBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DS.Spacing.s) { content }
            .controlSize(.small)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// Footer line of a tab ("2,610 quotes · …").
struct TabFooter: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Text(text)
            Spacer(minLength: DS.Spacing.s)
            if let trailing { Text(trailing) }
        }
        .font(.callout)
        .numeric()
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Transactions

/// Which columns of the transactions table fit into the pane. `Table` lays its columns out at
/// their ideal widths and scrolls sideways when they do not fit — nothing tells the user that
/// there is more. So the least important columns go first and Amount always stays visible; the
/// footer names what is hidden.
struct TransactionColumns: Hashable {
    var showsCosts: Bool
    var showsPlace: Bool
    var showsNote: Bool
    /// Narrowest panes: tighter columns and the type as an icon.
    var isTight: Bool
    /// The Note column gets the room the other columns leave (in steps, so that resizing the
    /// window does not rebuild the table for every point).
    var noteWidth: CGFloat

    /// Thresholds: the sum of the ideal widths in the table plus about 17 pt of chrome per column.
    init(width: CGFloat) {
        showsNote = width >= 780
        showsPlace = width >= 730
        showsCosts = width >= 630
        isTight = width < 540
        noteWidth = showsNote ? max(40, ((width - 740) / 20).rounded(.down) * 20) : 0
    }

    /// "Depot and Note hidden — widen the window", nil when everything is shown.
    var hiddenHint: String? {
        let hidden = [showsCosts ? nil : "Costs", showsPlace ? nil : "Depot", showsNote ? nil : "Note"].compactMap { $0 }
        guard let last = hidden.last else { return nil }
        let names = hidden.count == 1 ? last : hidden.dropLast().joined(separator: ", ") + " and " + last
        return "\(names) hidden — widen the window"
    }
}

struct SecurityTransactionsTab: View {
    @Environment(PortfolioStore.self) private var store
    let securityID: UUID

    @State private var rows = Loadable<[SecurityTransactionRow]>()
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\SecurityTransactionRow.date, order: .reverse)]
    /// Width of the tab, known after the first layout pass.
    @State private var width: CGFloat?

    private struct Query: Hashable, Sendable {
        var securityID: UUID
        var sortOrder: [KeyPathComparator<SecurityTransactionRow>]
    }

    private var items: [SecurityTransactionRow] { rows.value ?? [] }

    var body: some View {
        let query = Query(securityID: securityID, sortOrder: sortOrder)
        VStack(spacing: 0) {
            TabBar {
                Button("Buy") { store.presentNewTransaction(.buy, securityID: securityID) }
                Button("Sell") { store.presentNewTransaction(.sell, securityID: securityID) }
                Button("Dividend") { store.presentNewTransaction(.dividend, securityID: securityID) }
                Menu("More") {
                    Button(Transaction.Kind.deliveryIn.title) { store.presentNewTransaction(.deliveryIn, securityID: securityID) }
                    Button(Transaction.Kind.deliveryOut.title) { store.presentNewTransaction(.deliveryOut, securityID: securityID) }
                    Button(Transaction.Kind.securityTransfer.title) { store.presentNewTransaction(.securityTransfer, securityID: securityID) }
                }
                .fixedSize()
                Spacer()
                Button("Edit…") { if let id = selection.first { store.present(.editTransaction(id)) } }
                    .disabled(selection.count != 1)
                    .fixedSize()
                Button {
                    if let id = selection.first { store.navigate(to: .transaction(id)) }
                } label: {
                    Label("Show in Transactions", systemImage: "arrow.up.forward.square").labelStyle(.iconOnly)
                }
                .disabled(selection.count != 1)
                .help("Show the selected transaction on the Transactions screen")
            }
            if items.isEmpty, rows.value != nil {
                EmptyState("No Transactions", symbol: "list.bullet.rectangle",
                           message: "Record a purchase to start a position in this security.") {
                    Button("Record a Purchase…") { store.presentNewTransaction(.buy, securityID: securityID) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let width, rows.value != nil {
                table(TransactionColumns(width: width))
            } else {
                // The table is created once the rows exist: populating an empty NSTableView with
                // thousands of rows in one update makes AppKit log a re-entrancy warning.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).loadingOverlay(rows.isInitialLoad)
            }
            TabFooter(text: "\(Fmt.integer(items.count)) transaction\(items.count == 1 ? "" : "s")"
                      + (selection.isEmpty ? "" : " · \(Fmt.integer(selection.count)) selected"),
                      trailing: width.flatMap { TransactionColumns(width: $0).hiddenHint })
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .ledgerTask($rows, id: "securities.transactions", variant: query) { ledger in
            SecurityTransactionRow.rows(ledger, securityID: query.securityID).sorted(using: query.sortOrder)
        }
        .onChange(of: securityID) { _, _ in selection = [] }
        .onChange(of: store.revision) { _, _ in
            // Deleted here or elsewhere, or gone through undo: a selected row that no longer exists
            // must not keep "1 selected" and Edit… alive.
            let valid = selection.filter { store.transaction($0) != nil }
            if valid.count != selection.count { selection = valid }
        }
    }

    private func delete(_ ids: Set<UUID>) {
        store.deleteTransactions(ids)
        selection.subtract(ids)
    }

    private func table(_ columns: TransactionColumns) -> some View {
        let tight = columns.isTight
        return Table(items, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.date) { Text(Fmt.day($0.date)).numeric() }
                .width(min: 70, ideal: tight ? 74 : 80, max: 110)
            TableColumn(tight ? "" : "Type", value: \.kindTitle) { row in
                if tight {
                    Image(systemName: row.kind.symbol).help(row.kindTitle).accessibilityLabel(row.kindTitle)
                } else {
                    Label(row.kindTitle, systemImage: row.kind.symbol).lineLimit(1)
                }
            }
            .width(min: tight ? 22 : 70, ideal: tight ? 24 : 88, max: 170)
            TableColumn("Shares", value: \.signedShares) { row in
                let shares = Shares(raw: row.signedShares == 0 ? row.shares.raw : row.signedShares)
                Text(row.shares.isZero ? "" : Fmt.shares(shares, signed: row.signedShares != 0, maxDecimals: 4))
                    .numeric()
                    .foregroundStyle(row.signedShares == 0 ? .secondary : .primary)
                    .help(row.shares.isZero ? "" : Fmt.shares(shares, signed: row.signedShares != 0))
            }
            .width(min: 56, ideal: tight ? 60 : 80, max: 140)
            .alignment(.trailing)
            TableColumn("Price", value: \.priceRaw) { row in
                // Derived per-share figures (a dividend per share) have endless decimals: four are enough.
                Text(row.price.map { Fmt.price($0, currency: row.priceCurrency, maxDecimals: 4) } ?? "")
                    .numeric()
                    .help(Self.priceHelp(row))
            }
            .width(min: 64, ideal: tight ? 84 : 96, max: 150)
            .alignment(.trailing)
            TableColumn("Amount", value: \.amount.minor) { row in
                Text(Fmt.money(row.amount)).numeric().help(columns.showsCosts ? "" : Self.costsHelp(row))
            }
            .width(min: 72, ideal: tight ? 80 : 92, max: 150)
            .alignment(.trailing)
            if columns.showsCosts {
                TableColumn("Costs", value: \.costs) { row in
                    Text(row.costs == 0 ? "" : Fmt.money(minor: row.costs, currency: row.amount.currency))
                        .numeric()
                        .help(Self.costsHelp(row))
                }
                .width(min: 50, ideal: 76, max: 120)
                .alignment(.trailing)
            }
            if columns.showsPlace {
                TableColumn("Depot", value: \.place) { Text($0.place).lineLimit(1).help($0.place) }
                    .width(min: 60, ideal: 80, max: 220)
            }
            if columns.showsNote {
                TableColumn("Note", value: \.note) { Text($0.note).lineLimit(1).foregroundStyle(.secondary).help($0.note) }
                    .width(min: 36, ideal: columns.noteWidth)
            }
        }
        // A different set of columns is a different table (AppKit keeps the old widths otherwise).
        .id(columns)
        .opacity(rows.isRefreshing ? 0.7 : 1)
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Edit…") { ids.first.map { store.present(.editTransaction($0)) } }.disabled(ids.count != 1)
            Button("Duplicate…") {
                if let t = store.transaction(ids.first) { store.present(.newTransaction(TransactionPrefill(copying: t, date: store.today))) }
            }
            .disabled(ids.count != 1)
            Button("Show in Transactions") { ids.first.map { store.navigate(to: .transaction($0)) } }.disabled(ids.count != 1)
            Divider()
            Button("Copy") { Pasteboard.copy(tsv(ids)) }
            Divider()
            Button("Delete", role: .destructive) { delete(ids) }
        } primaryAction: { ids in
            ids.first.map { store.present(.editTransaction($0)) }
        }
        .onCopyCommand { [NSItemProvider(object: tsv(selection) as NSString)] }
        .onDeleteCommand { delete(selection) }
    }

    private static func priceHelp(_ row: SecurityTransactionRow) -> String {
        guard let price = row.price else { return "" }
        var text = "\(Fmt.price(price, currency: row.priceCurrency)) per share"
        if let booked = row.bookedPrice { text += " · booked at \(Fmt.price(booked, currency: row.amount.currency, maxDecimals: 4))" }
        return text
    }

    private static func costsHelp(_ row: SecurityTransactionRow) -> String {
        "Fees \(Fmt.money(minor: row.fees, currency: row.amount.currency)) · taxes \(Fmt.money(minor: row.taxes, currency: row.amount.currency))"
    }

    private func tsv(_ ids: Set<UUID>) -> String {
        TSV.string(
            header: ["Date", "Type", "Shares", "Price", "Price Currency", "Amount", "Fees", "Taxes", "Currency", "Depot", "Note"],
            rows: items.filter { ids.contains($0.id) }.map { row in
                [row.date.iso, row.kindTitle, TSV.number(row.shares.decimalValue), row.price.map { TSV.number($0.decimalValue) } ?? "",
                 row.price == nil ? "" : row.priceCurrency, TSV.number(row.amount.decimalValue), TSV.number(Money(minor: row.fees, currency: row.amount.currency).decimalValue),
                 TSV.number(Money(minor: row.taxes, currency: row.amount.currency).decimalValue), row.amount.currency, row.place, row.note]
            })
    }
}

extension SecurityTransactionRow {
    var priceRaw: Int64 { price?.raw ?? 0 }
    /// Fees and taxes contained in the amount.
    var costs: Int64 { fees + taxes }
}

// MARK: - Historical prices

struct SecurityPricesTab: View {
    @Environment(PortfolioStore.self) private var store
    let security: Security
    @Bindable var view: SecurityViewState

    @State private var rows = Loadable<[QuoteRow]>()
    @State private var selection = Set<Int32>()
    @State private var draftDay = Day(rawValue: 0)
    @State private var draftPrice = Price.zero
    @State private var rangeFrom = Day(rawValue: 0)
    @State private var rangeTo = Day(rawValue: 0)

    private var items: [QuoteRow] { rows.value ?? [] }
    private var id: UUID { security.id }

    var body: some View {
        let id = security.id
        VStack(spacing: 0) {
            TabBar {
                DayField("Date", day: $draftDay).labelsHidden().fixedSize()
                PriceField("Price", price: $draftPrice, currency: security.currency).frame(width: 104)
                Button(security.prices.point(onOrBefore: draftDay)?.day == draftDay ? "Update Quote" : "Add Quote", action: commitDraft)
                    .fixedSize()
                    .disabled(draftPrice.raw <= 0)
                    .help("Stores the price for that day — an existing quote of the day is replaced")
                Spacer(minLength: DS.Spacing.s)
                Menu {
                    Button("Paste Quotes from Clipboard", action: paste).keyboardShortcut("v", modifiers: [.command, .shift])
                    Button("Import CSV…") { store.present(.importFile) }
                    Button("Export Quotes…") { store.present(.export(ExportRequest(.quotes(securityID: id)))) }
                        .disabled(security.prices.isEmpty)
                    Divider()
                    Button("Delete a Date Range…") {
                        resetDeleteRange()
                        view.showsDeleteRange = true
                    }
                    .disabled(security.prices.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .fixedSize()
                .help("Paste rows of date and price (any common format), import or export CSV, delete a range")
            }
            if view.showsDeleteRange { deleteRangeBar }
            if items.isEmpty, rows.value != nil {
                EmptyState("No Quotes Yet", symbol: "tablecells",
                           message: "Download the history from a data source, paste rows of date and price from a spreadsheet, or add single quotes above.") {
                    Button("Set Up Data Source") { view.tab = .source }
                    Button("Paste from Clipboard", action: paste)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.value == nil {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).loadingOverlay(rows.isInitialLoad)
            } else {
                table
            }
            TabFooter(
                text: "\(Fmt.integer(items.count)) quote\(items.count == 1 ? "" : "s")"
                    + (selection.isEmpty ? "" : " · \(Fmt.integer(selection.count)) selected"),
                trailing: security.prices.firstDay.flatMap { first in
                    security.prices.lastDay.map { "\(Fmt.day(first, style: .medium)) – \(Fmt.day($0, style: .medium))" }
                })
        }
        .ledgerTask($rows, id: "securities.quotes", variant: id) { ledger in QuoteRow.rows(of: ledger.security(id)) }
        .onAppear(perform: resetDrafts)
        .onChange(of: security.id) { _, _ in
            selection = []
            resetDrafts()
        }
        .onChange(of: store.revision) { _, _ in
            // Quotes removed by undo or a quote update must not stay "selected".
            guard let prices = store.security(security.id)?.prices else { return }
            let valid = selection.filter { prices.point(onOrBefore: Day(rawValue: $0))?.day.rawValue == $0 }
            if valid.count != selection.count { selection = valid }
        }
    }

    private func resetDrafts() {
        draftDay = store.today
        draftPrice = security.prices.point(onOrBefore: store.today)?.day == store.today ? security.prices.latest?.price ?? .zero : .zero
        resetDeleteRange()
    }

    /// The delete bar starts with the least it can: the selected quotes' span, else only the oldest
    /// quote — never the whole history one click away from "Delete".
    private func resetDeleteRange() {
        let range = Self.defaultDeleteRange(selection: selection, prices: security.prices, today: store.today)
        rangeFrom = range.lowerBound
        rangeTo = range.upperBound
    }

    static func defaultDeleteRange(selection: Set<Int32>, prices: PriceSeries, today: Day) -> ClosedRange<Day> {
        if let first = selection.min(), let last = selection.max() { return Day(rawValue: first)...Day(rawValue: last) }
        let oldest = prices.firstDay ?? today
        return oldest...oldest
    }

    private var table: some View {
        Table(items, selection: $selection) {
            TableColumn("Date") { Text(Fmt.day($0.day, style: .medium)).numeric() }
                .width(min: 96, ideal: 108, max: 150)
            TableColumn("Weekday") { Text(Self.weekdays[($0.day.weekday - 1) % 7]).foregroundStyle(.secondary) }
                .width(min: 40, ideal: 56, max: 80)
            TableColumn("Close") { Text(Fmt.price($0.price, currency: security.currency)).numeric() }
                .width(min: 84, ideal: 104, max: 160)
                .alignment(.trailing)
            TableColumn("Change") { row in
                if let change = row.change { GainText(percent: change) } else { Text("") }
            }
            .width(min: 70, ideal: 84, max: 130)
            .alignment(.trailing)
        }
        .opacity(rows.isRefreshing ? 0.7 : 1)
        .contextMenu(forSelectionType: Int32.self) { days in
            Button("Edit") { edit(days) }.disabled(days.count != 1)
            Button("Copy") { Pasteboard.copy(tsv(days)) }
            Divider()
            Button("Delete", role: .destructive) { delete(days) }
        } primaryAction: { days in
            edit(days)
        }
        .onCopyCommand { [NSItemProvider(object: tsv(selection) as NSString)] }
        .onDeleteCommand { delete(selection) }
        .onPasteCommand(of: [.plainText]) { _ in paste() }
    }

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private var deleteRangeBar: some View {
        let count = quoteCount(from: rangeFrom, to: rangeTo)
        let quotes = "\(Fmt.integer(count)) quote\(count == 1 ? "" : "s")"
        // Narrow panes drop the words, never the dates, the count or the buttons.
        return ViewThatFits(in: .horizontal) {
            deleteRangeRow(lead: "Delete quotes from", count: count == 0 ? "no quotes in this range" : quotes, delete: "Delete", quotes: quotes)
            deleteRangeRow(lead: nil, count: count == 0 ? "no quotes" : quotes, delete: "Delete", quotes: quotes)
            deleteRangeRow(lead: nil, count: nil, delete: count == 0 ? "Delete" : "Delete \(Fmt.integer(count))", quotes: quotes)
        }
        .controlSize(.small)
        .lineLimit(1)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(.quaternary.opacity(0.35))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func deleteRangeRow(lead: String?, count: String?, delete: String, quotes: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            if let lead { Text(lead).fixedSize() }
            DayField("From", day: $rangeFrom).labelsHidden().fixedSize()
            Text("to").fixedSize()
            DayField("To", day: $rangeTo).labelsHidden().fixedSize()
            if let count { Text(count).foregroundStyle(.secondary).numeric().fixedSize() }
            Spacer(minLength: DS.Spacing.s)
            Button(delete, role: .destructive, action: deleteRange)
                .fixedSize()
                .disabled(quoteCount(from: rangeFrom, to: rangeTo) == 0)
                .help("Delete \(quotes) (undo with ⌘Z)")
            Button("Cancel") { view.showsDeleteRange = false }.buttonStyle(.borderless).fixedSize()
        }
    }

    private func deleteRange() {
        let from = rangeFrom, to = rangeTo
        let count = quoteCount(from: from, to: to)
        guard count > 0 else { return }
        store.updateSecurity(id, actionName: "Delete \(count) Quote\(count == 1 ? "" : "s")") { security in
            security.prices = Self.removing(security.prices) { $0 >= from.rawValue && $0 <= to.rawValue }
        }
        view.showsDeleteRange = false
        selection = []
        store.toast("Deleted \(Fmt.integer(count)) quote\(count == 1 ? "" : "s")", message: "Undo with ⌘Z", style: .info)
    }

    private func quoteCount(from: Day, to: Day) -> Int {
        guard from <= to else { return 0 }
        let prices = security.prices
        let upper = (prices.index(onOrBefore: to) ?? -1) + 1
        let lower = (prices.index(onOrBefore: from.advanced(by: -1)) ?? -1) + 1
        return max(0, upper - lower)
    }

    /// A copy of the series without the days matching `shouldRemove` (one pass, any number of days).
    private static func removing(_ prices: PriceSeries, where shouldRemove: (Int32) -> Bool) -> PriceSeries {
        var days = [Int32](), values = [Int64]()
        days.reserveCapacity(prices.count)
        values.reserveCapacity(prices.count)
        for i in 0..<prices.count where !shouldRemove(prices.days[i]) {
            days.append(prices.days[i])
            values.append(prices.values[i])
        }
        return PriceSeries(days: days, values: values)
    }

    private func commitDraft() {
        guard draftPrice.raw > 0 else { return }
        let day = draftDay, price = draftPrice
        let exists = security.prices.point(onOrBefore: day)?.day == day
        store.updateSecurity(id, actionName: exists ? "Edit Quote" : "Add Quote") { $0.prices.set(price, on: day) }
        selection = [day.rawValue]
    }

    private func edit(_ days: Set<Int32>) {
        guard days.count == 1, let raw = days.first, let row = items.first(where: { $0.id == raw }) else { return }
        draftDay = row.day
        draftPrice = row.price
    }

    private func delete(_ days: Set<Int32>) {
        guard !days.isEmpty else { return }
        store.updateSecurity(id, actionName: days.count == 1 ? "Delete Quote" : "Delete \(days.count) Quotes") { security in
            security.prices = Self.removing(security.prices) { days.contains($0) }
        }
        selection = []
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.toast("The clipboard has no text", style: .warning)
            return
        }
        do {
            let points = try CSVQuoteParser.parse(text)
            guard !points.isEmpty else {
                store.toast("No quotes found in the clipboard", message: "Expected rows with a date and a price.", style: .warning)
                return
            }
            var changed = 0
            store.updateSecurity(id, actionName: "Paste Quotes") { changed = $0.prices.merge(points) }
            store.toast(changed == 0 ? "All \(Fmt.integer(points.count)) quotes were already stored"
                        : "Pasted \(Fmt.integer(changed)) quote\(changed == 1 ? "" : "s")", style: changed == 0 ? .info : .success)
        } catch {
            store.show(Toast("Could not read quotes from the clipboard", message: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                             style: .error, duration: 6))
        }
    }

    private func tsv(_ days: Set<Int32>) -> String {
        TSV.string(header: ["Date", "Close", "Currency"],
                   rows: items.filter { days.contains($0.id) }.map { [$0.day.iso, TSV.number($0.price.decimalValue), security.currency] })
    }
}

// MARK: - Events

struct SecurityEventsTab: View {
    @Environment(PortfolioStore.self) private var store
    let security: Security
    @Bindable var view: SecurityViewState

    @State private var selection = Set<UUID>()
    @State private var noteDay = Day(rawValue: 0)
    @State private var noteText = ""
    /// Width of the tab, known after the first layout pass.
    @State private var width: CGFloat?

    var body: some View {
        let events = security.events.sorted { ($0.day, $0.kind.rawValue) > ($1.day, $1.kind.rawValue) }
        VStack(spacing: 0) {
            TabBar {
                Button("Record Split…") {
                    store.present(.custom(id: SplitSheet.requestID, payload: ["security": security.id.uuidString]))
                }
                .help("Adjust earlier quotes, share counts or both for a stock split")
                Button("Add Note") {
                    noteDay = store.today
                    view.showsNoteEditor = true
                }
                Spacer()
                Text("Splits, distributions reported by the data source, and your own notes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if view.showsNoteEditor { noteBar }
            if events.isEmpty {
                EmptyState("No Events", symbol: "calendar.badge.exclamationmark",
                           message: "Stock splits, dividends announced by the data source and notes you attach to a date appear here — and as dots on the chart.") {
                    Button("Record Split…") {
                        store.present(.custom(id: SplitSheet.requestID, payload: ["security": security.id.uuidString]))
                    }
                    Button("Add Note") {
                        noteDay = store.today
                        view.showsNoteEditor = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let width {
                // `Table` gives a column its ideal width and no more, so Details is told how much
                // room there is: everything the two fixed columns leave (about 17 pt chrome each).
                let detailsWidth = (max(160, width - 110 - 104 - 3 * 17 - 12) / 40).rounded(.down) * 40
                Table(events, selection: $selection) {
                    TableColumn("Date") { Text(Fmt.day($0.day, style: .medium)).numeric() }
                        .width(min: 96, ideal: 110, max: 130)
                    TableColumn("Event") { event in
                        Label(Self.title(event.kind), systemImage: Self.symbol(event.kind)).lineLimit(1)
                    }
                    .width(min: 84, ideal: 104, max: 130)
                    TableColumn("Details") { event in
                        let text = detail(event)
                        Text(text).lineLimit(1).numeric().help(text)
                    }
                    .width(min: 160, ideal: detailsWidth)
                }
                .id(detailsWidth)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let event = events.first(where: { $0.id == ids.first }), event.kind == .dividend {
                        Button("Record Dividend…") { store.presentNewTransaction(.dividend, securityID: security.id, date: event.day) }
                        Divider()
                    }
                    Button("Delete", role: .destructive) { delete(ids) }
                }
                .onDeleteCommand { delete(selection) }
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            TabFooter(text: "\(Fmt.integer(events.count)) event\(events.count == 1 ? "" : "s")"
                      + (selection.isEmpty ? "" : " · \(Fmt.integer(selection.count)) selected"),
                      trailing: "Deleting an event does not change quotes or transactions")
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { if noteDay.rawValue == 0 { noteDay = store.today } }
        .onChange(of: security.id) { _, _ in selection = [] }
        .onChange(of: store.revision) { _, _ in
            let events = store.security(security.id)?.events ?? []
            let valid = selection.filter { id in events.contains { $0.id == id } }
            if valid.count != selection.count { selection = valid }
        }
    }

    private var noteBar: some View {
        HStack(spacing: DS.Spacing.s) {
            DayField("Date", day: $noteDay).labelsHidden().fixedSize()
            TextField("Note, e.g. “Merger announced”", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addNote)
            Button("Add", action: addNote)
                .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { view.showsNoteEditor = false }.buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(.quaternary.opacity(0.35))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func addNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let event = SecurityEvent(day: noteDay, kind: .note, detail: text)
        store.updateSecurity(security.id, actionName: "Add Note") { $0.events.append(event) }
        noteText = ""
        view.showsNoteEditor = false
        selection = [event.id]
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.updateSecurity(security.id, actionName: ids.count == 1 ? "Delete Event" : "Delete Events") { security in
            security.events.removeAll { ids.contains($0.id) }
        }
        selection = []
    }

    private func detail(_ event: SecurityEvent) -> String {
        switch event.kind {
        case .split: "\(event.detail) — every \(event.detail.split(separator: ":").last ?? "1") old became \(event.detail.split(separator: ":").first ?? "?") new"
        case .dividend:
            if let amount = Double(event.detail).map({ Price($0) }) ?? Fmt.parsePrice(event.detail) {
                "\(Fmt.price(amount, currency: security.currency)) per share"
            } else {
                event.detail
            }
        case .note: event.detail
        }
    }

    static func title(_ kind: SecurityEvent.Kind) -> String {
        switch kind {
        case .split: "Split"
        case .dividend: "Dividend"
        case .note: "Note"
        }
    }

    static func symbol(_ kind: SecurityEvent.Kind) -> String {
        switch kind {
        case .split: "arrow.triangle.branch"
        case .dividend: "banknote"
        case .note: "note.text"
        }
    }
}
