import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

/// Throughput smoke test on a large generated document. Set `KONTOR_BENCH_SCALE` (default 1) to scale
/// it up, and run with `swift test -c release` for meaningful timings (they are printed, not asserted).
@Suite struct PerformanceTests {
    static func largeFile(scale: Int) -> PortfolioFile {
        var generator = SystemRandomNumberGeneratorStub(state: 0x9E37_79B9_7F4A_7C15)
        let account = Account(name: "Giro", currency: "EUR")
        let depot = Depot(name: "Broker", referenceAccountID: account.id)
        var securities: [Security] = []
        let start = Day(year: 2005, month: 1, day: 3)
        for index in 0..<(40 * scale) {
            var security = Security(name: "Security \(index)", currency: "EUR", isin: String(format: "DE%010d", index), ticker: "S\(index)", feed: QuoteFeed(provider: "yahoo", symbol: "S\(index).DE"))
            var price: Int64 = 5_000_000_000
            var series = PriceSeries()
            for offset in 0..<5_000 {
                price = max(1_000_000, price + Int64(generator.next() % 200_000_001) - 100_000_000)
                series.set(Price(raw: price), on: start.advanced(by: offset))
            }
            security.prices = series
            securities.append(security)
        }
        var transactions: [Transaction] = []
        for index in 0..<(5_000 * scale) {
            let security = securities[index % securities.count]
            let date = start.advanced(by: index % 5_000)
            let kind: Transaction.Kind = index % 7 == 0 ? .dividend : index % 5 == 0 ? .sell : .buy
            var transaction = Transaction(kind: kind, date: date, accountID: account.id, depotID: kind == .dividend ? nil : depot.id, securityID: security.id,
                                          shares: Shares(raw: Int64(1 + index % 50) * 100_000_000), amount: Money(minor: Int64(10_000 + index), currency: "EUR"))
            transaction.fees = 990
            transactions.append(transaction)
        }
        return PortfolioFile(name: "Large", securities: securities, accounts: [account], depots: [depot], transactions: transactions)
    }

    struct SystemRandomNumberGeneratorStub {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    @Test func largeDocumentRoundTrip() throws {
        let scale = Int(ProcessInfo.processInfo.environment["KONTOR_BENCH_SCALE"] ?? "") ?? 1
        let file = Self.largeFile(scale: scale)
        func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let result = try body()
            print("[perf] \(label): \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000)) ms")
            return result
        }
        let export = measure("PP export (\(file.securities.count) securities, \(file.securities.count * 5000) prices, \(file.transactions.count) transactions)") {
            PortfolioPerformanceExporter.export(file, options: .init(timestamp: Date(timeIntervalSince1970: 0)))
        }
        print("[perf] XML size: \(export.data.count / 1_048_576) MB")
        let imported = try measure("PP import") { try PortfolioPerformanceImporter.read(export.data) }
        #expect(imported.file.transactions.count == file.transactions.count)
        #expect(imported.report.counts.prices == file.securities.count * 5000)
        #expect(imported.file.securities == file.securities)
        #expect(Set(imported.file.transactions) == Set(file.transactions))

        let csv = measure("CSV export") { CSVExporter.data(CSVExporter.transactions(file), format: .german) }
        let proposal = measure("CSV sniff + parse + propose") { CSVImporter.propose(CSVDocument(data: csv), file: file) }
        #expect(proposal.duplicateCount == file.transactions.count)
        var empty = file
        empty.transactions = []
        let fresh = measure("CSV propose + apply into empty ledger") { CSVImporter.propose(CSVDocument(data: csv), file: empty).apply(to: empty) }
        #expect(fresh.transactions.count == file.transactions.count)
    }
}
