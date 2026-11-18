import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

/// A random but valid document exercising every transaction kind, awkward text (XML/CSV metacharacters,
/// padding, line breaks, non-ASCII), quote feeds, events, taxonomies, plans, watchlists and dashboards.
func randomPortfolioFile(_ rng: inout SplitMix64) -> PortfolioFile {
    let words = ["Alpha", "Bé ta", "Γάμμα", "D&D <x>", "E \"q\" 'a'", "F]]>g", "line1\nline2", "tab\there", "😀 Fund", "a/b[1]", "../..", "  padded  ", "x;y,z"]
    func word() -> String { words.randomElement(using: &rng)! }
    func name(_ p: String, _ i: Int) -> String { Bool.random(using: &rng) ? "\(p) \(i) \(word())" : word() + " \(p)\(i)" }
    let currencies = ["EUR", "USD", "CHF"]
    var file = PortfolioFile(name: word())
    file.settings.baseCurrency = currencies.randomElement(using: &rng)!
    file.settings.riskFreeRate = 0.0125
    file.settings.preferences = ["k": word()]
    for i in 0..<Int.random(in: 0...4, using: &rng) {
        var s = Security(name: name("S", i), currency: currencies.randomElement(using: &rng)!, isin: Bool.random(using: &rng) ? "DE000000000\(i)" : "", wkn: Bool.random(using: &rng) ? "W\(i)" : "",
                         ticker: Bool.random(using: &rng) ? "T\(i)" : "", note: Bool.random(using: &rng) ? word() : "", isRetired: Bool.random(using: &rng))
        var day = Day(year: 2020, month: 1, day: 1)
        for _ in 0..<Int.random(in: 0...5, using: &rng) { day = day.advanced(by: Int.random(in: 1...9, using: &rng)); s.prices.set(Price(raw: Int64.random(in: 0...1_000_000_000_000, using: &rng)), on: day) }
        switch Int.random(in: 0..<7, using: &rng) {
        case 0: s.feed = .manual
        case 1: s.feed = QuoteFeed(provider: "yahoo", symbol: "X\(i).DE", options: Bool.random(using: &rng) ? ["adjusted": "true"] : [:])
        case 2: s.feed = QuoteFeed(provider: "coingecko", symbol: "bitcoin")
        case 3: s.feed = QuoteFeed(provider: "json-url", symbol: "https://x/y?a=1&b=2", options: ["datePath": "$.d", "closePath": "$.c", "weird": word()])
        case 4: s.feed = QuoteFeed(provider: "something-else", symbol: word(), options: ["a": "b"])
        case 5: s.feed = QuoteFeed(provider: "yahoo", symbol: "")
        default: break
        }
        if Bool.random(using: &rng) { s.attributes = ["TER": "0.2", word(): word()] }
        if Bool.random(using: &rng) { s.updatedAt = Date(timeIntervalSince1970: Double(Int.random(in: 0...2_000_000_000, using: &rng)) + 0.25) }
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            let kind = SecurityEvent.Kind.allCases.randomElement(using: &rng)!
            s.events.append(SecurityEvent(day: day.advanced(by: Int.random(in: 0...50, using: &rng)), kind: kind, detail: ["2:1", "0.52 EUR", "0,5", word(), ""].randomElement(using: &rng)!))
        }
        file.securities.append(s)
    }
    for i in 0..<Int.random(in: 0...3, using: &rng) { file.accounts.append(Account(name: name("A", i), currency: currencies.randomElement(using: &rng)!, note: Bool.random(using: &rng) ? word() : "", isRetired: Bool.random(using: &rng))) }
    for i in 0..<Int.random(in: 0...3, using: &rng) { file.depots.append(Depot(name: name("D", i), referenceAccountID: Bool.random(using: &rng) ? file.accounts.randomElement(using: &rng)?.id : nil, note: Bool.random(using: &rng) ? word() : "")) }
    if !file.accounts.isEmpty {
        for _ in 0..<Int.random(in: 0...40, using: &rng) {
            let kind = Transaction.Kind.allCases.randomElement(using: &rng)!
            let account = file.accounts.randomElement(using: &rng)!
            var t = Transaction(kind: kind, date: Day(year: 2021, month: 1, day: 1).advanced(by: Int.random(in: 0...30, using: &rng)), amount: Money(minor: Int64.random(in: 0...10_000_000, using: &rng), currency: account.currency))
            if Bool.random(using: &rng) { t.minuteOfDay = Int.random(in: 1...1439, using: &rng) }
            if Bool.random(using: &rng) { t.note = word() }
            if Bool.random(using: &rng) { t.source = ["csv-import", "plan:\(UUID().uuidString)", "manual"].randomElement(using: &rng)! }
            if kind.requiresAccount { t.accountID = account.id }
            if kind.requiresDepot { guard let depot = file.depots.randomElement(using: &rng) else { continue }; t.depotID = depot.id }
            if kind.requiresSecurity || ((kind == .fee || kind == .tax || kind == .feeRefund || kind == .taxRefund) && Bool.random(using: &rng)) {
                guard let s = file.securities.randomElement(using: &rng) else { if kind.requiresSecurity { continue } else { file.transactions.append(t); continue } }
                t.securityID = s.id
                if kind.requiresDepot || kind == .dividend { t.shares = Shares(raw: Int64.random(in: (kind == .dividend ? 0 : 1)...10_000_000_000, using: &rng)) }
                if [.buy, .sell, .deliveryIn, .deliveryOut, .dividend].contains(kind) {
                    t.fees = Int64.random(in: 0...500, using: &rng); t.taxes = Int64.random(in: 0...500, using: &rng)
                    if kind == .buy || kind == .deliveryIn { t.amount.minor += t.fees + t.taxes }
                    if s.currency != t.amount.currency, Bool.random(using: &rng) { t.securityGross = Money(minor: Int64.random(in: 1...10_000_000, using: &rng), currency: s.currency) }
                }
            }
            if kind == .interest { t.taxes = Int64.random(in: 0...50, using: &rng) }
            if kind == .cashTransfer {
                guard let other = file.accounts.first(where: { $0.id != account.id }) else { continue }
                t.counterAccountID = other.id
                if other.currency != account.currency || Bool.random(using: &rng) { t.counterAmount = Money(minor: t.amount.minor + 7, currency: other.currency) }
            }
            if kind == .securityTransfer {
                guard let other = file.depots.first(where: { $0.id != t.depotID }) else { continue }
                t.counterDepotID = other.id
            }
            file.transactions.append(t)
        }
    }
    file.transactions.sort { ($0.date, $0.minuteOfDay ?? -1) < ($1.date, $1.minuteOfDay ?? -1) }
    if !file.securities.isEmpty {
        file.watchlists = [Watchlist(name: word(), securityIDs: [file.securities[0].id]), Watchlist(name: "", securityIDs: [])]
        func cls(_ depth: Int) -> Classification {
            var c = Classification(name: name("C", depth), color: "#A1B2C3", targetWeight: Bool.random(using: &rng) ? Int.random(in: 0...10_000, using: &rng) : nil, note: Bool.random(using: &rng) ? word() : "")
            if depth < 2 { for _ in 0..<Int.random(in: 0...2, using: &rng) { c.children.append(cls(depth + 1)) } }
            if Bool.random(using: &rng) { c.assignments.append(.init(securityID: file.securities.randomElement(using: &rng)!.id, weight: Int.random(in: 1...10_000, using: &rng))) }
            if Bool.random(using: &rng), let a = file.accounts.randomElement(using: &rng) { c.assignments.append(.init(accountID: a.id)) }
            return c
        }
        file.taxonomies = [Taxonomy(name: word(), root: [cls(0), cls(0)]), Taxonomy(name: "Empty")]
        if let d = file.depots.first, let a = file.accounts.first {
            file.plans = [InvestmentPlan(name: name("P", 0), kind: .purchase, securityID: file.securities[0].id, depotID: d.id, accountID: a.id, amount: Money(minor: 5_000, currency: a.currency), fees: 10,
                                         start: Day(year: 2022, month: 1, day: 5), end: Bool.random(using: &rng) ? Day(year: 2030, month: 1, day: 1) : nil, intervalMonths: Int.random(in: 1...12, using: &rng), note: word()),
                          InvestmentPlan(name: name("P", 1), kind: Bool.random(using: &rng) ? .deposit : .withdrawal, accountID: a.id, amount: Money(minor: 77, currency: a.currency), start: Day(year: 2022, month: 2, day: 1))]
        }
    }
    if Bool.random(using: &rng) { file.exchangeRates = [ExchangeRateSeries(base: "EUR", quote: "USD", days: [18_000, 18_001], rates: [1.1, 1.125])] }
    if Bool.random(using: &rng) { file.dashboards = [Dashboard(name: word(), widgets: [.init(kind: "k", title: word(), span: 2, config: ["a": word()])])] }
    return file
}

/// Randomised export → import round trips. The generator is seeded, so failures are reproducible.
@Suite struct RoundTripTests {
    @Test func portfolioPerformanceExportIsLosslessForRandomDocuments() throws {
        var rng = SplitMix64(seed: 99)
        for round in 0..<150 {
            let file = randomPortfolioFile(&rng)
            for style in PortfolioPerformanceExportOptions.ReferenceStyle.allCases {
                let exported = PortfolioPerformanceExporter.export(file, options: .init(referenceStyle: style))
                let back = try PortfolioPerformanceImporter.read(exported.data).file
                // Everything, including names with padding, the order of same-day bookings and all ids.
                #expect(back == file, "round \(round), \(style)")
                if back != file { return }
            }
        }
    }

    @Test func csvExportReimportsTheSameLedger() throws {
        var rng = SplitMix64(seed: 1234)
        var compared = 0
        for round in 0..<150 {
            let file = randomPortfolioFile(&rng)
            // Rows refer to accounts, depots and securities by name, so names must be distinct.
            func distinct(_ names: [String]) -> Bool { Set(names.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }).count == names.count }
            guard distinct(file.accounts.map(\.name)), distinct(file.depots.map(\.name)), distinct(file.securities.map(\.name)) else { continue }
            compared += 1
            for format in [CSVExportFormat.international, .german] {
                let data = CSVExporter.data(CSVExporter.transactions(file, only: file.transactions, language: format.language), format: format)
                var empty = file
                empty.transactions = []
                let document = CSVDocument(data: data)
                #expect(!document.isDecimalSeparatorAmbiguous || file.transactions.isEmpty)
                let back = CSVImporter.propose(document, file: empty).apply(to: empty)
                // Ids and the source tag are assigned by the import; everything else must be identical.
                func comparable(_ transaction: Transaction) -> Transaction {
                    var copy = transaction
                    copy.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                    copy.source = nil
                    return copy
                }
                #expect(back.transactions.map(comparable) == file.transactions.map(comparable), "round \(round), \(format.language)")
                #expect(back.accounts == file.accounts && back.depots == file.depots && back.securities == file.securities)
            }
        }
        #expect(compared > 50)
    }
}
