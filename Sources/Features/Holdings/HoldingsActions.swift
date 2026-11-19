import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KontorUI

/// Everything the user can do with holdings rows — shared by the context menu, the keyboard
/// shortcuts, the inspector and the command palette.
@MainActor
enum HoldingsActions {
    // MARK: Transactions (prefilled editor requests; the Transactions feature owns the sheet)

    static func buy(_ row: HoldingRow, in store: PortfolioStore) {
        guard let securityID = row.securityID else { return }
        let depot = depot(for: row, in: store)
        store.present(.newTransaction(TransactionPrefill(
            kind: .buy, date: store.today, securityID: securityID, accountID: depot?.referenceAccountID, depotID: depot?.id)))
    }

    static func sell(_ row: HoldingRow, in store: PortfolioStore) {
        guard let securityID = row.securityID, row.kind == .position else { return }
        let depot = depot(for: row, in: store)
        // Offer the shares actually held in that depot (not a scope- or classification-weighted part).
        let held = heldShares(of: securityID, depot: depot?.id, in: store) ?? row.shares
        store.present(.newTransaction(TransactionPrefill(
            kind: .sell, date: store.today, securityID: securityID, accountID: depot?.referenceAccountID, depotID: depot?.id, shares: held)))
    }

    static func recordDividend(_ row: HoldingRow, in store: PortfolioStore) {
        guard let securityID = row.securityID else { return }
        let depot = depot(for: row, in: store)
        let held = row.kind == .position ? heldShares(of: securityID, depot: depot?.id, in: store) ?? row.shares : nil
        store.present(.newTransaction(TransactionPrefill(
            kind: .dividend, date: store.today, securityID: securityID, accountID: depot?.referenceAccountID, depotID: depot?.id, shares: held)))
    }

    static func deposit(_ row: HoldingRow, in store: PortfolioStore) {
        guard let accountID = row.accountID else { return }
        store.present(.newTransaction(TransactionPrefill(kind: .deposit, date: store.today, accountID: accountID)))
    }

    static func withdraw(_ row: HoldingRow, in store: PortfolioStore) {
        guard let accountID = row.accountID else { return }
        store.present(.newTransaction(TransactionPrefill(kind: .withdrawal, date: store.today, accountID: accountID)))
    }

    // MARK: Navigation

    /// The primary action (Return / double-click): the security or the account behind the row.
    static func open(_ row: HoldingRow, in store: PortfolioStore) {
        if let id = row.securityID {
            store.navigate(to: .security(id))
        } else if let id = row.accountID {
            store.navigate(to: .account(id))
        }
    }

    static func showTransactions(_ row: HoldingRow, in store: PortfolioStore) {
        if let id = row.securityID {
            store.navigate(to: Route(.transactions, focus: .security(id)))
        } else if let id = row.accountID {
            store.navigate(to: Route(.transactions, focus: .account(id)))
        }
    }

    static func showPerformance(_ row: HoldingRow, in store: PortfolioStore) {
        guard let id = row.securityID else { return }
        store.navigate(to: Route(.performance, focus: .security(id)))
    }

    static func edit(_ row: HoldingRow, in store: PortfolioStore) {
        if let id = row.securityID {
            store.present(.editSecurity(id))
        } else if let id = row.accountID {
            store.present(.editAccount(id))
        }
    }

    // MARK: Copy and export

    /// Copies the given rows — or the whole table when none are given — as TSV.
    static func copy(_ rows: [HoldingRow], in store: PortfolioStore) {
        let state = HoldingsViewState.of(store)
        let lines = rows.isEmpty ? state.display.lines : rows
        guard !lines.isEmpty else { return }
        let currency = state.displayedCurrency ?? store.baseCurrency
        Pasteboard.copy(HoldingsExport.tsv(lines, reportingCurrency: currency))
        let entities = lines.count { $0.isEntity }
        store.toast(rows.isEmpty ? "Copied the table (\(Fmt.integer(entities)) rows)" : "Copied \(Fmt.integer(lines.count)) \(lines.count == 1 ? "row" : "rows")", style: .success)
    }

    /// Saves the table as shown (filter, grouping, subtotals) as a CSV file the user chooses.
    static func exportCSV(in store: PortfolioStore) {
        let state = HoldingsViewState.of(store)
        let lines = state.display.lines
        guard !lines.isEmpty else {
            store.toast("Nothing to export", message: "The holdings table is empty.", style: .warning)
            return
        }
        let day = state.displayedDay ?? state.day(in: store)
        let csv = HoldingsExport.csv(lines, reportingCurrency: state.displayedCurrency ?? store.baseCurrency)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Holdings \(day.iso).csv"
        panel.title = "Export Holdings"
        panel.message = "Saves the table as shown: \(Fmt.integer(lines.count { $0.isEntity })) rows as of \(Fmt.day(day, style: .medium))."
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(csv.utf8).write(to: url, options: .atomic)
                store.toast("Exported \(url.lastPathComponent)", style: .success)
            } catch {
                store.show(Toast("Export failed", message: error.localizedDescription, style: .error, duration: 6))
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            panel.begin(completionHandler: save)
        }
    }

    // MARK: Helpers

    private static func depot(for row: HoldingRow, in store: PortfolioStore) -> Depot? {
        if let depot = store.depot(row.depotID) { return depot }
        guard let securityID = row.securityID else { return nil }
        // A closed position: the depot it was last booked in.
        let last = store.transactions(forSecurity: securityID).last { $0.depotID != nil }
        return store.depot(last?.depotID) ?? store.file.depots.first { !$0.isRetired }
    }

    /// Shares of a security held today in one depot, straight from the document's ledger.
    private static func heldShares(of securityID: UUID, depot: UUID?, in store: PortfolioStore) -> Shares? {
        guard let depot else { return nil }
        var shares = Shares.zero
        for transaction in store.transactions(forSecurity: securityID) where transaction.date <= store.today {
            shares += transaction.sharesEffect(on: depot)
        }
        return shares.raw > 0 ? shares : nil
    }
}

/// Text renderings of the table for the clipboard (TSV) and files (CSV).
enum HoldingsExport {
    static func header(reportingCurrency: CurrencyCode) -> [String] {
        [
            "Type", "Name", "Details", "Currency", "Shares", "Price", "Price Date", "Day Change %",
            "Value (Local)", "Value (\(reportingCurrency))", "Weight %", "Cost Basis (\(reportingCurrency))",
            "Purchase Price (\(reportingCurrency))", "Unrealized Gain (\(reportingCurrency))", "Unrealized Gain %",
            "TTWROR %", "IRR %", "Dividends (\(reportingCurrency))", "Yield on Cost %", "Realized Gain (\(reportingCurrency))",
        ]
    }

    /// One line as cells; numbers through `number` so each format picks its decimal separator.
    static func cells(_ row: HoldingRow, number: (Decimal) -> String) -> [String] {
        func money(_ minor: Int64?) -> String { minor.map { number(Decimal($0) / 100) } ?? "" }
        func percent(_ fraction: Double?) -> String {
            guard let fraction, fraction.isFinite else { return "" }
            return number(Decimal((fraction * 1_000_000).rounded()) / 10_000)
        }
        let type: String
        switch row.kind {
        case .position: type = "Position"
        case .cash: type = "Cash"
        case .closed: type = "Closed"
        case .group: type = "Subtotal"
        case .total: type = "Total"
        }
        return [
            type, row.name, row.isSummary ? "" : row.detail, row.localValue == nil && row.isSummary ? "" : row.currency,
            row.shares.map { number($0.decimalValue) } ?? "",
            row.price.map { number($0.decimalValue) } ?? "",
            row.priceDay?.iso ?? "",
            percent(row.dayChange),
            money(row.localValue), money(row.kind == .closed ? nil : row.value), percent(row.weight), money(row.costBasis),
            row.purchasePrice.map { number($0.decimalValue) } ?? "",
            money(row.gain), percent(row.gainFraction), percent(row.ttwror), percent(row.irr),
            money(row.dividends), percent(row.yieldOnCost), money(row.realized),
        ]
    }

    /// Tab-separated, numbers with the user's decimal separator (what spreadsheets expect on paste).
    static func tsv(_ rows: [HoldingRow], reportingCurrency: CurrencyCode) -> String {
        TSV.string(header: header(reportingCurrency: reportingCurrency), rows: rows.map { cells($0) { TSV.number($0) } })
    }

    /// RFC 4180 CSV: comma-separated, "." as decimal separator, CRLF line ends, UTF-8.
    static func csv(_ rows: [HoldingRow], reportingCurrency: CurrencyCode) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        var out = header(reportingCurrency: reportingCurrency).map { field($0, isText: true) }.joined(separator: ",") + "\r\n"
        for row in rows {
            let values = cells(row) { TSV.number($0, locale: posix) }
            // The first four cells are free text, the rest are numbers and ISO dates.
            out += values.enumerated().map { field($1, isText: $0 < 4) }.joined(separator: ",") + "\r\n"
        }
        return out
    }

    /// Quotes a field where needed. Text that a spreadsheet would run as a formula is neutralized
    /// with a leading apostrophe.
    static func field(_ value: String, isText: Bool) -> String {
        var text = value
        if isText, let first = text.first, "=+-@\t\r".contains(first) { text = "'" + text }
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
