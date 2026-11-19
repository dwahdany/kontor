import Foundation
import UniformTypeIdentifiers
import KontorInterchange
import KontorUI

/// What the export sheet can write.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case transactions, holdings, quotes, securities
    case portfolioPerformance = "pp"
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transactions: "Transactions"
        case .holdings: "Holdings"
        case .quotes: "Quotes"
        case .securities: "Securities"
        case .portfolioPerformance: "Portfolio Performance"
        case .json: "Kontor JSON"
        }
    }

    /// Under the title in the export sheet's list (grouped by kind there).
    var subtitle: String {
        switch self {
        case .transactions: "The ledger, one transaction per row"
        case .holdings: "Positions and cash balances"
        case .quotes: "Price history of one security"
        case .securities: "Name, ISIN, ticker, currency"
        case .portfolioPerformance: "Compatible export — best effort"
        case .json: "Everything, in the open format"
        }
    }

    /// Under the title on the Import screen (names the file type).
    var summary: String {
        switch self {
        case .transactions: "The ledger as CSV"
        case .holdings: "Positions and cash as CSV"
        case .quotes: "Price history of one security as CSV"
        case .securities: "Master data as CSV"
        case .portfolioPerformance: "XML — compatible export, best effort"
        case .json: "The whole portfolio, readable"
        }
    }

    var symbol: String {
        switch self {
        case .transactions: "list.bullet.rectangle"
        case .holdings: "chart.pie"
        case .quotes: "chart.line.uptrend.xyaxis"
        case .securities: "building.columns"
        case .portfolioPerformance: "shippingbox"
        case .json: "curlybraces"
        }
    }

    var isCSV: Bool {
        switch self {
        case .transactions, .holdings, .quotes, .securities: true
        case .portfolioPerformance, .json: false
        }
    }

    var fileExtension: String {
        switch self {
        case .transactions, .holdings, .quotes, .securities: "csv"
        case .portfolioPerformance: "xml"
        case .json: "json"
        }
    }

    var contentType: UTType {
        switch self {
        case .transactions, .holdings, .quotes, .securities: .commaSeparatedText
        case .portfolioPerformance: .xml
        case .json: .json
        }
    }

    init(_ content: ExportRequest.Content) {
        switch content {
        case .portfolio: self = .json
        case .transactions: self = .transactions
        case .securities: self = .securities
        case .quotes: self = .quotes
        }
    }
}

/// The CSV notation presets of the export sheet.
enum CSVPreset: String, CaseIterable, Identifiable, Sendable {
    case international, german, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .international: "International"
        case .german: "German"
        case .custom: "Custom"
        }
    }

    init(_ format: CSVExportFormat) {
        var plain = format
        plain.includeByteOrderMark = false
        self = plain == .international ? .international : plain == .german ? .german : .custom
    }
}

/// Positions and cash balances of a scope on a day — the engine's snapshot, flattened for export.
struct HoldingsExport: Sendable, Hashable {
    struct Position: Sendable, Hashable {
        var name: String, isin: String, wkn: String, ticker: String
        var currency: CurrencyCode
        var shares: Shares
        var price: Price?
        var priceDay: Day?
        var valueInSecurityCurrency: Money
        var value: Money
        var costBasis: Money
        var gain: Money
        var gainFraction: Double?
        var share: Double?
        /// False when the quote or the exchange rate is missing: `value`, `costBasis` and `gain` are
        /// then not known (the engine reports zero) and are written as empty cells.
        var isValued = true
    }

    struct Cash: Sendable, Hashable {
        var name: String
        var balance: Money
        var value: Money
        var share: Double?
        /// False when the exchange rate into the reporting currency is missing.
        var isValued = true
    }

    var day: Day
    var currency: CurrencyCode
    var positions: [Position]
    var cash: [Cash]
    var total: Money

    init(_ analysis: Analysis) {
        self.init(analysis.snapshot, ledger: analysis.ledger)
    }

    init(_ snapshot: Snapshot, ledger: Ledger) {
        day = snapshot.day
        currency = snapshot.currency
        total = snapshot.totalValue
        let totalMinor = snapshot.totalValue.minor
        positions = snapshot.positions.map { position in
            let security = ledger.security(position.securityID)
            return Position(
                name: security?.name ?? "", isin: security?.isin ?? "", wkn: security?.wkn ?? "", ticker: security?.ticker ?? "",
                currency: security?.currency ?? position.valueInSecurityCurrency.currency, shares: position.shares,
                price: position.price, priceDay: position.priceDay, valueInSecurityCurrency: position.valueInSecurityCurrency,
                value: position.value, costBasis: position.costBasis, gain: position.unrealizedGain,
                gainFraction: position.isValued ? position.unrealizedGainFraction : nil,
                share: position.isValued ? snapshot.share(of: position) : nil, isValued: position.isValued)
        }
        cash = snapshot.cash.filter { !$0.balance.isZero }.map { balance in
            Cash(
                name: ledger.account(balance.accountID)?.name ?? "", balance: balance.balance, value: balance.value,
                share: balance.isValued && totalMinor > 0 ? Double(balance.value.minor) / Double(totalMinor) : nil,
                isValued: balance.isValued)
        }
    }

    /// One row per position, then one per cash account. Percentages are written as numbers (12.34 = 12.34 %).
    /// What could not be valued in the reporting currency has empty cells there — never a made-up 0.00.
    func table(language: CSVExportFormat.Language) -> CSVTable {
        let german = language == .german
        var table = CSVTable(header: german
            ? ["Art", "Name", "ISIN", "WKN", "Ticker-Symbol", "Stück", "Kurs", "Kursdatum", "Währung", "Kurswert",
               "Kurswert (\(currency))", "Einstandswert (\(currency))", "Kursgewinn (\(currency))", "Kursgewinn %", "Anteil %"]
            : ["Type", "Name", "ISIN", "WKN", "Ticker Symbol", "Shares", "Quote", "Quote Date", "Currency", "Market Value",
               "Market Value (\(currency))", "Cost Basis (\(currency))", "Unrealized Gain (\(currency))", "Unrealized Gain %", "Share %"])
        func percent(_ fraction: Double?) -> CSVValue { fraction.map { .number($0 * 100, fractionDigits: 2) } ?? .empty }
        func money(_ value: Money, if known: Bool) -> CSVValue { known ? .money(value) : .empty }
        for position in positions {
            let valued = position.isValued
            table.rows.append([
                .text(german ? "Wertpapier" : "Security"), .text(position.name), .text(position.isin), .text(position.wkn), .text(position.ticker),
                .shares(position.shares), position.price.map { .price($0) } ?? .empty, position.priceDay.map { .day($0) } ?? .empty,
                .text(position.currency), money(position.valueInSecurityCurrency, if: position.price != nil),
                money(position.value, if: valued), money(position.costBasis, if: valued), money(position.gain, if: valued),
                percent(position.gainFraction), percent(position.share),
            ])
        }
        for account in cash {
            table.rows.append([
                .text(german ? "Konto" : "Cash"), .text(account.name), .empty, .empty, .empty, .empty, .empty, .day(day),
                .text(account.balance.currency), .money(account.balance), money(account.value, if: account.isValued),
                .empty, .empty, .empty, percent(account.share),
            ])
        }
        return table
    }

    /// Says which rows have no value in the reporting currency, and why; nil when all have one.
    var valuationNotice: String? {
        let unquoted = positions.count { !$0.isValued && $0.price == nil }
        var currencies = Set<CurrencyCode>()
        var unconverted = 0
        for position in positions where !position.isValued && position.price != nil {
            unconverted += 1
            currencies.insert(position.currency)
        }
        for account in cash where !account.isValued {
            unconverted += 1
            currencies.insert(account.balance.currency)
        }
        var parts: [String] = []
        if unconverted > 0 {
            let rates = currencies.sorted().map { "\($0)/\(currency)" }.formatted(.list(type: .and))
            parts.append("\(ImportText.count(unconverted, "row has", "rows have")) no value in \(currency): no exchange rate for \(rates) on \(Fmt.day(day, style: .medium)).")
        }
        if unquoted > 0 {
            parts.append("\(ImportText.count(unquoted, "position has", "positions have")) no quote.")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ") + " Those cells are left empty and the rows are not part of the shares in %."
    }
}

/// Everything an export depends on besides the document.
struct ExportOptions: Hashable, Sendable {
    var format = ExportFormat.json
    var csv = CSVExportFormat.international
    /// Transactions: restrict the export to these (a selection handed over by another screen).
    var transactionIDs: Set<UUID>?
    var onlySelection = true
    /// Quotes: the security.
    var securityID: UUID?
    var prettyJSON = true
    /// Holdings: the day of the statement (nil = today) and the part of the portfolio.
    var holdingsDay: Day?
    var holdingsScope = ScopeSelection.portfolio
}

/// What a finished build was made from. A result may only be written under the options, document
/// revision and date it was built for — never under the file name of a newer choice.
struct ExportKey: Hashable, Sendable {
    var options: ExportOptions
    var revision: Int
    var today: Day

    /// The day a holdings export states.
    var holdingsDay: Day { options.holdingsDay ?? today }
}

/// A finished build together with what it was built from.
struct ExportSnapshot: Sendable {
    var key: ExportKey
    var result: ExportResult

    func isCurrent(for key: ExportKey) -> Bool { self.key == key }

    /// The bytes to write for `key`: this build's, or nil when it was made for other options, another
    /// revision of the document or another day (the caller then builds again).
    func data(for key: ExportKey) -> Data? { isCurrent(for: key) ? result.data : nil }
}

/// A finished export, or the description of one that is produced when the user saves.
struct ExportResult: Sendable {
    var data: Data?
    /// The first lines of the output.
    var previewLines: [String]
    var rowCount: Int?
    var warnings: [ImportWarning] = []
    /// Something the user should know about the content (e.g. holdings that could not be valued).
    var notice: String?
    /// Why nothing can be exported (e.g. no security chosen).
    var problem: String?
}

enum ExportBuilder {
    static let previewLineCount = 14

    /// Whole-document formats are produced on demand for very large files (the preview is skipped).
    static func isHeavy(_ file: PortfolioFile) -> Bool {
        var quotes = 0
        for security in file.securities { quotes += security.prices.count }
        return quotes + file.transactions.count * 4 > 400_000
    }

    /// Builds the export. `holdings` must be supplied for `.holdings`. Pure — call it off the main actor.
    static func build(_ options: ExportOptions, file: PortfolioFile, holdings: HoldingsExport?, preview: Bool = true) -> ExportResult {
        switch options.format {
        case .transactions:
            var subset: [Transaction]?
            if options.onlySelection, let ids = options.transactionIDs {
                subset = file.transactions.filter { ids.contains($0.id) }.sorted(by: Transaction.chronological)
            }
            return csv(CSVExporter.transactions(file, only: subset, language: options.csv.language), options, preview: preview)
        case .securities:
            return csv(CSVExporter.securities(file, language: options.csv.language), options, preview: preview)
        case .quotes:
            guard let security = file.security(options.securityID) else {
                return ExportResult(data: nil, previewLines: [], problem: "Choose a security.")
            }
            return csv(CSVExporter.quotes(of: security, language: options.csv.language), options, preview: preview)
        case .holdings:
            guard let holdings else { return ExportResult(data: nil, previewLines: [], problem: "Holdings are not available.") }
            var result = csv(holdings.table(language: options.csv.language), options, preview: preview)
            result.notice = holdings.valuationNotice
            return result
        case .portfolioPerformance:
            let export = PortfolioPerformanceExporter.export(file)
            return ExportResult(data: export.data, previewLines: preview ? lines(of: export.data) : [], warnings: export.warnings)
        case .json:
            do {
                let data = try file.encoded(pretty: options.prettyJSON)
                return ExportResult(data: data, previewLines: preview ? lines(of: data) : [])
            } catch {
                return ExportResult(data: nil, previewLines: [], problem: error.localizedDescription)
            }
        }
    }

    private static func csv(_ table: CSVTable, _ options: ExportOptions, preview: Bool) -> ExportResult {
        let data = CSVExporter.data(table, format: options.csv)
        var head: [String] = []
        if preview {
            var format = options.csv
            format.includeByteOrderMark = false
            format.lineEnding = "\n"
            let sample = CSVTable(header: table.header, rows: Array(table.rows.prefix(previewLineCount - 1)))
            head = CSVExporter.string(sample, format: format).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return ExportResult(data: data, previewLines: head, rowCount: table.rows.count)
    }

    private static func lines(of data: Data) -> [String] {
        let text = String(decoding: data.prefix(6_000), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).prefix(previewLineCount).map { line in
            line.count > 160 ? String(line.prefix(160)) + "…" : String(line)
        }
    }

    /// "Family Portfolio Transactions.csv", "Family Portfolio Holdings Main Depot 2024-12-31.csv".
    /// - Parameters:
    ///   - today: the day a holdings export states unless `options.holdingsDay` says otherwise.
    ///   - scopeTitle: holdings — the part of the portfolio, nil for the whole portfolio.
    static func fileName(_ options: ExportOptions, file: PortfolioFile, today: Day, scopeTitle: String? = nil) -> String {
        func safe(_ text: String) -> String {
            text.replacingOccurrences(of: " ▸ ", with: " - ").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        }
        let base = file.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Portfolio" : file.name.trimmingCharacters(in: .whitespaces)
        let suffix: String
        switch options.format {
        case .transactions: suffix = " Transactions"
        case .holdings:
            let scope = scopeTitle.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""
            suffix = " Holdings\(scope) \((options.holdingsDay ?? today).iso)"
        case .quotes: suffix = " Quotes" + (file.security(options.securityID).map { " \($0.ticker.isEmpty ? $0.name : $0.ticker)" } ?? "")
        case .securities: suffix = " Securities"
        case .portfolioPerformance: suffix = " (Portfolio Performance)"
        case .json: suffix = ""
        }
        return safe(base + suffix) + "." + options.format.fileExtension
    }
}
