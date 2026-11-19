import Foundation
import KontorModel

/// Options for writing a Portfolio Performance XML file.
public struct PortfolioPerformanceExportOptions: Hashable, Sendable {
    public enum ReferenceStyle: String, Hashable, Sendable, CaseIterable {
        /// Relative XPath references — PP's default, understood by every PP version.
        case xpath
        /// `id`/`reference` attributes — more compact for large files, requires PP 0.70 (2024) or newer.
        case id
    }

    public var referenceStyle: ReferenceStyle
    /// Written as the "last updated" time stamp of every object. Fix it for reproducible output.
    public var timestamp: Date

    public init(referenceStyle: ReferenceStyle = .xpath, timestamp: Date = Date()) {
        self.referenceStyle = referenceStyle
        self.timestamp = timestamp
    }
}

/// A rendered Portfolio Performance file.
public struct PortfolioPerformanceExport: Hashable, Sendable {
    /// UTF-8 XML; save it with the extension `.xml` (or `.portfolio`).
    public var data: Data
    /// Things Portfolio Performance cannot represent (they are still preserved for re-import into Kontor where possible).
    public var warnings: [ImportWarning]
}

/// Writes a `PortfolioFile` as Portfolio Performance `client` XML so that users are never locked in.
///
/// The output mirrors what PP's own XStream serializer produces: securities, accounts and securities
/// accounts with their transactions (purchases, sales and transfers as linked cross entries),
/// taxonomies, watchlists and savings plans. Data that only Kontor knows (settings, dashboards,
/// precise quote-feed configuration, stable ids) is stored in properties PP preserves but ignores,
/// so that exporting and importing again yields an equivalent file.
///
/// ```swift
/// let export = PortfolioPerformanceExporter.export(file)
/// try export.data.write(to: url)
/// ```
public enum PortfolioPerformanceExporter {
    /// Renders `file` as a Portfolio Performance XML document (format 56). Never fails; anything PP
    /// cannot hold is listed in the result's `warnings`.
    public static func export(_ file: PortfolioFile, options: PortfolioPerformanceExportOptions = .init()) -> PortfolioPerformanceExport {
        var builder = PPDocumentBuilder(file: file, options: options)
        return builder.build()
    }
}

// MARK: - Portfolio Performance object model

private final class PPSecurity: XStreamObject {
    let security: Security
    var targetCurrency: String?
    init(_ security: Security, targetCurrency: String? = nil) {
        self.security = security
        self.targetCurrency = targetCurrency
    }
}

private final class PPAccount: XStreamObject {
    let account: Account
    var transactions: [PPTransaction] = []
    init(_ account: Account) { self.account = account }
}

private final class PPPortfolio: XStreamObject {
    let depot: Depot
    var referenceAccount: PPAccount?
    var transactions: [PPTransaction] = []
    init(_ depot: Depot) { self.depot = depot }
}

private struct PPUnit {
    var type: String
    var amount: Money
    var forex: Money?
    var exchangeRate: String?
}

private final class PPTransaction: XStreamObject {
    let elementName: String // account-transaction / portfolio-transaction
    var uuid: UUID
    var date: String
    var currency: String
    var amount: Int64
    var security: PPSecurity?
    var shares: Int64 = 0
    var note = ""
    var source: String?
    var units: [PPUnit] = []
    var type: String
    /// Dividends: the ex-dividend day as PP's `LocalDateTime` ("2024-03-28T00:00").
    var exDate: String?
    var crossEntry: PPCrossEntry?

    init(account type: String, uuid: UUID, date: String, money: Money) {
        elementName = "account-transaction"
        self.type = type
        self.uuid = uuid
        self.date = date
        currency = money.currency
        amount = money.minor
    }

    init(portfolio type: String, uuid: UUID, date: String, money: Money) {
        elementName = "portfolio-transaction"
        self.type = type
        self.uuid = uuid
        self.date = date
        currency = money.currency
        amount = money.minor
    }
}

private final class PPCrossEntry: XStreamObject {
    enum Kind {
        case buySell(portfolio: PPPortfolio, portfolioTransaction: PPTransaction, account: PPAccount, accountTransaction: PPTransaction)
        case accountTransfer(from: PPAccount, transactionFrom: PPTransaction, to: PPAccount, transactionTo: PPTransaction)
        case portfolioTransfer(from: PPPortfolio, transactionFrom: PPTransaction, to: PPPortfolio, transactionTo: PPTransaction)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    var className: String {
        switch kind {
        case .buySell: return "buysell"
        case .accountTransfer: return "account-transfer"
        case .portfolioTransfer: return "portfolio-transfer"
        }
    }
}

private final class PPClassification: XStreamObject {
    let id: String
    let name: String
    let note: String
    let color: String
    let weight: Int
    let hasTarget: Bool
    let rank: Int
    weak var parent: PPClassification?
    var children: [PPClassification] = []
    var assignments: [(vehicle: XStreamObject, isAccount: Bool, weight: Int)] = []
    init(id: String, name: String, note: String, color: String, weight: Int, hasTarget: Bool, rank: Int) {
        self.id = id
        self.name = name
        self.note = note
        self.color = color
        self.weight = weight
        self.hasTarget = hasTarget
        self.rank = rank
    }
}

private final class PPPlainObject: XStreamObject {}

// MARK: - Builder

private struct PPDocumentBuilder {
    let file: PortfolioFile
    let options: PortfolioPerformanceExportOptions
    var warnings = WarningCollector()

    var securities: [PPSecurity] = []
    var securityByID: [UUID: PPSecurity] = [:]
    var accounts: [PPAccount] = []
    var accountByID: [UUID: PPAccount] = [:]
    var portfolios: [PPPortfolio] = []
    var portfolioByID: [UUID: PPPortfolio] = [:]
    var transactionByID: [UUID: PPTransaction] = [:]
    var properties: [(String, String)] = []
    let timestamp: String

    init(file: PortfolioFile, options: PortfolioPerformanceExportOptions) {
        self.file = file
        self.options = options
        timestamp = ISOInstant.format(options.timestamp)
    }

    private static func lower(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func dateTime(_ transaction: Transaction) -> String {
        let minute = min(max(transaction.minuteOfDay ?? 0, 0), 1439)
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(transaction.date.iso)T\(two(minute / 60)):\(two(minute % 60))"
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func escapeSidecar(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    mutating func build() -> PortfolioPerformanceExport {
        prepareObjects()
        prepareTransactions()
        prepareProperties()

        var writer = XStreamWriter(style: options.referenceStyle == .id ? .id : .xpath, capacity: 1 << 20)
        let root = PPPlainObject()
        writer.object(root, as: "client") { w in
            w.leaf("version", String(PortfolioPerformanceFormat.exportedVersion))
            w.leaf("baseCurrency", file.settings.baseCurrency)
            w.open("securities")
            for security in securities { write(security, as: "security", to: &w) }
            w.close("securities")
            writeWatchlists(to: &w)
            w.open("accounts")
            for account in accounts { write(account, as: "account", to: &w) }
            w.close("accounts")
            w.open("portfolios")
            for portfolio in portfolios { write(portfolio, as: "portfolio", to: &w) }
            w.close("portfolios")
            writePlans(to: &w)
            writeTaxonomies(to: &w)
            w.empty("dashboards")
            w.open("properties")
            for (key, value) in properties {
                w.open("entry")
                w.leaf("string", key)
                w.leaf("string", value)
                w.close("entry")
            }
            w.close("properties")
            writeSettings(to: &w)
        }
        var output = writer.output
        output.append(10)
        return PortfolioPerformanceExport(data: Data(output), warnings: warnings.warnings)
    }

    // MARK: Preparation

    private mutating func prepareObjects() {
        for security in file.securities {
            let object = PPSecurity(security)
            securities.append(object)
            securityByID[security.id] = object
        }
        // Exchange rates travel as PP's "exchange rate" pseudo securities.
        for series in file.exchangeRates {
            var security = Security(id: StableID.uuid("kontor-fx|\(series.base)|\(series.quote)"), name: "\(series.base)/\(series.quote)", currency: series.base)
            security.prices = PriceSeries(days: series.days, values: series.rates.map { Price($0).raw })
            securities.append(PPSecurity(security, targetCurrency: series.quote))
        }
        for account in file.accounts {
            let object = PPAccount(account)
            accounts.append(object)
            accountByID[account.id] = object
        }
        for depot in file.depots {
            let object = PPPortfolio(depot)
            object.referenceAccount = depot.referenceAccountID.flatMap { accountByID[$0] }
            portfolios.append(object)
            portfolioByID[depot.id] = object
        }
    }

    private func describe(_ transaction: Transaction) -> String {
        "\(transaction.kind.rawValue) on \(transaction.date.iso)"
    }

    private mutating func prepareTransactions() {
        for transaction in file.transactions {
            let account = transaction.accountID.flatMap { accountByID[$0] }
            let depot = transaction.depotID.flatMap { portfolioByID[$0] }
            let security = transaction.securityID.flatMap { securityByID[$0] }
            let date = PPDocumentBuilder.dateTime(transaction)
            let counterID = StableID.uuid("pp-counter|\(transaction.id.uuidString)")

            var units: [PPUnit] = []
            if transaction.fees != 0 { units.append(PPUnit(type: "FEE", amount: Money(minor: transaction.fees, currency: transaction.amount.currency))) }
            if transaction.taxes != 0 { units.append(PPUnit(type: "TAX", amount: Money(minor: transaction.taxes, currency: transaction.amount.currency))) }
            if let gross = transaction.securityGross, gross.minor != 0, gross.currency != transaction.amount.currency {
                // rate = amount in transaction currency per unit of security currency, 10 decimals like PP
                let rate = mulDiv(transaction.grossMinor, 10_000_000_000, gross.minor)
                units.append(PPUnit(type: "GROSS_VALUE", amount: Money(minor: transaction.grossMinor, currency: transaction.amount.currency),
                                    forex: gross, exchangeRate: FixedDecimal.format(rate, digits: 10, minFraction: 4)))
            }

            func accountSide(_ type: String, uuid: UUID, money: Money) -> PPTransaction {
                let side = PPTransaction(account: type, uuid: uuid, date: date, money: money)
                side.note = transaction.note
                side.source = transaction.source
                return side
            }
            func portfolioSide(_ type: String, uuid: UUID) -> PPTransaction {
                let side = PPTransaction(portfolio: type, uuid: uuid, date: date, money: transaction.amount)
                side.note = transaction.note
                side.source = transaction.source
                side.security = security
                side.shares = transaction.shares.raw
                return side
            }
            func skip(_ reason: String) {
                warnings.add(.notExportable, reason, example: describe(transaction))
            }

            switch transaction.kind {
            case .buy, .sell:
                let type = transaction.kind == .buy ? "BUY" : "SELL"
                guard let depot, security != nil else { skip("A purchase/sale without securities account or security cannot be exported and was left out"); continue }
                guard let account else {
                    warnings.add(.notExportable, "A purchase/sale without cash account was exported as a delivery", example: describe(transaction))
                    let side = portfolioSide(transaction.kind == .buy ? "DELIVERY_INBOUND" : "DELIVERY_OUTBOUND", uuid: transaction.id)
                    side.units = units
                    depot.transactions.append(side)
                    transactionByID[transaction.id] = side
                    continue
                }
                let shareSide = portfolioSide(type, uuid: transaction.id)
                shareSide.units = units
                let cashSide = accountSide(type, uuid: counterID, money: transaction.amount)
                cashSide.security = security
                let entry = PPCrossEntry(.buySell(portfolio: depot, portfolioTransaction: shareSide, account: account, accountTransaction: cashSide))
                shareSide.crossEntry = entry
                cashSide.crossEntry = entry
                account.transactions.append(cashSide)
                depot.transactions.append(shareSide)
                transactionByID[transaction.id] = shareSide
            case .deliveryIn, .deliveryOut:
                guard let depot, security != nil else { skip("A delivery without securities account or security cannot be exported and was left out"); continue }
                let side = portfolioSide(transaction.kind == .deliveryIn ? "DELIVERY_INBOUND" : "DELIVERY_OUTBOUND", uuid: transaction.id)
                side.units = units
                depot.transactions.append(side)
                transactionByID[transaction.id] = side
            case .deposit, .withdrawal, .dividend, .interest, .interestCharge, .fee, .feeRefund, .tax, .taxRefund:
                guard let account else { skip("A cash booking without account cannot be exported and was left out"); continue }
                let type: String
                switch transaction.kind {
                case .deposit: type = "DEPOSIT"
                case .withdrawal: type = "REMOVAL"
                case .dividend: type = "DIVIDENDS"
                case .interest: type = "INTEREST"
                case .interestCharge: type = "INTEREST_CHARGE"
                case .fee: type = "FEES"
                case .feeRefund: type = "FEES_REFUND"
                case .tax: type = "TAXES"
                default: type = "TAX_REFUND"
                }
                let side = accountSide(type, uuid: transaction.id, money: transaction.amount)
                if transaction.kind == .dividend || transaction.kind == .interest {
                    side.units = units
                } else if !units.isEmpty {
                    warnings.add(.notExportable, "Fee/tax details on bookings that Portfolio Performance stores without them were left out", example: describe(transaction))
                }
                switch transaction.kind {
                case .dividend, .fee, .feeRefund, .tax, .taxRefund: side.security = security
                default: break
                }
                if transaction.kind == .dividend {
                    side.shares = transaction.shares.raw
                    side.exDate = transaction.exDate.map { "\($0.iso)T00:00" }
                }
                account.transactions.append(side)
                transactionByID[transaction.id] = side
            case .cashTransfer:
                guard let account else { skip("A transfer without source account cannot be exported and was left out"); continue }
                guard let target = transaction.counterAccountID.flatMap({ accountByID[$0] }) else {
                    warnings.add(.notExportable, "A transfer without target account was exported as a withdrawal", example: describe(transaction))
                    let side = accountSide("REMOVAL", uuid: transaction.id, money: transaction.amount)
                    account.transactions.append(side)
                    transactionByID[transaction.id] = side
                    continue
                }
                let out = accountSide("TRANSFER_OUT", uuid: transaction.id, money: transaction.amount)
                let into = accountSide("TRANSFER_IN", uuid: counterID, money: transaction.counterAmount ?? transaction.amount)
                let entry = PPCrossEntry(.accountTransfer(from: account, transactionFrom: out, to: target, transactionTo: into))
                out.crossEntry = entry
                into.crossEntry = entry
                account.transactions.append(out)
                target.transactions.append(into)
                transactionByID[transaction.id] = out
            case .securityTransfer:
                guard let depot, security != nil else { skip("A securities transfer without source or security cannot be exported and was left out"); continue }
                guard let target = transaction.counterDepotID.flatMap({ portfolioByID[$0] }) else {
                    warnings.add(.notExportable, "A securities transfer without target was exported as an outbound delivery", example: describe(transaction))
                    let side = portfolioSide("DELIVERY_OUTBOUND", uuid: transaction.id)
                    depot.transactions.append(side)
                    transactionByID[transaction.id] = side
                    continue
                }
                let out = portfolioSide("TRANSFER_OUT", uuid: transaction.id)
                let into = portfolioSide("TRANSFER_IN", uuid: counterID)
                let entry = PPCrossEntry(.portfolioTransfer(from: depot, transactionFrom: out, to: target, transactionTo: into))
                out.crossEntry = entry
                into.crossEntry = entry
                depot.transactions.append(out)
                target.transactions.append(into)
                transactionByID[transaction.id] = out
            }
        }
    }

    private mutating func prepareProperties() {
        properties.append((KontorMarker.export, "1"))
        if !file.name.isEmpty { properties.append((KontorMarker.name, file.name)) }
        properties.append((KontorMarker.settings, PPDocumentBuilder.json(file.settings)))
        if !file.dashboards.isEmpty { properties.append((KontorMarker.dashboards, PPDocumentBuilder.json(file.dashboards))) }
        if file.transactions.count > 1 {
            // PP keeps one transaction list per account; the order of the single ledger travels separately.
            var order = [UInt8]()
            order.reserveCapacity(file.transactions.count * 32)
            let digits = Array("0123456789abcdef".utf8)
            for transaction in file.transactions {
                withUnsafeBytes(of: transaction.id.uuid) { raw in
                    for byte in raw {
                        order.append(digits[Int(byte >> 4)])
                        order.append(digits[Int(byte & 0x0F)])
                    }
                }
            }
            properties.append((KontorMarker.order, String(decoding: order, as: UTF8.self)))
            // Dividends, interest, fees and taxes live on the cash account alone in PP: remember
            // the depot they were booked for.
            var depots = [UInt8]()
            func appendHex(_ id: UUID) {
                withUnsafeBytes(of: id.uuid) { raw in
                    for byte in raw {
                        depots.append(digits[Int(byte >> 4)])
                        depots.append(digits[Int(byte & 0x0F)])
                    }
                }
            }
            for transaction in file.transactions {
                guard let depot = transaction.depotID else { continue }
                switch transaction.kind {
                case .buy, .sell, .deliveryIn, .deliveryOut, .securityTransfer: continue
                default: break
                }
                appendHex(transaction.id)
                appendHex(depot)
            }
            if !depots.isEmpty { properties.append((KontorMarker.depots, String(decoding: depots, as: UTF8.self))) }
        }
        for (index, watchlist) in file.watchlists.enumerated() {
            properties.append(("\(KontorMarker.idPrefix)watchlist.\(index)", "\(watchlist.id.uuidString)||\(watchlist.name)"))
        }
        for (index, plan) in file.plans.enumerated() {
            properties.append(("\(KontorMarker.idPrefix)plan.\(index)", "\(plan.id.uuidString)|\(plan.end?.iso ?? "")|\(plan.name)"))
        }
        for security in file.securities {
            for (index, event) in security.events.enumerated() {
                let extra = PPDocumentBuilder.escapeSidecar("\(event.kind.rawValue):\(event.detail)")
                properties.append(("\(KontorMarker.idPrefix)event.\(security.id.uuidString).\(index)", "\(event.id.uuidString)|\(extra)|\(event.day.iso)"))
            }
        }
        if !file.dashboards.isEmpty {
            warnings.add(.notExportable, "Dashboards are not shown by Portfolio Performance (they are kept for re-import into Kontor)", severity: .info)
        }
    }

    // MARK: Securities

    private func feedElements(_ security: Security) -> (feed: String?, url: String?, ticker: String, properties: [(String, String)], unknown: Bool) {
        var ticker = security.ticker
        guard let feed = security.feed else { return (nil, nil, ticker, [], false) }
        var properties: [(String, String)] = []
        var id: String?
        var url: String?
        var unknown = false
        switch feed.provider {
        case "manual":
            id = feed.options["pp.feed"] ?? "MANUAL"
        case "yahoo":
            id = feed.options["pp.feed"] ?? (feed.options["adjusted"] == "true" ? "YAHOO-ADJUSTEDCLOSE" : "YAHOO")
            if !feed.symbol.isEmpty { ticker = feed.symbol }
        case "coingecko":
            id = "COINGECKO"
            if !feed.symbol.isEmpty { properties.append(("COINGECKOCOINID", feed.symbol)) }
        case "json-url":
            id = "GENERIC-JSON"
            url = feed.symbol
            let names = ["datePath": "GENERIC-JSON-DATE", "closePath": "GENERIC-JSON-CLOSE", "dateFormat": "GENERIC-JSON-DATE-FORMAT",
                         "timeZone": "GENERIC-JSON-DATE-TIMEZONE", "highPath": "GENERIC-JSON-HIGH", "lowPath": "GENERIC-JSON-LOW", "volumePath": "GENERIC-JSON-VOLUME"]
            for (key, value) in feed.options.sorted(by: { $0.key < $1.key }) {
                if let name = names[key] { properties.append((name, value)) }
            }
        case "html-table":
            id = "GENERIC_HTML_TABLE"
            url = feed.symbol
        default:
            if let original = feed.options["pp.feed"] {
                id = original
                url = feed.options["pp.feedURL"]
                for (key, value) in feed.options.sorted(by: { $0.key < $1.key }) where key.hasPrefix("pp.") && key != "pp.feed" && key != "pp.feedURL" {
                    properties.append((String(key.dropFirst(3)), value))
                }
            } else {
                id = "MANUAL"
                unknown = true
            }
        }
        if ticker != security.ticker { properties.append((KontorMarker.tickerProperty, security.ticker)) }
        properties.append((KontorMarker.feedProperty, PPDocumentBuilder.json(feed)))
        return (id, url, ticker, properties, unknown)
    }

    private mutating func write(_ object: PPSecurity, as name: String, to w: inout XStreamWriter) {
        let security = object.security
        let feed = feedElements(security)
        if feed.unknown, !object.isWritten {
            warnings.add(.notExportable, "Quote providers unknown to Portfolio Performance were exported as manual quotes", example: "\(security.name) (\(security.feed?.provider ?? ""))")
        }
        let timestamp = timestamp
        w.object(object, as: name) { w in
            w.leaf("uuid", PPDocumentBuilder.lower(security.id))
            w.leaf("name", security.name)
            w.leaf("currencyCode", security.currency)
            if let target = object.targetCurrency { w.leaf("targetCurrencyCode", target) }
            if !security.note.isEmpty { w.leaf("note", security.note) }
            if !security.isin.isEmpty { w.leaf("isin", security.isin) }
            if !feed.ticker.isEmpty { w.leaf("tickerSymbol", feed.ticker) }
            if !security.wkn.isEmpty { w.leaf("wkn", security.wkn) }
            if let id = feed.feed { w.leaf("feed", id) }
            if let url = feed.url, !url.isEmpty { w.leaf("feedURL", url) }
            if security.prices.isEmpty {
                w.empty("prices")
            } else {
                w.open("prices")
                let days = security.prices.days, values = security.prices.values
                w.rawChildren(named: "price", count: days.count) { output, indentation in
                    let prefix = [UInt8](repeating: 32, count: indentation) + Array("<price t=\"".utf8)
                    let middle = Array("\" v=\"".utf8), suffix = Array("\"/>".utf8)
                    for index in days.indices {
                        output.append(10)
                        output.append(contentsOf: prefix)
                        ByteFormatting.appendISODate(Day(rawValue: days[index]), to: &output)
                        output.append(contentsOf: middle)
                        ByteFormatting.appendInteger(values[index], to: &output)
                        output.append(contentsOf: suffix)
                    }
                }
                w.close("prices")
            }
            w.open("attributes")
            if security.attributes.isEmpty {
                w.empty("map")
            } else {
                w.open("map")
                for (key, value) in security.attributes.sorted(by: { $0.key < $1.key }) {
                    w.open("entry")
                    w.leaf("string", key)
                    w.leaf("string", value)
                    w.close("entry")
                }
                w.close("map")
            }
            w.close("attributes")
            if security.events.isEmpty {
                w.empty("events")
            } else {
                w.open("events")
                for event in security.events {
                    let dividend = event.kind == .dividend ? PPDocumentBuilder.dividendAmount(event.detail, fallbackCurrency: security.currency) : nil
                    let element = dividend != nil ? "dividendEvent" : "event"
                    w.open(element)
                    w.leaf("date", event.day.iso)
                    w.leaf("type", event.kind == .split ? "STOCK_SPLIT" : dividend != nil ? "DIVIDEND_PAYMENT" : "NOTE")
                    w.leaf("details", event.detail)
                    if let dividend {
                        w.leaf("paymentDate", event.day.iso)
                        w.empty("amount", attributes: [("currency", dividend.currency), ("amount", String(dividend.minor))])
                    }
                    w.close(element)
                }
                w.close("events")
            }
            for (key, value) in feed.properties {
                w.leaf("property", value, attributes: [("type", "FEED"), ("name", key)])
            }
            if security.updatedAt == nil, object.targetCurrency == nil {
                w.leaf("property", "1", attributes: [("type", "FEED"), ("name", KontorMarker.noTimestampProperty)])
            }
            w.leaf("isRetired", security.isRetired ? "true" : "false")
            w.leaf("updatedAt", security.updatedAt.map(ISOInstant.format) ?? timestamp)
        }
    }

    /// Parses dividend event details like "0.52", "0,52 EUR" or "USD 1.20" into a per-share amount.
    private static func dividendAmount(_ detail: String, fallbackCurrency: String) -> Money? {
        var number = ""
        var currency = ""
        for token in detail.split(whereSeparator: { $0 == " " }) {
            if token.allSatisfy({ $0.isLetter }), token.count == 3, currency.isEmpty {
                currency = token.uppercased()
            } else if number.isEmpty {
                number = String(token)
            } else {
                return nil
            }
        }
        if number.contains(","), !number.contains(".") { number = number.replacingOccurrences(of: ",", with: ".") }
        guard let minor = FixedDecimal.parse(number, digits: 2), minor >= 0 else { return nil }
        return Money(minor: minor, currency: currency.isEmpty ? fallbackCurrency : currency)
    }

    // MARK: Accounts, portfolios, transactions

    private mutating func write(_ object: PPAccount, as name: String, to w: inout XStreamWriter) {
        let timestamp = timestamp
        w.object(object, as: name) { w in
            let account = object.account
            w.leaf("uuid", PPDocumentBuilder.lower(account.id))
            w.leaf("name", account.name)
            w.leaf("currencyCode", account.currency)
            if !account.note.isEmpty { w.leaf("note", account.note) }
            w.leaf("isRetired", account.isRetired ? "true" : "false")
            if object.transactions.isEmpty {
                w.empty("transactions")
            } else {
                w.open("transactions")
                for transaction in object.transactions { write(transaction, as: transaction.elementName, to: &w) }
                w.close("transactions")
            }
            w.open("attributes")
            w.empty("map")
            w.close("attributes")
            w.leaf("updatedAt", timestamp)
        }
    }

    private mutating func write(_ object: PPPortfolio, as name: String, to w: inout XStreamWriter) {
        let timestamp = timestamp
        w.object(object, as: name) { w in
            let depot = object.depot
            w.leaf("uuid", PPDocumentBuilder.lower(depot.id))
            w.leaf("name", depot.name)
            if !depot.note.isEmpty { w.leaf("note", depot.note) }
            w.leaf("isRetired", depot.isRetired ? "true" : "false")
            if let reference = object.referenceAccount { write(reference, as: "referenceAccount", to: &w) }
            if object.transactions.isEmpty {
                w.empty("transactions")
            } else {
                w.open("transactions")
                for transaction in object.transactions { write(transaction, as: transaction.elementName, to: &w) }
                w.close("transactions")
            }
            w.open("attributes")
            w.empty("map")
            w.close("attributes")
            w.leaf("updatedAt", timestamp)
        }
    }

    private mutating func write(_ object: PPTransaction, as name: String, to w: inout XStreamWriter) {
        let timestamp = timestamp
        w.object(object, as: name) { w in
            w.leaf("uuid", PPDocumentBuilder.lower(object.uuid))
            w.leaf("date", object.date)
            w.leaf("currencyCode", object.currency)
            w.leaf("amount", String(object.amount))
            if let security = object.security { write(security, as: "security", to: &w) }
            if let entry = object.crossEntry { write(entry, to: &w) }
            w.leaf("shares", String(object.shares))
            if !object.note.isEmpty { w.leaf("note", object.note) }
            if let source = object.source, !source.isEmpty { w.leaf("source", source) }
            if !object.units.isEmpty {
                w.open("units")
                for unit in object.units {
                    w.open("unit", attributes: [("type", unit.type)])
                    w.empty("amount", attributes: [("currency", unit.amount.currency), ("amount", String(unit.amount.minor))])
                    if let forex = unit.forex, let rate = unit.exchangeRate {
                        w.empty("forex", attributes: [("currency", forex.currency), ("amount", String(forex.minor))])
                        w.leaf("exchangeRate", rate)
                    }
                    w.close("unit")
                }
                w.close("units")
            }
            w.leaf("updatedAt", timestamp)
            w.leaf("type", object.type)
            if let exDate = object.exDate { w.leaf("exDate", exDate) }
        }
    }

    private mutating func write(_ entry: PPCrossEntry, to w: inout XStreamWriter) {
        w.object(entry, as: "crossEntry", attributes: [("class", entry.className)]) { w in
            switch entry.kind {
            case .buySell(let portfolio, let portfolioTransaction, let account, let accountTransaction):
                write(portfolio, as: "portfolio", to: &w)
                write(portfolioTransaction, as: "portfolioTransaction", to: &w)
                write(account, as: "account", to: &w)
                write(accountTransaction, as: "accountTransaction", to: &w)
            case .accountTransfer(let from, let transactionFrom, let to, let transactionTo):
                write(from, as: "accountFrom", to: &w)
                write(transactionFrom, as: "transactionFrom", to: &w)
                write(to, as: "accountTo", to: &w)
                write(transactionTo, as: "transactionTo", to: &w)
            case .portfolioTransfer(let from, let transactionFrom, let to, let transactionTo):
                write(from, as: "portfolioFrom", to: &w)
                write(transactionFrom, as: "transactionFrom", to: &w)
                write(to, as: "portfolioTo", to: &w)
                write(transactionTo, as: "transactionTo", to: &w)
            }
        }
    }

    // MARK: Watchlists, plans, taxonomies, settings

    private mutating func writeWatchlists(to w: inout XStreamWriter) {
        guard !file.watchlists.isEmpty else { w.empty("watchlists"); return }
        w.open("watchlists")
        for watchlist in file.watchlists {
            w.open("watchlist")
            w.leaf("name", watchlist.name)
            w.open("securities")
            for id in watchlist.securityIDs {
                if let security = securityByID[id] { write(security, as: "security", to: &w) }
            }
            w.close("securities")
            w.close("watchlist")
        }
        w.close("watchlists")
    }

    private mutating func writePlans(to w: inout XStreamWriter) {
        guard !file.plans.isEmpty else { w.empty("plans"); return }
        var generated: [UUID: [PPTransaction]] = [:]
        for transaction in file.transactions {
            guard let source = transaction.source, source.hasPrefix("plan:"), let plan = UUID(uuidString: String(source.dropFirst(5))),
                  let object = transactionByID[transaction.id] else { continue }
            generated[plan, default: []].append(object)
        }
        w.open("plans")
        for plan in file.plans {
            w.open("investment-plan")
            w.leaf("name", plan.name)
            if !plan.note.isEmpty { w.leaf("note", plan.note) }
            if plan.kind == .purchase {
                if let security = plan.securityID.flatMap({ securityByID[$0] }) { write(security, as: "security", to: &w) }
                if let depot = plan.depotID.flatMap({ portfolioByID[$0] }) { write(depot, as: "portfolio", to: &w) }
            }
            if let account = plan.accountID.flatMap({ accountByID[$0] }) { write(account, as: "account", to: &w) }
            w.open("attributes")
            w.empty("map")
            w.close("attributes")
            w.leaf("autoGenerate", "false")
            w.leaf("start", "\(plan.start.iso)T00:00")
            w.leaf("interval", String(max(1, min(plan.intervalMonths, 99))))
            // Format 56 has no plan type: plans with a securities account buy, the sign selects deposit/removal.
            w.leaf("amount", String(plan.kind == .withdrawal ? -plan.amount.minor : plan.amount.minor))
            w.leaf("fees", String(plan.fees))
            let transactions = generated[plan.id] ?? []
            if transactions.isEmpty {
                w.empty("transactions")
            } else {
                w.open("transactions")
                for transaction in transactions { write(transaction, as: transaction.elementName, to: &w) }
                w.close("transactions")
            }
            w.close("investment-plan")
            if plan.end != nil {
                warnings.add(.notExportable, "End dates of savings plans are not supported by Portfolio Performance (kept for re-import into Kontor)", example: plan.name, severity: .info)
            }
            if plan.kind == .purchase, plan.depotID.flatMap({ portfolioByID[$0] }) == nil {
                warnings.add(.notExportable, "A purchase plan without securities account will appear as a deposit plan in Portfolio Performance", example: plan.name)
            }
        }
        w.close("plans")
    }

    private func makeClassification(_ source: Classification, rank: Int, parent: PPClassification) -> PPClassification {
        let node = PPClassification(id: PPDocumentBuilder.lower(source.id), name: source.name, note: source.note, color: source.color,
                                    weight: source.targetWeight ?? 10_000, hasTarget: source.targetWeight != nil, rank: rank)
        node.parent = parent
        for assignment in source.assignments {
            if let id = assignment.securityID, let security = securityByID[id] {
                node.assignments.append((security, false, assignment.weight))
            } else if let id = assignment.accountID, let account = accountByID[id] {
                node.assignments.append((account, true, assignment.weight))
            }
        }
        node.children = source.children.enumerated().map { makeClassification($0.element, rank: $0.offset, parent: node) }
        return node
    }

    private mutating func write(_ node: PPClassification, as name: String, to w: inout XStreamWriter) {
        w.object(node, as: name) { w in
            w.leaf("id", node.id)
            w.leaf("name", node.name)
            if !node.note.isEmpty { w.leaf("description", node.note) }
            w.leaf("color", node.color)
            if let parent = node.parent { write(parent, as: "parent", to: &w) }
            if node.children.isEmpty {
                w.empty("children")
            } else {
                w.open("children")
                for child in node.children { write(child, as: "classification", to: &w) }
                w.close("children")
            }
            if node.assignments.isEmpty {
                w.empty("assignments")
            } else {
                w.open("assignments")
                for (rank, assignment) in node.assignments.enumerated() {
                    w.open("assignment")
                    if assignment.isAccount, let account = assignment.vehicle as? PPAccount {
                        write(account, as: "investmentVehicle", attributes: [("class", "account")], to: &w)
                    } else if let security = assignment.vehicle as? PPSecurity {
                        write(security, as: "investmentVehicle", attributes: [("class", "security")], to: &w)
                    }
                    w.leaf("weight", String(assignment.weight))
                    w.leaf("rank", String(rank))
                    w.close("assignment")
                }
                w.close("assignments")
            }
            w.leaf("weight", String(node.weight))
            w.leaf("rank", String(node.rank))
            if node.hasTarget {
                w.open("data")
                w.open("entry")
                w.leaf("string", KontorMarker.targetWeightKey)
                w.leaf("string", "1")
                w.close("entry")
                w.close("data")
            }
        }
    }

    /// Vehicles referenced from a classification are always written before (securities, accounts), so these are references.
    private mutating func write(_ account: PPAccount, as name: String, attributes: [(String, String)], to w: inout XStreamWriter) {
        w.object(account, as: name, attributes: attributes) { _ in }
    }

    private mutating func write(_ security: PPSecurity, as name: String, attributes: [(String, String)], to w: inout XStreamWriter) {
        w.object(security, as: name, attributes: attributes) { _ in }
    }

    private mutating func writeTaxonomies(to w: inout XStreamWriter) {
        guard !file.taxonomies.isEmpty else { w.empty("taxonomies"); return }
        w.open("taxonomies")
        for taxonomy in file.taxonomies {
            let id = PPDocumentBuilder.lower(taxonomy.id)
            let root = PPClassification(id: id, name: taxonomy.name, note: "", color: "#89AFEE", weight: 10_000, hasTarget: false, rank: 0)
            root.children = taxonomy.root.enumerated().map { makeClassification($0.element, rank: $0.offset, parent: root) }
            w.open("taxonomy")
            w.leaf("id", id)
            w.leaf("name", taxonomy.name)
            w.empty("dimensions") // PP expects the list to exist
            write(root, as: "root", to: &w)
            w.close("taxonomy")
        }
        w.close("taxonomies")
    }

    private func writeSettings(to w: inout XStreamWriter) {
        w.open("settings")
        var bookmarks: [[String: String]] = []
        if let json = file.settings.preferences["pp.bookmarks"], let decoded = try? JSONDecoder().decode([[String: String]].self, from: Data(json.utf8)) {
            bookmarks = decoded
        }
        if bookmarks.isEmpty {
            w.empty("bookmarks")
        } else {
            w.open("bookmarks")
            for bookmark in bookmarks {
                w.open("bookmark")
                w.leaf("label", bookmark["label"] ?? "")
                w.leaf("pattern", bookmark["pattern"] ?? "")
                w.close("bookmark")
            }
            w.close("bookmarks")
        }
        let keys = Set(file.securities.flatMap { $0.attributes.keys }).sorted()
        if keys.isEmpty {
            w.empty("attributeTypes")
        } else {
            w.open("attributeTypes")
            for key in keys {
                w.open("attribute-type")
                w.leaf("id", key)
                w.leaf("name", key)
                w.leaf("columnLabel", key)
                w.leaf("target", "name.abuchen.portfolio.model.Security")
                w.leaf("type", "java.lang.String")
                w.leaf("converterClass", "name.abuchen.portfolio.model.AttributeType$StringConverter")
                w.empty("properties")
                w.close("attribute-type")
            }
            w.close("attributeTypes")
        }
        w.empty("configurationSets")
        w.close("settings")
    }
}
