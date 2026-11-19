import Foundation
import KontorModel

/// Names shared between the Portfolio Performance importer and exporter for data that only Kontor knows.
/// They are stored in places PP preserves but ignores (client properties, feed properties), which
/// makes Kontor → PP → Kontor round trips lossless.
enum KontorMarker {
    static let export = "kontor.export"
    static let name = "kontor.name"
    static let settings = "kontor.settings"
    static let dashboards = "kontor.dashboards"
    static let idPrefix = "kontor.id."
    static let feedProperty = "KONTOR_FEED"
    static let tickerProperty = "KONTOR_TICKER"
    static let noTimestampProperty = "KONTOR_NO_TIMESTAMP"
    static let targetWeightKey = "kontor.target"
    /// Ids of all transactions in ledger order (32 hex digits each, no separators).
    static let order = "kontor.order"
    /// Depots of cash-only entries (dividends, fees, taxes …) — PP books those on the account alone.
    static let depots = "kontor.depots"
}

/// Converts the object graph of a PP `client` document into a `PortfolioFile`.
///
/// PP keeps two ledgers (account transactions and portfolio transactions) linked by "cross entries";
/// a purchase, for example, exists as an account transaction, a portfolio transaction and a
/// `BuySellEntry` joining them. Kontor has one ledger, so every cross entry is emitted exactly once,
/// keyed by the identity of its XML element after reference resolution.
struct PPMapper {
    typealias NodeID = XMLTree.NodeID

    private let graph: XStreamGraph
    private let tree: XMLTree
    private let n: Names
    private let documentName: String
    private let lines: LineIndex
    private var warnings = WarningCollector()
    private var counts = ImportReport.Counts()

    private var version = 0
    private var sharesFactor: Int64 = 1
    private var priceFactor: Int64 = 1
    private var baseCurrency = "EUR"
    private var properties: [String: String] = [:]
    private var isKontorExport = false

    // Object registries, keyed by canonical XML node.
    private var securityIDs: [NodeID: UUID] = [:]
    private var securities: [Security] = []
    private var securityCurrencies: [UUID: String] = [:]
    private var exchangeRateNodes: [NodeID: Int] = [:] // node -> index in exchangeRates
    private var exchangeRateSecurities: [NodeID: Security] = [:]
    private var exchangeRates: [ExchangeRateSeries] = []
    private var accountIDs: [NodeID: UUID] = [:]
    private var accountNodes: [NodeID] = []
    private var accounts: [Account] = []
    private var accountCurrencies: [UUID: String] = [:]
    private var depotIDs: [NodeID: UUID] = [:]
    private var depotNodes: [NodeID] = []
    private var depots: [Depot] = []
    private var usedIDs: Set<UUID> = []
    private var attributeTypes: [String: (name: String, converter: String)] = [:]

    private var transactions: [Transaction] = []
    private var transactionIndexByNode: [NodeID: Int] = [:]
    private var ownerOfTransaction: [NodeID: NodeID] = [:]
    private var emittedEntries: Set<NodeID> = []

    /// Interned element/attribute names (−1 when the document does not contain the name).
    private struct Names {
        let version, baseCurrency, securities, watchlists, accounts, portfolios, plans, taxonomies, dashboards, properties, settings: XMLTree.NameID
        let uuid, name, currencyCode, targetCurrencyCode, note, isin, tickerSymbol, wkn, feed, feedURL, latestFeed, latestFeedURL: XMLTree.NameID
        let prices, price, t, v, latest, attributes, map, entry, events, property, isRetired, updatedAt, type: XMLTree.NameID
        let transactions, date, amount, security, crossEntry, shares, source, units, unit, forex, exchangeRate, currency, fees, taxes, exDate: XMLTree.NameID
        let portfolio, portfolioTransaction, account, accountTransaction, accountFrom, accountTo, portfolioFrom, portfolioTo, transactionFrom, transactionTo: XMLTree.NameID
        let referenceAccount, classAttribute, details, paymentDate: XMLTree.NameID
        let id, root, color, children, assignments, investmentVehicle, weight, rank, data, description: XMLTree.NameID
        let start, interval, bookmarks, label, pattern, attributeTypes, converterClass, configurationSets, autoGenerate: XMLTree.NameID

        init(_ t: XMLTree) {
            func id(_ s: String) -> XMLTree.NameID { t.nameID(s) }
            version = id("version"); baseCurrency = id("baseCurrency"); securities = id("securities"); watchlists = id("watchlists")
            accounts = id("accounts"); portfolios = id("portfolios"); plans = id("plans"); taxonomies = id("taxonomies")
            dashboards = id("dashboards"); properties = id("properties"); settings = id("settings")
            uuid = id("uuid"); name = id("name"); currencyCode = id("currencyCode"); targetCurrencyCode = id("targetCurrencyCode")
            note = id("note"); isin = id("isin"); tickerSymbol = id("tickerSymbol"); wkn = id("wkn"); feed = id("feed"); feedURL = id("feedURL")
            latestFeed = id("latestFeed"); latestFeedURL = id("latestFeedURL")
            prices = id("prices"); price = id("price"); self.t = id("t"); v = id("v"); latest = id("latest"); attributes = id("attributes")
            map = id("map"); entry = id("entry"); events = id("events"); property = id("property"); isRetired = id("isRetired")
            updatedAt = id("updatedAt"); type = id("type")
            transactions = id("transactions"); date = id("date"); amount = id("amount"); security = id("security"); crossEntry = id("crossEntry")
            shares = id("shares"); source = id("source"); units = id("units"); unit = id("unit"); forex = id("forex")
            exchangeRate = id("exchangeRate"); currency = id("currency"); fees = id("fees"); taxes = id("taxes"); exDate = id("exDate")
            portfolio = id("portfolio"); portfolioTransaction = id("portfolioTransaction"); account = id("account")
            accountTransaction = id("accountTransaction"); accountFrom = id("accountFrom"); accountTo = id("accountTo")
            portfolioFrom = id("portfolioFrom"); portfolioTo = id("portfolioTo"); transactionFrom = id("transactionFrom"); transactionTo = id("transactionTo")
            referenceAccount = id("referenceAccount"); classAttribute = id("class"); details = id("details"); paymentDate = id("paymentDate")
            self.id = id("id"); root = id("root"); color = id("color"); children = id("children"); assignments = id("assignments")
            investmentVehicle = id("investmentVehicle"); weight = id("weight"); rank = id("rank"); data = id("data"); description = id("description")
            start = id("start"); interval = id("interval"); bookmarks = id("bookmarks"); label = id("label"); pattern = id("pattern")
            attributeTypes = id("attributeTypes"); converterClass = id("converterClass"); configurationSets = id("configurationSets")
            autoGenerate = id("autoGenerate")
        }
    }

    init(graph: XStreamGraph, name: String) {
        self.graph = graph
        tree = graph.tree
        n = Names(graph.tree)
        documentName = name
        lines = LineIndex(graph.tree.bytes)
    }

    // MARK: - Field access

    private func text(_ node: NodeID, _ name: XMLTree.NameID) -> String? {
        graph.object(node, name).map { tree.text(of: $0) }
    }

    private func nonEmpty(_ node: NodeID, _ name: XMLTree.NameID) -> String {
        text(node, name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// An object's name as stored: trimmed for PP files; verbatim for files written by Kontor, so that
    /// names survive a round trip exactly (including empty ones and surrounding spaces).
    private func sourceName(_ node: NodeID) -> String {
        isKontorExport ? (text(node, n.name) ?? "") : nonEmpty(node, n.name)
    }

    /// `name`, or `placeholder` for a nameless object of a PP file (Kontor's own files keep empty names).
    private func named(_ name: String, _ placeholder: @autoclosure () -> String) -> String {
        name.isEmpty && !isKontorExport ? placeholder() : name
    }

    private static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var slice = bytes
        while let f = slice.first, f == 32 || f == 10 || f == 13 || f == 9 { slice = slice.dropFirst() }
        while let l = slice.last, l == 32 || l == 10 || l == 13 || l == 9 { slice = slice.dropLast() }
        return slice
    }

    private static func integer(_ bytes: ArraySlice<UInt8>) -> Int64? {
        FixedDecimal.parse(utf8: trimmed(bytes), digits: 0)
    }

    private func integer(_ node: NodeID, _ name: XMLTree.NameID) -> Int64? {
        graph.object(node, name).flatMap { PPMapper.integer(tree.textBytes(of: $0)) }
    }

    /// Largest magnitude accepted for a single monetary value (10^16 currency units). Anything beyond is
    /// file corruption; capping keeps sums such as amount + fees + taxes far away from `Int64` overflow.
    static let amountLimit: Int64 = 1_000_000_000_000_000_000

    /// `value × factor` (a format-upgrade scale), saturating instead of wrapping.
    private static func scaled(_ value: Int64, by factor: Int64) -> (value: Int64, overflow: Bool) {
        let (result, overflow) = value.multipliedReportingOverflow(by: factor)
        return overflow ? ((value < 0) == (factor < 0) ? Int64.max : -Int64.max, true) : (result, false)
    }

    /// A monetary value limited to ±`amountLimit`, with a warning when the file exceeds it.
    private mutating func money(_ value: Int64, at node: NodeID) -> Int64 {
        guard value > PPMapper.amountLimit || value < -PPMapper.amountLimit else { return value }
        warnings.add(.invalidValue, "An implausibly large number was capped", example: location(node))
        return value < 0 ? -PPMapper.amountLimit : PPMapper.amountLimit
    }

    private func bool(_ node: NodeID, _ name: XMLTree.NameID) -> Bool {
        nonEmpty(node, name) == "true"
    }

    private static func day(_ bytes: ArraySlice<UInt8>) -> Day? {
        let b = trimmed(bytes)
        guard b.count >= 10 else { return nil }
        let s = b.startIndex
        guard b[s + 4] == 45, b[s + 7] == 45 else { return nil }
        func number(_ from: Int, _ count: Int) -> Int? {
            var value = 0
            for i in from..<(from + count) {
                guard b[i] >= 48, b[i] <= 57 else { return nil }
                value = value * 10 + Int(b[i] - 48)
            }
            return value
        }
        guard let y = number(s, 4), let m = number(s + 5, 2), let d = number(s + 8, 2), (1...12).contains(m),
              d >= 1, d <= Day.daysInMonth(year: y, month: m) else { return nil }
        let day = Day(year: y, month: m, day: d)
        // Files from before 2015 stored dates as instants: "2013-12-31 23:00:00.0 UTC" is midnight of
        // 2014-01-01 in the author's (unknown) time zone. Local midnight east of Greenwich falls on the
        // evening before in UTC, west of it on the morning of the same day — so round to the nearest midnight.
        if b.count >= 23, b[s + 10] == 32, b[b.endIndex - 3] == 85, b[b.endIndex - 2] == 84, b[b.endIndex - 1] == 67,
           let hour = number(s + 11, 2), hour >= 12, hour < 24 {
            return day.advanced(by: 1)
        }
        return day
    }

    /// Parses `2019-01-07`, `2019-01-07T00:00` or `2019-01-07T09:30:15`. Midnight means "no time".
    private static func dateTime(_ bytes: ArraySlice<UInt8>) -> (day: Day, minute: Int?)? {
        let b = trimmed(bytes)
        guard let day = day(b) else { return nil }
        let s = b.startIndex
        guard b.count >= 16, b[s + 10] == 84, b[s + 13] == 58 else { return (day, nil) }
        func two(_ i: Int) -> Int? {
            guard b[i] >= 48, b[i] <= 57, b[i + 1] >= 48, b[i + 1] <= 57 else { return nil }
            return Int(b[i] - 48) * 10 + Int(b[i + 1] - 48)
        }
        guard let h = two(s + 11), let m = two(s + 14), h < 24, m < 60 else { return (day, nil) }
        let minute = h * 60 + m
        return (day, minute == 0 ? nil : minute)
    }

    private func location(_ node: NodeID) -> String { "line \(lines.line(at: Int(tree.nodes[Int(node)].offset)))" }

    /// Registers an id, replacing it by a derived one if the source file contains it twice.
    private mutating func unique(_ candidate: UUID?, fallback: String, what: String) -> UUID {
        if let candidate, usedIDs.insert(candidate).inserted { return candidate }
        if candidate != nil {
            warnings.add(.duplicateObject, "Several objects share the same identifier; a new one was assigned", example: what)
        }
        var salt = 0
        while true {
            let derived = StableID.uuid(salt == 0 ? fallback : "\(fallback)#\(salt)")
            if usedIDs.insert(derived).inserted { return derived }
            salt += 1
        }
    }

    // MARK: - Run

    mutating func run() -> PortfolioPerformanceImport {
        let client = tree.root
        version = Int(integer(client, n.version) ?? 0)
        // File-format history (ClientFactory upgrade steps): shares had 5 decimals up to version 25,
        // 6 up to version 48; quotes had 2 decimals up to version 29, 4 up to version 48. Since 49 both use 8.
        sharesFactor = version <= 25 ? 1_000 : version <= 48 ? 100 : 1
        priceFactor = version <= 29 ? 1_000_000 : version <= 48 ? 10_000 : 1
        if version == 0 {
            warnings.add(.unsupportedVersion, "The file does not declare a format version; it was read as a current Portfolio Performance file")
            sharesFactor = 1
            priceFactor = 1
        } else if version < 29 {
            warnings.add(.unsupportedVersion, "The file was written by a very old Portfolio Performance (format \(version)); for best results open and save it with a current version first")
        } else if version > PortfolioPerformanceFormat.newestKnownVersion {
            warnings.add(.unsupportedVersion, "The file format (\(version)) is newer than the newest one known to this importer (\(PortfolioPerformanceFormat.newestKnownVersion)); unknown data is ignored", severity: .info)
        }
        let currency = nonEmpty(client, n.baseCurrency)
        if !currency.isEmpty { baseCurrency = currency }

        for node in graph.unresolved {
            warnings.add(.unresolvedReference, "A reference inside the file points nowhere and was ignored", example: "<\(tree.name(of: node))> at \(location(node))")
        }

        readProperties(client)
        readAttributeTypes(client)

        if let list = tree.child(client, n.securities) {
            for (index, child) in tree.children(of: list).enumerated() {
                guard let node = graph.resolve(child) else { continue }
                _ = registerSecurity(node, index: index, listed: true)
            }
        }
        if let list = tree.child(client, n.accounts) {
            for child in tree.children(of: list) {
                guard let node = graph.resolve(child) else { continue }
                _ = registerAccount(node, listed: true)
            }
        }
        if let list = tree.child(client, n.portfolios) {
            for child in tree.children(of: list) {
                guard let node = graph.resolve(child) else { continue }
                _ = registerDepot(node, listed: true)
            }
        }
        readTransactions()
        let plans = readPlans(client)
        finishTransactions()
        let taxonomies = readTaxonomies(client)
        let watchlists = readWatchlists(client)
        let (settings, dashboards) = readSettings(client)

        // Exchange-rate "securities" that are used like ordinary securities stay securities, too.
        for (node, security) in exchangeRateSecurities.sorted(by: { $0.key < $1.key }) where securityIDs[node] == security.id {
            securities.append(security)
        }

        counts.securities = securities.count
        counts.prices = securities.reduce(0) { $0 + $1.prices.count }
        counts.securityEvents = securities.reduce(0) { $0 + $1.events.count }
        counts.accounts = accounts.count
        counts.depots = depots.count
        counts.transactions = transactions.count
        for transaction in transactions { counts.transactionsByKind[transaction.kind, default: 0] += 1 }
        counts.taxonomies = taxonomies.count
        counts.watchlists = watchlists.count
        counts.plans = plans.count
        counts.exchangeRateSeries = exchangeRates.count

        var file = PortfolioFile(
            name: properties[KontorMarker.name] ?? documentName, settings: settings, securities: securities, accounts: accounts,
            depots: depots, transactions: transactions, taxonomies: taxonomies, watchlists: watchlists, plans: plans,
            exchangeRates: exchangeRates, dashboards: dashboards
        )
        if file.name.isEmpty { file.name = documentName }
        let report = ImportReport(sourceFormat: "Portfolio Performance XML", sourceVersion: version == 0 ? nil : version, counts: counts, warnings: warnings.warnings)
        return PortfolioPerformanceImport(file: file, report: report)
    }

    // MARK: - Client properties and attribute types

    /// Reads a `Map<String, String>` serialized as `<entry><string>k</string><string>v</string></entry>`.
    private func stringMap(_ mapNode: NodeID) -> [(key: String, value: NodeID?)] {
        var result: [(String, NodeID?)] = []
        for entry in tree.children(of: mapNode) {
            var iterator = tree.children(of: entry)
            guard let keyNode = iterator.next() else { continue }
            let valueNode = iterator.next().flatMap { graph.resolve($0) }
            result.append((tree.text(of: graph.resolve(keyNode) ?? keyNode), valueNode))
        }
        return result
    }

    private mutating func readProperties(_ client: NodeID) {
        guard let node = graph.object(client, n.properties) else { return }
        for (key, value) in stringMap(node) {
            properties[key] = value.map { tree.text(of: $0) } ?? ""
        }
        isKontorExport = properties[KontorMarker.export] != nil
    }

    private mutating func readAttributeTypes(_ client: NodeID) {
        guard let settings = graph.object(client, n.settings), let list = graph.object(settings, n.attributeTypes) else { return }
        for child in tree.children(of: list) {
            guard let node = graph.resolve(child) else { continue }
            let id = nonEmpty(node, n.id)
            guard !id.isEmpty, attributeTypes[id] == nil else { continue }
            let name = sourceName(node)
            attributeTypes[id] = (name.isEmpty ? id : name, nonEmpty(node, n.converterClass))
        }
    }

    /// The Kontor id stored for the `index`-th object of `kind` by a previous Kontor export, if the
    /// object is still recognisable (`check` matches what the exporter recorded).
    private func preservedID(_ kind: String, _ index: Int, check: String) -> (id: UUID, extra: String)? {
        guard isKontorExport, let value = properties["\(KontorMarker.idPrefix)\(kind).\(index)"] else { return nil }
        let parts = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let id = UUID(uuidString: String(parts[0])), parts[2] == check else { return nil }
        return (id, String(parts[1]))
    }

    // MARK: - Securities

    private mutating func registerSecurity(_ node: NodeID, index: Int? = nil, listed: Bool) -> UUID? {
        if let known = securityIDs[node] { return known }
        if exchangeRateNodes[node] != nil {
            // An exchange-rate series referenced like a security (transaction, watchlist …): keep it as one.
            guard let security = exchangeRateSecurities[node] else { return nil }
            usedIDs.insert(security.id)
            securityIDs[node] = security.id
            securityCurrencies[security.id] = security.currency
            warnings.add(.exchangeRateSecurity, "An exchange-rate entry is used like a security; it was imported both as exchange rates and as a security", example: security.name)
            return security.id
        }
        let name = sourceName(node)
        let isin = nonEmpty(node, n.isin)
        let id = unique(UUID(uuidString: nonEmpty(node, n.uuid)), fallback: "pp-security|\(name)|\(isin)|\(index ?? Int(node))", what: name)
        if !listed {
            warnings.add(.orphanedObject, "A security is used by transactions but missing from the list of securities; it was added", example: name)
        }
        let currency = nonEmpty(node, n.currencyCode)
        let targetCurrency = nonEmpty(node, n.targetCurrencyCode)
        let ticker = nonEmpty(node, n.tickerSymbol)

        var security = Security(
            id: id, name: named(name, isin.isEmpty ? (ticker.isEmpty ? "Unnamed security" : ticker) : isin),
            currency: currency.isEmpty ? baseCurrency : currency, isin: isin, wkn: nonEmpty(node, n.wkn), ticker: ticker,
            note: text(node, n.note) ?? "", isRetired: bool(node, n.isRetired)
        )
        security.updatedAt = ISOInstant.parse(nonEmpty(node, n.updatedAt))
        security.prices = readPrices(node, securityName: security.name)

        var feedProperties: [(name: String, value: String)] = []
        for child in tree.children(of: node) where tree.nodes[Int(child)].name == n.property {
            feedProperties.append((tree.attribute(child, n.name) ?? "", tree.text(of: child)))
        }
        if let original = feedProperties.first(where: { $0.name == KontorMarker.tickerProperty }) { security.ticker = original.value }
        if feedProperties.contains(where: { $0.name == KontorMarker.noTimestampProperty }) { security.updatedAt = nil }
        feedProperties.removeAll { $0.name == KontorMarker.noTimestampProperty }
        security.feed = mapFeed(node, security: security, feedTicker: ticker, properties: feedProperties)
        security.attributes = readAttributes(node, owner: security.name)
        security.events = readEvents(node, security: security)

        if !targetCurrency.isEmpty {
            // PP models exchange rates as pseudo securities: 1 unit of currencyCode = price units of targetCurrencyCode.
            var series = ExchangeRateSeries(base: security.currency, quote: targetCurrency)
            series.days = security.prices.days
            series.rates = security.prices.values.map { Double($0) / Double(Scale.price) }
            exchangeRateNodes[node] = exchangeRates.count
            exchangeRates.append(series)
            exchangeRateSecurities[node] = security
            usedIDs.remove(id) // reserved again if the entry turns out to be used as a security
            return nil
        }
        securityIDs[node] = id
        securityCurrencies[id] = security.currency
        securities.append(security)
        return id
    }

    private mutating func readPrices(_ node: NodeID, securityName: String) -> PriceSeries {
        // Parallel columns, handed to the model's bulk initializer (adopted as-is when ascending,
        // sorted and de-duplicated — last value per day wins — otherwise).
        var days: [Int32] = []
        var values: [Int64] = []
        var newest: Int32?
        var invalid = 0
        if let list = graph.object(node, n.prices) {
            for child in tree.children(of: list) {
                guard let price = graph.resolve(child), let dayBytes = tree.attributeBytes(price, n.t), let valueBytes = tree.attributeBytes(price, n.v),
                      let day = PPMapper.day(dayBytes), let raw = PPMapper.integer(valueBytes),
                      case let quote = PPMapper.scaled(raw, by: priceFactor), !quote.overflow else {
                    invalid += 1
                    continue
                }
                days.append(day.rawValue)
                values.append(quote.value)
                newest = max(newest ?? day.rawValue, day.rawValue)
            }
        }
        // PP keeps the most recent quote separately; fold it in when it extends the history.
        if let latest = graph.object(node, n.latest), let dayBytes = tree.attributeBytes(latest, n.t), let valueBytes = tree.attributeBytes(latest, n.v),
           let day = PPMapper.day(dayBytes), let raw = PPMapper.integer(valueBytes),
           case let quote = PPMapper.scaled(raw, by: priceFactor), !quote.overflow {
            if newest.map({ day.rawValue > $0 }) ?? true {
                days.append(day.rawValue)
                values.append(quote.value)
            } else if newest == day.rawValue, let index = days.lastIndex(of: day.rawValue) {
                // Same day as the newest historic price: Portfolio Performance values the position
                // with the latest quote then, so it wins here as well.
                values[index] = quote.value
            }
        }
        if invalid > 0 {
            for _ in 0..<invalid { warnings.add(.invalidValue, "A historical price without a valid date or value was skipped", example: securityName) }
        }
        return PriceSeries(days: days, values: values)
    }

    private mutating func mapFeed(_ node: NodeID, security: Security, feedTicker: String, properties: [(name: String, value: String)]) -> QuoteFeed? {
        if let stored = properties.first(where: { $0.name == KontorMarker.feedProperty }),
           let feed = try? JSONDecoder().decode(QuoteFeed.self, from: Data(stored.value.utf8)) {
            return feed
        }
        let feed = nonEmpty(node, n.feed)
        let url = nonEmpty(node, n.feedURL)
        func property(_ name: String) -> String? { properties.first { $0.name == name }?.value }
        switch feed {
        case "":
            return nil
        case "MANUAL":
            return .manual
        case "YAHOO":
            return QuoteFeed(provider: "yahoo", symbol: feedTicker)
        case "YAHOO-ADJUSTEDCLOSE":
            return QuoteFeed(provider: "yahoo", symbol: feedTicker, options: ["adjusted": "true"])
        case "COINGECKO":
            return QuoteFeed(provider: "coingecko", symbol: property("COINGECKOCOINID") ?? feedTicker.lowercased())
        case "GENERIC-JSON":
            var options: [String: String] = [:]
            for (name, value) in properties where name.hasPrefix("GENERIC-JSON-") {
                switch name {
                case "GENERIC-JSON-DATE": options["datePath"] = value
                case "GENERIC-JSON-CLOSE": options["closePath"] = value
                case "GENERIC-JSON-DATE-FORMAT": options["dateFormat"] = value
                case "GENERIC-JSON-DATE-TIMEZONE": options["timeZone"] = value
                case "GENERIC-JSON-HIGH": options["highPath"] = value
                case "GENERIC-JSON-LOW": options["lowPath"] = value
                case "GENERIC-JSON-VOLUME": options["volumePath"] = value
                default: options[name.lowercased()] = value
                }
            }
            return QuoteFeed(provider: "json-url", symbol: url, options: options)
        case "GENERIC_HTML_TABLE":
            return QuoteFeed(provider: "html-table", symbol: url)
        case "PP":
            // PP's built-in feed is served by PP's own infrastructure; the closest portable source is the ticker.
            if feedTicker.isEmpty {
                warnings.add(.approximatedQuoteFeed, "Securities using Portfolio Performance's built-in quote feed have no ticker symbol and were set to manual quotes", example: security.name)
                return QuoteFeed(provider: "manual", symbol: "", options: ["pp.feed": feed])
            }
            warnings.add(.approximatedQuoteFeed, "Securities using Portfolio Performance's built-in quote feed were switched to Yahoo Finance using their ticker symbol", example: "\(security.name) (\(feedTicker))")
            return QuoteFeed(provider: "yahoo", symbol: feedTicker, options: ["pp.feed": feed])
        default:
            warnings.add(.unknownQuoteFeed, "The quote feed \"\(feed)\" has no direct counterpart; it was kept as provider \"\(feed.lowercased())\" and may need to be reconfigured", example: security.name)
            var options = ["pp.feed": feed]
            if !url.isEmpty { options["pp.feedURL"] = url }
            for (name, value) in properties where name != KontorMarker.tickerProperty { options["pp." + name] = value }
            return QuoteFeed(provider: feed.lowercased(), symbol: feedTicker.isEmpty ? url : feedTicker, options: options)
        }
    }

    private mutating func readAttributes(_ node: NodeID, owner: String) -> [String: String] {
        guard let attributes = graph.object(node, n.attributes), let map = graph.object(attributes, n.map) else { return [:] }
        var result: [String: String] = [:]
        for (key, valueNode) in stringMap(map) {
            guard let valueNode else { continue }
            let type = attributeTypes[key]
            let label = type?.name ?? key
            let converter = type?.converter ?? ""
            let valueName = tree.name(of: valueNode)
            let raw = tree.text(of: valueNode).trimmingCharacters(in: .whitespacesAndNewlines)
            var value: String?
            switch valueName {
            case "null":
                value = nil
            case "string":
                if converter.hasSuffix("ImageConverter") {
                    warnings.add(.skippedAttribute, "Logo images attached to securities and accounts are not imported", example: owner, severity: .info)
                } else {
                    value = tree.text(of: valueNode) // free text: verbatim
                }
            case "long", "int":
                guard let number = Int64(raw) else { value = raw; break }
                if converter.hasSuffix("QuoteConverter") || converter.hasSuffix("ShareConverter") {
                    value = FixedDecimal.format(number, digits: 8)
                } else if converter.hasSuffix("AmountConverter") || converter.hasSuffix("AmountPlainConverter") {
                    value = FixedDecimal.format(number, digits: 2, minFraction: 2)
                } else {
                    value = String(number)
                }
            case "double":
                guard let number = Double(raw) else { value = raw; break }
                if converter.hasSuffix("PercentConverter") || converter.hasSuffix("PercentPlainConverter") {
                    value = PPMapper.compact(number * 100) + "%"
                } else {
                    value = PPMapper.compact(number)
                }
            case "bookmark":
                value = nonEmpty(valueNode, n.pattern)
            case "limitPrice":
                let op = nonEmpty(valueNode, tree.nameID("operator"))
                let limit = integer(valueNode, tree.nameID("value")) ?? 0
                let symbol = ["GREATER": ">", "GREATER_OR_EQUAL": ">=", "SMALLER": "<", "SMALLER_OR_EQUAL": "<="][op] ?? op
                value = "\(symbol) \(FixedDecimal.format(limit, digits: 8))"
            default:
                value = raw.isEmpty ? nil : raw // dates, booleans and other simple values
            }
            if let value, !value.isEmpty { result[label] = value }
        }
        return result
    }

    /// Shortest decimal text for a double without exponent noise (0.0545 × 100 → "5.45").
    private static func compact(_ value: Double) -> String {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
        return String(rounded)
    }

    private mutating func readEvents(_ node: NodeID, security: Security) -> [SecurityEvent] {
        guard let list = graph.object(node, n.events) else { return [] }
        var events: [SecurityEvent] = []
        for (index, child) in tree.children(of: list).enumerated() {
            guard let node = graph.resolve(child) else { continue }
            guard let dateNode = graph.object(node, n.date), let day = PPMapper.day(tree.textBytes(of: dateNode)) else {
                warnings.add(.skippedEvent, "A security event without a valid date was skipped", example: security.name)
                continue
            }
            let type = nonEmpty(node, n.type)
            var detail = text(node, n.details) ?? ""
            let kind: SecurityEvent.Kind
            switch type {
            case "STOCK_SPLIT": kind = .split
            case "DIVIDEND_PAYMENT":
                kind = .dividend
                if let amount = graph.object(node, n.amount), let minor = tree.attributeBytes(amount, n.amount).flatMap(PPMapper.integer) {
                    detail = FixedDecimal.format(minor, digits: 2, minFraction: 2) + " " + (tree.attribute(amount, n.currency) ?? security.currency)
                }
            default: kind = .note
            }
            var event = SecurityEvent(id: StableID.uuid("pp-event|\(security.id.uuidString)|\(index)|\(day.iso)|\(type)|\(detail)"), day: day, kind: kind, detail: detail)
            if let preserved = preservedID("event.\(security.id.uuidString)", index, check: day.iso) {
                // Written by Kontor: restore the exact id, kind and text.
                event.id = preserved.id
                if let original = preserved.extra.removingPercentEncoding, let colon = original.firstIndex(of: ":"),
                   let originalKind = SecurityEvent.Kind(rawValue: String(original[..<colon])) {
                    event.kind = originalKind
                    event.detail = String(original[original.index(after: colon)...])
                }
            }
            events.append(event)
        }
        return events
    }

    // MARK: - Accounts and depots

    private mutating func registerAccount(_ node: NodeID, listed: Bool) -> UUID {
        if let known = accountIDs[node] { return known }
        let name = sourceName(node)
        let id = unique(UUID(uuidString: nonEmpty(node, n.uuid)), fallback: "pp-account|\(name)|\(accountNodes.count)", what: name)
        if !listed {
            warnings.add(.orphanedObject, "An account is referenced by transactions but missing from the list of accounts; it was added", example: name)
        }
        let currency = nonEmpty(node, n.currencyCode)
        accountIDs[node] = id
        accountNodes.append(node)
        accountCurrencies[id] = currency.isEmpty ? baseCurrency : currency
        accounts.append(Account(id: id, name: named(name, "Account \(accounts.count + 1)"), currency: currency.isEmpty ? baseCurrency : currency,
                                note: text(node, n.note) ?? "", isRetired: bool(node, n.isRetired)))
        return id
    }

    private mutating func registerDepot(_ node: NodeID, listed: Bool) -> UUID {
        if let known = depotIDs[node] { return known }
        let name = sourceName(node)
        let id = unique(UUID(uuidString: nonEmpty(node, n.uuid)), fallback: "pp-portfolio|\(name)|\(depotNodes.count)", what: name)
        if !listed {
            warnings.add(.orphanedObject, "A securities account is referenced by transactions but missing from the list of securities accounts; it was added", example: name)
        }
        depotIDs[node] = id
        depotNodes.append(node)
        let position = depots.count
        depots.append(Depot(id: id, name: named(name, "Depot \(position + 1)"), note: text(node, n.note) ?? "", isRetired: bool(node, n.isRetired)))
        if let reference = graph.object(node, n.referenceAccount) {
            depots[position].referenceAccountID = registerAccount(reference, listed: false)
        }
        return id
    }

    // MARK: - Transactions

    /// The fields every PP transaction (account or portfolio side) carries.
    private struct Core {
        var node: NodeID
        var uuid: UUID?
        var day: Day?
        var minute: Int?
        /// `<exDate>` (dividends).
        var exDate: Day?
        var currency: String
        var amount: Int64
        var securityNode: NodeID?
        var shares: Int64
        var note: String
        var source: String?
        var type: String
        var fees: Int64 = 0
        var taxes: Int64 = 0
        var forexGross: Money?
    }

    private mutating func core(_ node: NodeID) -> Core {
        let shares = PPMapper.scaled(integer(node, n.shares) ?? 0, by: sharesFactor)
        if shares.overflow { warnings.add(.invalidValue, "An implausibly large number was capped", example: location(node)) }
        var core = Core(
            node: node, uuid: UUID(uuidString: nonEmpty(node, n.uuid)), currency: nonEmpty(node, n.currencyCode),
            amount: money(integer(node, n.amount) ?? 0, at: node), securityNode: graph.object(node, n.security),
            shares: shares.value, note: text(node, n.note) ?? "",
            source: text(node, n.source), type: nonEmpty(node, n.type)
        )
        if let dateNode = graph.object(node, n.date), let parsed = PPMapper.dateTime(tree.textBytes(of: dateNode)) {
            core.day = parsed.day
            core.minute = parsed.minute
        }
        if let units = graph.object(node, n.units) {
            for child in tree.children(of: units) {
                guard let unit = graph.resolve(child), let amountNode = graph.object(unit, n.amount) else { continue }
                let value = abs(money(tree.attributeBytes(amountNode, n.amount).flatMap(PPMapper.integer) ?? 0, at: unit))
                switch tree.attribute(unit, n.type) ?? "" {
                case "FEE": core.fees = min(core.fees + value, PPMapper.amountLimit) // both ≤ limit: the sum cannot overflow
                case "TAX": core.taxes = min(core.taxes + value, PPMapper.amountLimit)
                case "GROSS_VALUE":
                    if let forex = graph.object(unit, n.forex), let forexValue = tree.attributeBytes(forex, n.amount).flatMap(PPMapper.integer),
                       let forexCurrency = tree.attribute(forex, n.currency), !forexCurrency.isEmpty {
                        core.forexGross = Money(minor: abs(money(forexValue, at: unit)), currency: forexCurrency)
                    }
                default: break
                }
            }
        }
        // Files older than format 29 stored fees and taxes as plain fields.
        if core.fees == 0, let legacy = integer(node, n.fees) { core.fees = abs(money(legacy, at: node)) }
        if core.taxes == 0, let legacy = integer(node, n.taxes) { core.taxes = abs(money(legacy, at: node)) }
        if let exNode = graph.object(node, n.exDate) {
            if let parsed = PPMapper.dateTime(tree.textBytes(of: exNode)) {
                core.exDate = parsed.day
            } else {
                warnings.add(.skippedExDate, "An ex-dividend date that is not a valid date was ignored", example: location(node), severity: .info)
            }
        }
        if !isKontorExport, let source = core.source, !source.isEmpty {
            warnings.add(.skippedDocumentReference, "References to imported documents (PDF file names) are not carried over", severity: .info)
        }
        return core
    }

    /// First pass: who owns which transaction element. Second pass: emit the unified ledger.
    private mutating func readTransactions() {
        var listed: [(owner: NodeID, transaction: NodeID, isAccount: Bool)] = []
        // Registering depots/accounts can discover further owners (inline in cross entries), so index-based loops.
        var accountCursor = 0, depotCursor = 0
        while accountCursor < accountNodes.count || depotCursor < depotNodes.count {
            while accountCursor < accountNodes.count {
                let owner = accountNodes[accountCursor]
                accountCursor += 1
                guard let list = graph.object(owner, n.transactions) else { continue }
                for child in tree.children(of: list) {
                    guard let transaction = graph.resolve(child) else { continue }
                    if ownerOfTransaction[transaction] == nil { ownerOfTransaction[transaction] = owner }
                    listed.append((owner, transaction, true))
                    discoverOwners(of: transaction)
                }
            }
            while depotCursor < depotNodes.count {
                let owner = depotNodes[depotCursor]
                depotCursor += 1
                guard let list = graph.object(owner, n.transactions) else { continue }
                for child in tree.children(of: list) {
                    guard let transaction = graph.resolve(child) else { continue }
                    if ownerOfTransaction[transaction] == nil { ownerOfTransaction[transaction] = owner }
                    listed.append((owner, transaction, false))
                    discoverOwners(of: transaction)
                }
            }
        }
        transactions.reserveCapacity(listed.count)
        for item in listed {
            guard transactionIndexByNode[item.transaction] == nil else { continue } // already emitted through its cross entry
            if let entry = graph.object(item.transaction, n.crossEntry) {
                emit(entry: entry, encounteredIn: item.transaction)
            } else if item.isAccount {
                emitAccountTransaction(item.transaction, owner: item.owner)
            } else {
                emitPortfolioTransaction(item.transaction, owner: item.owner)
            }
        }
    }

    /// Accounts and portfolios that only occur inside cross entries still own transactions.
    private mutating func discoverOwners(of transaction: NodeID) {
        guard let entry = graph.object(transaction, n.crossEntry) else { return }
        for name in [n.account, n.accountFrom, n.accountTo] {
            if let node = graph.object(entry, name), accountIDs[node] == nil { _ = registerAccount(node, listed: false) }
        }
        for name in [n.portfolio, n.portfolioFrom, n.portfolioTo] {
            if let node = graph.object(entry, name), depotIDs[node] == nil { _ = registerDepot(node, listed: false) }
        }
    }

    private mutating func securityID(_ core: Core) -> UUID? {
        guard let node = core.securityNode else { return nil }
        return registerSecurity(node, listed: false)
    }

    private func describe(_ core: Core) -> String {
        "\(core.type.isEmpty ? "transaction" : core.type) on \(core.day?.iso ?? "unknown date") (\(location(core.node)))"
    }

    private mutating func magnitude(_ value: Int64, _ core: Core) -> Int64 {
        if value < 0 {
            warnings.add(.negativeValue, "A transaction has a negative amount or share count; its absolute value was used", example: describe(core))
        }
        return abs(value)
    }

    private mutating func append(_ transaction: Transaction, nodes: [NodeID]) {
        for node in nodes { transactionIndexByNode[node] = transactions.count }
        transactions.append(transaction)
    }

    private mutating func make(
        kind: Transaction.Kind, primary: Core, amount: Int64, currency: String, accountID: UUID? = nil, depotID: UUID? = nil,
        counterAccountID: UUID? = nil, counterDepotID: UUID? = nil, withBreakdown: Bool, counterAmount: Money? = nil, note: String? = nil
    ) -> Transaction? {
        guard let day = primary.day else {
            warnings.add(.invalidValue, "A transaction without a valid date was skipped", example: describe(primary))
            return nil
        }
        let security = securityID(primary)
        if kind.requiresSecurity, security == nil {
            warnings.add(.missingSecurity, "A transaction that needs a security has none and was skipped", example: describe(primary))
            return nil
        }
        let id: UUID
        if let own = primary.uuid, usedIDs.insert(own).inserted {
            id = own // the common case, kept free of string building
        } else {
            id = unique(primary.uuid, fallback: "pp-transaction|\(kind.rawValue)|\(day.iso)|\(amount)|\(primary.shares)|\(transactions.count)", what: describe(primary))
        }
        var transaction = Transaction(
            id: id, kind: kind, date: day, minuteOfDay: primary.minute, accountID: accountID, depotID: depotID,
            counterAccountID: counterAccountID, counterDepotID: counterDepotID, securityID: security,
            shares: Shares(raw: magnitude(primary.shares, primary)), amount: Money(minor: magnitude(amount, primary), currency: currency),
            counterAmount: counterAmount, note: note ?? primary.note, source: isKontorExport ? primary.source : "pp-import"
        )
        if let exDate = primary.exDate {
            if kind == .dividend {
                transaction.exDate = exDate
            } else {
                warnings.add(.skippedExDate, "Ex-dividend dates on bookings other than dividends are not imported", example: describe(primary), severity: .info)
            }
        }
        if withBreakdown {
            transaction.fees = primary.fees
            transaction.taxes = primary.taxes
            if let gross = primary.forexGross, gross.currency != currency { transaction.securityGross = gross }
        } else if primary.fees != 0 || primary.taxes != 0 {
            warnings.add(.ignoredUnits, "Fee/tax details on a transaction type that cannot carry them were ignored", example: describe(primary))
        }
        return transaction
    }

    /// The transaction's currency; old files omit it, then the account's or the security's currency applies.
    private mutating func currency(of core: Core, account: UUID?) -> String {
        if !core.currency.isEmpty { return core.currency }
        if let account, let currency = accountCurrencies[account] { return currency }
        if let id = securityID(core), let currency = securityCurrencies[id] { return currency }
        return baseCurrency
    }

    private mutating func emitAccountTransaction(_ node: NodeID, owner: NodeID) {
        let core = core(node)
        guard let account = accountIDs[owner] else { return }
        let kind: Transaction.Kind
        var breakdown = false
        switch core.type {
        case "DEPOSIT": kind = .deposit
        case "REMOVAL": kind = .withdrawal
        case "INTEREST": kind = .interest; breakdown = true
        case "INTEREST_CHARGE": kind = .interestCharge
        case "DIVIDENDS", "DIVIDEND":
            if core.securityNode == nil {
                warnings.add(.approximatedTransaction, "A dividend without a security was imported as interest", example: describe(core))
                kind = .interest
            } else {
                kind = .dividend
            }
            breakdown = true
        case "FEES": kind = .fee
        case "FEES_REFUND": kind = .feeRefund
        case "TAXES": kind = .tax
        case "TAX_REFUND": kind = .taxRefund
        case "BUY", "TRANSFER_OUT":
            warnings.add(.incompleteCrossEntry, "An account booking of a purchase or transfer has lost its counterpart; it was imported as a withdrawal", example: describe(core))
            kind = .withdrawal
        case "SELL", "TRANSFER_IN":
            warnings.add(.incompleteCrossEntry, "An account booking of a sale or transfer has lost its counterpart; it was imported as a deposit", example: describe(core))
            kind = .deposit
        default:
            warnings.add(.unknownTransactionType, "A transaction of an unknown type was skipped", example: describe(core))
            return
        }
        var withoutSecurity = core
        if !kind.requiresSecurity, kind != .fee, kind != .feeRefund, kind != .tax, kind != .taxRefund { withoutSecurity.securityNode = nil }
        if kind != .dividend { withoutSecurity.shares = 0 }
        guard let transaction = make(kind: kind, primary: withoutSecurity, amount: core.amount, currency: currency(of: core, account: account),
                                     accountID: account, withBreakdown: breakdown) else { return }
        append(transaction, nodes: [node])
    }

    private mutating func emitPortfolioTransaction(_ node: NodeID, owner: NodeID) {
        let core = core(node)
        guard let depot = depotIDs[owner] else { return }
        let kind: Transaction.Kind
        switch core.type {
        case "DELIVERY_INBOUND": kind = .deliveryIn
        case "DELIVERY_OUTBOUND": kind = .deliveryOut
        case "BUY", "TRANSFER_IN":
            warnings.add(.incompleteCrossEntry, "A purchase or inbound transfer has lost its counterpart; it was imported as an inbound delivery", example: describe(core))
            kind = .deliveryIn
        case "SELL", "TRANSFER_OUT":
            warnings.add(.incompleteCrossEntry, "A sale or outbound transfer has lost its counterpart; it was imported as an outbound delivery", example: describe(core))
            kind = .deliveryOut
        default:
            warnings.add(.unknownTransactionType, "A transaction of an unknown type was skipped", example: describe(core))
            return
        }
        guard let transaction = make(kind: kind, primary: core, amount: core.amount, currency: currency(of: core, account: nil),
                                     depotID: depot, withBreakdown: true) else { return }
        append(transaction, nodes: [node])
    }

    private mutating func emit(entry: NodeID, encounteredIn transaction: NodeID) {
        guard emittedEntries.insert(entry).inserted else { return }
        let entryClass = tree.attribute(entry, n.classAttribute) ?? ""
        let hasBuySellShape = tree.child(entry, n.portfolioTransaction) != nil || tree.child(entry, n.accountTransaction) != nil
        let hasAccountTransferShape = tree.child(entry, n.accountFrom) != nil || tree.child(entry, n.accountTo) != nil
        if entryClass == "buysell" || (entryClass.isEmpty && hasBuySellShape) {
            emitBuySell(entry, encounteredIn: transaction)
        } else if entryClass == "account-transfer" || (entryClass.isEmpty && hasAccountTransferShape) {
            emitAccountTransfer(entry, encounteredIn: transaction)
        } else if entryClass == "portfolio-transfer" || entryClass.isEmpty {
            emitPortfolioTransfer(entry, encounteredIn: transaction)
        } else {
            warnings.add(.unknownTransactionType, "A linked transaction of an unknown kind (\(entryClass)) was skipped", example: location(entry))
        }
    }

    /// Falls back to stand-alone bookings when one half of a cross entry cannot be found.
    private mutating func emitHalves(_ halves: [NodeID?]) {
        for case let node? in halves where transactionIndexByNode[node] == nil {
            guard let owner = ownerOfTransaction[node] else {
                warnings.add(.missingOwner, "A linked transaction belongs to no account and was skipped", example: location(node))
                continue
            }
            if accountIDs[owner] != nil { emitAccountTransaction(node, owner: owner) } else { emitPortfolioTransaction(node, owner: owner) }
        }
    }

    private mutating func emitBuySell(_ entry: NodeID, encounteredIn: NodeID) {
        let portfolioSide = graph.object(entry, n.portfolioTransaction)
        let accountSide = graph.object(entry, n.accountTransaction)
        guard let portfolioSide, let accountSide else {
            emitHalves([portfolioSide ?? encounteredIn, accountSide])
            return
        }
        let depotNode = graph.object(entry, n.portfolio) ?? ownerOfTransaction[portfolioSide]
        let accountNode = graph.object(entry, n.account) ?? ownerOfTransaction[accountSide]
        guard let depotNode, let accountNode else {
            warnings.add(.missingOwner, "A purchase/sale is not attached to both an account and a securities account; its parts were imported separately", example: location(entry))
            emitHalves([portfolioSide, accountSide])
            return
        }
        let depot = registerDepot(depotNode, listed: depotIDs[depotNode] != nil)
        let account = registerAccount(accountNode, listed: accountIDs[accountNode] != nil)
        var primary = core(portfolioSide)
        let cash = core(accountSide)
        let kind: Transaction.Kind
        switch primary.type.isEmpty ? cash.type : primary.type {
        case "BUY": kind = .buy
        case "SELL": kind = .sell
        default:
            warnings.add(.unknownTransactionType, "A purchase/sale entry has an unexpected type and was skipped", example: describe(primary))
            return
        }
        if primary.securityNode == nil { primary.securityNode = cash.securityNode }
        if primary.day == nil { primary.day = cash.day; primary.minute = cash.minute }
        if primary.fees == 0, primary.taxes == 0, primary.forexGross == nil {
            primary.fees = cash.fees
            primary.taxes = cash.taxes
            primary.forexGross = cash.forexGross
        }
        let note = primary.note.isEmpty ? cash.note : primary.note
        // The account side is authoritative for the cash amount (both sides agree in consistent files).
        guard let transaction = make(kind: kind, primary: primary, amount: cash.amount, currency: currency(of: cash, account: account),
                                     accountID: account, depotID: depot, withBreakdown: true, note: note) else { return }
        append(transaction, nodes: [portfolioSide, accountSide])
    }

    private mutating func emitAccountTransfer(_ entry: NodeID, encounteredIn: NodeID) {
        let fromSide = graph.object(entry, n.transactionFrom)
        let toSide = graph.object(entry, n.transactionTo)
        guard let fromSide, let toSide else {
            emitHalves([fromSide ?? encounteredIn, toSide])
            return
        }
        guard let fromNode = graph.object(entry, n.accountFrom) ?? ownerOfTransaction[fromSide],
              let toNode = graph.object(entry, n.accountTo) ?? ownerOfTransaction[toSide] else {
            warnings.add(.missingOwner, "A transfer between accounts is missing one of its accounts; its parts were imported separately", example: location(entry))
            emitHalves([fromSide, toSide])
            return
        }
        let from = registerAccount(fromNode, listed: accountIDs[fromNode] != nil)
        let to = registerAccount(toNode, listed: accountIDs[toNode] != nil)
        var primary = core(fromSide)
        let target = core(toSide)
        if primary.day == nil { primary.day = target.day; primary.minute = target.minute }
        primary.securityNode = nil
        primary.shares = 0
        let sourceCurrency = currency(of: primary, account: from)
        let targetCurrency = currency(of: target, account: to)
        var counterAmount: Money?
        if targetCurrency != sourceCurrency || abs(target.amount) != abs(primary.amount) {
            counterAmount = Money(minor: abs(target.amount), currency: targetCurrency)
        }
        let note = primary.note.isEmpty ? target.note : primary.note
        guard let transaction = make(kind: .cashTransfer, primary: primary, amount: primary.amount, currency: sourceCurrency, accountID: from,
                                     counterAccountID: to, withBreakdown: false, counterAmount: counterAmount, note: note) else { return }
        append(transaction, nodes: [fromSide, toSide])
    }

    private mutating func emitPortfolioTransfer(_ entry: NodeID, encounteredIn: NodeID) {
        let fromSide = graph.object(entry, n.transactionFrom)
        let toSide = graph.object(entry, n.transactionTo)
        guard let fromSide, let toSide else {
            emitHalves([fromSide ?? encounteredIn, toSide])
            return
        }
        guard let fromNode = graph.object(entry, n.portfolioFrom) ?? ownerOfTransaction[fromSide],
              let toNode = graph.object(entry, n.portfolioTo) ?? ownerOfTransaction[toSide] else {
            warnings.add(.missingOwner, "A transfer between securities accounts is missing one of them; its parts were imported separately", example: location(entry))
            emitHalves([fromSide, toSide])
            return
        }
        let from = registerDepot(fromNode, listed: depotIDs[fromNode] != nil)
        let to = registerDepot(toNode, listed: depotIDs[toNode] != nil)
        var primary = core(fromSide)
        let target = core(toSide)
        if primary.securityNode == nil { primary.securityNode = target.securityNode }
        if primary.day == nil { primary.day = target.day; primary.minute = target.minute }
        if primary.shares == 0 { primary.shares = target.shares }
        primary.fees = 0
        primary.taxes = 0
        let note = primary.note.isEmpty ? target.note : primary.note
        guard let transaction = make(kind: .securityTransfer, primary: primary, amount: primary.amount, currency: currency(of: primary, account: nil),
                                     depotID: from, counterDepotID: to, withBreakdown: false, note: note) else { return }
        append(transaction, nodes: [fromSide, toSide])
    }

    /// Orders the ledger chronologically, keeping the source order within a day.
    private mutating func finishTransactions() {
        // A file written by Kontor records the exact ledger order (PP's two ledgers cannot express it).
        var rank: [UUID: Int] = [:]
        if isKontorExport, let recorded = properties[KontorMarker.order] {
            let hex = Array(recorded.utf8)
            rank.reserveCapacity(hex.count / 32)
            var offset = 0
            while offset + 32 <= hex.count {
                if let id = PPMapper.uuid(hex: hex[offset..<(offset + 32)]) { rank[id] = rank.count }
                offset += 32
            }
        }
        // Cash-only entries (dividends, fees, taxes) have no securities account in PP; a Kontor
        // export records which depot they belong to.
        if isKontorExport, let recorded = properties[KontorMarker.depots] {
            let hex = Array(recorded.utf8)
            var depotByTransaction: [UUID: UUID] = [:]
            var offset = 0
            while offset + 64 <= hex.count {
                if let id = PPMapper.uuid(hex: hex[offset..<(offset + 32)]),
                   let depot = PPMapper.uuid(hex: hex[(offset + 32)..<(offset + 64)]) {
                    depotByTransaction[id] = depot
                }
                offset += 64
            }
            let known = Set(depotIDs.values)
            for index in transactions.indices where transactions[index].depotID == nil {
                if let depot = depotByTransaction[transactions[index].id], known.contains(depot) {
                    transactions[index].depotID = depot
                }
            }
        }
        let ranks = transactions.map { rank[$0.id] }
        let order: [Int]
        if !ranks.isEmpty, ranks.allSatisfy({ $0 != nil }) {
            // Untouched since the export: restore the recorded order verbatim.
            order = transactions.indices.sorted { ranks[$0]! < ranks[$1]! }
        } else {
            // Chronological; within a day the recorded order (if any), then the source order.
            order = transactions.indices.sorted { a, b in
                let x = transactions[a], y = transactions[b]
                if x.date != y.date { return x.date < y.date }
                let tx = x.minuteOfDay ?? -1, ty = y.minuteOfDay ?? -1
                if tx != ty { return tx < ty }
                let ra = ranks[a] ?? Int.max, rb = ranks[b] ?? Int.max
                if ra != rb { return ra < rb }
                return a < b
            }
        }
        transactions = order.map { transactions[$0] }
        transactionIndexByNode.removeAll()
    }

    /// Parses 32 hexadecimal digits into a UUID.
    private static func uuid(hex: ArraySlice<UInt8>) -> UUID? {
        var bytes = [UInt8](repeating: 0, count: 16)
        var index = hex.startIndex
        for position in 0..<32 {
            let c = hex[index]
            let nibble: UInt8
            switch c {
            case 48...57: nibble = c - 48
            case 97...102: nibble = c - 87
            case 65...70: nibble = c - 55
            default: return nil
            }
            bytes[position / 2] = bytes[position / 2] << 4 | nibble
            index += 1
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Investment plans

    private mutating func readPlans(_ client: NodeID) -> [InvestmentPlan] {
        guard let list = graph.object(client, n.plans) else { return [] }
        var plans: [InvestmentPlan] = []
        for (index, child) in tree.children(of: list).enumerated() {
            guard let node = graph.resolve(child) else { continue }
            let name = sourceName(node)
            let security = graph.object(node, n.security).flatMap { registerSecurity($0, listed: false) }
            let depotNode = graph.object(node, n.portfolio)
            let depot = depotNode.map { registerDepot($0, listed: depotIDs[$0] != nil) }
            let account = graph.object(node, n.account).map { registerAccount($0, listed: accountIDs[$0] != nil) }
            var amount = money(integer(node, n.amount) ?? 0, at: node)
            let type = nonEmpty(node, n.type)
            let kind: InvestmentPlan.Kind
            switch type {
            case "PURCHASE_OR_DELIVERY": kind = .purchase
            case "DEPOSIT": kind = .deposit
            case "REMOVAL": kind = .withdrawal
            case "INTEREST":
                warnings.add(.skippedPlan, "Recurring interest plans have no counterpart and were not imported", example: name)
                continue
            default:
                // Before format 61 the type was implied: plans with a securities account buy, the sign selects deposit/removal.
                kind = depotNode != nil ? .purchase : (amount >= 0 ? .deposit : .withdrawal)
            }
            amount = abs(amount)
            guard let startNode = graph.object(node, n.start), let start = PPMapper.dateTime(tree.textBytes(of: startNode))?.day else {
                warnings.add(.skippedPlan, "A savings plan without a start date was not imported", example: name)
                continue
            }
            var interval = Int(integer(node, n.interval) ?? 1)
            if interval > 100 {
                // PP encodes weekly plans as 100 + number of weeks.
                let weeks = interval - 100
                interval = max(1, Int((Double(weeks) / 4.345).rounded()))
                warnings.add(.approximatedPlan, "Weekly savings plans are not supported; the interval was converted to months", example: "\(name): every \(weeks) week(s) → every \(interval) month(s)")
            }
            if kind == .purchase, account == nil {
                warnings.add(.approximatedPlan, "A savings plan that books deliveries (no cash account) was imported as a purchase plan without account", example: name, severity: .info)
            }
            let currency: String
            if let account, let c = accountCurrencies[account] {
                currency = c
            } else if let depot, let reference = depots.first(where: { $0.id == depot })?.referenceAccountID, let c = accountCurrencies[reference] {
                currency = c
            } else if let security, let c = securityCurrencies[security] {
                currency = c
            } else {
                currency = baseCurrency
            }
            let preserved = preservedID("plan", index, check: name)
            let id = preserved?.id ?? StableID.uuid("pp-plan|\(index)|\(name)")
            var plan = InvestmentPlan(
                id: id, name: named(name, "Plan \(index + 1)"), kind: kind, securityID: kind == .purchase ? security : nil,
                depotID: kind == .purchase ? depot : nil, accountID: account, amount: Money(minor: amount, currency: currency),
                fees: abs(money(integer(node, n.fees) ?? 0, at: node)), start: start, intervalMonths: max(1, interval), note: text(node, n.note) ?? ""
            )
            if let end = preserved?.extra, !end.isEmpty { plan.end = Day(iso: end) }
            if let taxes = integer(node, n.taxes), taxes != 0 {
                warnings.add(.approximatedPlan, "Taxes configured on a savings plan are not supported and were ignored", example: name)
            }
            // Bookings generated by the plan keep their link to it.
            if !isKontorExport, let generated = graph.object(node, n.transactions) {
                for child in tree.children(of: generated) {
                    if let transaction = graph.resolve(child), let position = transactionIndexByNode[transaction] {
                        transactions[position].source = "plan:\(id.uuidString)"
                    }
                }
            }
            plans.append(plan)
        }
        return plans
    }

    // MARK: - Taxonomies

    private mutating func readTaxonomies(_ client: NodeID) -> [Taxonomy] {
        guard let list = graph.object(client, n.taxonomies) else { return [] }
        var taxonomies: [Taxonomy] = []
        for (index, child) in tree.children(of: list).enumerated() {
            guard let node = graph.resolve(child) else { continue }
            let sourceID = nonEmpty(node, n.id)
            let name = sourceName(node)
            let scope = sourceID.isEmpty ? "taxonomy-\(index)" : sourceID
            let id = unique(UUID(uuidString: sourceID), fallback: "pp-taxonomy|\(scope)", what: name)
            var taxonomy = Taxonomy(id: id, name: named(name, "Taxonomy \(index + 1)"))
            if let root = graph.object(node, n.root) {
                taxonomy.root = readChildren(of: root, scope: scope, depth: 0)
                if let assignments = graph.object(root, n.assignments), tree.hasChildren(assignments) {
                    let direct = readAssignments(assignments, classification: taxonomy.name)
                    if !direct.isEmpty {
                        // Kontor's taxonomy root is a list, so vehicles assigned to PP's root node get their own category.
                        let holder = Classification(id: unique(nil, fallback: "pp-classification|\(scope)|root-assignments", what: name),
                                                    name: taxonomy.name, assignments: direct)
                        taxonomy.root.append(holder)
                        counts.classifications += 1
                        warnings.add(.skippedAssignment, "Assignments made directly to the top of a taxonomy were moved into a category named like the taxonomy", example: taxonomy.name, severity: .info)
                    }
                }
            }
            taxonomies.append(taxonomy)
        }
        return taxonomies
    }

    private mutating func readChildren(of parent: NodeID, scope: String, depth: Int) -> [Classification] {
        guard let list = graph.object(parent, n.children) else { return [] }
        guard depth < 64 else {
            warnings.add(.invalidValue, "A taxonomy is nested deeper than 64 levels; the deeper levels were dropped", example: scope)
            return []
        }
        var items: [(rank: Int64, weight: Int64, hasTargetFlag: Bool, value: Classification)] = []
        for (index, child) in tree.children(of: list).enumerated() {
            guard let node = graph.resolve(child) else { continue }
            let sourceID = nonEmpty(node, n.id)
            let name = sourceName(node)
            let id = unique(UUID(uuidString: sourceID), fallback: "pp-classification|\(scope)|\(sourceID.isEmpty ? "\(depth).\(index).\(name)" : sourceID)", what: name)
            var classification = Classification(id: id, name: named(name, "Category \(index + 1)"))
            let color = nonEmpty(node, n.color)
            if color.hasPrefix("#"), color.count == 7 { classification.color = color.uppercased() }
            classification.note = text(node, n.description) ?? ""
            classification.children = readChildren(of: node, scope: scope, depth: depth + 1)
            if let assignments = graph.object(node, n.assignments) {
                classification.assignments = readAssignments(assignments, classification: classification.name)
            }
            var flagged = false
            if let data = graph.object(node, n.data) {
                flagged = stringMap(data).contains { $0.key == KontorMarker.targetWeightKey }
            }
            counts.classifications += 1
            items.append((integer(node, n.rank) ?? Int64(index), integer(node, n.weight) ?? 0, flagged, classification))
        }
        // PP gives every category a weight (default 100 %). It is only a meaningful target allocation
        // when the siblings add up to 100 %; files written by Kontor flag real targets explicitly.
        let meaningful = items.reduce(Int64(0)) { $0 &+ $1.weight } == 10_000
        let ordered = items.enumerated().sorted { a, b in a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset }
        return ordered.map { item in
            var classification = item.element.value
            if isKontorExport ? item.element.hasTargetFlag : meaningful { classification.targetWeight = Int(item.element.weight) }
            return classification
        }
    }

    private mutating func readAssignments(_ list: NodeID, classification: String) -> [Classification.Assignment] {
        var items: [(rank: Int64, value: Classification.Assignment)] = []
        for (index, child) in tree.children(of: list).enumerated() {
            guard let node = graph.resolve(child) else { continue }
            guard let vehicle = graph.object(node, n.investmentVehicle) else {
                warnings.add(.skippedAssignment, "A taxonomy assignment points to an object that no longer exists and was skipped", example: classification)
                continue
            }
            let weight = Int(integer(node, n.weight) ?? 10_000)
            var assignment = Classification.Assignment(weight: weight)
            if let account = accountIDs[vehicle] {
                assignment.accountID = account
            } else if let security = securityIDs[vehicle] ?? (depotIDs[vehicle] == nil ? registerSecurityIfSecurity(vehicle) : nil) {
                assignment.securityID = security
            } else {
                warnings.add(.skippedAssignment, "A taxonomy assignment refers to something that is neither a security nor an account and was skipped", example: classification)
                continue
            }
            counts.assignments += 1
            items.append((integer(node, n.rank) ?? Int64(index), assignment))
        }
        return items.enumerated().sorted { a, b in a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset }.map(\.element.value)
    }

    /// Registers `node` as a security if it looks like one (has prices or a currency), e.g. an
    /// exchange-rate entry or a security that is missing from the client's list.
    private mutating func registerSecurityIfSecurity(_ node: NodeID) -> UUID? {
        guard exchangeRateNodes[node] != nil || tree.child(node, n.prices) != nil || tree.child(node, n.isin) != nil else { return nil }
        return registerSecurity(node, listed: false)
    }

    // MARK: - Watchlists and settings

    private mutating func readWatchlists(_ client: NodeID) -> [Watchlist] {
        guard let list = graph.object(client, n.watchlists) else { return [] }
        var watchlists: [Watchlist] = []
        for (index, child) in tree.children(of: list).enumerated() {
            guard let node = graph.resolve(child) else { continue }
            let name = sourceName(node)
            var ids: [UUID] = []
            var seen: Set<UUID> = []
            if let members = graph.object(node, n.securities) {
                for member in tree.children(of: members) {
                    guard let security = graph.resolve(member), let id = registerSecurity(security, listed: false) else { continue }
                    if seen.insert(id).inserted { ids.append(id) }
                }
            }
            let id = preservedID("watchlist", index, check: name)?.id ?? StableID.uuid("pp-watchlist|\(index)|\(name)")
            watchlists.append(Watchlist(id: id, name: named(name, "Watchlist \(index + 1)"), securityIDs: ids))
        }
        return watchlists
    }

    private mutating func readSettings(_ client: NodeID) -> (Settings, [Dashboard]) {
        var settings = Settings(baseCurrency: baseCurrency)
        var dashboards: [Dashboard] = []
        let decoder = JSONDecoder()
        if isKontorExport {
            if let json = properties[KontorMarker.settings], var stored = try? decoder.decode(Settings.self, from: Data(json.utf8)) {
                stored.baseCurrency = baseCurrency
                settings = stored
            }
            if let json = properties[KontorMarker.dashboards], let stored = try? decoder.decode([Dashboard].self, from: Data(json.utf8)) {
                dashboards = stored
            }
            return (settings, dashboards)
        }

        if let node = graph.object(client, n.settings) {
            if let bookmarks = graph.object(node, n.bookmarks) {
                var items: [[String: String]] = []
                for child in tree.children(of: bookmarks) {
                    guard let bookmark = graph.resolve(child) else { continue }
                    let label = nonEmpty(bookmark, n.label), pattern = nonEmpty(bookmark, n.pattern)
                    if !pattern.isEmpty { items.append(["label": label, "pattern": pattern]) }
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if !items.isEmpty, let data = try? encoder.encode(items) {
                    settings.preferences["pp.bookmarks"] = String(decoding: data, as: UTF8.self)
                }
            }
            if let sets = graph.object(node, n.configurationSets), tree.hasChildren(sets) {
                warnings.add(.skippedSettings, "Table layouts, chart configurations and saved filters are specific to Portfolio Performance and were not imported", severity: .info)
            }
        }
        if let list = graph.object(client, n.dashboards) {
            let count = tree.children(of: list).reduce(0) { total, _ in total + 1 }
            if count > 0 {
                warnings.add(.skippedDashboards, "\(count) dashboard(s) were not imported because Kontor uses its own dashboard widgets", severity: .info)
            }
        }
        return (settings, dashboards)
    }
}

/// Maps byte offsets to line numbers for diagnostics. The index is built on first use, so files
/// without problems never pay for it, and files with thousands of problems pay only once.
private final class LineIndex {
    private let bytes: [UInt8]
    private lazy var lineStarts: [Int] = {
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 10 { starts.append(offset + 1) }
        return starts
    }()

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// 1-based line containing the byte at `offset`.
    func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(low, 1)
    }
}

/// Facts about the Portfolio Performance file format shared by importer and exporter.
public enum PortfolioPerformanceFormat {
    /// Newest `<version>` the importer has been verified against. Newer files are read on a best-effort basis.
    public static let newestKnownVersion = 70
    /// The `<version>` written by the exporter — old enough to be opened by every PP release since 2022.
    public static let exportedVersion = 56
}
