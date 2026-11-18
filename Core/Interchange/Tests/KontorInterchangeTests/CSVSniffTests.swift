import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

@Suite struct CSVSniffTests {
    // MARK: Encoding

    @Test func detectsEncodings() throws {
        let text = "Größe;Währung\n1,5;€\n"
        #expect(CSVTextEncoding.detect(Data(text.utf8)) == .utf8)
        #expect(CSVTextEncoding.detect(Data([0xEF, 0xBB, 0xBF] + Array(text.utf8))) == .utf8)
        #expect(CSVTextEncoding.utf8.decode(Data([0xEF, 0xBB, 0xBF] + Array(text.utf8))) == text)

        var utf16LE: [UInt8] = [], utf16BE: [UInt8] = []
        for unit in text.utf16 { utf16LE += [UInt8(unit & 0xFF), UInt8(unit >> 8)]; utf16BE += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        #expect(CSVTextEncoding.detect(Data([0xFF, 0xFE] + utf16LE)) == .utf16LittleEndian)
        #expect(CSVTextEncoding.detect(Data([0xFE, 0xFF] + utf16BE)) == .utf16BigEndian)
        #expect(CSVTextEncoding.detect(Data(utf16LE)) == .utf16LittleEndian) // no BOM
        #expect(CSVTextEncoding.detect(Data(utf16BE)) == .utf16BigEndian)
        #expect(CSVTextEncoding.utf16LittleEndian.decode(Data([0xFF, 0xFE] + utf16LE)) == text)
        #expect(CSVTextEncoding.utf16BigEndian.decode(Data(utf16BE)) == text)

        // Windows-1252: "Größe;Währung\n1,5;€" — 0x80 is the euro sign, which Latin-1 does not have.
        let cp1252: [UInt8] = [0x47, 0x72, 0xF6, 0xDF, 0x65, 0x3B, 0x57, 0xE4, 0x68, 0x72, 0x75, 0x6E, 0x67, 0x0A, 0x31, 0x2C, 0x35, 0x3B, 0x80, 0x0A]
        #expect(CSVTextEncoding.detect(Data(cp1252)) == .windows1252)
        #expect(CSVTextEncoding.windows1252.decode(Data(cp1252)) == text)
        #expect(CSVTextEncoding.detect(Data()) == .utf8)
        // Truncated or overlong UTF-8 is not UTF-8.
        #expect(CSVTextEncoding.detect(Data([0x41, 0xC3])) == .windows1252)
        #expect(CSVTextEncoding.detect(Data([0xC0, 0xAF])) == .windows1252)
    }

    // MARK: Delimiter / header matrix

    @Test(arguments: [
        ("Date;Type;Value\n2024-01-02;Buy;1,5\n2024-01-03;Sell;2,5\n", ";" as Character, 3, true),
        ("Date,Type,Value\n2024-01-02,Buy,1.5\n2024-01-03,Sell,2.5\n", ",", 3, true),
        ("Date\tType\tValue\n2024-01-02\tBuy\t1,5\n", "\t", 3, true),
        ("Date|Type|Value\n2024-01-02|Buy|1.5\n", "|", 3, true),
        ("Datum;Text;Betrag\n02.01.2024;\"Miete; Januar, warm\";-1.000,00\n03.01.2024;\"a,b,c,d,e\";5,00\n", ";", 3, true),
        ("\"Date\",\"Note\",\"Value\"\n\"2024-01-02\",\"x;y;z;1;2;3\",\"1.5\"\n\"2024-01-03\",\"p;q\",\"2.5\"\n", ",", 3, true),
        ("2024-01-02,12.5\n2024-01-03,12.7\n", ",", 2, false),
        ("Kontoauszug\nErstellt am;01.02.2024\n\nDatum;Typ;Wert;Notiz\n02.01.2024;Kauf;1,00;a\n03.01.2024;Kauf;2,00;b\n", ";", 4, true),
    ])
    func sniffsDelimiterAndHeader(text: String, delimiter: Character, columns: Int, hasHeader: Bool) {
        let document = CSVDocument(data: Data(text.utf8))
        #expect(document.dialect.delimiter == delimiter)
        #expect(document.header.count == columns)
        #expect((document.dialect.headerRecord != nil) == hasHeader)
        #expect(document.rows.allSatisfy { $0.count == columns })
    }

    @Test func parsesQuotingAndLineEndings() {
        let text = "a,b,c\r\n\"multi\nline\",\"with \"\"quotes\"\"\",  padded  \r\n\r\n,,\r\nlast,,x"
        let records = CSVCodec.parse(text, delimiter: 44)
        #expect(records.map(\.fields) == [["a", "b", "c"], ["multi\nline", "with \"quotes\"", "padded"], ["last", "", "x"]])
        #expect(records.map(\.line) == [1, 2, 6])
        // classic Mac line endings and a trailing delimiter
        #expect(CSVCodec.parse("a;b;\rc;d;\r", delimiter: 59).map(\.fields) == [["a", "b", ""], ["c", "d", ""]])
        #expect(CSVCodec.parse("", delimiter: 44).isEmpty)
        #expect(CSVCodec.parse("x", delimiter: 44).map(\.fields) == [["x"]])
    }

    @Test func skipsPreambleAndKeepsLineNumbers() throws {
        let document = CSVDocument(data: try Fixture.data("csv/broker_de_windows1252.csv"))
        #expect(document.dialect.encoding == .windows1252)
        #expect(document.dialect.delimiter == ";")
        #expect(document.dialect.headerRecord == 2)
        #expect(document.dialect.decimalSeparator == ",")
        #expect(document.dialect.dateOrder == .dayMonthYear)
        #expect(document.header == ["Buchungstag", "Geschäftsart", "Stück", "Bezeichnung", "ISIN", "Kurs", "Betrag", "Währung", "Gebühr"])
        #expect(document.rows.count == 4)
        #expect(document.lineNumbers == [5, 6, 7, 8])
        #expect(document.rows[0][3] == "Müller & Söhne Beteiligungs-AG")
        #expect(document.rows[3][3] == "Fonds „Größe“ €")
    }

    @Test func generatesColumnTitlesWithoutHeader() {
        let document = CSVDocument(data: Data("2024-01-02;12,5;x\n2024-01-03;12,7;\n".utf8))
        #expect(document.header == ["Column 1", "Column 2", "Column 3"])
        #expect(document.rows == [["2024-01-02", "12,5", "x"], ["2024-01-03", "12,7", ""]])
        // An explicit dialect overrides everything that was sniffed.
        var dialect = document.dialect
        dialect.headerRecord = 0
        dialect.firstDataRecord = 1
        let forced = CSVDocument(data: Data("2024-01-02;12,5;x\n2024-01-03;12,7;\n".utf8), dialect: dialect)
        #expect(forced.header == ["2024-01-02", "12,5", "x"])
        #expect(forced.rows.count == 1)
    }

    // MARK: Numbers

    @Test(arguments: [
        ("1.234,56", "," as Character, 123_456 as Int64?), ("1,234.56", ".", 123_456), ("1234.5", ".", 123_450), ("1 234,56", ",", 123_456),
        ("1'234.56", ".", 123_456), ("-12,50 €", ",", -1_250), ("€ 12,50", ",", 1_250), ("12.50 USD", ".", 1_250), ("EUR 0,99", ",", 99),
        ("(1,816.80)", ".", -181_680), ("$5.00", ".", 500), ("12,50-", ",", -1_250), ("−3,5", ",", -350), ("+7", ".", 700), ("1.000", ",", 100_000),
        ("1.000", ".", 100), ("0,005", ",", 1), ("0,004", ",", 0), ("1.5E2", ".", 15_000), ("2e-2", ".", 2), ("12 %", ".", 1_200), (".5", ".", 50),
        ("abc", ".", nil), ("", ".", nil), ("null", ".", nil), ("-", ".", nil), ("1.2.3", ".", nil),
    ])
    func parsesNumbers(text: String, separator: Character, expected: Int64?) {
        #expect(CSVValueParser.decimal(text, decimalSeparator: separator, digits: 2) == expected)
    }

    @Test func parsesHighPrecisionAndLargeValues() {
        #expect(CSVValueParser.decimal("0,00636567", decimalSeparator: ",", digits: 8) == 636_567)
        #expect(CSVValueParser.decimal("123456789.123456789", decimalSeparator: ".", digits: 8) == 12_345_678_912_345_679)
        #expect(CSVValueParser.decimal("99999999999999999999", decimalSeparator: ".", digits: 2) == nil) // overflow
    }

    @Test(arguments: [
        (["1.234,56", "12,5"], "," as Character, false), (["1,234.56", "0.5"], ".", false), (["12,5", "7,25", "1.000"], ",", false),
        (["12.5", "1,000"], ".", false), (["1,234", "5,678"], ",", true), (["1.234", "5.678"], ".", true), (["1.234.567", "3"], ",", false),
        (["1,234,567", "3"], ".", false), (["0,125"], ",", false), (["12", "7"], ".", false),
    ])
    func sniffsDecimalSeparator(cells: [String], separator: Character, ambiguous: Bool) {
        // comma-delimited would be ambiguous with decimal commas, so the matrix uses tabs
        let text = "Name\tValue\n" + cells.map { "x\t\($0)" }.joined(separator: "\n") + "\n"
        let sniffed = CSVSniffer.sniff(Data(text.utf8))
        #expect(sniffed.dialect.delimiter == "\t")
        #expect(sniffed.dialect.decimalSeparator == separator)
        #expect(sniffed.isDecimalSeparatorAmbiguous == ambiguous)
    }

    @Test func datesDoNotCountAsDecimalEvidence() {
        // German dates with English numbers: the dots in the dates must not vote for a decimal comma.
        let sniffed = CSVSniffer.sniff(Data("Datum\tWert\n02.01.2024\t12.50\n03.01.2024\t7.25\n".utf8))
        #expect(sniffed.dialect.decimalSeparator == ".")
    }

    // MARK: Dates

    @Test(arguments: [
        ("2024-03-31", CSVDateOrder.yearMonthDay, "2024-03-31", nil as Int?), ("2024/03/31", .dayMonthYear, "2024-03-31", nil), ("20240331", .monthDayYear, "2024-03-31", nil),
        ("31.03.2024", .dayMonthYear, "2024-03-31", nil), ("31.3.24", .dayMonthYear, "2024-03-31", nil), ("1.2.99", .dayMonthYear, "1999-02-01", nil),
        ("03/31/2024", .monthDayYear, "2024-03-31", nil), ("3/4/2024", .monthDayYear, "2024-03-04", nil), ("3/4/2024", .dayMonthYear, "2024-04-03", nil),
        ("31-03-2024", .dayMonthYear, "2024-03-31", nil), ("24-03-31", .yearMonthDay, "2024-03-31", nil),
        ("2024-03-31T14:05:09Z", .yearMonthDay, "2024-03-31", 845), ("2024-03-31 00:00:00", .yearMonthDay, "2024-03-31", nil),
        ("31.03.2024 09:30", .dayMonthYear, "2024-03-31", 570), ("03/31/2024 2:05 PM", .monthDayYear, "2024-03-31", 845), ("03/31/2024 12:10 AM", .monthDayYear, "2024-03-31", 10),
        ("5 Jan 2024", .yearMonthDay, "2024-01-05", nil), ("Jan 5, 2024", .dayMonthYear, "2024-01-05", nil), ("5. Januar 2024", .dayMonthYear, "2024-01-05", nil),
        ("12. März 2023", .dayMonthYear, "2023-03-12", nil), ("31 Dez 24", .dayMonthYear, "2024-12-31", nil), ("2024 Oct 7", .dayMonthYear, "2024-10-07", nil),
    ])
    func parsesDates(text: String, order: CSVDateOrder, expected: String, minute: Int?) {
        let parsed = CSVValueParser.date(text, order: order)
        #expect(parsed?.day.iso == expected)
        #expect(parsed?.minuteOfDay == minute)
    }

    @Test(arguments: ["31/02/2024", "2024-13-01", "00.01.2024", "hello", "", "12", "2024-02-30", "32.01.2024"])
    func rejectsInvalidDates(text: String) {
        #expect(CSVValueParser.date(text, order: .dayMonthYear) == nil)
    }

    @Test(arguments: [
        (["2024-01-05", "2024-01-06"], CSVDateOrder.yearMonthDay, false),
        (["05.01.2024", "17.01.2024"], .dayMonthYear, false),
        (["01/05/2024", "01/17/2024"], .monthDayYear, false),
        (["13/01/2024", "02/02/2024"], .dayMonthYear, false),
        // every row fits both readings; only day-first keeps the column sorted
        (["01/02/2024", "05/02/2024", "09/02/2024", "02/03/2024", "07/03/2024"], .dayMonthYear, true),
        // … and here only month-first does
        (["01/02/2024", "01/05/2024", "01/09/2024", "02/03/2024", "03/01/2024"], .monthDayYear, true),
        // descending exports count as sorted, too
        (["03/01/2024", "02/03/2024", "01/09/2024", "01/05/2024"], .monthDayYear, true),
        // no evidence at all: dots mean day-first, slashes month-first
        (["01.02.2024"], .dayMonthYear, true),
        (["01/02/2024"], .monthDayYear, true),
        (["01-02-2024"], .dayMonthYear, true),
    ])
    func disambiguatesDateOrderOverTheWholeColumn(cells: [String], order: CSVDateOrder, ambiguous: Bool) {
        let text = "When\tValue\n" + cells.map { "\($0)\t1.5" }.joined(separator: "\n") + "\n"
        let sniffed = CSVSniffer.sniff(Data(text.utf8))
        #expect(sniffed.dialect.dateOrder == order)
        #expect(sniffed.isDateOrderAmbiguous == ambiguous)
    }

    @Test func decimalCommaTipsAmbiguousSlashDatesToDayFirst() {
        let sniffed = CSVSniffer.sniff(Data("Date;Amount\n01/02/2024;12,50\n".utf8))
        #expect(sniffed.dialect.dateOrder == .dayMonthYear)
        #expect(sniffed.isDateOrderAmbiguous)
    }

    @Test func parsesTimes() {
        #expect(CSVValueParser.time("14:05") == 845)
        #expect(CSVValueParser.time("14:05:33") == 845)
        #expect(CSVValueParser.time("2:05 PM") == 845)
        #expect(CSVValueParser.time("1405") == 845)
        #expect(CSVValueParser.time("25:00") == nil)
        #expect(CSVValueParser.time("soon") == nil)
    }

    // MARK: Header mapping

    @Test func mapsPortfolioPerformanceHeadersInGermanAndEnglish() {
        let german = ["Datum", "Uhrzeit", "Typ", "Wert", "Buchungswährung", "Bruttobetrag", "Währung Bruttobetrag", "Wechselkurs", "Gebühren", "Steuern", "Stück",
                      "ISIN", "WKN", "Ticker-Symbol", "Wertpapiername", "Notiz", "Konto", "Gegenkonto", "Depot", "Gegendepot", "Kurs"]
        let english = ["Date", "Time", "Type", "Value", "Transaction Currency", "Gross Amount", "Currency Gross Amount", "Exchange Rate", "Fees", "Taxes", "Shares",
                       "ISIN", "WKN", "Ticker Symbol", "Security Name", "Note", "Cash Account", "Offset Account", "Securities Account", "Offset securities account", "Quote"]
        let expected: [CSVField?] = [.date, .time, .type, .amount, .currency, .grossAmount, .grossCurrency, .exchangeRate, .fees, .taxes, .shares,
                                     .isin, .wkn, .ticker, .securityName, .note, .account, .counterAccount, .depot, .counterDepot, .quote]
        #expect(CSVColumnMapping.automatic(header: german).columns == expected)
        #expect(CSVColumnMapping.automatic(header: english).columns == expected)
        // every field's own display name maps back to it
        #expect(CSVColumnMapping.automatic(header: CSVField.allCases.map(\.displayName)).columns == CSVField.allCases)
    }

    @Test func mapsCommonBrokerHeaders() {
        let broker = CSVColumnMapping.automatic(header: ["Buchungstag", "Geschäftsart", "Stück", "Bezeichnung", "ISIN", "Kurs", "Betrag (EUR)", "Währung", "Gebühr", "Unbekannt"])
        #expect(broker.columns == [.date, .type, .shares, .securityName, .isin, .quote, .amount, .currency, .fees, nil])
        let us = CSVColumnMapping.automatic(header: ["Trade Date", "Symbol", "Description", "Quantity", "Price", "Amount", "Commission"])
        #expect(us.columns == [.date, .ticker, .securityName, .shares, .quote, .amount, .fees])
        // decorated titles, duplicates (first wins) and case/diacritics
        let decorated = CSVColumnMapping.automatic(header: ["DATUM", "Betrag in EUR", "Betrag in USD", "Kapitalertragsteuer (KESt)", "Wertpapier-Nr."])
        #expect(decorated.columns == [.date, .amount, nil, .taxes, .securityName])
        // target restricts the vocabulary
        let quotes = CSVColumnMapping.automatic(header: ["Date", "Open", "High", "Low", "Close", "Adj Close", "Volume"], target: .quotes)
        #expect(quotes.columns == [.date, nil, nil, nil, .quote, nil, nil])
        #expect(CSVColumnMapping.automatic(header: ["Column 1", "Column 2"], target: .quotes).columns == [.date, .quote])
        let securities = CSVColumnMapping.automatic(header: ["Name", "ISIN", "Währung", "Kurs", "Datum"], target: .securities)
        #expect(securities.columns == [.securityName, .isin, .currency, nil, nil])

        var mapping = broker
        mapping.set(.note, column: 9)
        mapping.set(.amount, column: 5) // steals the column from .quote
        #expect(mapping.columns == [.date, .type, .shares, .securityName, .isin, .amount, nil, .currency, .fees, .note])
        #expect(mapping.column(for: .amount) == 5)
        mapping.set(.fees, column: nil)
        #expect(mapping.column(for: .fees) == nil)
    }

    @Test func mapsTypeValuesInGermanAndEnglish() {
        let pairs: [(String, CSVTransactionType)] = [
            ("Buy", .buy), ("Kauf", .buy), ("Sell", .sell), ("Verkauf", .sell), ("Dividend", .dividend), ("Dividende", .dividend), ("Ausschüttung", .dividend),
            ("Deposit", .deposit), ("Einlage", .deposit), ("Removal", .withdrawal), ("Entnahme", .withdrawal), ("Withdrawal", .withdrawal),
            ("Interest", .interest), ("Zinsen", .interest), ("Interest Charge", .interestCharge), ("Zinsbelastung", .interestCharge),
            ("Fees", .fee), ("Gebühren", .fee), ("Fees Refund", .feeRefund), ("Gebührenerstattung", .feeRefund), ("Taxes", .tax), ("Steuern", .tax),
            ("Tax Refund", .taxRefund), ("Steuerrückerstattung", .taxRefund), ("Transfer", .transfer), ("Umbuchung", .transfer),
            ("Transfer (Inbound)", .transferIn), ("Umbuchung (Eingang)", .transferIn), ("Transfer (Outbound)", .transferOut), ("Umbuchung (Ausgang)", .transferOut),
            ("Delivery (Inbound)", .deliveryIn), ("Einlieferung", .deliveryIn), ("Delivery (Outbound)", .deliveryOut), ("Auslieferung", .deliveryOut),
            ("  KAUF ", .buy), ("wertpapierkauf", .buy), ("Savings Plan", .buy),
        ]
        for (text, expected) in pairs { #expect(CSVTransactionType.match(text) == expected, "\(text)") }
        #expect(CSVTransactionType.match("Kapitalmaßnahme") == nil)
        #expect(CSVTransactionType.match("") == nil)
        // exported labels are understood again, in both languages
        for type in CSVTransactionType.allCases {
            #expect(CSVTransactionType.match(type.label(german: false)) == type)
            #expect(CSVTransactionType.match(type.label(german: true)) == type)
        }
    }
}
