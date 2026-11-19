import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

/// Assertions against unmodified files from the Portfolio Performance repository. Expected values
/// were established independently of the importer (by inspecting the XML with a separate script).
@Suite struct PPFixtureTests {
    private func id(_ string: String) -> UUID { UUID(uuidString: string)! }

    @Test func kommerDemoPortfolio() throws {
        let result = try Fixture.pp("kommer.xml")
        let file = result.file, report = result.report

        #expect(report.sourceVersion == 60)
        #expect(report.counts.securities == 15)
        #expect(report.counts.accounts == 4)
        #expect(report.counts.depots == 2)
        #expect(report.counts.transactions == 102)
        #expect(report.counts.transactionsByKind == [.buy: 9, .deliveryIn: 4, .deliveryOut: 3, .deposit: 5, .dividend: 81])
        #expect(report.counts.taxonomies == 5)
        #expect(report.counts.watchlists == 2)
        #expect(report.counts.plans == 0)
        #expect(report.counts.assignments == 155)
        #expect(file.settings.baseCurrency == "EUR")
        #expect(file.name == "kommer.xml")
        #expect(Set(file.transactions.map(\.id)).count == 102)
        #expect(file.transactions.allSatisfy { $0.source == "pp-import" })
        #expect(zip(file.transactions, file.transactions.dropFirst()).allSatisfy { $0.date <= $1.date })

        // Accounts keep the order of the file, including the USD account that is first serialized deep inside a cross entry.
        #expect(file.accounts.map(\.name) == ["${Kommer_DepositAccount}", "${Kommer_CallDepositMoneyAccount}", "${Kommer_ForeignCurrencyAccountUSD}", "${Kommer_ForeignCurrencyAccountGBP}"])
        #expect(file.accounts.map(\.currency) == ["EUR", "EUR", "USD", "GBP"])
        #expect(file.accounts[2].id == id("789294db-0aa4-4673-9d91-ad083c9d6916"))
        #expect(file.depots.map(\.name) == ["${Kommer_BrokerageAccount}", "${Kommer_CryptocurrencyAccount}"])
        #expect(file.depots.allSatisfy { $0.referenceAccountID == file.accounts[0].id })

        // Securities.
        let bond = try #require(file.security(id("99b9419f-8c70-422e-8e8e-05eadb4507ec")))
        #expect(bond.name == "iShares Core Euro Government Bond UCITS ETF (Dist)")
        #expect(bond.isin == "IE00B4WXJJ64")
        #expect(bond.wkn == "A0RL83")
        #expect(bond.ticker == "EUNH.DE")
        #expect(bond.currency == "EUR")
        #expect(bond.attributes["Anbieter"] != nil || !bond.attributes.isEmpty)
        let dax = file.securities[0]
        #expect(dax.name == "Dax")
        #expect(dax.feed == QuoteFeed(provider: "yahoo", symbol: "^GDAXI"))
        // one historical price plus the separately stored latest quote
        #expect(dax.prices.count == 2)
        #expect(dax.prices.price(on: day("2018-01-02"), fallbackToFirst: false) == Price(raw: 1_287_139_000_000))
        #expect(dax.prices.latest == PricePoint(day: day("2021-01-08"), price: Price(raw: 1_404_953_000_000)))
        let bitcoin = try #require(file.security(id("4fcafd74-6fe9-4699-8fe7-8ec44136392e")))
        #expect(bitcoin.feed == QuoteFeed(provider: "coingecko", symbol: "bitcoin"))
        let amazon = try #require(file.security(id("3cfa101b-0558-4ec4-a9e5-baab4eeddb2a")))
        #expect(amazon.currency == "USD")
        #expect(amazon.events.count == 1)
        #expect(report.counts.prices == 18)

        // A purchase: account side + portfolio side + cross entry collapse into one entry.
        let buy = try #require(file.transactions.first { $0.id == id("2c8cacef-faef-4192-a958-a075cb176c1f") })
        #expect(buy.kind == .buy)
        #expect(buy.date == day("2019-01-07"))
        #expect(buy.minuteOfDay == nil)
        #expect(buy.amount == Money(minor: 294_683, currency: "EUR"))
        #expect(buy.shares == Shares(raw: 2_400_000_000))
        #expect(buy.fees == 995)
        #expect(buy.taxes == 0)
        #expect(buy.securityID == bond.id)
        #expect(buy.accountID == file.accounts[0].id)
        #expect(buy.depotID == file.depots[0].id)
        #expect(!file.transactions.contains { $0.id == id("2e83b15a-c62d-4084-9a4a-664473db55ef") }) // its account side is not a second entry

        // A purchase settled in the USD account.
        let usd = try #require(file.transactions.first { $0.id == id("75ef09c8-8632-4f3e-b93c-02bcc5c9b08c") })
        #expect(usd.kind == .buy)
        #expect(usd.amount == Money(minor: 267_600, currency: "USD"))
        #expect(usd.shares == Shares(raw: 2_000_000_000))
        #expect(usd.fees == 600)
        #expect(usd.securityID == amazon.id)
        #expect(usd.accountID == file.accounts[2].id)

        // A dividend with withheld tax.
        let dividend = try #require(file.transactions.first { $0.id == id("e3700faa-6685-4091-8cf3-de99d2300e23") })
        #expect(dividend.kind == .dividend)
        #expect(dividend.date == day("2019-08-12"))
        #expect(dividend.amount == Money(minor: 870, currency: "EUR"))
        #expect(dividend.taxes == 290)
        #expect(dividend.shares == Shares(raw: 1_000_000_000))
        #expect(dividend.securityID == id("ff0a2b77-9749-45b0-8333-cb1d9787812c"))
        #expect(dividend.accountID == file.accounts[0].id)
        #expect(dividend.depotID == nil)

        // Deliveries of a crypto asset with fractional share counts.
        let delivery = try #require(file.transactions.first { $0.id == id("5ab057e3-659e-4f66-982f-5a64c5c7eed1") })
        #expect(delivery.kind == .deliveryOut)
        #expect(delivery.date == day("2021-01-11"))
        #expect(delivery.amount.minor == 19_562)
        #expect(delivery.shares == Shares(raw: 775_933))
        #expect(delivery.securityID == bitcoin.id)
        #expect(delivery.depotID == file.depots[1].id)
        #expect(delivery.accountID == nil)

        // Taxonomies: tree sizes, colours, assignments to securities *and* accounts.
        #expect(file.taxonomies.map(\.name) == ["Anlagekategorien", "Asset Allocation", "Branchen (GICS, Sektoren)", "Regionen", "Regionen (MSCI)"])
        func count(_ nodes: [Classification]) -> Int { nodes.reduce(0) { $0 + 1 + count($1.children) } }
        func assignments(_ nodes: [Classification]) -> Int { nodes.reduce(0) { $0 + $1.assignments.count + assignments($1.children) } }
        #expect(file.taxonomies.map { count($0.root) } == [5, 8, 12, 253, 100])
        #expect(file.taxonomies.map { assignments($0.root) } == [18, 11, 40, 43, 43])
        #expect(report.counts.classifications == 378)
        let assetClasses = file.taxonomies[0]
        #expect(assetClasses.root.map(\.name) == ["Barvermögen", "Eigenkapital", "Fremdkapital", "Immobilien", "Rohstoffe"])
        let cash = assetClasses.root[0]
        #expect(cash.color == "#C437C2")
        #expect(cash.targetWeight == nil) // PP's default weights (5 × 100 %) are not a real target allocation
        #expect(cash.assignments.count == 5)
        #expect(cash.assignments.map(\.accountID) == [file.accounts[0].id, file.accounts[1].id, nil, file.accounts[3].id, file.accounts[2].id])
        #expect(cash.assignments[2].securityID == bitcoin.id)
        #expect(cash.assignments.allSatisfy { $0.weight == 10_000 })
        // Assignments are ordered by PP's rank, not by position in the file.
        #expect(assetClasses.root[1].assignments.prefix(2).map(\.securityID) == [id("c770a389-0a84-442c-ad85-2a58c3066924"), id("47094920-535c-4508-9a92-80c01933f567")])
        // Partial assignments (a world ETF split over regions).
        let partial = file.taxonomies.flatMap { flatten($0.root) }.flatMap(\.assignments).filter { $0.weight != 10_000 }
        #expect(partial.contains { $0.securityID == id("c770a389-0a84-442c-ad85-2a58c3066924") && $0.weight == 442 })

        // Watchlists.
        #expect(file.watchlists.map(\.name) == ["${Kommer_WatchlistIndices}", "${Kommer_WatchlistAsia}"])
        #expect(file.watchlists[0].securityIDs == Array(file.securities.prefix(3).map(\.id)))
        #expect(file.watchlists[1].securityIDs.isEmpty)

        // Nothing is dropped silently.
        #expect(report.warnings.contains { $0.code == .skippedDashboards && $0.severity == .info })
        #expect(report.warnings.contains { $0.code == .approximatedQuoteFeed && $0.count == 10 })
        #expect(report.warnings.contains { $0.code == .unknownQuoteFeed })
        #expect(!report.warnings.contains { $0.code == .unresolvedReference })
        #expect(!report.isLossless)
        #expect(report.summary.contains("102 transactions"))

        // Referential integrity of the whole result.
        try assertIntegrity(file)
    }

    private func flatten(_ nodes: [Classification]) -> [Classification] { nodes.flatMap { [$0] + flatten($0.children) } }

    @Test func multiCurrencySampleInAnOldFormat() throws {
        // Format 29: quotes have two decimals and shares six — both are rescaled to eight.
        let result = try Fixture.pp("currency_sample.xml")
        let file = result.file
        #expect(result.report.sourceVersion == 29)
        #expect(result.report.counts.transactionsByKind == [.buy: 5, .deposit: 6])
        #expect(file.accounts.map(\.currency) == ["EUR", "USD"])

        let apple = try #require(file.securities.first { $0.name == "Apple" })
        #expect(apple.currency == "USD")
        #expect(apple.prices.count == 1409)
        #expect(apple.prices.price(on: day("2010-01-04")) == Price(30.57))
        #expect(apple.prices.latest == PricePoint(day: day("2015-08-07"), price: Price(115.51)))
        #expect(apple.events.map(\.kind) == [.split])
        #expect(apple.events[0].detail == "7:1")
        #expect(apple.events[0].day == day("2014-06-09"))
        let basf = try #require(file.securities.first { $0.name == "BASF" })
        #expect(basf.prices.count == 1328)
        #expect(result.report.counts.prices == 2737)

        // Apple (USD) bought from the EUR account: gross value carried in the security's currency.
        let forex = try #require(file.transactions.first { $0.kind == .buy && $0.securityID == apple.id && $0.amount.currency == "EUR" })
        #expect(forex.amount.minor == 45_460)
        #expect(forex.shares == Shares(5))
        #expect(forex.securityGross == Money(minor: 55_190, currency: "USD"))
        #expect(forex.fees == 0)
        #expect(forex.date == day("2015-01-01"))

        // BASF (EUR) bought from the USD account.
        let reverse = try #require(file.transactions.first { $0.kind == .buy && $0.securityID == basf.id && $0.amount.currency == "USD" })
        #expect(reverse.amount.minor == 84_841)
        #expect(reverse.shares == Shares(10))
        #expect(reverse.securityGross == Money(minor: 69_880, currency: "EUR"))

        // Same-currency purchase with fees and taxes.
        let plain = try #require(file.transactions.first { $0.kind == .buy && $0.securityID == basf.id && $0.amount.currency == "EUR" })
        #expect(plain.amount.minor == 71_880)
        #expect(plain.fees == 1000)
        #expect(plain.taxes == 1000)
        #expect(plain.grossMinor == 69_880)
        #expect(plain.securityGross == nil)

        // A transaction whose <date> element is itself a reference to another transaction's date.
        #expect(file.transactions.contains { $0.kind == .buy && $0.date == day("2015-08-03") && $0.amount == Money(minor: 57_760, currency: "USD") })
        // Transaction ids are derived (the format has none) but stable across imports.
        #expect(try Fixture.pp("currency_sample.xml").file == file)
        try assertIntegrity(file)
    }

    @Test func everyTransactionTypeIncludingTransfers() throws {
        let result = try Fixture.pp("classification_test_case.xml")
        let file = result.file
        #expect(result.report.sourceVersion == 34)
        #expect(result.report.counts.transactions == 25)
        #expect(result.report.counts.transactionsByKind == [
            .buy: 6, .sell: 1, .deliveryIn: 1, .deliveryOut: 1, .deposit: 3, .withdrawal: 1, .dividend: 2, .interest: 1, .interestCharge: 1,
            .fee: 1, .feeRefund: 1, .tax: 1, .taxRefund: 2, .cashTransfer: 2, .securityTransfer: 1,
        ])
        func account(_ name: String) -> UUID? { file.accounts.first { $0.name == name }?.id }
        func depot(_ name: String) -> UUID? { file.depots.first { $0.name == name }?.id }
        #expect(file.accounts.map(\.name) == ["Konto 1", "Konto 2", "Account Forex", "Konto 3"])

        let transfers = file.transactions.filter { $0.kind == .cashTransfer }
        let plain = try #require(transfers.first { $0.date == day("2012-01-25") })
        #expect(plain.accountID == account("Konto 2"))
        #expect(plain.counterAccountID == account("Konto 1"))
        #expect(plain.amount == Money(minor: 10_000, currency: "EUR"))
        #expect(plain.counterAmount == nil)
        let cross = try #require(transfers.first { $0.date == day("2012-01-17") })
        #expect(cross.accountID == account("Account Forex"))
        #expect(cross.counterAccountID == account("Konto 3"))
        #expect(cross.amount == Money(minor: 10_000, currency: "USD"))
        #expect(cross.counterAmount == Money(minor: 7_819, currency: "EUR"))

        let move = try #require(file.transactions.first { $0.kind == .securityTransfer })
        #expect(move.depotID == depot("Depot 1"))
        #expect(move.counterDepotID == depot("Depot 2"))
        #expect(move.date == day("2012-01-11"))
        #expect(move.shares == Shares(90)) // 90000000 at six decimals
        #expect(move.amount.minor == 666_000)
        #expect(file.security(move.securityID)?.name == "Allianz SE")

        let sell = try #require(file.transactions.first { $0.kind == .sell })
        #expect(sell.date == day("2012-01-10"))
        #expect(sell.amount.minor == 68_836)
        #expect(sell.shares == Shares(74.8))
        #expect(sell.fees == 1000)
        #expect(sell.taxes == 1000)
        #expect(file.security(sell.securityID)?.name == "Commerzbank AG")

        // Twelve small taxonomies with three categories each.
        #expect(file.taxonomies.count == 12)
        #expect(file.taxonomies.allSatisfy { $0.root.count + $0.root.reduce(0) { $0 + $1.children.count } == 3 })
        #expect(result.report.counts.assignments == 28)
        try assertIntegrity(file)
    }

    @Test func tradesFixtureMatchesIndependentCounts() throws {
        let report = try Fixture.pp("trade_test_case.xml").report
        #expect(report.counts.transactionsByKind == [
            .buy: 8, .sell: 3, .deliveryOut: 1, .deposit: 3, .withdrawal: 1, .dividend: 2, .interest: 1, .interestCharge: 1,
            .fee: 1, .feeRefund: 1, .tax: 1, .taxRefund: 2, .cashTransfer: 2, .securityTransfer: 2,
        ])
        let snapshot = try Fixture.pp("client_performance_snapshot.xml").report
        #expect(snapshot.counts.transactionsByKind == [
            .buy: 3, .sell: 1, .deliveryIn: 1, .deliveryOut: 1, .deposit: 9, .withdrawal: 1, .dividend: 1, .interest: 5, .interestCharge: 1,
            .fee: 1, .feeRefund: 1, .tax: 1, .taxRefund: 1, .cashTransfer: 1,
        ])
        let crossPortfolio = try Fixture.pp("Issue1498FifoCrossPortfolio.xml")
        #expect(crossPortfolio.report.counts.transactionsByKind == [.buy: 3, .sell: 1, .deposit: 3, .securityTransfer: 1])
        #expect(crossPortfolio.file.depots.count == 4)
        let feeTax = try Fixture.pp("security_tax_and_fee_account_transactions.xml")
        #expect(feeTax.report.counts.transactionsByKind == [.buy: 1, .deposit: 1, .fee: 1, .feeRefund: 1, .tax: 1, .taxRefund: 1])
        // Fees and taxes may be attributed to a security.
        #expect(feeTax.file.transactions.filter { [.fee, .feeRefund, .tax, .taxRefund].contains($0.kind) }.allSatisfy { $0.securityID != nil })
        let dividendFees = try Fixture.pp("Issue1897AddFeesToDividendTransactions.xml").file
        let dividend = try #require(dividendFees.transactions.first { $0.kind == .dividend })
        #expect(dividend.fees > 0)
    }

    @Test func plansAttributesAndEventsOfFormat52() throws {
        let result = try Fixture.pp("client52.xml")
        let file = result.file
        #expect(result.report.sourceVersion == 52)
        #expect(file.accounts.map(\.name) == ["My Cash Account"])
        #expect(file.depots.map(\.name) == ["My Securities Account"])
        #expect(file.depots[0].referenceAccountID == file.accounts[0].id)

        // The "Exchange Rate" pseudo security becomes an exchange-rate series instead of a security.
        #expect(file.securities.map(\.name) == ["Security with all Attributes", "Deutschland (HVPI)", "Security with all Attributes null"])
        #expect(file.exchangeRates.count == 1)
        #expect(file.exchangeRates[0].base == "EUR")
        #expect(file.exchangeRates[0].quote == "LVL")

        let rich = file.securities[0]
        #expect(rich.feed == .manual)
        #expect(rich.prices.count == 1)
        #expect(rich.prices.latest?.price == Price(1000))
        #expect(rich.events.map(\.kind) == [.split, .note, .dividend])
        #expect(rich.events[0].detail == "2:1")
        #expect(rich.events[0].day == day("2021-08-01"))
        #expect(rich.events[2].detail == "5.00 EUR")
        #expect(rich.updatedAt != nil)
        // Typed attributes are rendered using their attribute type (percent, amount, share, …).
        #expect(rich.attributes.count >= 8)
        #expect(rich.attributes.values.contains("5.45%"))
        #expect(rich.attributes.values.contains("https://www.google.com"))
        #expect(rich.attributes.values.contains("> 100"))
        #expect(file.securities[2].attributes.isEmpty)
        // A security without currency (consumer price index) falls back to the base currency.
        #expect(file.securities[1].currency == "EUR")

        // Plans: delivery plan, purchase plan, deposit plan (interval 2 months).
        #expect(file.plans.map(\.name) == ["Inbound Delivery", "Purchase", "Cash Deposit"])
        #expect(file.plans.map(\.kind) == [.purchase, .purchase, .deposit])
        let purchase = file.plans[1]
        #expect(purchase.securityID == rich.id)
        #expect(purchase.depotID == file.depots[0].id)
        #expect(purchase.accountID == file.accounts[0].id)
        #expect(purchase.amount == Money(minor: 100, currency: "EUR"))
        #expect(purchase.fees == 1000)
        #expect(purchase.start == day("2021-08-02"))
        #expect(purchase.intervalMonths == 1)
        #expect(file.plans[0].accountID == nil)
        let deposit = file.plans[2]
        #expect(deposit.intervalMonths == 2)
        #expect(deposit.amount.minor == 9000)
        #expect(deposit.securityID == nil)

        // Transactions generated by a plan stay linked to it.
        #expect(file.transactions.count == 2)
        let generatedDeposit = try #require(file.transactions.first { $0.kind == .deposit })
        #expect(generatedDeposit.source == "plan:\(deposit.id.uuidString)")
        #expect(generatedDeposit.note.hasPrefix("Generiert von Sparplan 'Cash Deposit'"))
        let delivery = try #require(file.transactions.first { $0.kind == .deliveryIn })
        #expect(delivery.source == "plan:\(file.plans[0].id.uuidString)")
        #expect(delivery.shares == Shares(0.09))
        #expect(delivery.fees == 1000)

        #expect(file.watchlists.count == 1)
        #expect(file.watchlists[0].securityIDs == [rich.id])
        #expect(file.taxonomies.count == 1)
        #expect(file.settings.preferences["pp.bookmarks"]?.contains("{isin}") == true)
        try assertIntegrity(file)
    }

    @Test func sharedObjectsInBothReferenceStyles() throws {
        // Two securities share one "latest price" object — once via XPath, once via id references.
        for name in ["client_with_relative_references.xml", "client_with_id_references.xml"] {
            let file = try Fixture.pp(name).file
            #expect(file.securities.count == 2)
            #expect(file.securities.map(\.id.uuidString) == ["987F74DD-2308-4B6B-A5B8-4918E3A73D95", "35B3BA7D-20F4-45BE-8804-9D5778F40B52"])
            for security in file.securities {
                #expect(security.prices.count == 1)
                #expect(security.prices.latest == PricePoint(day: day("2024-08-05"), price: Price(raw: 10)))
            }
        }
        let relative = try PortfolioPerformanceImporter.read(Fixture.data("pp/client_with_relative_references.xml")).file
        let byID = try PortfolioPerformanceImporter.read(Fixture.data("pp/client_with_id_references.xml")).file
        #expect(relative == byID)
    }

    @Test func currentFormatWithExDateAndSource() throws {
        let result = try Fixture.pp("client69.xml")
        #expect(result.report.sourceVersion == 69)
        let transaction = try #require(result.file.transactions.first)
        #expect(result.file.transactions.count == 1)
        #expect(transaction.kind == .dividend)
        #expect(transaction.date == day("2019-05-27"))
        #expect(transaction.amount == Money(minor: 1007, currency: "EUR"))
        #expect(transaction.taxes == 393)
        #expect(transaction.shares == Shares(70))
        #expect(transaction.note == "Abrechnungs-Nr. 19200128")
        #expect(result.file.securities[0].isin == "DE000CBK1001")
        #expect(transaction.exDate == day("2019-05-23"))
        #expect(!result.report.warnings.contains { $0.code == .skippedExDate })
        #expect(result.report.warnings.contains { $0.code == .skippedDocumentReference })

        let events = try Fixture.pp("client_with_security_events.xml").file
        #expect(events.securities[0].events.map(\.kind) == [.note, .split])
        #expect(events.securities[0].events.map(\.detail) == ["custom event", "10:1"])
    }

    @Test func zippedXMLContainer() throws {
        let zipped = try Fixture.pp("client69.xml.zip")
        let plain = try Fixture.pp("client69.xml")
        #expect(zipped.file.transactions == plain.file.transactions)
        #expect(zipped.file.securities == plain.file.securities)
        #expect(PortfolioPerformanceImporter.container(of: try Fixture.data("pp/client69.xml.zip")) == .zippedXML)
    }

    @Test func rejectsUnreadableContainersWithHelpfulErrors() throws {
        #expect(throws: PortfolioPerformanceImportError.encrypted) { try Fixture.pp("client53.encrypted.portfolio") }
        #expect(throws: PortfolioPerformanceImportError.binaryFormat) { try Fixture.pp("client69.binary.portfolio") }
        #expect(throws: PortfolioPerformanceImportError.binaryFormat) { try PortfolioPerformanceImporter.read(Data("PPPBV1\u{1}rest".utf8)) }
        #expect(throws: PortfolioPerformanceImportError.emptyFile) { try PortfolioPerformanceImporter.read(Data()) }
        #expect(throws: PortfolioPerformanceImportError.emptyFile) { try PortfolioPerformanceImporter.read(Data("  \n ".utf8)) }
        #expect(throws: PortfolioPerformanceImportError.notXML) { try PortfolioPerformanceImporter.read(Data("Date;Value\n1;2".utf8)) }
        #expect(throws: PortfolioPerformanceImportError.notPortfolioPerformance(rootElement: "html")) {
            try PortfolioPerformanceImporter.read(Data("<html><body/></html>".utf8))
        }
        #expect(throws: PortfolioPerformanceImportError.malformedXML(line: 2, message: "element <client> is not closed (file truncated?)")) {
            try PortfolioPerformanceImporter.read(Data("<client>\n<version>60</version>".utf8))
        }
        // A ZIP archive without a Portfolio Performance payload.
        #expect(throws: PortfolioPerformanceImportError.unsupportedArchive(reason: "it does not contain a data.xml entry")) {
            try PortfolioPerformanceImporter.read(Data(storedZip(name: "readme.txt", contents: Array("hello".utf8))))
        }
        // … and one whose XML entry merely has another name is still accepted.
        let renamed = storedZip(name: "portfolio.xml", contents: [UInt8](try Fixture.data("pp/client69.xml")))
        #expect(try PortfolioPerformanceImporter.read(Data(renamed)).file.transactions.count == 1)
        // Damaged archive contents are reported, not crashed on.
        var damaged = storedZip(name: "data.xml", contents: [UInt8](try Fixture.data("pp/client69.xml")))
        damaged[60] ^= 0xFF
        #expect(throws: PortfolioPerformanceImportError.unsupportedArchive(reason: "the archive is damaged (checksum mismatch)")) {
            try PortfolioPerformanceImporter.read(Data(damaged))
        }

        for error in [PortfolioPerformanceImportError.encrypted, .binaryFormat, .unsupportedArchive(reason: "x")] {
            #expect(error.errorDescription?.contains("Save As") == true)
        }
        #expect(PortfolioPerformanceImporter.container(of: try Fixture.data("pp/client53.encrypted.portfolio")) == .encrypted)
        #expect(PortfolioPerformanceImporter.container(of: try Fixture.data("pp/client69.binary.portfolio")) == .binary)
        #expect(PortfolioPerformanceImporter.container(of: try Fixture.data("pp/kommer.xml")) == .xml)
        #expect(PortfolioPerformanceImporter.container(of: Data("<html/>".utf8)) == .unknown)
    }
}

/// Every id used by transactions, plans, taxonomies and watchlists must exist, and the ledger must obey the model's conventions.
func assertIntegrity(_ file: PortfolioFile, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let securities = Set(file.securities.map(\.id)), accounts = Set(file.accounts.map(\.id)), depots = Set(file.depots.map(\.id))
    #expect(securities.count == file.securities.count, sourceLocation: sourceLocation)
    #expect(accounts.count == file.accounts.count, sourceLocation: sourceLocation)
    #expect(depots.count == file.depots.count, sourceLocation: sourceLocation)
    #expect(Set(file.transactions.map(\.id)).count == file.transactions.count, sourceLocation: sourceLocation)
    for t in file.transactions {
        #expect(t.amount.minor >= 0 && t.shares.raw >= 0 && t.fees >= 0 && t.taxes >= 0, "\(t)", sourceLocation: sourceLocation)
        if t.kind.requiresAccount { #expect(t.accountID.map(accounts.contains) == true, "\(t)", sourceLocation: sourceLocation) }
        if t.kind.requiresDepot { #expect(t.depotID.map(depots.contains) == true, "\(t)", sourceLocation: sourceLocation) }
        if t.kind.requiresSecurity { #expect(t.securityID.map(securities.contains) == true, "\(t)", sourceLocation: sourceLocation) }
        if let id = t.securityID { #expect(securities.contains(id), sourceLocation: sourceLocation) }
        if t.kind == .cashTransfer { #expect(t.counterAccountID.map(accounts.contains) == true, sourceLocation: sourceLocation) }
        if t.kind == .securityTransfer { #expect(t.counterDepotID.map(depots.contains) == true, sourceLocation: sourceLocation) }
    }
    for depot in file.depots { if let id = depot.referenceAccountID { #expect(accounts.contains(id), sourceLocation: sourceLocation) } }
    for watchlist in file.watchlists { #expect(watchlist.securityIDs.allSatisfy(securities.contains), sourceLocation: sourceLocation) }
    for plan in file.plans {
        if let id = plan.securityID { #expect(securities.contains(id), sourceLocation: sourceLocation) }
        if let id = plan.accountID { #expect(accounts.contains(id), sourceLocation: sourceLocation) }
        if let id = plan.depotID { #expect(depots.contains(id), sourceLocation: sourceLocation) }
    }
    func check(_ nodes: [Classification]) {
        for node in nodes {
            for assignment in node.assignments {
                #expect((assignment.securityID != nil) != (assignment.accountID != nil), sourceLocation: sourceLocation)
                if let id = assignment.securityID { #expect(securities.contains(id), sourceLocation: sourceLocation) }
                if let id = assignment.accountID { #expect(accounts.contains(id), sourceLocation: sourceLocation) }
            }
            check(node.children)
        }
    }
    for taxonomy in file.taxonomies { check(taxonomy.root) }
    for security in file.securities {
        #expect(zip(security.prices.days, security.prices.days.dropFirst()).allSatisfy { $0 < $1 }, sourceLocation: sourceLocation)
    }
}

/// Builds a minimal single-entry ZIP archive (method "stored").
func storedZip(name: String, contents: [UInt8]) -> [UInt8] {
    func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16 & 0xFFFF) }
    let nameBytes = Array(name.utf8)
    let crc = Int(CRC32.checksum(contents))
    var out: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(crc) + u32(contents.count) + u32(contents.count) + u16(nameBytes.count) + u16(0)
    out += nameBytes + contents
    let directoryOffset = out.count
    out += [0x50, 0x4B, 0x01, 0x02] + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(crc) + u32(contents.count) + u32(contents.count)
    out += u16(nameBytes.count) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(0) + nameBytes
    let directorySize = out.count - directoryOffset
    out += [0x50, 0x4B, 0x05, 0x06] + u16(0) + u16(0) + u16(1) + u16(1) + u32(directorySize) + u32(directoryOffset) + u16(0)
    return out
}
