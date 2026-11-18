import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

/// Regression tests for defects found during the independent review of the package.
/// Expected values are derived by hand from the inputs, never from the code under test.
@Suite struct ReviewRegressionTests {
    // MARK: Portfolio Performance import

    private func client(version: Int = 66, _ body: String) -> Data {
        Data("<client><version>\(version)</version><baseCurrency>EUR</baseCurrency>\(body)</client>".utf8)
    }

    @Test func oversizedReferenceIndexIsDanglingNotACrash() throws {
        let xml = client("""
        <securities><security><uuid>11111111-1111-1111-1111-111111111111</uuid><name>A</name><currencyCode>EUR</currencyCode></security></securities>
        <watchlists><watchlist><name>W</name><securities>
          <security reference="/client/securities/security[99999999999999999999]"/>
          <security reference="../../../../securities/security[18446744073709551617]"/>
          <security reference="../../../../securities/security[1]"/>
        </securities></watchlist></watchlists>
        """)
        let result = try PortfolioPerformanceImporter.read(xml)
        #expect(result.file.watchlists.first?.securityIDs == [UUID(uuidString: "11111111-1111-1111-1111-111111111111")!])
        #expect(result.report.warnings.first { $0.code == .unresolvedReference }?.count == 2)
    }

    @Test func absurdNumbersNeverOverflow() throws {
        // Two fee units of Int64.max each, and (format 25: shares × 1000) a share count that wraps to Int64.min.
        let xml = client(version: 25, """
        <securities><security><uuid>11111111-1111-1111-1111-111111111111</uuid><name>A</name><currencyCode>EUR</currencyCode>
          <prices><price t="2020-01-02" v="9223372036854775807"/></prices></security></securities>
        <accounts/>
        <portfolios><portfolio><name>P</name><transactions>
          <portfolio-transaction><date>2020-01-02</date><amount>9223372036854775807</amount>
            <security reference="../../../../../securities/security"/><shares>9223372036854775</shares><type>DELIVERY_INBOUND</type>
            <units><unit type="FEE"><amount currency="EUR" amount="9223372036854775807"/></unit>
                   <unit type="FEE"><amount currency="EUR" amount="9223372036854775807"/></unit>
                   <unit type="TAX"><amount currency="EUR" amount="-9223372036854775807"/></unit></units>
          </portfolio-transaction>
          <portfolio-transaction><date>2020-01-03</date><amount>100</amount>
            <security reference="../../../../../securities/security"/><shares>-9223372036854775808</shares><type>DELIVERY_OUTBOUND</type>
          </portfolio-transaction>
        </transactions></portfolio></portfolios>
        """)
        let result = try PortfolioPerformanceImporter.read(xml)
        #expect(result.file.transactions.count == 2)
        for transaction in result.file.transactions {
            #expect(transaction.shares.raw >= 0 && transaction.amount.minor >= 0 && transaction.fees >= 0 && transaction.taxes >= 0)
            // The model's own derived values must be computable without trapping.
            _ = transaction.grossMinor
            _ = transaction.grossPrice
        }
        #expect(result.report.warnings.contains { $0.code == .invalidValue })
        // … and the result can be written back.
        _ = PortfolioPerformanceExporter.export(result.file)
    }

    // MARK: CSV sniffing

    @Test func recognisesHeaderWithRepeatedTitles() throws {
        // Bank statements routinely repeat a title ("Währung" for balance and amount).
        let csv = """
        Buchung;Valuta;Auftraggeber/Empfänger;Buchungstext;Verwendungszweck;Saldo;Währung;Betrag;Währung
        02.01.2024;03.01.2024;Arbeitgeber GmbH;Gutschrift;Gehalt Januar;1.500,00;EUR;500,00;EUR
        05.01.2024;05.01.2024;Vermieter;Lastschrift;Miete;700,00;EUR;-800,00;EUR
        """
        let document = CSVDocument(data: Data(csv.utf8))
        #expect(document.dialect.headerRecord == 0)
        #expect(document.rows.count == 2)
        #expect(document.header[7] == "Betrag")
        let mapping = CSVColumnMapping.automatic(header: document.header)
        #expect(mapping.column(for: .amount) == 7)
        #expect(mapping.column(for: .currency) == 6)
        #expect(mapping.column(for: .date) == 1)
        let account = Account(name: "Giro", currency: "EUR")
        let proposal = CSVImporter.propose(document, file: PortfolioFile(accounts: [account]))
        #expect(proposal.rows.map { $0.transaction?.kind } == [.deposit, .withdrawal])
        #expect(proposal.rows.map { $0.transaction?.amount.minor } == [50_000, 80_000])
        #expect(proposal.rows.map { $0.transaction?.date } == [day("2024-01-03"), day("2024-01-05")])
    }

    @Test func dateOrderEvidenceFarDownTheFileCounts() {
        // 249 rows that fit both readings, then one that only fits month-first.
        var text = "When\tValue\n"
        for _ in 0..<249 { text += "03/04/2024\t1.5\n" }
        text += "03/25/2024\t1.5\n"
        let document = CSVDocument(data: Data(text.utf8))
        #expect(document.dialect.dateOrder == .monthDayYear)
        #expect(!document.isDateOrderAmbiguous)
        #expect(CSVValueParser.date(document.rows[0][0], order: document.dialect.dateOrder)?.day == day("2024-03-04"))

        // … and day-first evidence, with a German number format.
        text = "Datum;Wert\n"
        for _ in 0..<300 { text += "03.04.2024;1,5\n" }
        text += "25.04.2024;1,5\n"
        let german = CSVSniffer.sniff(Data(text.utf8))
        #expect(german.dialect.dateOrder == .dayMonthYear)
        #expect(!german.isDateOrderAmbiguous)
    }

    @Test func decimalSeparatorEvidenceFarDownTheFileCounts() {
        // 250 whole numbers, then the first decimal comma. Read with "." it would silently become 1250.
        var text = "Datum\tWert\n"
        for _ in 0..<250 { text += "2024-01-02\t12\n" }
        text += "2024-01-03\t12,50\n"
        let document = CSVDocument(data: Data(text.utf8))
        #expect(document.dialect.decimalSeparator == ",")
        #expect(!document.isDecimalSeparatorAmbiguous)
        #expect(CSVValueParser.decimal(document.rows[250][1], decimalSeparator: document.dialect.decimalSeparator, digits: 2) == 1_250)
    }

    @Test func mixedDecimalEvidenceIsFlagged() {
        // Half the cells say comma, half say dot: whatever is picked, the user must confirm.
        let sniffed = CSVSniffer.sniff(Data("Name\tA\tB\nx\t12,5\t12.5\ny\t7,25\t7.25\nz\t0,5\t3\n".utf8))
        #expect(sniffed.isDecimalSeparatorAmbiguous)
        #expect(sniffed.dialect.decimalSeparator == ",") // 3 votes against 2
    }

    // MARK: CSV import

    private func base() -> (file: PortfolioFile, account: Account, depot: Depot, bond: Security) {
        let account = Account(name: "Giro", currency: "EUR")
        let depot = Depot(name: "Broker", referenceAccountID: account.id)
        let bond = Security(name: "Euro Government Bond", currency: "EUR", isin: "IE00B4WXJJ64", wkn: "A0RL83", ticker: "EUNH.DE")
        return (PortfolioFile(name: "Test", securities: [bond], accounts: [account], depots: [depot]), account, depot, bond)
    }

    @Test func unsignedTradeListsWithoutTypeColumnArePurchases() {
        let (file, _, _, _) = base()
        // No amount in the file is negative, so the sign carries no direction: positions listed with shares are purchases.
        let unsigned = "Date,ISIN,Shares,Price,Amount\n2024-01-02,IE00B4WXJJ64,10,50.00,500.00\n2024-02-02,IE00B4WXJJ64,2,51.00,102.00\n"
        let first = CSVImporter.propose(CSVDocument(data: Data(unsigned.utf8)), file: file)
        #expect(first.rows.map { $0.transaction?.kind } == [.buy, .buy])
        #expect(first.rows.map { $0.transaction?.amount.minor } == [50_000, 10_200])
        // With signed amounts, money in + shares is a sale; negative share counts always are.
        let signed = "Date,ISIN,Shares,Price,Amount\n2024-01-02,IE00B4WXJJ64,10,50.00,-500.00\n2024-02-02,IE00B4WXJJ64,2,51.00,102.00\n2024-02-03,IE00B4WXJJ64,-1,51.00,51.00\n"
        let second = CSVImporter.propose(CSVDocument(data: Data(signed.utf8)), file: file)
        #expect(second.rows.map { $0.transaction?.kind } == [.buy, .sell, .sell])
    }

    @Test func weakerIdentifiersNeverOverrideAConflictingISIN() {
        let (file, _, _, bond) = base()
        let csv = """
        Date,Type,Shares,Value,ISIN,Ticker Symbol,WKN,Security Name
        2024-01-02,Buy,1,1.00,IE00B1FZS798,,,Euro Government Bond
        2024-01-02,Buy,1,2.00,IE00B1FZS798,EUNH.DE,,
        2024-01-02,Buy,1,3.00,,EUNH.DE,,Something else
        2024-01-02,Buy,1,4.00,,,A0RL83,
        """
        let proposal = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), file: file)
        let ids = proposal.rows.map { $0.transaction?.securityID }
        // Rows 1 and 2 carry a different ISIN: a different security, whatever name or ticker say.
        #expect(proposal.newSecurities.count == 1)
        #expect(proposal.newSecurities.first?.isin == "IE00B1FZS798")
        #expect(ids[0] == proposal.newSecurities.first?.id && ids[1] == ids[0])
        #expect(ids[0] != bond.id)
        // Without an ISIN in the row, ticker and WKN still match.
        #expect(ids[2] == bond.id && ids[3] == bond.id)
    }

    @Test func sameBookingInAnotherAccountIsNotADuplicate() {
        let giro = Account(name: "Giro", currency: "EUR"), savings = Account(name: "Savings", currency: "EUR")
        var file = PortfolioFile(accounts: [giro, savings])
        file.transactions = [Transaction(kind: .deposit, date: day("2024-01-02"), accountID: giro.id, amount: Money(minor: 50_000, currency: "EUR"))]
        let csv = "Date,Type,Value,Cash Account\n2024-01-02,Deposit,500.00,Giro\n2024-01-02,Deposit,500.00,Savings\n"
        let proposal = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), file: file)
        #expect(proposal.rows[0].status == .duplicate(of: file.transactions[0].id))
        #expect(proposal.rows[1].status == .ok)
        #expect(proposal.apply(to: file).transactions.count == 2)
    }

    @Test func hugeNumbersAreRejectedNotTrapped() {
        let (file, _, _, _) = base()
        let csv = """
        Date,Type,Shares,Quote,Value,Fees,Taxes,ISIN
        2024-01-02,Buy,90000000000,90000000000,,5,,IE00B4WXJJ64
        2024-01-02,Sell,1,,92233720368547758.07,1,1,IE00B4WXJJ64
        2024-01-02,Sell,,0.00000001,92233720368547758.07,1,1,IE00B4WXJJ64
        2024-01-02,Buy,1,,10.00,92233720368547758.07,92233720368547758.07,IE00B4WXJJ64
        2024-01-02,Buy,1,,10.00,1,,IE00B4WXJJ64
        """
        let proposal = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), file: file)
        #expect(proposal.rows.prefix(4).allSatisfy { $0.status == .error })
        #expect(proposal.rows[4].status == .ok)
        for row in proposal.rows { if let transaction = row.transaction { _ = transaction.grossMinor } }
    }

    @Test func derivesValueOfFeeTaxAndDividendRowsFromTheirBreakdown() {
        let (file, _, _, bond) = base()
        let csv = """
        Date,Type,ISIN,Gross Amount,Fees,Taxes
        2024-01-02,Fees,,,5.00,
        2024-01-03,Taxes,,,,7.50
        2024-02-01,Dividend,IE00B4WXJJ64,10.00,0.50,2.50
        2024-02-02,Deposit,,,,
        """
        let rows = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), file: file).rows
        #expect(rows[0].transaction?.kind == .fee)
        #expect(rows[0].transaction?.amount.minor == 500)
        #expect(rows[1].transaction?.kind == .tax)
        #expect(rows[1].transaction?.amount.minor == 750)
        // net = 10.00 − 0.50 − 2.50
        #expect(rows[2].transaction?.amount.minor == 700)
        #expect(rows[2].transaction?.fees == 50)
        #expect(rows[2].transaction?.taxes == 250)
        #expect(rows[2].transaction?.securityID == bond.id)
        #expect(rows[3].messages == ["The value is missing."])
    }
}

@Suite struct ReviewAdditionalTests {
    @Test func semicolonFilesReadLoneDotsAsGrouping() {
        // Only values like "1.000": in a semicolon (decimal-comma locale) file that is one thousand, not one.
        let german = CSVSniffer.sniff(Data("Datum;Stück\n02.01.2024;1.000\n03.01.2024;2.500\n".utf8))
        #expect(german.dialect.decimalSeparator == ",")
        #expect(german.isDecimalSeparatorAmbiguous)
        #expect(CSVValueParser.decimal("1.000", decimalSeparator: german.dialect.decimalSeparator, digits: 8) == 100_000_000_000)
        // … and in a comma-delimited file a quoted "1,000" is one thousand as well.
        let english = CSVSniffer.sniff(Data("Date,Shares\n2024-01-02,\"1,000\"\n2024-01-03,\"2,500\"\n".utf8))
        #expect(english.dialect.decimalSeparator == ".")
        #expect(english.isDecimalSeparatorAmbiguous)
    }

    @Test func dottedDatesFarDownTheFileAreNotDecimalEvidence() {
        // A second date column that is empty in the first 200 rows must not vote "comma" through its dots.
        var text = "Datum\tValuta\tWert\n"
        for _ in 0..<220 { text += "2024-01-02\t\t12.5\n" }
        for _ in 0..<400 { text += "2024-01-03\t03.01.2024\t7\n" }
        let sniffed = CSVSniffer.sniff(Data(text.utf8))
        #expect(sniffed.dialect.decimalSeparator == ".")
        #expect(!sniffed.isDecimalSeparatorAmbiguous)
    }

    @Test func readsInstantDatesOfVeryOldFiles() throws {
        // XStream's java.util.Date notation (UTC): local midnight of 2014-01-01 in Berlin and in New York.
        func xml(_ date: String) -> Data {
            Data("""
            <client><version>20</version><securities/><accounts><account><name>A</name><transactions>
              <account-transaction><date>\(date)</date><amount>100</amount><type>DEPOSIT</type></account-transaction>
            </transactions></account></accounts><portfolios/></client>
            """.utf8)
        }
        #expect(try PortfolioPerformanceImporter.read(xml("2013-12-31 23:00:00.0 UTC")).file.transactions.first?.date == day("2014-01-01"))
        #expect(try PortfolioPerformanceImporter.read(xml("2014-01-01 05:00:00.0 UTC")).file.transactions.first?.date == day("2014-01-01"))
        #expect(try PortfolioPerformanceImporter.read(xml("2014-01-01 00:00:00.0 UTC")).file.transactions.first?.date == day("2014-01-01"))
        #expect(try PortfolioPerformanceImporter.read(xml("2014-01-01")).file.transactions.first?.date == day("2014-01-01"))
        #expect(try PortfolioPerformanceImporter.read(xml("2014-01-01T23:30")).file.transactions.first?.date == day("2014-01-01"))
    }

    @Test func proposalCountsAndIdentities() {
        let csv = "Date,Type,Value\n2024-01-02,Deposit,1.00\n2024-01-03,Bogus,1.00\n2024-01-04,,1.00\n2024-01-02,Deposit,1.00\n"
        let account = Account(name: "Giro", currency: "EUR")
        var file = PortfolioFile(accounts: [account])
        let first = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), file: file)
        // rows: ok, unknown type, inferred type (warning), ok (same-file repeats are not duplicates)
        #expect(first.statusCounts == ImportProposal.StatusCounts(ok: 2, warning: 1, error: 1, duplicate: 0))
        #expect(first.statusCounts.recommended == 3)
        #expect((first.okCount, first.warningCount, first.errorCount, first.duplicateCount) == (2, 1, 1, 0))
        #expect(first.unrecognizedTypes == ["Bogus"])
        file = first.apply(to: file)
        let second = CSVImporter.propose(CSVDocument(data: Data(csv.utf8)), file: file)
        #expect(second.statusCounts == ImportProposal.StatusCounts(ok: 0, warning: 0, error: 1, duplicate: 3))
        #expect(second.apply(to: file) == file) // importing the same file twice changes nothing

        #expect(CSVTransactionType.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(CSVTransactionType.deliveryIn.displayName == "Delivery (Inbound)")
        let warning = ImportWarning(code: .invalidValue, message: "m")
        #expect(warning.id == "invalidValue|m")
    }
}

extension ReviewAdditionalTests {
    @Test func tickerSymbolsWithDotsAreNotDecimalEvidence() {
        // Exchange suffixes ("0700.HK", "7203.T") in a German file: one comma-decimal column, one ticker column.
        let sniffed = CSVSniffer.sniff(Data("Datum;Ticker;Kurs\n02.01.2024;0700.HK;301,20\n03.01.2024;7203.T;2650,5\n04.01.2024;005930.KS;71000\n".utf8))
        #expect(sniffed.dialect.decimalSeparator == ",")
        #expect(!sniffed.isDecimalSeparatorAmbiguous)
    }
}

extension ReviewAdditionalTests {
    @Test func ledgerOrderSurvivesPortfolioPerformanceRoundTrip() throws {
        let account = Account(name: "Giro", currency: "EUR")
        func deposit(_ minor: Int64, _ date: String) -> Transaction {
            Transaction(kind: .deposit, date: day(date), accountID: account.id, amount: Money(minor: minor, currency: "EUR"))
        }
        // Three bookings on one day in a deliberate order, plus a ledger that is not chronological (appended import).
        let first = deposit(300, "2024-01-02"), second = deposit(100, "2024-01-02"), third = deposit(200, "2024-01-02"), earlier = deposit(900, "2023-05-05")
        let file = PortfolioFile(accounts: [account], transactions: [first, second, third, earlier])
        let exported = PortfolioPerformanceExporter.export(file)
        #expect(try PortfolioPerformanceImporter.read(exported.data).file.transactions.map(\.id) == [first, second, third, earlier].map(\.id))

        // Edited outside Kontor (here: one id vanished from the recorded order): the ledger is sorted by
        // date; the recorded order only breaks ties, unknown entries come last within their day.
        let hex = second.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let xml = String(decoding: exported.data, as: UTF8.self)
        #expect(xml.contains(hex))
        let edited = Data(xml.replacingOccurrences(of: hex, with: "").utf8)
        #expect(try PortfolioPerformanceImporter.read(edited).file.transactions.map(\.id) == [earlier, first, third, second].map(\.id))
    }
}
