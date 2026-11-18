import Foundation
import KontorModel

/// How CSV output is written.
public struct CSVExportFormat: Hashable, Sendable {
    public enum DateStyle: String, Hashable, Sendable, CaseIterable {
        /// 2024-03-31
        case iso
        /// 31.03.2024
        case dayMonthYearDots
        /// 03/31/2024
        case monthDayYearSlashes
    }

    public enum Language: String, Hashable, Sendable, CaseIterable { case english, german }

    public var delimiter: Character
    public var decimalSeparator: Character
    public var dateStyle: DateStyle
    /// Language of the column titles and transaction types of the built-in exports.
    public var language: Language
    public var lineEnding: String
    /// Prefix the output with a UTF-8 byte-order mark (helps Excel recognise UTF-8).
    public var includeByteOrderMark: Bool

    public init(
        delimiter: Character = ",", decimalSeparator: Character = ".", dateStyle: DateStyle = .iso, language: Language = .english,
        lineEnding: String = "\r\n", includeByteOrderMark: Bool = false
    ) {
        self.delimiter = delimiter
        self.decimalSeparator = decimalSeparator
        self.dateStyle = dateStyle
        self.language = language
        self.lineEnding = lineEnding
        self.includeByteOrderMark = includeByteOrderMark
    }

    /// Comma-separated, decimal point, ISO dates, English titles.
    public static let international = CSVExportFormat()
    /// Semicolon-separated, decimal comma, dd.MM.yyyy, German titles — what German spreadsheet setups expect.
    public static let german = CSVExportFormat(delimiter: ";", decimalSeparator: ",", dateStyle: .dayMonthYearDots, language: .german)
}

/// A typed CSV cell; numbers and dates are rendered according to the `CSVExportFormat`.
public enum CSVValue: Hashable, Sendable, ExpressibleByStringLiteral {
    case empty
    case text(String)
    case integer(Int)
    /// Fixed-point number `raw / 10^digits`, shown with at least `minFraction` decimals.
    case decimal(raw: Int64, digits: Int, minFraction: Int)
    /// Floating-point number rounded to `fractionDigits` decimals (percentages, ratios).
    case number(Double, fractionDigits: Int)
    case day(Day)

    public init(stringLiteral value: String) { self = .text(value) }

    /// A money amount (two decimals; the currency goes into its own column).
    public static func money(_ money: Money) -> CSVValue { .decimal(raw: money.minor, digits: 2, minFraction: 2) }
    /// An amount in minor units (1/100).
    public static func minor(_ value: Int64) -> CSVValue { .decimal(raw: value, digits: 2, minFraction: 2) }
    public static func shares(_ shares: Shares) -> CSVValue { .decimal(raw: shares.raw, digits: 8, minFraction: 0) }
    public static func price(_ price: Price) -> CSVValue { .decimal(raw: price.raw, digits: 8, minFraction: 2) }
}

/// A table to be written as CSV: any report (holdings, statement of assets, performance rows …) can
/// be exported by filling one of these.
public struct CSVTable: Hashable, Sendable {
    public var header: [String]
    public var rows: [[CSVValue]]

    public init(header: [String], rows: [[CSVValue]] = []) {
        self.header = header
        self.rows = rows
    }
}

/// CSV export: a generic table writer plus ready-made tables for transactions, quotes and securities.
///
/// ```swift
/// let table = CSVTable(header: ["Name", "Shares", "Value"], rows: [["ACME", .shares(position.shares), .money(position.value)]])
/// let data = CSVExporter.data(table, format: .german)
/// ```
public enum CSVExporter {
    /// Renders one cell.
    public static func string(_ value: CSVValue, format: CSVExportFormat) -> String {
        switch value {
        case .empty: return ""
        case .text(let text): return text
        case .integer(let value): return String(value)
        case .decimal(let raw, let digits, let minFraction):
            return FixedDecimal.format(raw, digits: min(max(digits, 0), 18), minFraction: min(minFraction, digits), decimalSeparator: format.decimalSeparator)
        case .number(let value, let fractionDigits):
            guard value.isFinite else { return "" }
            let digits = min(max(fractionDigits, 0), 12)
            let scaled = (value * Double(FixedDecimal.pow10[digits])).rounded()
            guard abs(scaled) < 9e18 else { return String(value) }
            return FixedDecimal.format(Int64(scaled), digits: digits, minFraction: digits, decimalSeparator: format.decimalSeparator)
        case .day(let day):
            switch format.dateStyle {
            case .iso: return day.iso
            case .dayMonthYearDots:
                let c = day.ymd
                return "\(c.day < 10 ? "0" : "")\(c.day).\(c.month < 10 ? "0" : "")\(c.month).\(c.year)"
            case .monthDayYearSlashes:
                let c = day.ymd
                return "\(c.month < 10 ? "0" : "")\(c.month)/\(c.day < 10 ? "0" : "")\(c.day)/\(c.year)"
            }
        }
    }

    /// Renders a table as CSV text with proper quoting.
    public static func string(_ table: CSVTable, format: CSVExportFormat = .international) -> String {
        var output = ""
        output.reserveCapacity((table.rows.count + 1) * max(table.header.count, 1) * 12)
        for (index, title) in table.header.enumerated() {
            if index > 0 { output.append(format.delimiter) }
            CSVCodec.append(title, to: &output, delimiter: format.delimiter)
        }
        output.append(format.lineEnding)
        for row in table.rows {
            for (index, value) in row.enumerated() {
                if index > 0 { output.append(format.delimiter) }
                CSVCodec.append(string(value, format: format), to: &output, delimiter: format.delimiter)
            }
            output.append(format.lineEnding)
        }
        return output
    }

    /// Renders a table as UTF-8 CSV data.
    public static func data(_ table: CSVTable, format: CSVExportFormat = .international) -> Data {
        var data = Data()
        if format.includeByteOrderMark { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: string(table, format: format).utf8)
        return data
    }

    // MARK: Built-in tables

    /// Column titles of the transactions export, in Portfolio Performance's vocabulary.
    static func title(_ field: CSVField, _ language: CSVExportFormat.Language) -> String {
        guard language == .german else { return field.displayName }
        switch field {
        case .date: return "Datum"
        case .time: return "Uhrzeit"
        case .type: return "Typ"
        case .securityName: return "Wertpapiername"
        case .isin: return "ISIN"
        case .wkn: return "WKN"
        case .ticker: return "Ticker-Symbol"
        case .shares: return "Stück"
        case .quote: return "Kurs"
        case .amount: return "Wert"
        case .fees: return "Gebühren"
        case .taxes: return "Steuern"
        case .currency: return "Buchungswährung"
        case .grossAmount: return "Bruttobetrag"
        case .grossCurrency: return "Währung Bruttobetrag"
        case .exchangeRate: return "Wechselkurs"
        case .account: return "Konto"
        case .counterAccount: return "Gegenkonto"
        case .depot: return "Depot"
        case .counterDepot: return "Gegendepot"
        case .note: return "Notiz"
        }
    }

    static let transactionColumns: [CSVField] = [
        .date, .time, .type, .securityName, .isin, .wkn, .ticker, .shares, .amount, .currency, .fees, .taxes,
        .grossAmount, .grossCurrency, .exchangeRate, .account, .counterAccount, .depot, .counterDepot, .note,
    ]

    /// The ledger as a table — one row per transaction, in the given order (default: chronological).
    /// The layout can be re-imported with `CSVImporter` (and largely with Portfolio Performance's CSV import).
    /// - Parameter transactions: subset to export; nil exports the whole ledger.
    public static func transactions(_ file: PortfolioFile, only transactions: [Transaction]? = nil, language: CSVExportFormat.Language = .english) -> CSVTable {
        let securities = Dictionary(file.securities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let accounts = Dictionary(file.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let depots = Dictionary(file.depots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let german = language == .german
        var table = CSVTable(header: transactionColumns.map { title($0, language) })
        let ledger = transactions ?? file.transactions.sorted(by: Transaction.chronological)
        table.rows.reserveCapacity(ledger.count)
        for transaction in ledger {
            let security = transaction.securityID.flatMap { securities[$0] }
            let type: CSVTransactionType
            switch transaction.kind {
            case .buy: type = .buy
            case .sell: type = .sell
            case .deliveryIn: type = .deliveryIn
            case .deliveryOut: type = .deliveryOut
            case .deposit: type = .deposit
            case .withdrawal: type = .withdrawal
            case .dividend: type = .dividend
            case .interest: type = .interest
            case .interestCharge: type = .interestCharge
            case .fee: type = .fee
            case .feeRefund: type = .feeRefund
            case .tax: type = .tax
            case .taxRefund: type = .taxRefund
            case .cashTransfer, .securityTransfer: type = .transferOut
            }
            var time = CSVValue.empty
            if let minute = transaction.minuteOfDay {
                time = .text("\(minute / 60 < 10 ? "0" : "")\(minute / 60):\(minute % 60 < 10 ? "0" : "")\(minute % 60)")
            }
            // Foreign-currency detail: the gross value in the security's currency, or the amount credited by a cross-currency transfer.
            let foreign = transaction.kind == .cashTransfer ? transaction.counterAmount : transaction.securityGross
            var rate = CSVValue.empty
            if let foreign, foreign.minor != 0 {
                let base = transaction.kind == .cashTransfer ? transaction.amount.minor : transaction.grossMinor
                rate = .decimal(raw: mulDiv(base, 100_000_000, foreign.minor), digits: 8, minFraction: 4)
            }
            let hasShares = transaction.kind.sharesSign != 0 || transaction.kind == .dividend
            let hasBreakdown: Bool
            switch transaction.kind {
            case .buy, .sell, .deliveryIn, .deliveryOut, .dividend, .interest: hasBreakdown = true
            default: hasBreakdown = false
            }
            table.rows.append([
                .day(transaction.date), time, .text(type.label(german: german)),
                .text(security?.name ?? ""), .text(security?.isin ?? ""), .text(security?.wkn ?? ""), .text(security?.ticker ?? ""),
                hasShares && !transaction.shares.isZero ? .shares(transaction.shares) : .empty,
                .money(transaction.amount), .text(transaction.amount.currency),
                hasBreakdown && transaction.fees != 0 ? .minor(transaction.fees) : .empty,
                hasBreakdown && transaction.taxes != 0 ? .minor(transaction.taxes) : .empty,
                foreign.map { .money($0) } ?? .empty, .text(foreign?.currency ?? ""), rate,
                .text(transaction.accountID.flatMap { accounts[$0] } ?? ""), .text(transaction.counterAccountID.flatMap { accounts[$0] } ?? ""),
                .text(transaction.depotID.flatMap { depots[$0] } ?? ""), .text(transaction.counterDepotID.flatMap { depots[$0] } ?? ""),
                .text(transaction.note),
            ])
        }
        return table
    }

    /// Historical quotes of a security (`Date`, `Quote`), optionally limited to a range of days.
    public static func quotes(of security: Security, in range: ClosedRange<Day>? = nil, language: CSVExportFormat.Language = .english) -> CSVTable {
        var table = CSVTable(header: [title(.date, language), title(.quote, language)])
        let points = range.map { Array(security.prices.points(in: $0)) } ?? Array(security.prices)
        table.rows = points.map { [.day($0.day), .price($0.price)] }
        return table
    }

    /// Securities master data (`Security Name`, `ISIN`, `WKN`, `Ticker Symbol`, `Currency`, `Note`).
    public static func securities(_ file: PortfolioFile, language: CSVExportFormat.Language = .english) -> CSVTable {
        var table = CSVTable(header: [title(.securityName, language), "ISIN", "WKN", title(.ticker, language), language == .german ? "Währung" : "Currency", title(.note, language)])
        table.rows = file.securities.map { [.text($0.name), .text($0.isin), .text($0.wkn), .text($0.ticker), .text($0.currency), .text($0.note)] }
        return table
    }
}
