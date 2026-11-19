import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KontorModel
import KontorUI

/// A plain table of strings: what ⌘C copies (TSV) and "Export CSV" writes.
struct EarningsTable: Sendable {
    var name: String
    var header: [String]
    var rows: [[String]]
}

/// Builds the tables behind every view of the Earnings screen and writes them as CSV.
enum EarningsExport {
    /// How numbers are written: `plain` for files (always "." — what every CSV reader expects),
    /// `pasteboard` for copy and paste into a spreadsheet (the user's decimal separator).
    enum Numbers: Sendable {
        case plain, pasteboard

        func string(_ value: Decimal) -> String {
            switch self {
            case .plain: "\(value)"
            case .pasteboard: TSV.number(value)
            }
        }

        func money(_ minor: Int64) -> String { string(Decimal(minor) / Decimal(Scale.amount)) }
        func fraction(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            return string(Decimal(Int64((value * 1_000_000).rounded())) / 1_000_000)
        }
    }

    static func table(for view: EarningsView, model: EarningsModel, grouping: EarningsGrouping, payments: PaymentsModel?) -> EarningsTable {
        switch view {
        case .chart: chart(model, grouping: grouping, numbers: .plain)
        case .matrix: matrix(model, numbers: .plain)
        case .securities: securities(model, rows: model.securities, numbers: .plain)
        case .accounts: accounts(model, rows: model.accounts, numbers: .plain)
        case .payments: self.payments(payments?.rows ?? [], currency: model.currency, numbers: .plain)
        case .calendar: calendar(model, numbers: .plain)
        }
    }

    static func matrix(_ model: EarningsModel, numbers: Numbers = .pasteboard) -> EarningsTable {
        let header = ["Year"] + (1...12).map { ChartLabels.shortMonth($0) } + ["Total", "Change vs. prior year", "Currency"]
        var rows = model.matrix.reversed().map { row in
            [String(row.year)] + row.values.map(numbers.money) + [numbers.money(row.total), numbers.fraction(row.growth), model.currency]
        }
        rows.append(["Total"] + model.matrixColumnTotals.map(numbers.money) + [numbers.money(model.totalValue), "", model.currency])
        return EarningsTable(name: "\(model.kind.title) by Month", header: header, rows: rows)
    }

    static func chart(_ model: EarningsModel, grouping: EarningsGrouping, numbers: Numbers = .pasteboard) -> EarningsTable {
        let chart = model.charts[grouping] ?? EarningsModel.Chart()
        let rows = chart.categories.indices.map { i in
            let a = chart.amounts[i]
            return [chart.categories[i].id, numbers.money(a.dividends), numbers.money(a.interest), numbers.money(a.interestCharges),
                    numbers.money(a.fees), numbers.money(a.taxes), numbers.money(a.net), model.currency]
        }
        return EarningsTable(
            name: "Earnings per \(grouping.title)",
            header: [grouping.title, "Dividends", "Interest", "Interest paid", "Fees", "Taxes", "Net", "Currency"], rows: rows)
    }

    static func securities(_ model: EarningsModel, rows: [EarningsModel.SecurityRow], numbers: Numbers = .pasteboard) -> EarningsTable {
        EarningsTable(
            name: "\(model.kind.title) by Security",
            header: ["Security", "Symbol", model.kind.title, "Share of total", "Payments", "Last payment", "Last amount",
                     "Per share", "Yield on cost (12 months)", "Currency"],
            rows: rows.map { row in
                [row.name, row.securityID == nil ? "" : row.detail, numbers.money(row.amount), numbers.fraction(row.share),
                 String(row.count), row.lastDay?.iso ?? "", row.lastDay == nil ? "" : numbers.money(row.lastGross),
                 row.perShare.map { numbers.string($0.decimalValue) } ?? "", numbers.fraction(row.yieldOnCost), model.currency]
            })
    }

    static func accounts(_ model: EarningsModel, rows: [EarningsModel.AccountRow], numbers: Numbers = .pasteboard) -> EarningsTable {
        EarningsTable(
            name: "Earnings by Account",
            header: ["Account", "Dividends", "Interest", "Fees", "Taxes", "Net", "Currency"],
            rows: rows.map { row in
                [row.name, numbers.money(row.dividends), numbers.money(row.interest), numbers.money(row.fees),
                 numbers.money(row.taxes), numbers.money(row.net), model.currency]
            })
    }

    static func payments(_ rows: [PaymentRow], currency: CurrencyCode, numbers: Numbers = .pasteboard) -> EarningsTable {
        EarningsTable(
            name: "Dividend Payments",
            header: ["Date", "Security", "Account", "Shares", "Per share", "Gross", "Taxes", "Fees", "Net", "Yield", "Currency"],
            rows: rows.map { row in
                [row.day.iso, row.security, row.account, row.shares.isZero ? "" : numbers.string(row.shares.decimalValue),
                 row.perShare.map { numbers.string($0.decimalValue) } ?? "", numbers.money(row.gross), numbers.money(row.taxes),
                 numbers.money(row.fees), numbers.money(row.net), numbers.fraction(row.yield), currency]
            })
    }

    static func calendar(_ model: EarningsModel, numbers: Numbers = .pasteboard) -> EarningsTable {
        let calendar = model.calendar
        var rows = calendar.rows.map { row in
            [row.name, String(row.paymentsPerYear), numbers.string(row.shares.decimalValue)]
                + row.expected.map(numbers.money) + [numbers.money(row.expectedTotal), model.currency]
        }
        rows.append(["Total", "", ""] + calendar.expected.map(numbers.money) + [numbers.money(calendar.expectedTotal), model.currency])
        return EarningsTable(
            name: "Expected Dividends (Estimate)",
            header: ["Security", "Payments per year", "Shares"] + calendar.months.map(\.detail) + ["Expected total (estimate)", "Currency"],
            rows: rows)
    }

    /// RFC 4180 text. Cells that a spreadsheet would run as a formula are neutralized with a
    /// leading apostrophe (names come from imported files).
    static func csv(_ table: EarningsTable) -> String {
        func cell(_ raw: String, isText: Bool) -> String {
            var text = raw
            if isText, let first = text.first, "=+-@\t\r".contains(first) { text = "'" + text }
            if text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                text = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return text
        }
        var lines = [table.header.map { cell($0, isText: true) }.joined(separator: ",")]
        for row in table.rows {
            lines.append(row.map { cell($0, isText: Decimal(string: $0) == nil) }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Asks where to save and writes the table. Only ever called from a user action.
    @MainActor static func save(_ table: EarningsTable, store: PortfolioStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(store.file.name.isEmpty ? "Kontor" : store.file.name) – \(table.name).csv"
            .replacingOccurrences(of: "/", with: "-")
        panel.message = "Export \(table.name) as CSV"
        let text = csv(table)
        let count = table.rows.count
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                Task { @MainActor in store.toast("Exported \(Fmt.integer(count)) rows to \(url.lastPathComponent)", style: .success) }
            } catch {
                Task { @MainActor in
                    store.show(Toast("Export Failed", message: error.localizedDescription, style: .error, duration: 6))
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
