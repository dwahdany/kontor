import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

/// Compares the importer with `Fixtures/pp_reference.json`, which was computed from the real
/// Portfolio Performance files by an independent Python script (`Fixtures/tools/pp_reference.py`,
/// XStream references resolved by lxml's XPath engine). Nothing in the expected values comes from
/// the Swift code under test.
@Suite struct PPReferenceTests {
    struct Reference: Decodable {
        var version: Int
        var securities: Int
        var exchangeRateSecurities: Int
        var accounts: Int
        var depots: Int
        var transactions: Int
        /// account uuid → balance in minor units, summed PP-style over the account's own bookings
        var balances: [String: Int64]
        /// "depot uuid|security uuid" → shares × 10^8 (non-zero positions only)
        var positions: [String: Int64]
        /// security uuid → [number of prices, sum of all prices × 10^8]
        var prices: [String: [Int64]]
        /// One line per unified ledger entry (every purchase, sale and transfer exactly once), sorted.
        var ledger: [String]
    }

    static let reference: [String: Reference] = {
        let data = try! Fixture.data("pp_reference.json")
        return try! JSONDecoder().decode([String: Reference].self, from: data)
    }()

    static func line(_ t: Transaction, in file: PortfolioFile) -> String {
        func pair(_ money: Money?) -> String { money.map { "\($0.minor) \($0.currency)" } ?? "" }
        let fields: [String] = [
            t.kind.rawValue, t.date.iso, t.minuteOfDay.map(String.init) ?? "", String(t.amount.minor), t.amount.currency, String(t.shares.raw),
            String(t.fees), String(t.taxes), pair(t.securityGross), file.security(t.securityID)?.name ?? "", pair(t.counterAmount),
        ]
        return fields.joined(separator: "|")
    }

    @Test(arguments: ["Issue1498FifoCrossPortfolio.xml", "Issue1897AddFeesToDividendTransactions.xml", "classification_test_case.xml", "client52.xml",
                      "client69.xml", "client_performance_snapshot.xml", "client_with_id_references.xml", "client_with_relative_references.xml",
                      "client_with_security_events.xml", "currency_sample.xml", "kommer.xml", "security_tax_and_fee_account_transactions.xml",
                      "trade_test_case.xml"])
    func importMatchesIndependentReference(name: String) throws {
        let expected = try #require(Self.reference[name])
        let result = try Fixture.pp(name)
        let file = result.file
        #expect(result.report.sourceVersion == expected.version)
        #expect(file.securities.count == expected.securities)
        #expect(file.exchangeRates.count == expected.exchangeRateSecurities)
        #expect(file.accounts.count == expected.accounts)
        #expect(file.depots.count == expected.depots)
        #expect(file.transactions.count == expected.transactions)
        #expect(Set(file.transactions.map(\.id)).count == file.transactions.count)

        // The unified ledger, entry by entry: kind, date, amount, shares, fees, taxes, forex gross, security.
        #expect(file.transactions.map { Self.line($0, in: file) }.sorted() == expected.ledger)

        // Balances and positions computed from Kontor's single ledger equal those of PP's double ledger.
        var balances: [String: Int64] = [:]
        for account in file.accounts {
            balances[account.id.uuidString.lowercased()] = file.transactions.reduce(0) { $0 + $1.cashEffect(on: account.id) }
        }
        #expect(balances == expected.balances)
        var positions: [String: Int64] = [:]
        for transaction in file.transactions {
            guard let security = transaction.securityID else { continue }
            for depot in [transaction.depotID, transaction.counterDepotID].compactMap({ $0 }) {
                positions["\(depot.uuidString.lowercased())|\(security.uuidString.lowercased())", default: 0] += transaction.sharesEffect(on: depot).raw
            }
        }
        #expect(positions.filter { $0.value != 0 } == expected.positions)
        // The demo files never sell what they do not hold.
        #expect(positions.values.allSatisfy { $0 >= 0 })

        for security in file.securities {
            let reference = try #require(expected.prices[security.id.uuidString.lowercased()])
            #expect([Int64(security.prices.count), security.prices.values.reduce(0, +)] == reference)
        }

        // Exporting and re-importing (both reference styles) preserves all of it.
        for style in [PortfolioPerformanceExportOptions.ReferenceStyle.xpath, .id] {
            let exported = PortfolioPerformanceExporter.export(file, options: .init(referenceStyle: style))
            let again = try PortfolioPerformanceImporter.read(exported.data).file
            #expect(again.transactions.map { Self.line($0, in: again) }.sorted() == expected.ledger)
            #expect(again.accounts.map(\.id) == file.accounts.map(\.id))
        }
    }
}

/// `CSVValueParser` against values computed by Python's `decimal` and `datetime`
/// (`Fixtures/tools/csv_value_reference.py`).
@Suite struct CSVValueReferenceTests {
    struct Reference: Decodable {
        struct Number: Decodable { var text: String; var decimalSeparator: String; var digits: Int; var expected: Int64 }
        struct DateCase: Decodable { var text: String; var order: CSVDateOrder; var day: String; var minuteOfDay: Int? }
        var numbers: [Number]
        var dates: [DateCase]
    }

    @Test func numbersAndDatesMatchIndependentReference() throws {
        let reference = try JSONDecoder().decode(Reference.self, from: Fixture.data("csv_value_reference.json"))
        #expect(reference.numbers.count == 500 && reference.dates.count == 300)
        for number in reference.numbers {
            let parsed = CSVValueParser.decimal(number.text, decimalSeparator: Character(number.decimalSeparator), digits: number.digits)
            #expect(parsed == number.expected, "\(number.text) with \(number.digits) digits")
        }
        for date in reference.dates {
            let parsed = CSVValueParser.date(date.text, order: date.order)
            #expect(parsed?.day.iso == date.day && parsed?.minuteOfDay == date.minuteOfDay, "\(date.text) as \(date.order)")
        }
    }

    @Test(arguments: [
        ("12,50 EUR-", "," as Character, -1_250 as Int64?), ("938.21 EUR-", ".", -93_821), ("1.234,56- EUR", ",", -123_456), ("5 each", ".", 500),
        ("1.5E-3", ".", 0), ("1.5E+2", ".", 15_000), ("2e2 EUR", ".", 20_000), ("7E", ".", 700),
    ])
    func lettersAfterDigitsAreNotExponents(text: String, separator: Character, expected: Int64?) {
        #expect(CSVValueParser.decimal(text, decimalSeparator: separator, digits: 2) == expected)
    }
}
