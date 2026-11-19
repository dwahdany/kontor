import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

@Suite struct PPSyntheticTests {
    private func id(_ suffix: String) -> UUID { UUID(uuidString: "00000000-0000-4000-8000-0000000000\(suffix)")! }

    @Test(arguments: ["synthetic_all_types.xml", "synthetic_all_types_ids.xml"])
    func everyTransactionTypeOnce(fixture: String) throws {
        let result = try PortfolioPerformanceImporter.read(Fixture.data("pp/\(fixture)"), name: "Synthetic")
        let file = result.file
        try assertIntegrity(file)
        #expect(file.name == "Synthetic")
        #expect(result.report.counts.transactions == 15)
        #expect(Set(file.transactions.map(\.kind)) == Set(Transaction.Kind.allCases))
        #expect(result.report.counts.transactionsByKind.values.allSatisfy { $0 == 1 })

        let acme = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, globex = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let giro = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!, usd = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!
        let depotA = UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000001")!, depotB = UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000002")!

        #expect(file.accounts == [
            Account(id: giro, name: "Giro", currency: "EUR", note: "main account"),
            Account(id: usd, name: "USD Account", currency: "USD", isRetired: true),
        ])
        #expect(file.depots == [
            Depot(id: depotA, name: "Depot A", referenceAccountID: giro, note: "broker"),
            Depot(id: depotB, name: "Depot B"),
        ])

        let first = file.securities[0]
        #expect(first.id == acme)
        #expect(first.name == "ACME & Sons AG")
        #expect(first.note == "first line\nsecond line")
        #expect((first.isin, first.wkn, first.ticker) == ("DE0001111111", "111111", "ACM.DE"))
        #expect(first.feed == QuoteFeed(provider: "yahoo", symbol: "ACM.DE"))
        #expect(first.prices.map(\.day.iso) == ["2024-01-02", "2024-01-03", "2024-01-05", "2024-01-08"])
        #expect(first.prices.latest?.price == Price(52))
        #expect(first.attributes == ["Total Expense Ratio (TER)": "0.22%"])
        #expect(first.events.map(\.detail) == ["3:1"])
        #expect(first.updatedAt == Date(timeIntervalSince1970: 1_714_558_272.5))
        let second = file.securities[1]
        #expect(second.isRetired)
        #expect(second.feed == QuoteFeed(provider: "json-url", symbol: "https://example.com/quotes/GLBX.json", options: ["datePath": "$.data[*].date", "closePath": "$.data[*].close"]))
        #expect(second.updatedAt == nil)

        func transaction(_ kind: Transaction.Kind) throws -> Transaction { try #require(file.transactions.first { $0.kind == kind }) }
        func expected(_ suffix: String, _ kind: Transaction.Kind, _ date: String, _ amount: Int64) -> Transaction {
            Transaction(id: id(suffix), kind: kind, date: day(date), amount: Money(minor: amount, currency: "EUR"), source: "pp-import")
        }

        var deposit = expected("01", .deposit, "2024-01-02", 1_000_000)
        deposit.accountID = giro
        #expect(try transaction(.deposit) == deposit)

        var buy = expected("02", .buy, "2024-01-03", 50_500)
        buy.minuteOfDay = 9 * 60 + 30
        buy.accountID = giro; buy.depotID = depotA; buy.securityID = acme
        buy.shares = Shares(10); buy.fees = 400; buy.taxes = 100; buy.note = "first purchase"
        buy.source = "plan:" + file.plans[0].id.uuidString
        #expect(try transaction(.buy) == buy)

        var deliveryIn = expected("03", .deliveryIn, "2024-01-04", 25_000)
        deliveryIn.depotID = depotA; deliveryIn.securityID = globex; deliveryIn.shares = Shares(5); deliveryIn.fees = 150
        #expect(try transaction(.deliveryIn) == deliveryIn)

        var deliveryOut = expected("04", .deliveryOut, "2024-01-05", 5_100)
        deliveryOut.depotID = depotA; deliveryOut.securityID = acme; deliveryOut.shares = Shares(1)
        #expect(try transaction(.deliveryOut) == deliveryOut)

        var sell = expected("05", .sell, "2024-02-01", 23_000)
        sell.minuteOfDay = 15 * 60 + 45
        sell.accountID = giro; sell.depotID = depotA; sell.securityID = acme; sell.shares = Shares(4); sell.fees = 500; sell.taxes = 1500
        #expect(try transaction(.sell) == sell)
        #expect(sell.grossMinor == 25_000)

        var move = expected("06", .securityTransfer, "2024-03-01", 11_000)
        move.depotID = depotA; move.counterDepotID = depotB; move.securityID = acme; move.shares = Shares(2); move.note = "to the other depot"
        #expect(try transaction(.securityTransfer) == move)

        var dividend = expected("07", .dividend, "2024-04-01", 850)
        dividend.accountID = giro; dividend.securityID = globex; dividend.shares = Shares(5); dividend.taxes = 150
        dividend.securityGross = Money(minor: 1100, currency: "USD")
        dividend.exDate = Day(year: 2024, month: 3, day: 28)
        #expect(try transaction(.dividend) == dividend)

        var interest = expected("08", .interest, "2024-04-02", 300)
        interest.accountID = giro; interest.taxes = 100
        #expect(try transaction(.interest) == interest)

        var charge = expected("09", .interestCharge, "2024-04-03", 120)
        charge.accountID = giro
        #expect(try transaction(.interestCharge) == charge)

        var fee = expected("0A", .fee, "2024-04-04", 990)
        fee.accountID = giro; fee.securityID = acme
        #expect(try transaction(.fee) == fee)

        var feeRefund = expected("0B", .feeRefund, "2024-04-05", 90)
        feeRefund.accountID = giro
        #expect(try transaction(.feeRefund) == feeRefund)

        var tax = expected("0C", .tax, "2024-04-06", 2_500)
        tax.accountID = giro
        #expect(try transaction(.tax) == tax)

        var taxRefund = expected("0D", .taxRefund, "2024-04-07", 500)
        taxRefund.accountID = giro
        #expect(try transaction(.taxRefund) == taxRefund)

        var withdrawal = expected("0E", .withdrawal, "2024-04-08", 10_000)
        withdrawal.accountID = giro; withdrawal.note = "ATM <cash>"
        #expect(try transaction(.withdrawal) == withdrawal)

        var transfer = expected("0F", .cashTransfer, "2024-04-09", 20_000)
        transfer.accountID = giro; transfer.counterAccountID = usd; transfer.counterAmount = Money(minor: 21_800, currency: "USD")
        #expect(try transaction(.cashTransfer) == transfer)

        // Cash and share effects follow from the unified ledger.
        let balance = file.transactions.reduce(Int64(0)) { $0 + $1.cashEffect(on: giro) }
        #expect(balance == 1_000_000 - 50_500 + 23_000 + 850 + 300 - 120 - 990 + 90 - 2_500 + 500 - 10_000 - 20_000)
        #expect(file.transactions.reduce(Int64(0)) { $0 + $1.cashEffect(on: usd) } == 21_800)
        let acmeInA = file.transactions.filter { $0.securityID == acme }.reduce(Shares.zero) { $0 + $1.sharesEffect(on: depotA) }
        #expect(acmeInA == Shares(10 - 1 - 4 - 2))
        #expect(file.transactions.filter { $0.securityID == acme }.reduce(Shares.zero) { $0 + $1.sharesEffect(on: depotB) } == Shares(2))

        // Plans: typed, weekly interval approximated, interest plan reported as skipped.
        #expect(file.plans.map(\.name) == ["Monthly ACME", "Pocket money", "Weekly saver"])
        #expect(file.plans.map(\.kind) == [.purchase, .withdrawal, .deposit])
        #expect(file.plans[0].intervalMonths == 3)
        #expect(file.plans[0].amount == Money(minor: 20_000, currency: "EUR"))
        #expect(file.plans[0].fees == 150)
        #expect((file.plans[0].securityID, file.plans[0].depotID, file.plans[0].accountID) == (acme, depotA, giro))
        #expect(file.plans[0].note == "savings")
        #expect(file.plans[1].amount.minor == 5_000)
        #expect(file.plans[2].intervalMonths == 1)
        #expect(result.report.warnings.contains { $0.code == .skippedPlan && $0.examples == ["Interest plan"] })
        #expect(result.report.warnings.contains { $0.code == .approximatedPlan && $0.severity == .warning })
        let dividends = file.transactions.filter { $0.kind == .dividend }
        #expect(dividends.contains { $0.exDate == Day(year: 2024, month: 3, day: 28) })
        #expect(file.transactions.allSatisfy { $0.kind == .dividend || $0.exDate == nil })
        #expect(!result.report.warnings.contains { $0.code == .skippedExDate })

        // Taxonomy: children and assignments ordered by rank; weights adding up to 100 % are target weights.
        let taxonomy = try #require(file.taxonomies.first)
        #expect(taxonomy.id == UUID(uuidString: "3F0C7C80-5A5B-4A50-9D4F-0A1B2C3D4E5F"))
        #expect(taxonomy.root.map(\.name) == ["Equity", "Bonds"])
        #expect(taxonomy.root.map(\.targetWeight) == [6000, 4000])
        #expect(taxonomy.root[0].note == "risky part")
        #expect(taxonomy.root[0].color == "#FF0000")
        let developed = taxonomy.root[0].children[0]
        #expect(developed.id == UUID(uuidString: "9B2D1C3E-4F5A-4B6C-8D7E-9F0A1B2C3D4E"))
        #expect(developed.targetWeight == 10_000)
        #expect(developed.assignments == [.init(securityID: globex, weight: 10_000), .init(securityID: acme, weight: 7000)])
        #expect(taxonomy.root[1].assignments == [.init(securityID: acme, weight: 3000), .init(accountID: usd, weight: 10_000)])
        #expect(file.watchlists.map(\.securityIDs) == [[globex, acme]])
    }

    @Test func bothReferenceStylesYieldTheSameDocument() throws {
        let xpath = try PortfolioPerformanceImporter.read(Fixture.data("pp/synthetic_all_types.xml"))
        let ids = try PortfolioPerformanceImporter.read(Fixture.data("pp/synthetic_all_types_ids.xml"))
        #expect(xpath.file == ids.file)
        #expect(xpath.report == ids.report)
    }

    private func client(version: Int = 66, _ body: String) -> Data {
        Data("<client><version>\(version)</version><baseCurrency>CHF</baseCurrency>\(body)</client>".utf8)
    }

    @Test func legacyScalesAndPlainFeeFields() throws {
        // Format 25: shares with five decimals, quotes with two, fees/taxes as fields, no currency, dates without time.
        let result = try PortfolioPerformanceImporter.read(client(version: 25, """
        <securities><security><uuid>11111111-1111-4111-8111-111111111111</uuid><name>Old</name>
          <prices><price t="2014-01-02" v="1234"/></prices></security></securities>
        <accounts><account><uuid>aaaaaaaa-0000-4000-8000-000000000001</uuid><name>Konto</name><transactions/></account></accounts>
        <portfolios><portfolio><uuid>dddddddd-0000-4000-8000-000000000001</uuid><name>Depot</name>
          <referenceAccount reference="../../../accounts/account"/>
          <transactions><portfolio-transaction><date>2014-01-02</date><security reference="../../../../../securities/security"/>
            <shares>150000</shares><amount>2000</amount><fees>120</fees><taxes>30</taxes><type>DELIVERY_INBOUND</type></portfolio-transaction></transactions>
        </portfolio></portfolios>
        """))
        let transaction = try #require(result.file.transactions.first)
        #expect(transaction.shares == Shares(1.5))
        #expect(transaction.amount == Money(minor: 2000, currency: "CHF"))
        #expect((transaction.fees, transaction.taxes) == (120, 30))
        #expect(result.file.securities[0].prices.latest?.price == Price(12.34))
        #expect(result.file.securities[0].currency == "CHF")
        #expect(result.report.warnings.contains { $0.code == .unsupportedVersion })
        // Derived ids are deterministic.
        #expect(transaction.id == (try PortfolioPerformanceImporter.read(client(version: 25, """
        <securities><security><uuid>11111111-1111-4111-8111-111111111111</uuid><name>Old</name>
          <prices><price t="2014-01-02" v="1234"/></prices></security></securities>
        <accounts><account><uuid>aaaaaaaa-0000-4000-8000-000000000001</uuid><name>Konto</name><transactions/></account></accounts>
        <portfolios><portfolio><uuid>dddddddd-0000-4000-8000-000000000001</uuid><name>Depot</name>
          <referenceAccount reference="../../../accounts/account"/>
          <transactions><portfolio-transaction><date>2014-01-02</date><security reference="../../../../../securities/security"/>
            <shares>150000</shares><amount>2000</amount><fees>120</fees><taxes>30</taxes><type>DELIVERY_INBOUND</type></portfolio-transaction></transactions>
        </portfolio></portfolios>
        """)).file.transactions[0].id))
        // Format 40: six decimals for shares, four for quotes.
        let mid = try PortfolioPerformanceImporter.read(client(version: 40, """
        <securities><security><name>Mid</name><currencyCode>EUR</currencyCode><prices><price t="2018-01-02" v="123456"/></prices></security></securities>
        """))
        #expect(mid.file.securities[0].prices.latest?.price == Price(12.3456))
    }

    @Test func neverDropsDataSilently() throws {
        let result = try PortfolioPerformanceImporter.read(client("""
        <securities>
          <security><uuid>11111111-1111-4111-8111-111111111111</uuid><name>S</name><currencyCode>EUR</currencyCode>
            <feed>SOMETHING_NEW</feed><prices><price t="bad" v="1"/><price t="2024-01-03" v="300"/><price t="2024-01-02" v="200"/></prices></security>
          <security><uuid>11111111-1111-4111-8111-111111111111</uuid><name>Duplicate id</name><currencyCode>EUR</currencyCode></security>
        </securities>
        <accounts>
          <account><uuid>aaaaaaaa-0000-4000-8000-000000000001</uuid><name>A</name><currencyCode>EUR</currencyCode>
            <transactions>
              <account-transaction><date>2024-01-01T00:00</date><amount>-500</amount><type>DEPOSIT</type></account-transaction>
              <account-transaction><date>2024-01-02T00:00</date><amount>100</amount><type>DIVIDENDS</type></account-transaction>
              <account-transaction><date>2024-01-03T00:00</date><amount>100</amount><type>BUY</type></account-transaction>
              <account-transaction><date>2024-01-04T00:00</date><amount>100</amount><type>MYSTERY</type></account-transaction>
              <account-transaction><amount>100</amount><type>DEPOSIT</type></account-transaction>
              <account-transaction><date>2024-01-05T00:00</date><amount>70</amount><type>FEES</type>
                <units><unit type="TAX"><amount currency="EUR" amount="5"/></unit></units></account-transaction>
              <account-transaction reference="../../../../nowhere/thing"/>
            </transactions>
          </account>
        </accounts>
        <portfolios>
          <portfolio><uuid>dddddddd-0000-4000-8000-000000000001</uuid><name>P</name>
            <transactions>
              <portfolio-transaction><date>2024-01-06T00:00</date><amount>100</amount><shares>100000000</shares><type>DELIVERY_INBOUND</type></portfolio-transaction>
              <portfolio-transaction><date>2024-01-07T00:00</date><amount>100</amount><shares>100000000</shares>
                <security reference="../../../../../securities/security"/><type>SELL</type></portfolio-transaction>
            </transactions>
          </portfolio>
        </portfolios>
        <taxonomies><taxonomy><id>t</id><name>T</name><root><id>t</id><name>T</name><children>
          <classification><id>c</id><name>C</name><children/><assignments>
            <assignment><investmentVehicle class="portfolio" reference="../../../../../../../../portfolios/portfolio"/><weight>10000</weight></assignment>
            <assignment><investmentVehicle class="security" reference="../../../../../../../../securities/security[9]"/><weight>10000</weight></assignment>
          </assignments><weight>10000</weight></classification>
        </children><assignments>
            <assignment><investmentVehicle class="account" reference="../../../../../../accounts/account"/><weight>5000</weight></assignment>
        </assignments></root></taxonomy></taxonomies>
        <dashboards><dashboard name="D"/></dashboards>
        """))
        let file = result.file
        let codes = Set(result.report.warnings.map(\.code))
        #expect(codes.isSuperset(of: [
            .unknownQuoteFeed, .invalidValue, .duplicateObject, .negativeValue, .approximatedTransaction, .incompleteCrossEntry,
            .unknownTransactionType, .ignoredUnits, .unresolvedReference, .missingSecurity, .skippedAssignment, .skippedDashboards,
        ]))
        try assertIntegrity(file)
        #expect(file.securities.count == 2)
        #expect(file.securities[0].id != file.securities[1].id)
        #expect(file.securities[0].prices.map(\.day.iso) == ["2024-01-02", "2024-01-03"]) // unsorted input is sorted, bad rows skipped
        #expect(file.securities[0].feed?.provider == "something_new")
        #expect(file.securities[0].feed?.options["pp.feed"] == "SOMETHING_NEW")
        // negative deposit -> absolute value; dividend without security -> interest; lone BUY -> withdrawal; SELL without cross entry -> delivery out
        #expect(file.transactions.map(\.kind) == [.deposit, .interest, .withdrawal, .fee, .deliveryOut])
        #expect(file.transactions[0].amount.minor == 500)
        // assignments on the taxonomy root get their own category instead of vanishing
        #expect(file.taxonomies[0].root.map(\.name) == ["C", "T"])
        #expect(file.taxonomies[0].root[1].assignments == [.init(accountID: file.accounts[0].id, weight: 5000)])
        #expect(file.taxonomies[0].root[0].targetWeight == 10_000)
        #expect(result.report.warnings.first { $0.code == .unresolvedReference }?.examples.first?.contains("line") == true)
    }

    @Test func exchangeRateSeriesAndOrphans() throws {
        let result = try PortfolioPerformanceImporter.read(client("""
        <securities>
          <security><uuid>11111111-1111-4111-8111-111111111111</uuid><name>EUR/USD</name><currencyCode>EUR</currencyCode>
            <targetCurrencyCode>USD</targetCurrencyCode><prices><price t="2024-01-02" v="109500000"/><price t="2024-01-03" v="109200000"/></prices></security>
        </securities>
        <accounts/>
        <portfolios>
          <portfolio><name>P</name><transactions>
            <portfolio-transaction><date>2024-01-06T00:00</date><amount>100</amount><shares>100000000</shares>
              <security><name>Inline only</name><currencyCode>USD</currencyCode><isin>US0000000001</isin><prices/></security>
              <type>DELIVERY_INBOUND</type></portfolio-transaction>
          </transactions></portfolio>
        </portfolios>
        """))
        #expect(result.file.exchangeRates == [ExchangeRateSeries(base: "EUR", quote: "USD", days: [day("2024-01-02").rawValue, day("2024-01-03").rawValue], rates: [1.095, 1.092])])
        #expect(result.file.securities.map(\.name) == ["Inline only"])
        #expect(result.report.counts.exchangeRateSeries == 1)
        #expect(result.report.warnings.contains { $0.code == .orphanedObject })
        #expect(result.file.transactions[0].amount.currency == "USD")
        try assertIntegrity(result.file)
    }
}
