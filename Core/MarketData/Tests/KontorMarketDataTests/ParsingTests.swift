import Foundation
import KontorModel
import Testing
@testable import KontorMarketData

@Suite struct DateParsingTests {
    @Test(arguments: [
        ("2024-01-31", "2024-01-31"), ("2024-01-31T16:00:00Z", "2024-01-31"), ("2024-01-31 16:00:00", "2024-01-31"),
        ("2024/01/31", "2024-01-31"), ("20240131", "2024-01-31"), ("31.01.2024", "2024-01-31"), ("31.01.24", "2024-01-31"),
        ("1.2.2024", "2024-02-01"), ("31-01-2024", "2024-01-31"), ("01/31/2024", "2024-01-31"), ("1/2/2024", "2024-01-02"),
        ("31/01/2024", "2024-01-31"), ("31 Jan 2024", "2024-01-31"), ("Jan 31, 2024", "2024-01-31"), ("31-Jan-24", "2024-01-31"),
        ("31. Januar 2024", "2024-01-31"), ("3. März 2024", "2024-03-03"), ("Wed, 31 Jan 2024 10:00:00 GMT", "2024-01-31"),
        ("15 Dez 1999", "1999-12-15"), ("1704067200", "2024-01-01"), ("1704067200000", "2024-01-01"), ("\"2024-01-31\"", "2024-01-31"),
        ("2024-Jan-31", "2024-01-31"), ("05.06.98", "1998-06-05"),
    ])
    func parsesNotation(_ text: String, _ expected: String) {
        #expect(DayParser.parse(text) == day(expected))
    }

    @Test(arguments: ["", "n/a", "2024-13-01", "31.02.2024", "12:30", "185.64", "1,234.56", "2024", "Date"])
    func rejectsNonDates(_ text: String) {
        #expect(DayParser.parse(text) == nil)
    }

    @Test func resolvesAmbiguousOrder() {
        #expect(DayParser.parse("03/04/2024") == day("2024-03-04"))
        #expect(DayParser.parse("03/04/2024", order: .dayFirst) == day("2024-04-03"))
        #expect(DayParser.parse("03.04.2024") == day("2024-04-03"))
        #expect(DayParser.parse("03.04.2024", order: .monthFirst) == day("2024-03-04"))
        #expect(DayParser.detectOrder(["01/02/2024", "13/02/2024"]) == .dayFirst)
        #expect(DayParser.detectOrder(["01/02/2024", "02/13/2024"]) == .monthFirst)
        #expect(DayParser.detectOrder(["01/02/2024", "03/04/2024"]) == nil)
        #expect(DayParser.detectOrder(["2024-01-02"]) == nil)
    }

    @Test func interpretsNumbers() {
        #expect(DayParser.day(fromNumber: 20240131) == day("2024-01-31"))
        #expect(DayParser.day(fromNumber: 1_704_067_200) == day("2024-01-01"))
        #expect(DayParser.day(fromNumber: 1_704_153_599_000) == day("2024-01-01"))
        #expect(DayParser.day(fromNumber: -86_400) == day("1969-12-31"))
        #expect(DayParser.day(fromNumber: .nan) == nil)
    }

    @Test func explicitPatterns() throws {
        let german = try #require(DatePattern("dd.MM.yyyy"))
        #expect(german.parse("31.01.2024") == day("2024-01-31"))
        #expect(german.parse("1.2.2024 17:35") == day("2024-02-01"))
        #expect(german.parse("2024-01-31") == nil)
        #expect(german.format(day("2024-02-01")) == "01.02.2024")
        #expect(DatePattern("yyyyMMdd")?.parse("20240131") == day("2024-01-31"))
        #expect(DatePattern("yyyyMMdd")?.format(day("2024-01-05")) == "20240105")
        #expect(DatePattern("MM/dd/yy")?.parse("01/31/24") == day("2024-01-31"))
        #expect(DatePattern("d-MMM-yy")?.parse("5-Feb-24") == day("2024-02-05"))
        #expect(DatePattern("d-MMM-yy")?.format(day("2024-02-05")) == "5-Feb-24")
        #expect(DatePattern("DD/MM/YYYY")?.parse("31/01/2024") == day("2024-01-31"))
        #expect(DatePattern("yyyy-MM") == nil)
        #expect(DatePattern("hello") == nil)
    }

    @Test func dateFormatOption() throws {
        #expect(DateFormat(option: nil) == .auto)
        #expect(DateFormat(option: " auto ") == .auto)
        #expect(DateFormat(option: "unix") == .unixSeconds)
        #expect(DateFormat(option: "unix-ms") == .unixMilliseconds)
        #expect(DateFormat(option: "bogus") == nil)
        #expect(DateFormat.unixSeconds.parse("1704067200") == day("2024-01-01"))
        #expect(DateFormat.unixMilliseconds.parse(number: 1_704_067_200_000) == day("2024-01-01"))
        // Explicit unix seconds are not mistaken for yyyyMMdd.
        #expect(DateFormat.unixSeconds.parse(number: 20_240_131) == day("1970-08-23"))
        let pattern = try #require(DateFormat(option: "yyyyMMdd"))
        #expect(pattern.parse(number: 20240131) == day("2024-01-31"))
    }
}

@Suite struct NumberParsingTests {
    @Test(arguments: [
        ("1234.56", 1234.56), ("1,234.56", 1234.56), ("1.234,56", 1234.56), ("1'234.56", 1234.56), ("82,21 €", 82.21),
        ("$ 1,234", 1234), ("0,123", 0.123), ("82,2160", 82.216), ("1 234,5", 1234.5), ("-3.5", -3.5), ("1.2e3", 1200),
        ("1.234.567", 1234567), ("1,234,567", 1234567), ("12", 12), ("−7,5", -7.5), ("5%", 5),
    ])
    func parsesAutomatically(_ text: String, _ expected: Double) {
        #expect(NumberParser.parse(text) == expected)
    }

    @Test func explicitSeparatorWins() {
        #expect(NumberParser.parse("1,234", decimal: .comma) == 1.234)
        #expect(NumberParser.parse("1,234", decimal: .point) == 1234)
        #expect(NumberParser.parse("1.234", decimal: .comma) == 1234)
        #expect(NumberParser.parse("1.2.3", decimal: .point) == nil)
    }

    @Test(arguments: ["", "n/a", "null", "abc", "--", "12abc"])
    func rejectsNonNumbers(_ text: String) {
        #expect(NumberParser.parse(text) == nil)
    }

    @Test func cleansFloatArtifacts() {
        #expect(cleanedQuote(185.63999938964844) == 185.64)
        #expect(cleanedQuote(82.21600341796875) == 82.216)
        #expect(cleanedQuote(108.9375) == 108.9375)
        #expect(cleanedQuote(64529.95955638787) == 64529.95955638787) // a genuine double stays untouched
        #expect(Price(quote: 69.76000213623047) == Price(69.76))
        #expect(compactDescription(4) == "4")
        #expect(compactDescription(0.205) == "0.205")
    }
}

@Suite struct CSVTests {
    @Test func englishFileWithHeader() throws {
        let csv = """
        Date,Open,High,Low,Close,Adj Close,Volume
        2024-01-02,187.15,188.44,183.89,185.64,184.25,82488700
        2024-01-03,184.22,185.88,183.43,184.25,182.87,58414500
        2024-01-04,182.15,183.09,180.88,null,null,0
        2024-01-05,181.99,182.76,180.17,181.18,179.82,62379700
        """
        let dialect = try CSVQuoteParser.sniff(csv)
        #expect(dialect.delimiter == ",")
        #expect(dialect.header?.count == 7)
        #expect(dialect.firstDataRow == 1)
        #expect(dialect.dateColumn == 0)
        #expect(dialect.closeColumn == 4)
        #expect(dialect.decimalSeparator == .point)
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-02", 185.64), point("2024-01-03", 184.25), point("2024-01-05", 181.18)])
    }

    @Test func germanFileWithSemicolonsAndDecimalCommas() throws {
        let csv = "\u{FEFF}Datum;Eröffnung;Schlusskurs;Volumen\r\n03.01.2024;82,150;81,842;379.260\r\n02.01.2024;82,462;82,216;802.401\r\n"
        let dialect = try CSVQuoteParser.sniff(csv)
        #expect(dialect.delimiter == ";")
        #expect(dialect.dateColumn == 0)
        #expect(dialect.closeColumn == 2)
        #expect(dialect.decimalSeparator == .comma)
        // Sorted ascending even though the file is newest-first.
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-02", 82.216), point("2024-01-03", 81.842)])
    }

    @Test func headerlessTabSeparatedAndPreamble() throws {
        let tsv = "Quotes for XYZ\nexported 2024\n02/13/2024\t10.5\n02/14/2024\t11\n"
        let dialect = try CSVQuoteParser.sniff(tsv)
        #expect(dialect.delimiter == "\t")
        #expect(dialect.header == nil)
        #expect(dialect.firstDataRow == 2)
        #expect(try CSVQuoteParser.parse(tsv) == [point("2024-02-13", 10.5), point("2024-02-14", 11)])
    }

    @Test func detectsDayFirstSlashDatesAcrossTheColumn() throws {
        let csv = "date|price\n01/02/2024|10\n13/02/2024|11\n"
        #expect(try CSVQuoteParser.sniff(csv).dateOrder == .dayFirst)
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-02-01", 10), point("2024-02-13", 11)])
    }

    @Test func headerlessOHLCUsesFourthNumericColumn() throws {
        let csv = "2024-01-02,1,2,0.5,1.5,1000\n2024-01-03,1.5,2.5,1,2,2000\n"
        #expect(try CSVQuoteParser.sniff(csv).closeColumn == 4)
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-02", 1.5), point("2024-01-03", 2)])
    }

    @Test func quotedFieldsAndThousandsSeparators() throws {
        let csv = "Date,Last\n\"Jan 2, 2024\",\"4,742.83\"\n\"Jan 3, 2024\",\"4,704.81\"\n"
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-02", 4742.83), point("2024-01-03", 4704.81)])
        #expect(CSVQuoteParser.split("a,\"b \"\"q\"\", c\",d\r\n\r\ne,f", delimiter: UInt8(ascii: ",")) == [["a", "b \"q\", c", "d"], ["e", "f"]])
    }

    @Test func explicitOptionsOverrideDetection() throws {
        let csv = "Date;Bid;Ask\n2024-01-02;1,234;1,300\n2024-01-03;1,250;1,310\n"
        #expect(try CSVQuoteParser.parse(csv) == [point("2024-01-02", 1.234), point("2024-01-03", 1.25)])
        #expect(try CSVQuoteParser.parse(csv, options: CSVOptions(closeColumn: "ask")) == [point("2024-01-02", 1.3), point("2024-01-03", 1.31)])
        #expect(try CSVQuoteParser.parse(csv, options: CSVOptions(closeColumn: "3", decimalSeparator: .point)) == [point("2024-01-02", 1300), point("2024-01-03", 1310)])
        #expect(throws: MarketDataError.self) { _ = try CSVQuoteParser.parse(csv, options: CSVOptions(closeColumn: "Close")) }
        #expect(throws: MarketDataError.self) { _ = try CSVQuoteParser.parse(csv, options: CSVOptions(delimiter: "#")) }
        let unix = "ts,px\n1704153600,10\n1704240000,11\n"
        #expect(try CSVQuoteParser.parse(unix, options: CSVOptions(dateFormat: .unixSeconds)) == [point("2024-01-02", 10), point("2024-01-03", 11)])
        #expect(try CSVQuoteParser.parse(unix) == [point("2024-01-02", 10), point("2024-01-03", 11)])
    }

    @Test func decimalSeparatorDetection() {
        let comma = UInt8(ascii: ","), semicolon = UInt8(ascii: ";")
        #expect(CSVQuoteParser.detectDecimalSeparator(["1.234,56"], delimiter: semicolon) == .comma)
        #expect(CSVQuoteParser.detectDecimalSeparator(["1,234.56"], delimiter: comma) == .point)
        #expect(CSVQuoteParser.detectDecimalSeparator(["82,216", "81,842"], delimiter: semicolon) == .comma)
        #expect(CSVQuoteParser.detectDecimalSeparator(["4,742", "4,704"], delimiter: comma) == .point)
        #expect(CSVQuoteParser.detectDecimalSeparator(["1.234.567"], delimiter: semicolon) == .comma)
        #expect(CSVQuoteParser.detectDecimalSeparator(["12", "13"], delimiter: comma) == .point)
        #expect(CSVQuoteParser.detectDecimalSeparator(["0,500"], delimiter: comma) == .comma)
    }

    @Test func rejectsFilesWithoutQuotes() {
        #expect(throws: MarketDataError.self) { _ = try CSVQuoteParser.parse("<html><body>Not found</body></html>") }
        #expect(throws: MarketDataError.self) { _ = try CSVQuoteParser.parse("") }
    }

    @Test func decodesLatin1() throws {
        let data = "Datum;Schlu\u{DF}\n02.01.2024;1,5\n".data(using: .isoLatin1)!
        #expect(try CSVQuoteParser.parse(data) == [point("2024-01-02", 1.5)])
    }
}

@Suite struct URLTemplateTests {
    let context = URLTemplate.Context(ticker: "BRK B", isin: "US0846707026", wkn: "A0YJQ2", currency: "USD", from: day("2024-01-02"), to: day("2024-01-31"))

    @Test func expandsPlaceholders() {
        let template = "https://example.com/{ISIN}/{WKN}?s={TICKER}&c={currency}&from={FROM}&to={TO}"
        #expect(URLTemplate.expand(template, context) == "https://example.com/US0846707026/A0YJQ2?s=BRK%20B&c=USD&from=2024-01-02&to=2024-01-31")
    }

    @Test func formatsDates() {
        #expect(URLTemplate.expand("{FROM:unix}-{TO:unix}", context) == "1704153600-1706745599")
        #expect(URLTemplate.expand("{FROM:unix-ms}", context) == "1704153600000")
        #expect(URLTemplate.expand("{FROM:yyyyMMdd}/{TO:dd.MM.yyyy}", context) == "20240102/31.01.2024")
    }

    @Test func leavesUnknownPlaceholdersAndBrokenBraces() {
        #expect(URLTemplate.expand("a{UNKNOWN}b{ISIN", context) == "a{UNKNOWN}b{ISIN")
        #expect(URLTemplate.expand("{FROM:nonsense}", context) == "{FROM:nonsense}")
        #expect(URLTemplate.expand("plain", context) == "plain")
    }

    @Test func validatesURLs() throws {
        #expect(try URLTemplate.url(" https://example.com/q?s={TICKER} ", context).absoluteString == "https://example.com/q?s=BRK%20B")
        #expect(throws: MarketDataError.self) { _ = try URLTemplate.url("ftp://example.com/x", context) }
        #expect(throws: MarketDataError.self) { _ = try URLTemplate.url("{TICKER}", context) }
        #expect(throws: MarketDataError.self) { _ = try URLTemplate.url("", context) }
    }
}
