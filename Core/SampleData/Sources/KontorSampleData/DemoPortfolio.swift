import Foundation
import KontorModel

/// Builds the demo portfolio: a simulated market, then a scripted nine-year investor biography
/// replayed chronologically against a balance-tracking ledger.
enum DemoBuilder {
    // MARK: Cast

    /// Indices into the security list.
    enum S {
        static let global = 0, emerging = 1, smallCap = 2, europeDividend = 3
        static let brennwald = 4, solvane = 5, quillon = 6, harrow = 7, wexcombe = 8
        static let govBond = 9, corpBond = 10, gold = 11, realEstate = 12, crypto = 13
        static let worldIndex = 14, balancedIndex = 15
    }
    /// Indices into the account list.
    enum A { static let settlement = 0, savings = 1, usd = 2 }
    /// Indices into the depot list.
    enum D { static let main = 0, kids = 1 }

    struct Spec {
        var name: String
        var currency: CurrencyCode
        var isin = ""
        var wkn = ""
        var ticker = ""
        var note = "Demo data — fictional security."
        var feed = false
        var attributes: [String: String] = [:]
        var model: AssetModel
        /// Log return over the whole history the path is pinned to (plus a little seed-dependent noise).
        var totalReturn: Double?
    }

    static let demoNote = "Demo data"
    static let flatTax: Int64 = 26_375 // 26.375 % withholding on income and gains
    static let usWithholding: Int64 = 15_000
    static let broker = FeeModel.percent(bp: 25, min: 490, max: 5_990)
    static let usBroker = FeeModel.percent(bp: 10, min: 200, max: 2_500)
    static let cryptoExchange = FeeModel.percent(bp: 100, min: 100, max: 20_000)

    static func specs() -> [Spec] {
        func fund(_ ter: String, _ policy: String, _ domicile: String, _ replication: String = "Physical") -> [String: String] {
            ["TER": ter, "Distribution": policy, "Domicile": domicile, "Replication": replication]
        }
        func stock(_ sector: String, _ country: String) -> [String: String] { ["Sector": sector, "Country": country] }
        func isin(_ country: String, _ n: Int) -> String { ISIN.fictional(country: country, number: n) }
        return [
            Spec(name: "Meridian Global Equity UCITS ETF (Acc)", currency: "EUR", isin: isin("IE", 11), wkn: "DEMO11",
                 ticker: "MGEQ.KX", attributes: fund("0.20", "Accumulating", "Ireland"),
                 model: AssetModel(startPrice: 58.40, betaEquity: 1.0, idioVol: 0.02), totalReturn: 0.82),
            Spec(name: "Meridian Emerging Markets UCITS ETF (Dist)", currency: "EUR", isin: isin("IE", 12), wkn: "DEMO12",
                 ticker: "MEMD.KX", attributes: fund("0.18", "Distributing", "Ireland", "Sampled"),
                 model: AssetModel(startPrice: 24.10, betaEquity: 1.1, idioVol: 0.09), totalReturn: 0.33),
            Spec(name: "Northlight Global Small Cap UCITS ETF (Acc)", currency: "EUR", isin: isin("LU", 13), wkn: "DEMO13",
                 ticker: "NLSC.KX", attributes: fund("0.35", "Accumulating", "Luxembourg", "Sampled"),
                 model: AssetModel(startPrice: 41.75, betaEquity: 1.15, idioVol: 0.06), totalReturn: 0.60),
            Spec(name: "Halvard Europe Dividend UCITS ETF (Dist)", currency: "EUR", isin: isin("IE", 14), wkn: "DEMO14",
                 ticker: "HEDV.KX", attributes: fund("0.29", "Distributing", "Ireland"),
                 model: AssetModel(startPrice: 18.60, betaEquity: 0.9, idioVol: 0.05), totalReturn: 0.28),
            Spec(name: "Brennwald Maschinenbau AG", currency: "EUR", isin: isin("DE", 21), wkn: "DEMO21",
                 ticker: "BWM.KX", feed: true, attributes: stock("Industrials", "Germany"),
                 model: AssetModel(startPrice: 74.20, betaEquity: 1.1, idioVol: 0.20), totalReturn: 0.55),
            Spec(name: "Solvane Energie SE", currency: "EUR", isin: isin("DE", 22), wkn: "DEMO22", ticker: "SVE.KX",
                 note: "Demo data — fictional security. Position closed at a loss; no longer tracked.",
                 attributes: stock("Utilities", "Germany"),
                 model: AssetModel(startPrice: 38.50, betaEquity: 1.2, idioVol: 0.28)),
            Spec(name: "Quillon Systems Inc.", currency: "USD", isin: isin("US", 31), wkn: "DEMO31", ticker: "QLLN.KX",
                 feed: true, attributes: stock("Information Technology", "United States"),
                 model: AssetModel(startPrice: 96.00, betaEquity: 1.3, idioVol: 0.24)),
            Spec(name: "Harrow & Pike Foods Co.", currency: "USD", isin: isin("US", 32), wkn: "DEMO32", ticker: "HPFC.KX",
                 feed: true, attributes: stock("Consumer Staples", "United States"),
                 model: AssetModel(startPrice: 52.30, betaEquity: 0.6, idioVol: 0.14), totalReturn: 0.45),
            Spec(name: "Wexcombe Pharma plc", currency: "GBP", isin: isin("GB", 41), wkn: "DEMO41", ticker: "WXP.KX",
                 feed: true, attributes: stock("Health Care", "United Kingdom"),
                 model: AssetModel(startPrice: 14.85, betaEquity: 0.7, idioVol: 0.20), totalReturn: 0.40),
            Spec(name: "Meridian Euro Government Bond UCITS ETF (Dist)", currency: "EUR", isin: isin("IE", 51), wkn: "DEMO51",
                 ticker: "MEGB.KX", attributes: fund("0.09", "Distributing", "Ireland", "Sampled"),
                 model: AssetModel(startPrice: 131.20, betaEquity: -0.05, betaBond: 1.0, idioVol: 0.01), totalReturn: -0.05),
            Spec(name: "Northlight Global Corporate Bond UCITS ETF EUR Hedged (Acc)", currency: "EUR", isin: isin("LU", 52),
                 wkn: "DEMO52", ticker: "NLCB.KX", attributes: fund("0.20", "Accumulating", "Luxembourg", "Sampled"),
                 model: AssetModel(startPrice: 102.40, betaEquity: 0.15, betaBond: 0.9, idioVol: 0.015), totalReturn: 0.09),
            Spec(name: "Aurelis Physical Gold ETC", currency: "EUR", isin: isin("DE", 61), wkn: "DEMO61", ticker: "AUPG.KX",
                 attributes: ["TER": "0.12", "Distribution": "None", "Domicile": "Germany", "Backing": "Physical gold"],
                 model: AssetModel(startPrice: 33.90, betaEquity: -0.05, betaGold: 1.0, idioVol: 0.02), totalReturn: 0.72),
            Spec(name: "Stonegate Global Real Estate UCITS ETF (Dist)", currency: "EUR", isin: isin("IE", 71), wkn: "DEMO71",
                 ticker: "SGRE.KX", attributes: fund("0.25", "Distributing", "Ireland"),
                 model: AssetModel(startPrice: 22.75, betaEquity: 0.85, betaBond: 0.6, idioVol: 0.08), totalReturn: 0.16),
            Spec(name: "Tessera (TSR)", currency: "EUR", ticker: "TSR-EUR", note: "Demo data — fictional crypto asset, quoted 24/7.",
                 feed: true, attributes: ["Type": "Crypto asset", "Consensus": "Proof of stake"],
                 model: AssetModel(startPrice: 148.00, betaEquity: 1.2, idioVol: 0.60, continuous: true, cryptoCycles: true),
                 totalReturn: 2.9),
            Spec(name: "Atlas World Equity Index (Net Return, EUR)", currency: "EUR", ticker: "ATLW.IDX",
                 note: "Demo data — fictional benchmark index.", attributes: ["Type": "Index"],
                 model: AssetModel(startPrice: 2_450.00, betaEquity: 1.0, idioVol: 0.01), totalReturn: 0.86),
            Spec(name: "Atlas Balanced 60/40 Index (EUR)", currency: "EUR", ticker: "ATLB.IDX",
                 note: "Demo data — fictional benchmark index.", attributes: ["Type": "Index"],
                 model: AssetModel(startPrice: 1_000.00, betaEquity: 0.6, betaBond: 0.4, idioVol: 0.005), totalReturn: 0.48),
        ]
    }

    // MARK: Agenda

    struct State {
        var ledger: Ledger
        var events: [[SecurityEvent]]
        var eventIDs: SampleRandom
    }

    struct AgendaItem {
        let day: Day
        let order: Int
        let run: (inout State, Day) -> Void
    }

    /// Same-day ordering: money arrives before it is moved, sales precede purchases, spending comes last.
    enum Phase: Int { case income = 0, transfer, sell, buy, spend }

    // MARK: Build

    static func build(today: Day, seed: UInt64) -> PortfolioFile {
        let specs = specs()
        let start = today.addingYears(-SampleData.demoHistoryYears).startOfMonth
        let lastMonth = (today.year - start.year) * 12 + today.month - start.month
        let lastOffset = start.distance(to: today)

        /// Day `dom` of month `k` of the history, whether or not the exchange is open.
        func nominalDay(_ k: Int, _ dom: Int) -> Day { start.addingMonths(k).advanced(by: dom - 1) }
        /// The first trading day on or after day `dom` of month `k` of the history, if not in the future.
        func tradingDay(_ k: Int, _ dom: Int) -> Day? {
            let day = TradingCalendar.tradingDay(onOrAfter: nominalDay(k, dom))
            return day <= today ? day : nil
        }
        func offset(_ k: Int, _ dom: Int) -> Int { start.distance(to: tradingDay(k, dom) ?? today) }

        // Entity ids depend on the seed only.
        var entityIDs = SampleRandom(seed: seed, stream: 1)
        let securityIDs = specs.map { _ in entityIDs.uuid() }
        let accountIDs = (0..<3).map { _ in entityIDs.uuid() }
        let depotIDs = (0..<2).map { _ in entityIDs.uuid() }
        let purchasePlanID = entityIDs.uuid(), depositPlanID = entityIDs.uuid()
        let watchlistIDs = (0..<2).map { _ in entityIDs.uuid() }

        // Market. Most paths are pinned to a plausible long-run return; the two story stocks are
        // pinned at their trade dates so the scripted gain and loss materialise for every seed.
        var tuning = SampleRandom(seed: seed, stream: 2)
        var models = specs.map(\.model)
        for i in specs.indices {
            let noise = min(max(0.1 * tuning.gaussian(), -0.2), 0.2)
            if let total = specs[i].totalReturn { models[i].anchors = [(lastOffset, total + noise)] }
        }
        let quillonBuy = (k: 15, dom: 10), quillonDip = (k: 41, dom: 10), quillonSale = (k: 78, dom: 10)
        let solvaneBuy = (k: 20, dom: 10), solvaneExit = (k: 44, dom: 10), solvaneDelisting = (k: 50, dom: 1)
        models[S.quillon].anchors = [
            (offset(quillonBuy.k, quillonBuy.dom), tuning.uniform(0.10, 0.20)),
            (offset(quillonDip.k, quillonDip.dom), tuning.uniform(0.50, 0.60)),
            (offset(quillonSale.k, quillonSale.dom), tuning.uniform(1.17, 1.33)),
            (lastOffset, tuning.uniform(1.40, 1.60)),
        ]
        models[S.solvane].anchors = [
            (offset(solvaneBuy.k, solvaneBuy.dom), tuning.uniform(0.20, 0.30)),
            (offset(solvaneExit.k, solvaneExit.dom), tuning.uniform(-0.36, -0.24)),
            (lastOffset, -0.55),
        ]
        let market = MarketSimulation(start: start, end: today, assets: models, seed: SampleRandom.subSeed(seed, stream: 3))
        let usd = FXPath(start: start, end: today, mean: 1.12, reversion: 0.002, dailyVol: 0.0045,
                         seed: SampleRandom.subSeed(seed, stream: 4))
        let gbp = FXPath(start: start, end: today, mean: 0.86, reversion: 0.003, dailyVol: 0.0035,
                         seed: SampleRandom.subSeed(seed, stream: 5))

        let accountCurrencies: [CurrencyCode] = ["EUR", "EUR", "USD"]
        var state = State(
            ledger: Ledger(
                market: market, base: "EUR", rates: ["USD": usd, "GBP": gbp],
                securities: specs.indices.map { .init(id: securityIDs[$0], currency: specs[$0].currency) },
                accounts: (0..<3).map { .init(id: accountIDs[$0], currency: accountCurrencies[$0]) },
                depots: depotIDs, idSeed: SampleRandom.subSeed(seed, stream: 6), capacity: 720
            ),
            events: [[SecurityEvent]](repeating: [], count: specs.count),
            eventIDs: SampleRandom(seed: seed, stream: 7)
        )

        // MARK: Script

        var amounts = SampleRandom(seed: seed, stream: 8)
        var agenda = [AgendaItem]()
        agenda.reserveCapacity(900)
        func at(_ k: Int, _ dom: Int, _ phase: Phase, _ run: @escaping (inout State, Day) -> Void) {
            guard k <= lastMonth, let day = tradingDay(k, dom) else { return }
            agenda.append(AgendaItem(day: day, order: phase.rawValue * 100_000 + agenda.count, run: run))
        }
        func eur(_ value: Int) -> Int64 { Int64(value) * 100 }

        func buy(_ k: Int, _ dom: Int, _ security: Int, _ budget: Int64, depot: Int = D.main, account: Int = A.settlement,
                 note: String = "") {
            let fee = security == S.crypto ? cryptoExchange : (account == A.usd ? usBroker : broker)
            at(k, dom, .buy) { s, day in
                s.ledger.buy(on: day, security: security, depot: depot, account: account, budget: budget,
                             whole: security != S.crypto, fee: fee, reserve: account == A.usd ? 0 : eur(500), note: note)
            }
        }
        /// Sells `percent` of the position, in whole shares (crypto: four decimals).
        func sell(_ k: Int, _ dom: Int, _ security: Int, percent: Int64, account: Int = A.settlement, note: String = "") {
            let fee = security == S.crypto ? cryptoExchange : (account == A.usd ? usBroker : broker)
            let lot = security == S.crypto ? Scale.shares / 10_000 : Scale.shares
            at(k, dom, .sell) { s, day in
                let position = s.ledger.held[D.main][security]
                let quantity = percent >= 100 ? position : position / 100 * percent / lot * lot
                s.ledger.sell(on: day, security: security, depot: D.main, account: account, shares: quantity, fee: fee,
                              taxRate: flatTax, note: note)
            }
        }
        /// Distributions on fixed months of the year, proportional to the price and paid per depot.
        func dividends(_ security: Int, months: [Int], dom: Int, yield: Double, taxRate: Int64 = flatTax) {
            let perPayment = yield / Double(months.count)
            for k in 0...lastMonth where months.contains(k % 12) {
                at(k, dom, .income) { s, day in
                    let cents = max(1, Int64((s.ledger.market.price(security, on: day).doubleValue * perPayment * 100).rounded()))
                    let perShare = Price(raw: cents * (Scale.price / Scale.amount))
                    var paid = false
                    for depot in [D.main, D.kids] {
                        let account = depot == D.kids ? A.savings : (s.ledger.securities[security].currency == "USD" ? A.usd : A.settlement)
                        if s.ledger.dividend(on: day, security: security, depot: depot, account: account, perShare: perShare,
                                             taxRate: taxRate, note: "Distribution") { paid = true }
                    }
                    if paid {
                        s.events[security].append(SecurityEvent(id: s.eventIDs.uuid(), day: day, kind: .dividend, detail: decimal(cents)))
                    }
                }
            }
        }

        // Opening balances.
        at(0, 1, .income) { s, day in s.ledger.cash(.deposit, on: day, account: A.settlement, minor: eur(25_000), note: "Opening balance") }
        at(0, 1, .income) { s, day in s.ledger.cash(.deposit, on: day, account: A.savings, minor: eur(8_000), note: "Opening balance") }

        // Recurring life.
        // Plans run on a fixed day of the month; an execution that falls on a non-trading day is
        // booked on the next trading day, while the plan itself keeps its nominal schedule.
        let depositPlanDay = 1, purchasePlanDay = 5
        let depositAmount = eur(1_500), planAmount = eur(500), planFee: Int64 = 150
        let savingsRates: [Int64] = [80, 60, 40, 20, 10, 30, 180, 300, 260, 220] // annual, basis points, per year of history
        let withdrawalNotes = ["Vacation", "New bicycle", "Home office furniture", "Car repair", "Wedding gift", "Laptop"]
        let lumpTargets = [S.global, S.corpBond, S.global, S.emerging]
        for k in 0...lastMonth {
            at(k, depositPlanDay, .income) { s, day in
                s.ledger.cash(.deposit, on: day, account: A.settlement, minor: depositAmount, note: "Monthly transfer",
                              source: "plan:\(depositPlanID.uuidString)")
            }
            if k >= 1 {
                at(k, purchasePlanDay, .buy) { s, day in
                    s.ledger.buy(on: day, security: S.global, depot: D.main, account: A.settlement, budget: planAmount,
                                 fee: .flat(planFee), minFill: 1, note: "Savings plan", source: "plan:\(purchasePlanID.uuidString)")
                }
            }
            let rate = savingsRates[min(k / 12, savingsRates.count - 1)]
            at(k, 28, .income) { s, day in
                let gross = mulDiv(s.ledger.balance[A.savings], rate, 120_000)
                let taxes = gross >= 1_500 ? mulDiv(gross, flatTax, 100_000) : 0
                s.ledger.cash(.interest, on: day, account: A.savings, minor: gross - taxes, taxes: taxes, note: "Interest")
            }
            if k % 6 == 0, k > 0 {
                at(k, 2, .transfer) { s, day in
                    guard s.ledger.balance[A.settlement] >= eur(3_000) else { return }
                    s.ledger.transfer(on: day, from: A.settlement, to: A.savings, minor: eur(1_000), note: "Savings top-up")
                }
            }
            if k % 3 == 2 {
                at(k, 28, .spend) { s, day in s.ledger.cash(.fee, on: day, account: A.settlement, minor: 1_170, note: "Depot fee") }
            }
            switch k % 12 {
            case 3: // the kids' birthday investment
                at(k, 14, .buy) { s, day in
                    s.ledger.buy(on: day, security: S.global, depot: D.kids, account: A.savings, budget: eur(600),
                                 fee: .flat(planFee), reserve: eur(1_000), note: "Birthday investment")
                }
            case 5:
                let bonus = Int64(amounts.int(in: 50...90)) * eur(50)
                at(k, 20, .income) { s, day in s.ledger.cash(.deposit, on: day, account: A.settlement, minor: bonus, note: "Bonus") }
            case 7 where k >= 12:
                let refund = Int64(amounts.int(in: 15_000...48_000))
                if k / 12 == 5 {
                    at(k, 16, .spend) { s, day in
                        s.ledger.cash(.tax, on: day, account: A.settlement, minor: 21_340, note: "Additional tax assessment")
                    }
                } else {
                    at(k, 16, .income) { s, day in
                        s.ledger.cash(.taxRefund, on: day, account: A.settlement, minor: refund, note: "Income tax refund")
                    }
                }
            case 9:
                let planned = Int64(amounts.int(in: 12...28)) * eur(100)
                let note = withdrawalNotes[(k / 12) % withdrawalNotes.count]
                at(k, 19, .spend) { s, day in
                    let amount = min(planned, s.ledger.balance[A.settlement] - eur(2_000))
                    guard amount >= planned / 2 else { return }
                    s.ledger.cash(.withdrawal, on: day, account: A.settlement, minor: amount, note: note)
                }
            default: break
            }
            if k % 6 == 4, k >= 16 { // put idle cash to work
                let target = lumpTargets[(k / 6) % lumpTargets.count]
                at(k, 21, .buy) { s, day in
                    let idle = s.ledger.balance[A.settlement] - eur(9_000)
                    guard idle >= eur(5_000) else { return }
                    s.ledger.buy(on: day, security: target, depot: D.main, account: A.settlement,
                                 budget: min(idle, eur(6_000)) / eur(500) * eur(500), whole: true, fee: broker, note: "Lump-sum investment")
                }
            }
        }

        // Distributions.
        dividends(S.emerging, months: [4, 10], dom: 18, yield: 0.024)
        dividends(S.europeDividend, months: [1, 4, 7, 10], dom: 15, yield: 0.038)
        dividends(S.brennwald, months: [5], dom: 20, yield: 0.026)
        dividends(S.quillon, months: [2, 8], dom: 22, yield: 0.007, taxRate: usWithholding)
        dividends(S.harrow, months: [0, 3, 6, 9], dom: 12, yield: 0.030, taxRate: usWithholding)
        dividends(S.wexcombe, months: [3, 9], dom: 25, yield: 0.034)
        dividends(S.govBond, months: [1, 7], dom: 9, yield: 0.012)
        dividends(S.realEstate, months: [2, 8], dom: 26, yield: 0.032)

        // Opportunistic investing — the investor's story.
        buy(0, 8, S.global, eur(6_000), note: "Initial investment")
        buy(0, 9, S.govBond, eur(4_000), note: "Initial investment")
        buy(1, 12, S.europeDividend, eur(3_000))
        buy(2, 15, S.gold, eur(1_500))
        buy(3, 10, S.emerging, eur(2_000))
        buy(6, 14, S.brennwald, eur(2_400))
        buy(8, 10, S.realEstate, eur(2_000))
        at(10, 3, .income) { s, day in
            s.ledger.deliverIn(on: day, security: S.global, depot: D.kids, shares: 25 * Scale.shares, note: "Gift from grandparents")
        }
        buy(12, 11, S.smallCap, eur(2_000))
        at(14, 9, .transfer) { s, day in
            s.ledger.transfer(on: day, from: A.settlement, to: A.usd, minor: eur(6_500), note: "Currency exchange EUR → USD")
        }
        buy(quillonBuy.k, quillonBuy.dom, S.quillon, 300_000, account: A.usd)
        buy(16, 12, S.harrow, 250_000, account: A.usd)
        buy(18, 16, S.corpBond, eur(3_000))
        buy(solvaneBuy.k, solvaneBuy.dom, S.solvane, eur(3_200), note: "Energy transition bet")
        buy(23, 13, S.wexcombe, eur(2_200))
        buy(26, 10, S.crypto, eur(800), note: "Small speculative position")
        buy(28, 11, S.emerging, eur(1_500))
        buy(31, 14, S.gold, eur(1_200))
        sell(33, 10, S.emerging, percent: 30, note: "Trimmed position")
        buy(36, 10, S.brennwald, eur(1_800))
        at(40, 10, .transfer) { s, day in
            s.ledger.transfer(on: day, from: A.settlement, to: A.usd, minor: eur(4_000), note: "Currency exchange EUR → USD")
        }
        buy(quillonDip.k, quillonDip.dom, S.quillon, 300_000, account: A.usd, note: "Bought the dip")
        buy(41, 12, S.global, eur(4_000), note: "Bought the dip")
        buy(42, 11, S.smallCap, eur(2_000))
        sell(solvaneExit.k, solvaneExit.dom, S.solvane, percent: 100, note: "Closed position")
        buy(46, 10, S.crypto, eur(600))
        at(50, 15, .transfer) { s, day in
            let quantity = min(40 * Scale.shares, s.ledger.held[D.main][S.europeDividend] / 2 / Scale.shares * Scale.shares)
            s.ledger.transferSecurity(on: day, security: S.europeDividend, from: D.main, to: D.kids, shares: quantity,
                                      note: "Transfer to kids' depot")
        }
        buy(52, 11, S.realEstate, eur(1_500))
        buy(55, 13, S.corpBond, eur(2_000))
        buy(58, 12, S.wexcombe, eur(1_500))
        sell(58, 16, S.crypto, percent: 40, note: "Took profits")
        buy(63, 10, S.govBond, eur(2_500))
        buy(66, 11, S.harrow, 180_000, account: A.usd)
        at(70, 10, .spend) { s, day in
            let amount = min(eur(5_000), s.ledger.balance[A.savings] - eur(2_000))
            guard amount >= eur(1_000) else { return }
            s.ledger.cash(.withdrawal, on: day, account: A.savings, minor: amount, note: "Kitchen renovation")
        }
        at(59, 10, .income) { s, day in
            s.ledger.cash(.feeRefund, on: day, account: A.settlement, minor: 1_170, note: "Depot fee refund (loyalty promotion)")
        }
        buy(72, 12, S.emerging, eur(2_000))
        buy(75, 10, S.gold, eur(1_500))
        sell(quillonSale.k, quillonSale.dom, S.quillon, percent: 40, account: A.usd, note: "Rebalanced after strong run")
        at(79, 5, .transfer) { s, day in
            let amount = s.ledger.balance[A.usd] / 100 * 60 / 10_000 * 10_000
            s.ledger.transfer(on: day, from: A.usd, to: A.settlement, minor: amount, note: "Currency exchange USD → EUR")
        }
        buy(82, 10, S.smallCap, eur(2_500))
        buy(86, 12, S.brennwald, eur(2_000))
        buy(90, 10, S.crypto, eur(500))
        sell(94, 11, S.realEstate, percent: 50, note: "Reduced real estate exposure")
        buy(97, 10, S.corpBond, eur(3_000))
        buy(101, 13, S.europeDividend, eur(2_500))
        buy(104, 10, S.global, eur(3_000))
        buy(106, 11, S.emerging, eur(1_500))

        // MARK: Replay

        agenda.sort { ($0.day, $0.order) < ($1.day, $1.order) }
        for item in agenda { item.run(&state, item.day) }

        // MARK: Assemble

        let delisting = offset(solvaneDelisting.k, solvaneDelisting.dom)
        let securities = specs.indices.map { i -> Security in
            let spec = specs[i]
            let retired = i == S.solvane
            return Security(
                id: securityIDs[i], name: spec.name, currency: spec.currency, isin: spec.isin, wkn: spec.wkn,
                ticker: spec.ticker, note: spec.note, isRetired: retired,
                feed: spec.feed ? QuoteFeed(provider: "manual", symbol: spec.ticker) : nil,
                prices: market.series(i, through: retired ? delisting : nil), events: state.events[i],
                attributes: spec.attributes
            )
        }
        let accounts = [
            Account(id: accountIDs[A.settlement], name: "Settlement Account", currency: "EUR",
                    note: "Demo data — checking and settlement account of the main depot."),
            Account(id: accountIDs[A.savings], name: "Savings Account", currency: "EUR",
                    note: "Demo data — pays interest monthly."),
            Account(id: accountIDs[A.usd], name: "USD Broker Cash", currency: "USD",
                    note: "Demo data — US dollar cash for US stock trades."),
        ]
        let depots = [
            Depot(id: depotIDs[D.main], name: "Main Depot", referenceAccountID: accountIDs[A.settlement], note: demoNote),
            Depot(id: depotIDs[D.kids], name: "Kids Depot", referenceAccountID: accountIDs[A.savings],
                  note: "Demo data — long-term savings for the children."),
        ]

        let nextID = { entityIDs.uuid() }
        let taxonomies = taxonomies(securityIDs: securityIDs, accountIDs: accountIDs, nextID: nextID)
        let dashboard = Templates.dashboard(
            allocationTaxonomy: taxonomies[0].id, benchmark: securityIDs[S.worldIndex], nextID: nextID)

        let watchlists = [
            Watchlist(id: watchlistIDs[0], name: "Core Holdings",
                      securityIDs: [S.global, S.emerging, S.smallCap, S.govBond, S.gold].map { securityIDs[$0] }),
            Watchlist(id: watchlistIDs[1], name: "Stocks & Benchmarks",
                      securityIDs: [S.brennwald, S.quillon, S.harrow, S.wexcombe, S.crypto, S.worldIndex, S.balancedIndex]
                          .map { securityIDs[$0] }),
        ]
        let plans = [
            InvestmentPlan(
                id: purchasePlanID, name: "Monthly ETF savings plan", kind: .purchase, securityID: securityIDs[S.global],
                depotID: depotIDs[D.main], accountID: accountIDs[A.settlement], amount: Money(minor: planAmount, currency: "EUR"),
                fees: planFee, start: nominalDay(1, purchasePlanDay), intervalMonths: 1, note: demoNote),
            InvestmentPlan(
                id: depositPlanID, name: "Monthly deposit", kind: .deposit, accountID: accountIDs[A.settlement],
                amount: Money(minor: depositAmount, currency: "EUR"), start: nominalDay(0, depositPlanDay), intervalMonths: 1,
                note: demoNote),
        ]

        return PortfolioFile(
            name: "Demo Portfolio",
            settings: Settings(
                baseCurrency: "EUR", costMethod: .fifo,
                benchmarkSecurityIDs: [securityIDs[S.worldIndex], securityIDs[S.balancedIndex]], riskFreeRate: 0.02,
                preferences: ["sampleData": "demo"]),
            securities: securities, accounts: accounts, depots: depots, transactions: state.ledger.transactions,
            taxonomies: taxonomies, watchlists: watchlists, plans: plans,
            exchangeRates: [usd.series(base: "EUR", quote: "USD"), gbp.series(base: "EUR", quote: "GBP")],
            dashboards: [dashboard]
        )
    }

    // MARK: Taxonomies

    static func taxonomies(securityIDs: [UUID], accountIDs: [UUID], nextID: () -> UUID) -> [Taxonomy] {
        typealias Assignment = Classification.Assignment
        func sec(_ index: Int, _ weight: Int = 10_000) -> Assignment { Assignment(securityID: securityIDs[index], weight: weight) }
        func acct(_ index: Int) -> Assignment { Assignment(accountID: accountIDs[index]) }
        let cash = [acct(A.settlement), acct(A.savings), acct(A.usd)]
        let stocks = [S.brennwald, S.solvane, S.quillon, S.harrow, S.wexcombe]

        let assetClasses = Templates.taxonomy(
            name: Templates.assetClassesName, nodes: Templates.assetClasses, targets: true,
            assignments: [
                "Developed Markets": ([S.global, S.smallCap, S.europeDividend] + stocks + [S.worldIndex]).map { sec($0) }
                    + [sec(S.balancedIndex, 6_000)],
                "Emerging Markets": [sec(S.emerging)],
                "Bonds": [sec(S.govBond), sec(S.corpBond), sec(S.balancedIndex, 4_000)],
                "Commodities": [sec(S.gold)],
                "Real Estate": [sec(S.realEstate)],
                "Crypto": [sec(S.crypto)],
                "Cash": cash,
            ], nextID: nextID)

        let regions = Templates.taxonomy(
            name: Templates.regionsName, nodes: Templates.regions, targets: false,
            assignments: [
                "North America": [
                    sec(S.global, 6_800), sec(S.smallCap, 6_000), sec(S.quillon), sec(S.harrow), sec(S.corpBond, 5_500),
                    sec(S.realEstate, 6_500), sec(S.worldIndex, 7_000), sec(S.balancedIndex, 5_500), acct(A.usd),
                ],
                "Europe": [
                    sec(S.global, 1_800), sec(S.smallCap, 2_000), sec(S.europeDividend), sec(S.brennwald), sec(S.solvane),
                    sec(S.wexcombe), sec(S.govBond), sec(S.corpBond, 3_000), sec(S.realEstate, 1_500),
                    sec(S.worldIndex, 1_700), sec(S.balancedIndex, 3_500), acct(A.settlement), acct(A.savings),
                ],
                "Asia-Pacific": [
                    sec(S.global, 1_400), sec(S.smallCap, 2_000), sec(S.corpBond, 800), sec(S.realEstate, 2_000),
                    sec(S.worldIndex, 1_300), sec(S.balancedIndex, 1_000),
                ],
                "Emerging Markets": [sec(S.emerging), sec(S.corpBond, 700)],
                "Global / Other": [sec(S.gold), sec(S.crypto)],
            ], nextID: nextID)

        let types = Templates.taxonomy(
            name: Templates.investmentTypeName, nodes: Templates.investmentTypes, targets: false,
            assignments: [
                "Equity ETFs": [S.global, S.emerging, S.smallCap, S.europeDividend].map { sec($0) },
                "Bond ETFs": [sec(S.govBond), sec(S.corpBond)],
                "Real Estate Funds": [sec(S.realEstate)],
                "Commodity ETCs": [sec(S.gold)],
                "Single Stocks": stocks.map { sec($0) },
                "Crypto Assets": [sec(S.crypto)],
                "Indices": [sec(S.worldIndex), sec(S.balancedIndex)],
                "Cash Accounts": cash,
            ], nextID: nextID)

        return [assetClasses, regions, types]
    }

    /// Formats cents as a plain decimal string ("0.42").
    static func decimal(_ cents: Int64) -> String {
        let fraction = cents % 100
        return "\(cents / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}
