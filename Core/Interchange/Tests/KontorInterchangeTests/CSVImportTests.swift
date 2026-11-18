import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

@Suite struct CSVImportTests {
    private func base() -> (file: PortfolioFile, account: Account, depot: Depot, bond: Security) {
        let account = Account(name: "Giro", currency: "EUR")
        let depot = Depot(name: "Broker", referenceAccountID: account.id)
        let bond = Security(name: "iShares Core Euro Government Bond UCITS ETF (Dist)", currency: "EUR", isin: "IE00B4WXJJ64", wkn: "A0RL83", ticker: "EUNH.DE")
        return (PortfolioFile(name: "Test", securities: [bond], accounts: [account], depots: [depot]), account, depot, bond)
    }

    @Test func germanPortfolioPerformanceExport() throws {
        let (file, account, depot, bond) = base()
        let document = CSVDocument(data: try Fixture.data("csv/pp_portfolio_de.csv"))
        #expect(document.dialect == CSVDialect(encoding: .utf8, delimiter: ";", headerRecord: 0, firstDataRecord: 1, decimalSeparator: ",", dateOrder: .dayMonthYear))
        #expect(!document.isDateOrderAmbiguous)

        let proposal = CSVImporter.propose(document, file: file)
        #expect(proposal.missingFields.isEmpty)
        #expect(proposal.rows.count == 6)
        #expect(proposal.rows.allSatisfy { $0.status == .ok })
        #expect(proposal.rows.map(\.lineNumber) == [2, 3, 4, 5, 6, 7])
        #expect(proposal.okCount == 6)
        // The bond is matched by ISIN; the other three securities are new.
        #expect(proposal.newSecurities.map(\.name) == ["iShares Diversified Commodity Swap UCITS ETF", "Amazon.com Inc.", "Bitcoin"])
        #expect(proposal.newSecurities.map(\.currency) == ["EUR", "USD", "EUR"])
        #expect(proposal.newSecurities[1].isin == "US0231351067")
        #expect(proposal.newSecurities[1].wkn == "906866")
        #expect(proposal.newSecurities[2].ticker == "BTC")
        #expect(proposal.newAccounts.isEmpty && proposal.newDepots.isEmpty)

        let buy = try #require(proposal.rows[0].transaction)
        #expect(buy.kind == .buy)
        #expect(buy.date == day("2019-01-07"))
        #expect(buy.amount == Money(minor: 294_683, currency: "EUR"))
        #expect(buy.shares == Shares(24))
        #expect(buy.fees == 995)
        #expect(buy.taxes == 0)
        #expect(buy.securityID == bond.id)
        #expect(buy.accountID == account.id) // the only account
        #expect(buy.depotID == depot.id)
        #expect(buy.source == "csv-import")

        let second = try #require(proposal.rows[1].transaction)
        #expect(second.taxes == 995)
        #expect(second.shares == Shares(331))
        #expect(second.note == "Sparplan; erste Rate")

        let forex = try #require(proposal.rows[2].transaction)
        #expect(forex.amount == Money(minor: 267_600, currency: "EUR"))
        #expect(forex.securityGross == Money(minor: 283_054, currency: "USD"))
        #expect(forex.fees == 600)
        #expect(forex.securityID == proposal.newSecurities[1].id)

        let sell = try #require(proposal.rows[3].transaction)
        #expect(sell.kind == .sell)
        #expect((sell.amount.minor, sell.fees, sell.taxes) == (125_010, 590, 4_400))
        #expect(sell.grossMinor == 130_000)

        let deliveryIn = try #require(proposal.rows[4].transaction)
        #expect(deliveryIn.kind == .deliveryIn)
        #expect(deliveryIn.shares == Shares(raw: 130_100))
        #expect(deliveryIn.accountID == nil)
        #expect(deliveryIn.depotID == depot.id)
        #expect(proposal.rows[5].transaction?.kind == .deliveryOut)
        #expect(proposal.rows[5].transaction?.shares == Shares(raw: 636_567))

        // Applying is pure and adds exactly what the selected rows need.
        let updated = proposal.apply(to: file)
        #expect(file.transactions.isEmpty)
        #expect(updated.transactions.count == 6)
        #expect(updated.securities.count == 4)
        try assertIntegrity(updated)
        let partial = proposal.apply(to: file, selection: .rows([0, 4]))
        #expect(partial.transactions.count == 2)
        #expect(partial.securities.map(\.name) == [bond.name, "Bitcoin"]) // Amazon is not added when its row is not selected

        // Importing the same file again: everything is a duplicate and nothing is added.
        let again = CSVImporter.propose(document, file: updated)
        #expect(again.duplicateCount == 6)
        #expect(again.newSecurities.isEmpty)
        #expect(again.rows[0].status == .duplicate(of: updated.transactions[0].id))
        #expect(again.apply(to: updated) == updated)
        // … unless the user explicitly selects a duplicate.
        #expect(again.apply(to: updated, selection: .rows([0])).transactions.count == 7)
    }

    @Test func englishAccountExportWithSignedValues() throws {
        let (file, account, _, _) = base()
        let document = CSVDocument(data: try Fixture.data("csv/pp_account_en.csv"))
        #expect(document.dialect.delimiter == ",")
        #expect(document.dialect.decimalSeparator == ".")
        #expect(document.dialect.dateOrder == .yearMonthDay)
        let proposal = CSVImporter.propose(document, file: file)
        let kinds = proposal.rows.map { $0.transaction?.kind }
        #expect(kinds == [.deposit, .dividend, .interest, .interestCharge, .fee, .feeRefund, .tax, .taxRefund, .withdrawal, .withdrawal])
        #expect(proposal.rows.map { $0.transaction?.amount.minor } == [1_000_000, 870, 125, 80, 1_200, 200, 5_510, 510, 50_000, 25_000])
        #expect(proposal.rows.allSatisfy { $0.transaction?.accountID == account.id })
        #expect(proposal.rows[0].transaction?.note == "Initial funding")
        #expect(proposal.rows[4].transaction?.note == "Custody fee, Q3")
        let dividend = try #require(proposal.rows[1].transaction)
        #expect(dividend.taxes == 290)
        #expect(dividend.shares == Shares(10))
        #expect(proposal.newSecurities.map(\.isin) == ["LU0392495023"])
        #expect(proposal.rows[2].transaction?.taxes == 33)
        // a transfer without offset account cannot be a transfer
        #expect(proposal.rows[9].status == .warning)
        #expect(proposal.rows[9].messages.first?.contains("offset account") == true)
        #expect(proposal.warningCount == 1 && proposal.okCount == 9)
        try assertIntegrity(proposal.apply(to: file))
    }

    @Test func germanBrokerExportInWindows1252() throws {
        let (file, _, depot, _) = base()
        let document = CSVDocument(data: try Fixture.data("csv/broker_de_windows1252.csv"))
        var options = CSVImportOptions()
        var proposal = CSVImporter.propose(document, options: options, file: file)
        #expect(proposal.mapping.columns == [.date, .type, .shares, .securityName, .isin, .quote, .amount, .currency, .fees])
        #expect(proposal.rows.map(\.status) == [.ok, .ok, .ok, .error])
        #expect(proposal.unrecognizedTypes == ["Depotübertrag (intern)"])
        #expect(proposal.rows[3].messages == ["The type \"Depotübertrag (intern)\" is not known."])
        #expect(proposal.rows[3].lineNumber == 8)
        #expect(!proposal.rows[3].isImportable)

        let buy = try #require(proposal.rows[0].transaction)
        #expect(buy.kind == .buy)
        #expect(buy.amount.minor == 100_990) // sign dropped
        #expect(buy.shares == Shares(12.5))
        #expect(buy.fees == 990)
        #expect(buy.grossPrice == Price(80))
        #expect(proposal.rows[1].transaction?.kind == .dividend)
        #expect(proposal.rows[1].transaction?.amount.minor == 1_875)
        let sell = try #require(proposal.rows[2].transaction)
        #expect(sell.kind == .sell)
        #expect(sell.shares == Shares(2.5)) // negative share count of the export
        #expect(proposal.newSecurities.map(\.name) == ["Müller & Söhne Beteiligungs-AG"])

        // The wizard lets the user teach the importer the unknown type.
        options.typeAliases = ["depotübertrag (INTERN)": .deliveryIn]
        proposal = CSVImporter.propose(document, options: options, file: file)
        #expect(proposal.unrecognizedTypes.isEmpty)
        #expect(proposal.rows[3].status == .warning) // no value given
        let delivery = try #require(proposal.rows[3].transaction)
        #expect(delivery.kind == .deliveryIn)
        #expect(delivery.amount.minor == 0)
        #expect(delivery.depotID == depot.id)
        #expect(proposal.newSecurities.map(\.name) == ["Müller & Söhne Beteiligungs-AG", "Fonds „Größe“ €"])
        #expect(proposal.apply(to: file).transactions.count == 4)
    }

    @Test func infersTypesWithoutTypeColumn() throws {
        let document = CSVDocument(data: try Fixture.data("csv/broker_us_tab.csv"))
        #expect(document.dialect.delimiter == "\t")
        #expect(document.dialect.dateOrder == .monthDayYear)
        #expect(!document.isDateOrderAmbiguous)
        // Into an empty document: account and depot are created so the first import just works.
        let empty = PortfolioFile(settings: Settings(baseCurrency: "USD"))
        let proposal = CSVImporter.propose(document, file: empty)
        #expect(proposal.rows.map { $0.transaction?.kind } == [.buy, .sell, .dividend, .deposit, .withdrawal])
        #expect(proposal.rows.map { $0.transaction?.amount } == [181_680, 72_572, 144, 250_000, 20_000].map { Money(minor: $0, currency: "USD") })
        #expect(proposal.rows[0].transaction?.date == day("2024-01-05"))
        #expect(proposal.rows[0].transaction?.fees == 500)
        #expect(proposal.rows[1].transaction?.shares == Shares(4))
        #expect(proposal.rows[3].transaction?.note == "WIRE IN") // a bare description is a note, not a security
        #expect(proposal.rows[3].transaction?.securityID == nil)
        #expect(proposal.newSecurities.map(\.ticker) == ["AAPL"])
        #expect(proposal.newSecurities[0].currency == "USD")
        #expect(proposal.newAccounts.map(\.name) == ["Cash Account"])
        #expect(proposal.newAccounts[0].currency == "USD")
        #expect(proposal.newDepots.map(\.name) == ["Depot"])
        #expect(proposal.newDepots[0].referenceAccountID == proposal.newAccounts[0].id)
        let updated = proposal.apply(to: empty)
        #expect((updated.accounts.count, updated.depots.count, updated.securities.count, updated.transactions.count) == (1, 1, 1, 5))
        try assertIntegrity(updated)
    }

    @Test func resolvesAccountsDepotsAndTransfersByName() throws {
        var (file, giro, broker, bond) = base()
        let savings = Account(name: "Savings", currency: "EUR")
        let vault = Depot(name: "Vault")
        file.accounts.append(savings)
        file.depots.append(vault)
        let csv = """
        Date,Time,Type,Shares,Value,ISIN,Cash Account,Offset Account,Securities Account,Offset Securities Account,Gross Amount,Currency Gross Amount
        2024-01-02,10:15,Transfer,,500.00,,giro,SAVINGS,,,,
        2024-01-03,,Transfer (Inbound),,300.00,,Giro,Savings,,,,
        2024-01-04,,Transfer (Outbound),,100.00,,Giro,Dollars,,,108.50,USD
        2024-01-05,,Transfer (Outbound),7,,IE00B4WXJJ64,,,Broker,Vault,,
        2024-01-06,,Transfer (Inbound),3,,IE00B4WXJJ64,,,Broker,Vault,,
        2024-01-07,,Buy,2,200.00,IE00B4WXJJ64,Savings,,New Depot,,,
        2024-01-08,,Deposit,,50.00,,,,,,,
        2024-01-09,,Transfer,,10.00,,Giro,Giro,,,,
        2024-01-10,,Buy,2,200.00,IE00B4WXJJ64,,,,,,
        """
        let document = CSVDocument(data: Data(csv.utf8))
        var options = CSVImportOptions(defaultAccountID: savings.id, defaultDepotID: vault.id)
        let proposal = CSVImporter.propose(document, options: options, file: file)
        let t = proposal.rows.map(\.transaction)

        #expect(t[0]?.kind == .cashTransfer)
        #expect((t[0]?.accountID, t[0]?.counterAccountID) == (giro.id, savings.id))
        #expect(t[0]?.minuteOfDay == 615)
        // inbound rows are written from the receiver's point of view
        #expect((t[1]?.accountID, t[1]?.counterAccountID) == (savings.id, giro.id))
        // unknown offset account is created in the foreign currency; the credited amount is kept
        #expect(proposal.newAccounts.map(\.name) == ["Dollars"])
        #expect(proposal.newAccounts[0].currency == "USD")
        #expect(t[2]?.counterAccountID == proposal.newAccounts[0].id)
        #expect(t[2]?.counterAmount == Money(minor: 10_850, currency: "USD"))
        #expect(t[3]?.kind == .securityTransfer)
        #expect((t[3]?.depotID, t[3]?.counterDepotID, t[3]?.shares) == (broker.id, vault.id, Shares(7)))
        #expect((t[4]?.depotID, t[4]?.counterDepotID) == (vault.id, broker.id))
        #expect(t[3]?.securityID == bond.id)
        // named account + unknown depot (created, settling against the row's account)
        #expect(t[5]?.accountID == savings.id)
        #expect(proposal.newDepots.map(\.name) == ["New Depot"])
        #expect(proposal.newDepots[0].referenceAccountID == savings.id)
        #expect(t[5]?.depotID == proposal.newDepots[0].id)
        // defaults chosen by the caller
        #expect(t[6]?.accountID == savings.id)
        #expect((t[8]?.accountID, t[8]?.depotID) == (savings.id, vault.id))
        #expect(proposal.rows[7].status == .error)
        #expect(proposal.rows[7].messages == ["Source and target account of the transfer are the same."])
        #expect(proposal.errorCount == 1)
        try assertIntegrity(proposal.apply(to: file))

        // Without defaults and with several accounts the importer refuses to guess …
        options = CSVImportOptions()
        let undecided = CSVImporter.propose(document, options: options, file: file)
        #expect(undecided.rows[6].status == .error)
        #expect(undecided.rows[6].messages == ["No cash account is given and no default account was chosen."])
        // … but a depot's reference account settles its trades.
        var single = file
        single.depots = [broker]
        let viaReference = CSVImporter.propose(document, options: options, file: single)
        #expect(viaReference.rows[8].transaction?.accountID == giro.id)
        // … and unknown names can be forbidden.
        options.createMissingAccounts = false
        let strict = CSVImporter.propose(document, options: options, file: file)
        #expect(strict.rows[2].messages == ["The offset account \"Dollars\" does not exist."])
        #expect(strict.rows[5].messages == ["The securities account \"New Depot\" does not exist."])
        #expect(strict.newAccounts.isEmpty && strict.newDepots.isEmpty)
    }

    @Test func derivesMissingValuesAndReportsProblems() throws {
        let (file, _, _, bond) = base()
        let csv = """
        Datum;Typ;Stück;Kurs;Wert;Gebühren;ISIN;Name;Währung
        02.01.2024;Kauf;10;50,00;;5,00;IE00B4WXJJ64;;
        03.01.2024;Verkauf;;50,00;495,00;5,00;IE00B4WXJJ64;;
        04.01.2024;Kauf;;;100,00;;IE00B4WXJJ64;;
        05.01.2024;Kauf;1;;;;IE00B4WXJJ64;;
        06.01.2024;Kauf;1;10;10,00;;;;
        32.01.2024;Kauf;1;10;10,00;;IE00B4WXJJ64;;
        ;Einlage;;;10,00;;;;
        07.01.2024;Einlage;;;zehn;;;;
        08.01.2024;Dividende;;;-3,00;;IE00B4WXJJ64;;
        09.01.2024;;5;;-100,00;;;Neue AG;usd
        10.01.2024;Zinsen;;;-1,50;;;;
        11.01.2024;Kauf;1;10;10,00;25,00;IE00B4WXJJ64;;
        """
        let proposal = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), file: file)
        let rows = proposal.rows
        // value from shares × quote + fees
        #expect(rows[0].status == .warning)
        #expect(rows[0].transaction?.amount.minor == 50_500)
        #expect(rows[0].messages == ["The value was calculated from shares and quote."])
        // shares from value and quote: (495 + 5) / 50
        #expect(rows[1].transaction?.shares == Shares(10))
        #expect(rows[1].status == .warning)
        #expect(rows[2].messages == ["The number of shares is missing."])
        #expect(rows[3].messages == ["The value is missing."])
        #expect(rows[4].messages == ["A Buy needs a security, but the row names none (ISIN, ticker, WKN or name)."])
        #expect(rows[5].messages == ["\"32.01.2024\" is not a valid date."])
        #expect(rows[6].messages == ["The date is missing."])
        #expect(rows[7].messages == ["\"zehn\" in column \"Value\" is not a number."])
        #expect(rows[8].status == .warning)
        #expect(rows[8].transaction?.amount.minor == 300)
        // empty type cell: inferred, flagged, new security in the row's currency
        #expect(rows[9].transaction?.kind == .buy)
        #expect(rows[9].status == .warning)
        #expect(rows[9].transaction?.amount.currency == "USD")
        #expect(proposal.newSecurities.map(\.name) == ["Neue AG"])
        #expect(rows[9].messages.contains { $0.contains("differs from the account's currency") })
        // negative interest is an interest charge
        #expect(rows[10].transaction?.kind == .interestCharge)
        #expect(rows[11].messages == ["Fees and taxes exceed the value of the transaction."])
        #expect(rows.filter { $0.status == .error }.count == 6)
        #expect(rows.filter { $0.status == .error }.allSatisfy { $0.transaction == nil && !$0.isImportable && !$0.isRecommended })
        #expect(rows[0].transaction?.securityID == bond.id)
        // errors are never applied, even when explicitly selected
        #expect(proposal.apply(to: file, selection: .rows(Set(0..<12))).transactions.count == 6)
        #expect(proposal.apply(to: file).transactions.count == 6)
    }

    @Test func requiresADateColumn() {
        let (file, _, _, _) = base()
        let document = CSVDocument(data: Data("Foo;Bar\n1;2\n3;4\n".utf8))
        let proposal = CSVImporter.propose(document, file: file)
        #expect(proposal.missingFields == [.date])
        #expect(proposal.errorCount == 2)
        #expect(proposal.rows[0].messages == ["No column is mapped to \"Date\"."])
        // a manual mapping fixes it
        var mapping = proposal.mapping
        mapping.set(.date, column: 0)
        mapping.set(.amount, column: 1)
        let dated = CSVDocument(data: Data("Foo;Bar\n2024-01-02;2\n2024-01-03;-4\n".utf8))
        let fixed = CSVImporter.propose(dated, options: CSVImportOptions(mapping: mapping), file: file)
        #expect(fixed.rows.map { $0.transaction?.kind } == [.deposit, .withdrawal])
    }

    @Test func matchesSecuritiesByIsinThenTickerThenWknThenName() {
        var (file, _, _, bond) = base()
        let other = Security(name: "Other", currency: "EUR", isin: "XX0000000001", wkn: "OTHER1", ticker: "OTH")
        file.securities.append(other)
        let csv = """
        Date,Type,Shares,Value,ISIN,Ticker Symbol,WKN,Security Name
        2024-01-02,Buy,1,1.00,ie00b4wxjj64,OTH,OTHER1,Other
        2024-01-02,Buy,1,2.00,,oth,A0RL83,x
        2024-01-02,Buy,1,3.00,,,a0rl83,Other
        2024-01-02,Buy,1,4.00,,,,OTHER
        2024-01-02,Buy,1,5.00,YY0000000002,,,Brand New
        2024-01-02,Buy,1,6.00,YY0000000002,,,Spelled differently
        2024-01-02,Buy,1,7.00,,,,brand new
        """
        let proposal = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), file: file)
        let ids = proposal.rows.map { $0.transaction?.securityID }
        #expect(ids[0] == bond.id) // ISIN wins over everything else
        #expect(ids[1] == other.id) // then ticker
        #expect(ids[2] == bond.id) // then WKN
        #expect(ids[3] == other.id) // then name, case-insensitively
        #expect(proposal.newSecurities.count == 1) // rows 5–7 share one new security
        #expect(ids[4] == proposal.newSecurities[0].id && ids[5] == ids[4] && ids[6] == ids[4])
    }

    // MARK: Quotes and securities targets

    @Test func importsHistoricalQuotes() throws {
        var (file, _, _, bond) = base()
        file.securities[0].prices = PriceSeries([PricePoint(day: day("2024-01-02"), price: Price(185.64)), PricePoint(day: day("2024-01-03"), price: Price(100))])
        let document = CSVDocument(data: try Fixture.data("csv/quotes_yahoo.csv"))
        let proposal = CSVImporter.propose(document, options: CSVImportOptions(target: .quotes, securityID: bond.id), file: file)
        #expect(proposal.mapping.columns == [.date, nil, nil, nil, .quote, nil, nil])
        #expect(proposal.rows.map(\.status) == [.duplicate(of: bond.id), .warning, .ok, .ok, .error])
        #expect(proposal.rows[1].messages == ["Replaces the existing quote 100 of that day."])
        #expect(proposal.rows[4].messages == ["\"null\" is not a valid quote."])
        #expect(proposal.rows[2].quote == PricePoint(day: day("2024-01-04"), price: Price(181.91)))
        let updated = proposal.apply(to: file)
        #expect(updated.securities[0].prices.map(\.price) == [Price(185.64), Price(184.25), Price(181.91), Price(181.18)])
        #expect(updated.transactions.isEmpty)

        // The target security can be chosen after the proposal was computed.
        var late = CSVImporter.propose(document, options: CSVImportOptions(target: .quotes), file: file)
        #expect(late.apply(to: file) == file)
        late.quoteSecurityID = bond.id
        #expect(late.apply(to: file).securities[0].prices.count == 4)
    }

    @Test func importsUTF16QuotesWithGermanNumbers() throws {
        let (file, _, _, bond) = base()
        let document = CSVDocument(data: try Fixture.data("csv/quotes_utf16.csv"))
        #expect(document.dialect.encoding == .utf16LittleEndian)
        #expect(document.dialect.delimiter == "\t")
        #expect(document.isDateOrderAmbiguous) // 02.01., 03.01., 04.01. fit both readings; dots decide for day-first
        let proposal = CSVImporter.propose(document, options: CSVImportOptions(target: .quotes, securityID: bond.id), file: file)
        #expect(proposal.rows.compactMap(\.quote) == [
            PricePoint(day: day("2024-01-02"), price: Price(1234.5)), PricePoint(day: day("2024-01-03"), price: Price(1240)),
            PricePoint(day: day("2024-01-04"), price: Price(1199.99)),
        ])
    }

    @Test func importsSecuritiesMasterData() {
        let (file, _, _, bond) = base()
        let csv = """
        Name;ISIN;WKN;Ticker;Währung;Notiz
        Bund ETF;IE00B4WXJJ64;;;EUR;
        Apple Inc.;US0378331005;865985;AAPL;USD;Tech
        Ohne Währung AG;DE0000000001;;;;
        ;;;;;x
        Apple again;US0378331005;;;USD;
        """
        let proposal = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), options: CSVImportOptions(target: .securities), file: file)
        #expect(proposal.rows.map(\.status) == [.duplicate(of: bond.id), .ok, .warning, .error, .duplicate(of: proposal.newSecurities[0].id)])
        #expect(proposal.newSecurities.map(\.name) == ["Apple Inc.", "Ohne Währung AG"])
        #expect(proposal.newSecurities[0] == Security(id: proposal.newSecurities[0].id, name: "Apple Inc.", currency: "USD", isin: "US0378331005", wkn: "865985", ticker: "AAPL", note: "Tech"))
        #expect(proposal.newSecurities[1].currency == "EUR")
        let updated = proposal.apply(to: file)
        #expect(updated.securities.map(\.name) == [bond.name, "Apple Inc.", "Ohne Währung AG"])
        #expect(proposal.apply(to: file, selection: .rows([2])).securities.map(\.name) == [bond.name, "Ohne Währung AG"])
    }
}

@Suite struct CSVExportTests {
    @Test func writesTablesWithQuotingAndLocale() {
        let table = CSVTable(header: ["Name", "Shares", "Value", "Day", "Ratio", "Count", "Empty"], rows: [
            ["ACME; \"the\" best", .shares(Shares(1.5)), .money(Money(minor: -123_456, currency: "EUR")), .day(day("2024-03-05")), .number(0.123456, fractionDigits: 4), .integer(42), .empty],
            [" padded ", .shares(Shares(raw: 1)), .minor(5), .day(day("2024-12-31")), .number(-1.5, fractionDigits: 0), .integer(-1), .text("multi\nline")],
            [.text("plain"), .price(Price(12.3)), .price(Price(raw: 1_234_567_891)), .empty, .number(.nan, fractionDigits: 2), .decimal(raw: 1_000_000, digits: 6, minFraction: 0), .text("a,b")],
        ])
        let international = CSVExporter.string(table, format: .international)
        #expect(international == [
            "Name,Shares,Value,Day,Ratio,Count,Empty",
            "\"ACME; \"\"the\"\" best\",1.5,-1234.56,2024-03-05,0.1235,42,",
            "\" padded \",0.00000001,0.05,2024-12-31,-2,-1,\"multi\nline\"",
            "plain,12.30,12.34567891,,,1,\"a,b\"",
        ].joined(separator: "\r\n") + "\r\n")
        let german = CSVExporter.string(table, format: .german)
        #expect(german == [
            "Name;Shares;Value;Day;Ratio;Count;Empty",
            "\"ACME; \"\"the\"\" best\";1,5;-1234,56;05.03.2024;0,1235;42;",
            "\" padded \";0,00000001;0,05;31.12.2024;-2;-1;\"multi\nline\"",
            "plain;12,30;12,34567891;;;1;a,b",
        ].joined(separator: "\r\n") + "\r\n")
        var custom = CSVExportFormat(delimiter: "\t", dateStyle: .monthDayYearSlashes, lineEnding: "\n", includeByteOrderMark: true)
        custom.decimalSeparator = "."
        let data = CSVExporter.data(CSVTable(header: ["D"], rows: [[.day(day("2024-03-05"))]]), format: custom)
        #expect(Array(data) == [0xEF, 0xBB, 0xBF] + Array("D\n03/05/2024\n".utf8))
        // What we write, we can read.
        let reread = CSVDocument(data: Data(german.utf8))
        #expect(reread.header == table.header)
        #expect(reread.rows[0][0] == "ACME; \"the\" best")
        #expect(reread.rows[1][0] == " padded ")
        #expect(reread.rows[1][6] == "multi\nline")
        #expect(reread.dialect.decimalSeparator == ",")
    }

    @Test(arguments: [CSVExportFormat.international, .german])
    func transactionsRoundTripThroughCSV(format: CSVExportFormat) throws {
        let file = makeRichFile()
        let table = CSVExporter.transactions(file, language: format.language)
        #expect(table.rows.count == file.transactions.count)
        #expect(table.header.first == (format.language == .german ? "Datum" : "Date"))
        let data = CSVExporter.data(table, format: format)

        // Import into a copy of the document without its ledger: everything comes back.
        var target = file
        target.transactions = []
        let document = CSVDocument(data: data)
        #expect(document.dialect.delimiter == format.delimiter)
        #expect(document.dialect.decimalSeparator == format.decimalSeparator)
        let proposal = CSVImporter.propose(document, file: target)
        #expect(proposal.rows.allSatisfy { $0.status == .ok }, "\(proposal.rows.filter { $0.status != .ok })")
        #expect(proposal.newSecurities.isEmpty && proposal.newAccounts.isEmpty && proposal.newDepots.isEmpty)
        let restored = proposal.apply(to: target)
        func normalized(_ transactions: [Transaction]) -> [Transaction] {
            transactions.map { transaction in
                var copy = transaction
                copy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                copy.source = nil
                return copy
            }
        }
        #expect(normalized(restored.transactions) == normalized(file.transactions.sorted(by: Transaction.chronological)))

        // Importing the export into the original document: all duplicates.
        let duplicates = CSVImporter.propose(document, file: file)
        #expect(duplicates.duplicateCount == file.transactions.count)
        #expect(duplicates.apply(to: file) == file)
    }

    @Test func exportsQuotesAndSecurities() throws {
        let file = makeRichFile()
        let acme = file.securities[0]
        let all = CSVExporter.quotes(of: acme)
        #expect(all.header == ["Date", "Quote"])
        #expect(all.rows.count == 400)
        let january = CSVExporter.quotes(of: acme, in: day("2023-01-01")...day("2023-01-31"), language: .german)
        #expect(january.header == ["Datum", "Kurs"])
        #expect(january.rows.count == 31)
        #expect(CSVExporter.string(january, format: .german).hasPrefix("Datum;Kurs\r\n01.01.2023;100,00\r\n02.01.2023;100,12345678\r\n"))

        // quotes round trip
        var target = file
        target.securities[0].prices = PriceSeries()
        let proposal = CSVImporter.propose(CSVDocument(data: CSVExporter.data(all, format: .german)), options: CSVImportOptions(target: .quotes, securityID: acme.id), file: target)
        #expect(proposal.apply(to: target).securities[0].prices == acme.prices)

        // securities round trip
        let securities = CSVExporter.securities(file)
        #expect(securities.header == ["Security Name", "ISIN", "WKN", "Ticker Symbol", "Currency", "Note"])
        var blank = file
        blank.securities = []
        let imported = CSVImporter.propose(CSVDocument(data: CSVExporter.data(securities)), options: CSVImportOptions(target: .securities), file: blank).apply(to: blank)
        #expect(imported.securities.map(\.name) == file.securities.map(\.name))
        #expect(imported.securities.map(\.currency) == file.securities.map(\.currency))
        #expect(imported.securities.map(\.isin) == file.securities.map(\.isin))
        #expect(imported.securities[0].note == "multi\nline")
    }
}

@Suite struct FileFormatTests {
    @Test func detectsFormatsByContent() throws {
        #expect(FileFormat.detect(data: try Fixture.data("pp/kommer.xml"), filename: "kommer.xml") == .portfolioPerformanceXML)
        #expect(FileFormat.detect(data: try Fixture.data("pp/synthetic_all_types_ids.xml")) == .portfolioPerformanceXML)
        #expect(FileFormat.detect(data: try Fixture.data("pp/client69.xml.zip"), filename: "x.portfolio") == .portfolioPerformanceZippedXML)
        #expect(FileFormat.detect(data: try Fixture.data("pp/client69.binary.portfolio"), filename: "x.portfolio") == .portfolioPerformanceBinary)
        #expect(FileFormat.detect(data: Data("PPPBV1\u{0}\u{1}".utf8)) == .portfolioPerformanceBinary)
        #expect(FileFormat.detect(data: try Fixture.data("pp/client53.encrypted.portfolio")) == .portfolioPerformanceEncrypted)
        #expect(FileFormat.detect(data: try Fixture.data("csv/pp_portfolio_de.csv"), filename: "export.csv") == .csv)
        #expect(FileFormat.detect(data: try Fixture.data("csv/broker_de_windows1252.csv")) == .csv)
        #expect(FileFormat.detect(data: try Fixture.data("csv/quotes_utf16.csv")) == .csv)
        #expect(FileFormat.detect(data: try Fixture.data("csv/broker_us_tab.csv"), filename: "activity.txt") == .csv)

        let kontor = try makeRichFile().encoded(pretty: true)
        #expect(FileFormat.detect(data: kontor, filename: "my.kontor") == .kontor)
        #expect(FileFormat.detect(data: try makeRichFile().encoded()) == .kontor)
        #expect(try PortfolioFile(data: kontor) == makeRichFile())

        #expect(FileFormat.detect(data: Data()) == .unknown)
        #expect(FileFormat.detect(data: Data("<html><body>hi</body></html>".utf8), filename: "page.xml") == .unknown)
        #expect(FileFormat.detect(data: Data("{\"hello\": 1}".utf8), filename: "x.json") == .unknown)
        #expect(FileFormat.detect(data: Data("{}".utf8), filename: "empty.kontor") == .kontor)
        #expect(FileFormat.detect(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]), filename: "image.png") == .unknown)
        #expect(FileFormat.detect(data: Data(storedZip(name: "a.txt", contents: [1, 2, 3])), filename: "a.zip") == .unknown)
        #expect(FileFormat.detect(data: Data("just one line of prose".utf8)) == .unknown)
        #expect(FileFormat.detect(data: Data("single\ncolumn\n".utf8), filename: "list.csv") == .csv)

        #expect(FileFormat.portfolioPerformanceXML.isReadable && FileFormat.csv.isReadable && FileFormat.kontor.isReadable)
        #expect(!FileFormat.portfolioPerformanceBinary.isReadable)
        #expect(FileFormat.portfolioPerformanceEncrypted.advice?.contains("Save As") == true)
        #expect(FileFormat.csv.advice == nil)
        #expect(FileFormat.allCases.allSatisfy { !$0.displayName.isEmpty })
    }
}
