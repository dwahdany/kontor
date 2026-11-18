import Foundation
import KontorModel
import Testing
@testable import KontorSampleData

/// Reference calendar, independent of `TradingCalendar`: Easter Sundays from a published table
/// (cross-checked with python-dateutil), not from the algorithm under test.
enum ReferenceCalendar {
    static let easter: [Int: (month: Int, day: Int)] = [
        1999: (4, 4), 2000: (4, 23), 2001: (4, 15), 2002: (3, 31), 2003: (4, 20), 2004: (4, 11), 2005: (3, 27), 2006: (4, 16), 2007: (4, 8), 2008: (3, 23), 2009: (4, 12), 2010: (4, 4), 2011: (4, 24), 2012: (4, 8), 2013: (3, 31), 2014: (4, 20), 2015: (4, 5), 2016: (3, 27), 2017: (4, 16), 2018: (4, 1), 2019: (4, 21), 2020: (4, 12), 2021: (4, 4), 2022: (4, 17), 2023: (4, 9), 2024: (3, 31), 2025: (4, 20), 2026: (4, 5), 2027: (3, 28), 2028: (4, 16), 2029: (4, 1), 2030: (4, 21), 2031: (4, 13), 2032: (3, 28), 2033: (4, 17), 2034: (4, 9), 2035: (3, 25), 2036: (4, 13), 2037: (4, 5), 2038: (4, 25), 2039: (4, 10), 2040: (4, 1), 2041: (4, 21),
    ]

    static func isHoliday(_ day: Day) -> Bool {
        let c = day.ymd
        if (c.month, c.day) == (1, 1) || (c.month, c.day) == (12, 25) || (c.month, c.day) == (12, 26) { return true }
        guard let e = easter[c.year] else { preconditionFailure("no Easter reference for \(c.year)") }
        let sunday = Day(year: c.year, month: e.month, day: e.day)
        return day == sunday.advanced(by: -2) || day == sunday.advanced(by: 1)
    }

    static func isTradingDay(_ day: Day) -> Bool { !day.isWeekend && !isHoliday(day) }

    static func tradingDay(onOrAfter day: Day) -> Day {
        var day = day
        while !isTradingDay(day) { day = day.advanced(by: 1) }
        return day
    }
}

@Suite struct TradingCalendarTests {
    @Test func easterMatchesPublishedDates() {
        for (year, date) in ReferenceCalendar.easter {
            #expect(TradingCalendar.easterSunday(year: year) == Day(year: year, month: date.month, day: date.day), "\(year)")
        }
    }

    @Test func holidaysAndWeekendsAreClosed() {
        // Hand-picked days: Christmas 2024 (Wed), Boxing Day 2025 (Fri), New Year 2025 (Wed),
        // Good Friday and Easter Monday 2025, and ordinary neighbours.
        for iso in ["2024-12-25", "2025-12-26", "2025-01-01", "2025-04-18", "2025-04-21", "2026-04-03", "2026-04-06", "2026-11-21"] {
            #expect(!TradingCalendar.isTradingDay(Day(iso: iso)!), "\(iso) should be closed")
        }
        for iso in ["2024-12-24", "2024-12-27", "2025-01-02", "2025-04-17", "2025-04-22", "2025-05-01", "2026-11-18"] {
            #expect(TradingCalendar.isTradingDay(Day(iso: iso)!), "\(iso) should be open")
        }
        #expect(TradingCalendar.tradingDay(onOrAfter: Day(iso: "2025-04-18")!) == Day(iso: "2025-04-22")!)
        #expect(TradingCalendar.tradingDay(onOrAfter: Day(iso: "2026-12-25")!) == Day(iso: "2026-12-28")!)
        #expect(TradingCalendar.tradingDay(onOrAfter: Day(iso: "2026-11-18")!) == Day(iso: "2026-11-18")!)
    }

    @Test func bulkFlagsAgreeWithTheReference() {
        let start = Day(year: 2017, month: 11, day: 1), end = Day(year: 2026, month: 11, day: 18)
        let flags = TradingCalendar.tradingDays(from: start, count: start.distance(to: end) + 1)
        #expect(flags.count == start.distance(to: end) + 1)
        #expect(flags.filter { $0 }.count == 2_322) // counted independently with python
        for (offset, open) in flags.enumerated() {
            let day = start.advanced(by: offset)
            #expect(open == ReferenceCalendar.isTradingDay(day), "\(day)")
        }
        #expect(TradingCalendar.tradingDays(from: start, count: 0).isEmpty)
        // A window that starts on a holiday and one that spans a single day.
        #expect(TradingCalendar.tradingDays(from: Day(iso: "2025-01-01")!, count: 2) == [false, true])
        #expect(TradingCalendar.tradingDays(from: Day(iso: "2025-12-26")!, count: 1) == [false])
    }
}

/// Re-derives the economics of the demo ledger from the file alone and compares them with
/// hand-written expectations (fee schedules, tax rates, calendar), across seeds and days.
@Suite struct DemoEconomicsTests {
    static let cases: [(today: Day, seed: UInt64)] = {
        let reference = Day(year: 2026, month: 11, day: 18)
        var cases = [(today: Day, seed: UInt64)]()
        for i in 0..<16 { cases.append((reference.advanced(by: i * 211 - 1_500), UInt64(i * 7_919 + 42))) }
        cases.append((reference, 42))
        cases.append((Day(year: 2026, month: 4, day: 6), 1)) // Easter Monday
        cases.append((Day(year: 2027, month: 1, day: 1), 2)) // New Year's Day
        return cases
    }()

    static func round(_ value: Int64, times numerator: Int64, over denominator: Int64) -> Int64 {
        Int64((Double(value) * Double(numerator) / Double(denominator)).rounded(.toNearestOrAwayFromZero))
    }
    static func clamp(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 { min(max(value, low), high) }

    @Test func nothingHappensWhenTheExchangeIsClosed() {
        for (today, seed) in Self.cases {
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            let violations = Audit.violations(in: file, today: today)
            #expect(violations.isEmpty, "\(today), seed \(seed): \(violations.joined(separator: "\n"))")
            for tx in file.transactions {
                #expect(ReferenceCalendar.isTradingDay(tx.date), "\(tx.kind) on \(tx.date)")
            }
            for (index, security) in file.securities.enumerated() where index != DemoBuilder.S.crypto {
                let closed = security.prices.filter { !ReferenceCalendar.isTradingDay($0.day) }
                #expect(closed.isEmpty, "\(security.name) quoted on \(closed.first.map { "\($0.day)" } ?? "")")
            }
            for series in file.exchangeRates {
                #expect(series.days.allSatisfy { ReferenceCalendar.isTradingDay(Day(rawValue: $0)) }, "\(series.quote)")
            }
            // Crypto keeps trading through weekends and holidays.
            let crypto = file.securities[DemoBuilder.S.crypto].prices
            #expect(crypto.count == today.addingYears(-9).startOfMonth.distance(to: today) + 1)
        }
    }

    @Test func quotesCoverEveryTradingDay() {
        let today = Day(year: 2026, month: 11, day: 18)
        let file = SampleData.demoPortfolio(today: today, seed: 42)
        #expect(file.securities[DemoBuilder.S.global].prices.count == 2_322) // trading days 2017-11-01…2026-11-18 (python)
        #expect(file.exchangeRates[0].days.count == 2_322)
        #expect(file.securities[DemoBuilder.S.global].prices.days == file.exchangeRates[0].days)
        // Two-decimal quotes at believable levels.
        for security in file.securities {
            #expect(security.prices.values.allSatisfy { $0 % (Scale.price / 100) == 0 && $0 >= Scale.price }, "\(security.name)")
        }
    }

    @Test func dividendsMatchTheirAnnouncedPerShareAmount() throws {
        for (today, seed) in Self.cases {
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            let securities = Dictionary(uniqueKeysWithValues: file.securities.map { ($0.id, $0) })
            let rates = Dictionary(uniqueKeysWithValues: file.exchangeRates.map { ($0.quote, $0) })
            var paidPerYear = [UUID: [Int: Double]]()
            for tx in file.transactions where tx.kind == .dividend {
                let security = try #require(securities[tx.securityID!])
                let event = try #require(security.events.first { $0.kind == .dividend && $0.day == tx.date })
                let perShare = try #require(Double(event.detail))
                let gross = Int64((perShare * tx.shares.doubleValue * 100).rounded())
                if security.currency == tx.amount.currency {
                    #expect(tx.grossMinor == gross, "\(tx.date) \(security.name)")
                } else {
                    #expect(tx.securityGross == Money(minor: gross, currency: security.currency))
                    let rate = try #require(rates[security.currency]?.rate(on: tx.date))
                    #expect(abs(Double(tx.grossMinor) - Double(gross) / rate) <= 0.5 + 1e-6, "\(tx.date) \(security.name)")
                }
                // German flat tax, or US withholding tax on the US stocks.
                let taxRate: Int64 = security.currency == "USD" ? 15_000 : 26_375
                #expect(tx.taxes == Self.round(tx.grossMinor, times: taxRate, over: 100_000), "\(tx.date) \(security.name)")
                #expect(tx.fees == 0 && tx.amount.minor == tx.grossMinor - tx.taxes)
            }
            // One announcement per payment day, however many depots were paid.
            for security in file.securities {
                let days = security.events.map(\.day)
                #expect(Set(days).count == days.count && days == days.sorted(), "\(security.name)")
                for event in security.events {
                    let price = try #require(security.prices.price(on: event.day, fallbackToFirst: false)).doubleValue
                    paidPerYear[security.id, default: [:]][event.day.year, default: 0] += try #require(Double(event.detail)) / price
                }
            }
            // Yields per calendar year stay in the range of real funds and stocks.
            for (id, years) in paidPerYear {
                // The first and the current year of a holding are partial; full years must look real.
                for (year, yield) in years where year != today.year && year != years.keys.min() {
                    #expect(yield > 0.004 && yield < 0.05, "\(securities[id]!.name) yields \(yield) in \(year)")
                }
            }
        }
    }

    @Test func tradingFeesFollowTheBrokerSchedules() throws {
        for (today, seed) in Self.cases {
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            let crypto = file.securities[DemoBuilder.S.crypto].id
            let usd = file.accounts[DemoBuilder.A.usd].id
            for tx in file.transactions where tx.kind == .buy || tx.kind == .sell {
                let gross = tx.grossMinor
                let expected: Int64
                if tx.source != nil || tx.note == "Birthday investment" {
                    expected = 150 // savings-plan style executions: flat 1.50
                } else if tx.securityID == crypto {
                    // 1 % (1–200) of the order: the cash amount for buys, the proceeds for sells.
                    expected = Self.clamp(Self.round(tx.kind == .buy ? tx.amount.minor : gross, times: 1, over: 100), 100, 20_000)
                } else if tx.accountID == usd {
                    expected = Self.clamp(Self.round(gross, times: 10, over: 10_000), 200, 2_500) // 0.10 %, 2–25 USD
                } else {
                    expected = Self.clamp(Self.round(gross, times: 25, over: 10_000), 490, 5_990) // 0.25 %, 4.90–59.90 EUR
                }
                #expect(tx.fees == expected, "\(tx.date) \(tx.kind) \(tx.amount): fees \(tx.fees), expected \(expected)")
                #expect(tx.taxes == 0 || tx.kind == .sell)
                // Whole shares everywhere except savings-plan style buys and crypto.
                if expected != 150, tx.securityID != crypto { #expect(tx.shares.raw % Scale.shares == 0) }
            }
        }
    }

    @Test func salesWithholdTaxOnRealizedGainsOnly() throws {
        struct Position: Hashable { var depot: UUID; var security: UUID }
        for (today, seed) in Self.cases {
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            var shares = [Position: Int64](), cost = [Position: Int64]()
            var taxed = 0, untaxed = 0
            for tx in file.transactions {
                guard let security = tx.securityID, let depot = tx.depotID else { continue }
                let key = Position(depot: depot, security: security)
                switch tx.kind {
                case .buy, .deliveryIn:
                    shares[key, default: 0] += tx.shares.raw
                    cost[key, default: 0] += tx.amount.minor
                case .securityTransfer:
                    let target = Position(depot: tx.counterDepotID!, security: security)
                    let moved = Self.round(cost[key]!, times: tx.shares.raw, over: shares[key]!)
                    shares[key]! -= tx.shares.raw
                    cost[key]! -= moved
                    shares[target, default: 0] += tx.shares.raw
                    cost[target, default: 0] += moved
                case .sell:
                    let held = try #require(shares[key])
                    let basis = Self.round(cost[key]!, times: tx.shares.raw, over: held)
                    let gain = tx.grossMinor - tx.fees - basis
                    let expected = gain > 0 ? Self.round(gain, times: 26_375, over: 100_000) : 0
                    #expect(abs(tx.taxes - expected) <= 1, "\(tx.date): taxes \(tx.taxes), expected \(expected) on a gain of \(gain)")
                    if tx.taxes > 0 { taxed += 1 } else { untaxed += 1 }
                    shares[key]! -= tx.shares.raw
                    cost[key]! -= basis
                default: break
                }
            }
            #expect(taxed >= 1 && untaxed >= 1)
        }
    }

    @Test func savingsInterestIsPlausible() {
        for (today, seed) in Self.cases {
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            let savings = file.accounts[DemoBuilder.A.savings].id
            var balance: Int64 = 0
            var payments = 0
            for tx in file.transactions {
                if tx.kind == .interest {
                    #expect(tx.accountID == savings)
                    let gross = tx.amount.minor + tx.taxes
                    let annualRate = Double(gross) * 12 / Double(balance)
                    #expect(annualRate > 0.0005 && annualRate < 0.035, "\(tx.date): \(annualRate)")
                    #expect(tx.taxes == 0 || tx.taxes == Self.round(gross, times: 26_375, over: 100_000))
                    payments += 1
                }
                balance += tx.cashEffect(on: savings)
            }
            #expect(payments >= 106 && payments <= 109, "\(payments) interest payments")
        }
    }

    @Test func sameDayBookingsHaveDistinctIncreasingTimes() {
        for (today, seed) in Self.cases {
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            for (a, b) in zip(file.transactions, file.transactions.dropFirst()) {
                #expect(a.date < b.date || (a.date == b.date && a.minuteOfDay! < b.minuteOfDay!), "\(a.date) \(b.date)")
            }
            #expect(file.transactions.allSatisfy { (8 * 60..<20 * 60).contains($0.minuteOfDay ?? -1) })
        }
    }

    @Test func plansKeepTheirNominalSchedule() throws {
        for (today, seed) in Self.cases {
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            let start = today.addingYears(-9).startOfMonth
            // Nominal days: deposit on the 1st from the first month, purchase on the 5th from the second.
            #expect(file.plans[0].start == start.addingMonths(1).advanced(by: 4))
            #expect(file.plans[1].start == start)
            #expect(file.plans.allSatisfy { $0.intervalMonths == 1 && $0.end == nil })
            for plan in file.plans {
                let executions = file.transactions.filter { $0.source == "plan:\(plan.id.uuidString)" }.map(\.date)
                // One execution per month without gaps, each on the first trading day on or after the nominal day.
                var expected = [Day]()
                var month = 0
                while true {
                    let day = ReferenceCalendar.tradingDay(onOrAfter: plan.start.addingMonths(month))
                    if day > today { break }
                    expected.append(day)
                    month += 1
                }
                #expect(executions == expected, "\(plan.name) for \(today)")
            }
        }
    }

    /// Month-end net worth in EUR, valued with the file's own prices and rates.
    static func netWorthSeries(_ file: PortfolioFile, today: Day) -> (days: [Day], values: [Double], flows: [Double], largestShare: Double, cashShare: Double) {
        struct Position: Hashable { var security: Int }
        let index = Dictionary(uniqueKeysWithValues: file.securities.enumerated().map { ($1.id, $0) })
        let accountIndex = Dictionary(uniqueKeysWithValues: file.accounts.enumerated().map { ($1.id, $0) })
        let rates = Dictionary(uniqueKeysWithValues: file.exchangeRates.map { ($0.quote, $0) })
        func eur(_ minor: Double, _ currency: String, _ day: Day) -> Double { currency == "EUR" ? minor : minor / rates[currency]!.rate(on: day)! }
        var held = [Int64](repeating: 0, count: file.securities.count)
        var cash = [Int64](repeating: 0, count: file.accounts.count)
        var flow = 0.0
        var days = [Day](), values = [Double](), flows = [Double]()
        var largest = 0.0, cashShare = 0.0
        var next = 0
        var day = today.addingYears(-9).endOfMonth
        while true {
            let valuation = min(day, today)
            while next < file.transactions.count, file.transactions[next].date <= valuation {
                let tx = file.transactions[next]
                next += 1
                for (id, i) in accountIndex { cash[i] += tx.cashEffect(on: id) }
                if let id = tx.securityID, let i = index[id] {
                    for depot in file.depots { held[i] += tx.sharesEffect(on: depot.id).raw }
                }
                switch tx.kind {
                case .deposit: flow += Double(tx.amount.minor)
                case .withdrawal: flow -= Double(tx.amount.minor)
                case .deliveryIn: flow += Double(tx.amount.minor)
                default: break
                }
            }
            var total = 0.0, top = 0.0, money = 0.0
            for (i, security) in file.securities.enumerated() where held[i] != 0 {
                let value = eur(Double(security.prices.price(on: valuation)!.value(of: Shares(raw: held[i]))), security.currency, valuation)
                total += value
                top = max(top, value)
            }
            for (i, account) in file.accounts.enumerated() { money += eur(Double(cash[i]), account.currency, valuation) }
            total += money
            days.append(valuation)
            values.append(total / 100)
            flows.append(flow / 100)
            largest = top / total
            cashShare = money / total
            if valuation == today { break }
            day = day.advanced(by: 1).endOfMonth
        }
        return (days, values, flows, largest, cashShare)
    }

    @Test func netWorthLooksLikeAPrivateInvestorsPortfolio() {
        for (today, seed) in Self.cases {
            let file = SampleData.demoPortfolio(today: today, seed: seed)
            let series = Self.netWorthSeries(file, today: today)
            let final = series.values.last!, invested = series.flows.last!
            #expect(final > 200_000 && final < 450_000, "seed \(seed): net worth \(final)")
            #expect(invested > 150_000 && invested < 260_000, "seed \(seed): net contributions \(invested)")
            // A believable long-run result: clearly positive, far from a lottery win.
            #expect(final / invested > 1.15 && final / invested < 2.1, "seed \(seed): \(final) on \(invested)")
            // Not a one-way street: the market crash leaves a visible dent despite monthly contributions …
            var peak = 0.0, drawdown = 0.0, downMonths = 0
            for (i, value) in series.values.enumerated() {
                peak = max(peak, value)
                drawdown = max(drawdown, 1 - value / peak)
                if i > 0, value < series.values[i - 1] { downMonths += 1 }
            }
            #expect(drawdown > 0.04 && drawdown < 0.35, "seed \(seed): max drawdown \(drawdown)")
            #expect(downMonths >= 15, "seed \(seed): only \(downMonths) down months")
            // … and no single holding or idle cash dominates.
            #expect(series.largestShare < 0.62, "seed \(seed): largest position \(series.largestShare)")
            #expect(series.cashShare > 0.05 && series.cashShare < 0.18, "seed \(seed): cash share \(series.cashShare)")
        }
    }
}

@Suite struct StressCalendarAndIdentifierTests {
    @Test func fictionalISINsStayWellFormedForLargeNumbers() {
        // Check digits computed independently (python, ISO 6166 / Luhn).
        #expect(ISIN.fictional(country: "IE", number: 11) == "IEDEMO000116")
        #expect(ISIN.fictional(country: "DE", number: 22) == "DEDEMO000228")
        #expect(ISIN.fictional(country: "XX", tag: "TEST", number: 1) == "XXTEST000016")
        #expect(ISIN.fictional(country: "XX", tag: "TEST", number: 100_000) == "XXTES1000002")
        #expect(ISIN.fictional(country: "XX", tag: "TEST", number: 123_456_789) == "XX1234567899")
        for number in [0, 9, 99_999, 100_000, 999_999, 12_345_678, 999_999_999, 1_000_000_000, Int.max] {
            let isin = ISIN.fictional(country: "XX", tag: "TEST", number: number)
            #expect(isin.utf8.count == 12 && ISIN.isValid(isin), "\(number): \(isin)")
        }
        // Distinct numbers below 10⁹ never collide.
        let sample = (0..<3_000).map { ISIN.fictional(country: "XX", tag: "TEST", number: $0 * 41 + 99_000) }
        #expect(Set(sample).count == sample.count)
    }

    @Test func stressFilesRespectTheTradingCalendar() {
        let file = SampleData.stressPortfolio(securities: 6, years: 3, transactions: 4_000, seed: 2)
        #expect(file.transactions.allSatisfy { ReferenceCalendar.isTradingDay($0.date) })
        #expect(file.securities.allSatisfy { $0.prices.allSatisfy { ReferenceCalendar.isTradingDay($0.day) } })
        #expect(file.exchangeRates[0].days.allSatisfy { ReferenceCalendar.isTradingDay(Day(rawValue: $0)) })
        // 2022-12-31 … 2025-12-31: counted independently with python: 769 trading days.
        #expect(file.securities[0].prices.count == 769)
    }

    @Test func stressFileCanEndOnAnyDay() {
        let end = Day(year: 2026, month: 11, day: 22) // a Sunday
        let file = SampleData.stressPortfolio(securities: 8, years: 2, transactions: 1_500, seed: 4, endingOn: end)
        #expect(file.transactions.count == 1_500)
        #expect(file.securities[0].prices.lastDay == Day(year: 2026, month: 11, day: 20))
        #expect(file.securities[0].prices.firstDay! <= Day(year: 2024, month: 11, day: 25))
        #expect(file.transactions.last!.date == Day(year: 2026, month: 11, day: 20))
        let violations = Audit.violations(in: file, today: end)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
        #expect(file == SampleData.stressPortfolio(securities: 8, years: 2, transactions: 1_500, seed: 4, endingOn: end))
        // The default overload is the same generator pinned to `stressEndDay`.
        #expect(SampleData.stressPortfolio(securities: 3, years: 1, transactions: 200, seed: 4)
            == SampleData.stressPortfolio(securities: 3, years: 1, transactions: 200, seed: 4, endingOn: SampleData.stressEndDay))
    }

    @Test func generatorMatchesXoshiroReference() {
        // xoshiro256** seeded with SplitMix64(42); values from an independent python implementation
        // that reproduces the published xoshiro256** vector for state (1, 2, 3, 4).
        var rng = SampleRandom(seed: 42)
        #expect((0..<4).map { _ in rng.next() } == [
            1_546_998_764_402_558_742, 6_990_951_692_964_543_102, 12_544_586_762_248_559_009, 17_057_574_109_182_124_193,
        ])
    }
}
