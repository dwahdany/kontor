import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

/// A Kontor document exercising every feature the exporter has to carry.
func makeRichFile() -> PortfolioFile {
    func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "C0FFEE00-0000-4000-8000-%012d", n))! }
    let giro = Account(id: uuid(1), name: "Giro", currency: "EUR", note: "main")
    let dollars = Account(id: uuid(2), name: "Dollar \"Account\"", currency: "USD", isRetired: true)
    let depot = Depot(id: uuid(3), name: "Broker", referenceAccountID: giro.id, note: "note <1>")
    let vault = Depot(id: uuid(4), name: "Vault", isRetired: true)

    var acme = Security(id: uuid(10), name: "ACME & Co", currency: "EUR", isin: "DE000ACME001", wkn: "ACME01", ticker: "ACME", note: "multi\nline",
                        feed: QuoteFeed(provider: "yahoo", symbol: "ACME.DE"), attributes: ["TER": "0.22", "Vendor": "ACME Asset Management"],
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_123))
    acme.prices = PriceSeries((0..<400).map { PricePoint(day: Day(year: 2023, month: 1, day: 1).advanced(by: $0), price: Price(raw: 10_000_000_000 + Int64($0) * 12_345_678)) })
    acme.events = [
        SecurityEvent(id: uuid(11), day: day("2023-06-01"), kind: .split, detail: "2:1"),
        SecurityEvent(id: uuid(12), day: day("2023-07-01"), kind: .dividend, detail: "0.52 EUR"),
        SecurityEvent(id: uuid(13), day: day("2023-08-01"), kind: .dividend, detail: "special | not a number"),
        SecurityEvent(id: uuid(14), day: day("2023-09-01"), kind: .note, detail: "AGM"),
    ]
    var globex = Security(id: uuid(20), name: "Globex", currency: "USD", isin: "US0000GLBX01", ticker: "GLBX", isRetired: true,
                          feed: QuoteFeed(provider: "json-url", symbol: "https://example.com/q.json", options: ["datePath": "$.d", "closePath": "$.c", "custom": "x"]))
    globex.prices = PriceSeries([PricePoint(day: day("2024-01-02"), price: Price(12.5))])
    let coin = Security(id: uuid(30), name: "Bitcoin", currency: "EUR", ticker: "BTC", feed: QuoteFeed(provider: "coingecko", symbol: "bitcoin"))
    let manual = Security(id: uuid(40), name: "Private Equity Fund", currency: "EUR", feed: .manual)
    let exotic = Security(id: uuid(50), name: "Exotic", currency: "EUR", feed: QuoteFeed(provider: "my-own-provider", symbol: "XYZ", options: ["k": "v"]))
    let bare = Security(id: uuid(60), name: "No feed", currency: "CHF")

    func t(_ n: Int, _ kind: Transaction.Kind, _ date: String, _ amount: Int64, currency: String = "EUR") -> Transaction {
        Transaction(id: uuid(100 + n), kind: kind, date: day(date), amount: Money(minor: amount, currency: currency), source: "manual")
    }
    var transactions: [Transaction] = []
    var deposit = t(1, .deposit, "2024-01-02", 5_000_000); deposit.accountID = giro.id; deposit.note = "Start & go"; deposit.source = nil
    var buy = t(2, .buy, "2024-01-03", 101_000); buy.accountID = giro.id; buy.depotID = depot.id; buy.securityID = acme.id
    buy.shares = Shares(10); buy.fees = 900; buy.taxes = 100; buy.minuteOfDay = 9 * 60 + 5; buy.source = "plan:\(uuid(70).uuidString)"
    var forexBuy = t(3, .buy, "2024-01-04", 92_500); forexBuy.accountID = giro.id; forexBuy.depotID = depot.id; forexBuy.securityID = globex.id
    forexBuy.shares = Shares(8.12345678); forexBuy.fees = 500; forexBuy.securityGross = Money(minor: 100_000, currency: "USD")
    var sell = t(4, .sell, "2024-02-01", 49_000); sell.accountID = giro.id; sell.depotID = depot.id; sell.securityID = acme.id
    sell.shares = Shares(5); sell.fees = 500; sell.taxes = 500; sell.minuteOfDay = 23 * 60 + 59
    var deliveryIn = t(5, .deliveryIn, "2024-02-02", 30_000); deliveryIn.depotID = vault.id; deliveryIn.securityID = coin.id; deliveryIn.shares = Shares(raw: 1_234_567); deliveryIn.fees = 10
    var deliveryOut = t(6, .deliveryOut, "2024-02-03", 10_000); deliveryOut.depotID = vault.id; deliveryOut.securityID = coin.id; deliveryOut.shares = Shares(raw: 234_567); deliveryOut.taxes = 7
    var withdrawal = t(7, .withdrawal, "2024-02-04", 20_000); withdrawal.accountID = giro.id
    var dividend = t(8, .dividend, "2024-03-01", 1_840); dividend.accountID = giro.id; dividend.securityID = globex.id; dividend.shares = Shares(8.12345678)
    dividend.taxes = 460; dividend.fees = 0; dividend.securityGross = Money(minor: 2_500, currency: "USD")
    var interest = t(9, .interest, "2024-03-02", 750); interest.accountID = giro.id; interest.taxes = 250
    var charge = t(10, .interestCharge, "2024-03-03", 99); charge.accountID = giro.id
    var fee = t(11, .fee, "2024-03-04", 1_500); fee.accountID = giro.id; fee.securityID = acme.id
    var feeRefund = t(12, .feeRefund, "2024-03-05", 500); feeRefund.accountID = giro.id
    var tax = t(13, .tax, "2024-03-06", 2_600); tax.accountID = giro.id
    var taxRefund = t(14, .taxRefund, "2024-03-07", 600); taxRefund.accountID = giro.id; taxRefund.securityID = acme.id
    var transfer = t(15, .cashTransfer, "2024-03-08", 100_000); transfer.accountID = giro.id; transfer.counterAccountID = dollars.id
    transfer.counterAmount = Money(minor: 108_370, currency: "USD")
    var back = t(16, .cashTransfer, "2024-03-09", 1_000, currency: "USD"); back.accountID = dollars.id; back.counterAccountID = giro.id
    back.counterAmount = Money(minor: 920, currency: "EUR")
    var move = t(17, .securityTransfer, "2024-03-10", 50_500); move.depotID = depot.id; move.counterDepotID = vault.id; move.securityID = acme.id; move.shares = Shares(5)
    var planned = t(18, .deposit, "2024-03-15", 10_000); planned.accountID = giro.id; planned.source = "plan:\(uuid(71).uuidString)"
    transactions = [deposit, buy, forexBuy, sell, deliveryIn, deliveryOut, withdrawal, dividend, interest, charge, fee, feeRefund, tax, taxRefund, transfer, back, move, planned]

    let taxonomy = Taxonomy(id: uuid(80), name: "Asset Allocation", root: [
        Classification(id: uuid(81), name: "Equity", color: "#FF0000", targetWeight: 7000, note: "growth", children: [
            Classification(id: uuid(82), name: "Europe", color: "#AA0000", targetWeight: 5000, assignments: [.init(securityID: acme.id, weight: 6000)]),
            Classification(id: uuid(83), name: "World", color: "#BB0000", assignments: [.init(securityID: acme.id, weight: 4000), .init(securityID: globex.id)]),
        ]),
        Classification(id: uuid(84), name: "Cash", color: "#00FF00", targetWeight: nil, assignments: [.init(accountID: giro.id), .init(accountID: dollars.id, weight: 2500)]),
        Classification(id: uuid(85), name: "Crypto", color: "#0000FF", targetWeight: 0, assignments: [.init(securityID: coin.id)]),
    ])
    let empty = Taxonomy(id: uuid(86), name: "Empty")

    var settings = Settings(baseCurrency: "EUR", costMethod: .average, benchmarkSecurityIDs: [globex.id], riskFreeRate: 0.025, preferences: ["theme": "dark", "weird": "<&>\"'"])
    settings.preferences["pp.bookmarks"] = #"[{"label":"Yahoo","pattern":"https://finance.yahoo.com/quote/{tickerSymbol}"}]"#

    return PortfolioFile(
        name: "Rich & Famous", settings: settings, securities: [acme, globex, coin, manual, exotic, bare], accounts: [giro, dollars], depots: [depot, vault],
        transactions: transactions.sorted { ($0.date, $0.minuteOfDay ?? -1) < ($1.date, $1.minuteOfDay ?? -1) }, taxonomies: [taxonomy, empty],
        watchlists: [Watchlist(id: uuid(90), name: "Watch | list", securityIDs: [globex.id, acme.id]), Watchlist(id: uuid(91), name: "Empty")],
        plans: [
            InvestmentPlan(id: uuid(70), name: "ACME monthly", kind: .purchase, securityID: acme.id, depotID: depot.id, accountID: giro.id,
                           amount: Money(minor: 25_000, currency: "EUR"), fees: 150, start: day("2024-01-03"), end: day("2026-12-31"), intervalMonths: 1, note: "auto"),
            InvestmentPlan(id: uuid(71), name: "Salary share", kind: .deposit, accountID: giro.id, amount: Money(minor: 10_000, currency: "EUR"), start: day("2024-03-15"), intervalMonths: 3),
            InvestmentPlan(id: uuid(72), name: "Rent", kind: .withdrawal, accountID: giro.id, amount: Money(minor: 80_000, currency: "EUR"), start: day("2024-04-01"), intervalMonths: 1),
        ],
        exchangeRates: [ExchangeRateSeries(base: "EUR", quote: "USD", days: [day("2024-03-07").rawValue, day("2024-03-08").rawValue], rates: [1.0812, 1.0837])],
        dashboards: [Dashboard(id: uuid(95), name: "Overview", widgets: [.init(id: uuid(96), kind: "performance", title: "Perf", span: 2, config: ["period": "1Y"])])]
    )
}

@Suite struct PPExportTests {
    private let options = PortfolioPerformanceExportOptions(timestamp: Date(timeIntervalSince1970: 1_750_000_000))

    @Test(arguments: [PortfolioPerformanceExportOptions.ReferenceStyle.xpath, .id])
    func roundTripIsLossless(style: PortfolioPerformanceExportOptions.ReferenceStyle) throws {
        let file = makeRichFile()
        try assertIntegrity(file)
        var options = options
        options.referenceStyle = style
        let export = PortfolioPerformanceExporter.export(file, options: options)
        let imported = try PortfolioPerformanceImporter.read(export.data, name: "ignored")

        #expect(imported.file.name == file.name)
        #expect(imported.file.settings == file.settings)
        #expect(imported.file.securities == file.securities)
        #expect(imported.file.accounts == file.accounts)
        #expect(imported.file.depots == file.depots)
        #expect(imported.file.transactions == file.transactions)
        #expect(imported.file.taxonomies == file.taxonomies)
        #expect(imported.file.watchlists == file.watchlists)
        #expect(imported.file.plans == file.plans)
        #expect(imported.file.exchangeRates == file.exchangeRates)
        #expect(imported.file.dashboards == file.dashboards)
        #expect(imported.file == file)
        #expect(imported.report.warnings.filter { $0.severity == .warning }.isEmpty)
        #expect(imported.report.sourceVersion == PortfolioPerformanceFormat.exportedVersion)

        // Exporting is deterministic, and a second generation is identical to the first.
        #expect(PortfolioPerformanceExporter.export(file, options: options).data == export.data)
        #expect(PortfolioPerformanceExporter.export(imported.file, options: options).data == export.data)
    }

    @Test func outputLooksLikePortfolioPerformanceWroteIt() throws {
        let file = makeRichFile()
        let export = PortfolioPerformanceExporter.export(file, options: options)
        let xml = String(decoding: export.data, as: UTF8.self)
        #expect(xml.hasPrefix("<client>\n  <version>56</version>\n  <baseCurrency>EUR</baseCurrency>\n  <securities>\n    <security>\n      <uuid>c0ffee00-0000-4000-8000-000000000010</uuid>"))
        #expect(xml.contains("<name>ACME &amp; Co</name>"))
        #expect(xml.contains("<price t=\"2023-01-01\" v=\"10000000000\"/>"))
        #expect(xml.contains("<feed>YAHOO</feed>"))
        #expect(xml.contains("<tickerSymbol>ACME.DE</tickerSymbol>")) // PP's Yahoo feed is driven by the ticker symbol
        #expect(xml.contains("<feed>GENERIC-JSON</feed>"))
        #expect(xml.contains("<property type=\"FEED\" name=\"GENERIC-JSON-DATE\">$.d</property>"))
        #expect(xml.contains("<property type=\"FEED\" name=\"COINGECKOCOINID\">bitcoin</property>"))
        #expect(xml.contains("<targetCurrencyCode>USD</targetCurrencyCode>"))
        #expect(xml.contains("<date>2024-01-03T09:05</date>"))
        #expect(xml.contains("<crossEntry class=\"buysell\">"))
        #expect(xml.contains("<crossEntry class=\"account-transfer\">"))
        #expect(xml.contains("<crossEntry class=\"portfolio-transfer\">"))
        #expect(xml.contains("<unit type=\"GROSS_VALUE\">"))
        #expect(xml.contains("<forex currency=\"USD\" amount=\"100000\"/>"))
        #expect(xml.contains("<exchangeRate>0.9200</exchangeRate>"))
        #expect(xml.contains("<dividendEvent>"))
        #expect(xml.contains("<investmentVehicle class=\"account\" reference="))
        #expect(xml.contains("<amount>-80000</amount>")) // removal plans are negative in format 56
        #expect(xml.contains("name.abuchen.portfolio.model.AttributeType$StringConverter"))
        #expect(export.warnings.contains { $0.code == .notExportable && $0.message.contains("Quote providers") && $0.examples == ["Exotic (my-own-provider)"] })

        // PP's ledgers: each purchase/sale/transfer appears on both sides, linked by one cross entry.
        let tree = try XMLTree(parsing: [UInt8](export.data))
        let graph = XStreamGraph(tree)
        #expect(graph.unresolved.isEmpty)
        func objects(_ name: String) -> Int {
            let id = tree.nameID(name)
            return tree.nodes.indices.filter { tree.nodes[$0].name == id && !graph.isReference(Int32($0)) }.count
        }
        #expect(objects("crossEntry") == 3 + 2 + 1) // buys/sells + account transfers + portfolio transfer
        let accountSide = objects("account-transaction") + objects("accountTransaction") + objects("transactionFrom") + objects("transactionTo")
        let portfolioSide = objects("portfolio-transaction") + objects("portfolioTransaction")
        // 18 Kontor entries -> 3 buy/sell pairs, 2 cash transfer pairs, 1 securities transfer pair, 2 deliveries, 10 single cash bookings
        #expect(accountSide + portfolioSide == 3 * 2 + 2 * 2 + 1 * 2 + 2 + 10)

        // Every PP amount check holds: gross-value units agree with forex × rate (PP rejects files where they do not).
        let unit = tree.nameID("unit"), amount = tree.nameID("amount"), forex = tree.nameID("forex"), rate = tree.nameID("exchangeRate")
        for index in tree.nodes.indices where tree.nodes[index].name == unit {
            let node = Int32(index)
            guard let forexNode = tree.child(node, forex) else { continue }
            let value = Double(tree.attribute(tree.child(node, amount)!, amount)!)!
            let foreign = Double(tree.attribute(forexNode, amount)!)!
            let exchangeRate = Double(tree.text(of: tree.child(node, rate)!))!
            #expect(abs(value - foreign * exchangeRate) <= 1.0)
        }
    }

    @Test func idStyleIsRecognisableByPortfolioPerformance() {
        var options = options
        options.referenceStyle = .id
        let xml = String(decoding: PortfolioPerformanceExporter.export(makeRichFile(), options: options).data, as: UTF8.self)
        // PP sniffs the first 100 bytes for "<client id=" to choose its reference mode.
        #expect(xml.prefix(100).contains("<client id="))
        #expect(!xml.contains("reference=\"../"))
    }

    @Test(arguments: ["kommer.xml", "client52.xml", "currency_sample.xml", "classification_test_case.xml", "trade_test_case.xml",
                      "client_performance_snapshot.xml", "synthetic_all_types.xml", "Issue1498FifoCrossPortfolio.xml"])
    func realFilesSurviveExportAndReimport(fixture: String) throws {
        let original = try Fixture.pp(fixture).file
        for style in [PortfolioPerformanceExportOptions.ReferenceStyle.xpath, .id] {
            let export = PortfolioPerformanceExporter.export(original, options: .init(referenceStyle: style, timestamp: options.timestamp))
            let again = try PortfolioPerformanceImporter.read(export.data, name: fixture)
            #expect(again.file == original)
            #expect(again.report.counts.transactions == original.transactions.count)
            #expect(!again.report.warnings.contains { $0.code == .unresolvedReference })
        }
    }

    @Test func reportsWhatPortfolioPerformanceCannotHold() throws {
        var file = PortfolioFile(name: "Odd")
        let account = Account(name: "A", currency: "EUR")
        let depot = Depot(name: "D")
        let security = Security(name: "S", currency: "EUR")
        file.accounts = [account]; file.depots = [depot]; file.securities = [security]
        file.transactions = [
            Transaction(kind: .buy, date: day("2024-01-01"), depotID: depot.id, securityID: security.id, shares: Shares(1), amount: Money(1, "EUR")), // no account
            Transaction(kind: .cashTransfer, date: day("2024-01-02"), accountID: account.id, amount: Money(2, "EUR")), // no target
            Transaction(kind: .securityTransfer, date: day("2024-01-03"), depotID: depot.id, securityID: security.id, shares: Shares(1), amount: Money(3, "EUR")), // no target
            Transaction(kind: .deposit, date: day("2024-01-04"), amount: Money(4, "EUR")), // no account at all
            Transaction(kind: .sell, date: day("2024-01-05"), accountID: account.id, shares: Shares(1), amount: Money(5, "EUR")), // no depot/security
        ]
        let export = PortfolioPerformanceExporter.export(file)
        #expect(export.warnings.filter { $0.code == .notExportable }.count == 5)
        let imported = try PortfolioPerformanceImporter.read(export.data).file
        #expect(imported.transactions.map(\.kind) == [.deliveryIn, .withdrawal, .deliveryOut])
        try assertIntegrity(imported)
    }

    @Test func emptyDocument() throws {
        let export = PortfolioPerformanceExporter.export(PortfolioFile(name: "", settings: Settings(baseCurrency: "USD")))
        let imported = try PortfolioPerformanceImporter.read(export.data, name: "Empty")
        #expect(imported.file == PortfolioFile(name: "Empty", settings: Settings(baseCurrency: "USD")))
    }
}
