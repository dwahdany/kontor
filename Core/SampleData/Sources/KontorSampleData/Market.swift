import Foundation
import KontorModel

/// Stochastic parameters of one simulated instrument.
struct AssetModel: Sendable {
    /// Price on the first simulated day, in the instrument's currency.
    var startPrice: Double
    /// Annual log drift on top of factor and regime returns (irrelevant for anchored paths).
    var annualDrift = 0.0
    /// Loadings on the shared equity / bond / gold factors.
    var betaEquity = 0.0
    var betaBond = 0.0
    var betaGold = 0.0
    /// Annualised idiosyncratic volatility.
    var idioVol: Double
    /// Trades seven days a week (crypto) instead of on exchange trading days only.
    var continuous = false
    /// Follows the crypto boom/bust regimes.
    var cryptoCycles = false
    /// Quote precision.
    var decimals = 2
    /// Points the log path is forced through: day offset → log level relative to the start price.
    /// Between anchors the path keeps its random shape and is only tilted linearly.
    /// Offsets should be trading days of the instrument (on other days the previous close is quoted).
    var anchors: [(offset: Int, level: Double)] = []
}

/// A market phase, positioned as a fraction of the simulated time span. Drifts are total log returns
/// spread evenly over the phase.
struct Regime: Sendable {
    var from: Double
    var to: Double
    var equity = 0.0
    var bond = 0.0
    var gold = 0.0
    var crypto = 0.0
    var volScale = 1.0

    /// A sharp correction, a crash with V-shaped recovery, a slow rates-driven bear market and
    /// several crypto cycles — enough structure for charts and drawdown figures to look real.
    static let standard: [Regime] = [
        Regime(from: 0.140, to: 0.152, equity: -0.11, volScale: 1.6),
        Regime(from: 0.152, to: 0.180, equity: 0.08),
        Regime(from: 0.360, to: 0.369, equity: -0.38, bond: 0.02, gold: -0.05, volScale: 3.2),
        Regime(from: 0.369, to: 0.420, equity: 0.30, volScale: 1.7),
        Regime(from: 0.600, to: 0.680, equity: -0.24, bond: -0.17, volScale: 1.35),
        Regime(from: 0.680, to: 0.740, equity: 0.10, bond: 0.02),
        Regime(from: 0.100, to: 0.200, crypto: 1.6),
        Regime(from: 0.200, to: 0.320, crypto: -1.3),
        Regime(from: 0.440, to: 0.560, crypto: 2.2),
        Regime(from: 0.560, to: 0.700, crypto: -1.7),
        Regime(from: 0.800, to: 0.950, crypto: 1.2),
    ]
}

/// Simulated daily closes for a set of instruments: correlated geometric Brownian motion driven by
/// shared equity, bond and gold factors plus idiosyncratic noise.
///
/// Quotes are kept densely — one value per calendar day, forward-filled over non-trading days — so
/// that price lookups while building a ledger are a single array access. Non-continuous instruments
/// only move (and are only quoted) on `TradingCalendar` trading days.
struct MarketSimulation: Sendable {
    let start: Day
    let dayCount: Int
    /// Whether the calendar day at an offset is a trading day (a weekday that is not an exchange holiday).
    let isTradingDay: [Bool]
    private let continuous: [Bool]
    /// `Price.raw` per asset and calendar-day offset.
    private let quotes: [[Int64]]

    var end: Day { start.advanced(by: dayCount - 1) }
    func offset(of day: Day) -> Int { min(max(start.distance(to: day), 0), dayCount - 1) }

    /// The close of `asset` on `day` (the previous close on non-trading days).
    func price(_ asset: Int, on day: Day) -> Price { Price(raw: quotes[asset][offset(of: day)]) }

    /// The quoted history of `asset` (trading days only unless it trades continuously), optionally cut
    /// off after `lastOffset`.
    func series(_ asset: Int, through lastOffset: Int? = nil) -> PriceSeries {
        let values = quotes[asset]
        let last = min(lastOffset ?? dayCount - 1, dayCount - 1)
        let everyDay = continuous[asset]
        let first = start.rawValue
        guard last >= 0 else { return PriceSeries() }
        var days = [Int32](), raws = [Int64]()
        days.reserveCapacity(last + 1)
        raws.reserveCapacity(last + 1)
        for i in 0...last where everyDay || isTradingDay[i] {
            days.append(first + Int32(i))
            raws.append(values[i])
        }
        return PriceSeries(days: days, values: raws)
    }

    init(start: Day, end: Day, assets: [AssetModel], regimes: [Regime] = Regime.standard, seed: UInt64) {
        let n = max(start.distance(to: end) + 1, 1)
        self.start = start
        dayCount = n

        let open = TradingCalendar.tradingDays(from: start, count: n)
        isTradingDay = open
        continuous = assets.map(\.continuous)

        // Per-day regime drifts and volatility scale.
        var equityDrift = [Double](repeating: 0, count: n)
        var bondDrift = equityDrift, goldDrift = equityDrift, cryptoDrift = equityDrift
        var volScale = [Double](repeating: 1, count: n)
        for regime in regimes {
            let a = max(0, Int(regime.from * Double(n))), b = min(n, Int(regime.to * Double(n)))
            guard b > a else { continue }
            let tradingDays = max(1, Double(b - a) * 5 / 7)
            for i in a..<b {
                equityDrift[i] += regime.equity / tradingDays
                bondDrift[i] += regime.bond / tradingDays
                goldDrift[i] += regime.gold / tradingDays
                cryptoDrift[i] += regime.crypto / Double(b - a)
                volScale[i] *= regime.volScale
            }
        }

        // Shared factor returns (zero on non-trading days).
        let equityVol = 0.14 / 252.0.squareRoot(), bondVol = 0.045 / 252.0.squareRoot()
        let goldVol = 0.13 / 252.0.squareRoot()
        var factors = SampleRandom(seed: seed, stream: 0)
        var equity = [Double](repeating: 0, count: n)
        var bond = equity, gold = equity
        for i in 0..<n where open[i] {
            equity[i] = equityDrift[i] + equityVol * volScale[i] * factors.gaussian()
            bond[i] = bondDrift[i] + bondVol * volScale[i].squareRoot() * factors.gaussian()
            gold[i] = goldDrift[i] + goldVol * factors.gaussian()
        }

        var all = [[Int64]]()
        all.reserveCapacity(assets.count)
        var path = [Double](repeating: 0, count: n)
        for (index, asset) in assets.enumerated() {
            var rng = SampleRandom(seed: seed, stream: UInt64(index) + 1)
            let periods = asset.continuous ? 365.0 : 252.0
            let idio = asset.idioVol / periods.squareRoot()
            let drift = asset.annualDrift / periods
            var level = 0.0
            path[0] = 0
            for i in 1..<max(n, 1) {
                if open[i] {
                    level += drift + asset.betaEquity * equity[i] + asset.betaBond * bond[i]
                        + asset.betaGold * gold[i] + idio * volScale[i].squareRoot() * rng.gaussian()
                    if asset.cryptoCycles { level += cryptoDrift[i] }
                } else if asset.continuous {
                    level += drift + idio * 0.8 * rng.gaussian()
                    if asset.cryptoCycles { level += cryptoDrift[i] }
                }
                path[i] = level
            }

            // Tilt the path through its anchors.
            var previousOffset = 0
            var previousShift = 0.0
            for anchor in asset.anchors.sorted(by: { $0.offset < $1.offset }) {
                let offset = min(anchor.offset, n - 1)
                guard offset > previousOffset else { continue }
                let shift = anchor.level - path[offset]
                let span = Double(offset - previousOffset)
                for i in (previousOffset + 1)...offset {
                    path[i] += previousShift + (shift - previousShift) * Double(i - previousOffset) / span
                }
                previousOffset = offset
                previousShift = shift
            }
            if previousShift != 0, previousOffset + 1 < n {
                for i in (previousOffset + 1)..<n { path[i] += previousShift }
            }

            var scale = 1.0
            for _ in 0..<asset.decimals { scale *= 10 }
            let unit = Scale.price / Int64(scale)
            let scaledStart = asset.startPrice * scale
            var values = [Int64](repeating: 0, count: n)
            var current: Int64 = 0
            for i in 0..<n {
                if i == 0 || open[i] || asset.continuous {
                    current = max(1, Int64((scaledStart * exp(path[i])).rounded())) * unit
                }
                values[i] = current
            }
            all.append(values)
        }
        quotes = all
    }
}

/// A simulated exchange rate (1 unit of the base currency = `rate` units of the quote currency):
/// a mean-reverting walk in log space, densely stored per calendar day.
struct FXPath: Sendable {
    let start: Day
    /// One rate per calendar day, forward-filled over non-trading days.
    let rates: [Double]
    private let isTradingDay: [Bool]

    init(start: Day, end: Day, mean: Double, reversion: Double, dailyVol: Double, seed: UInt64) {
        let n = max(start.distance(to: end) + 1, 1)
        self.start = start
        var rng = SampleRandom(seed: seed)
        let target = log(mean)
        var x = target + 0.03 * rng.gaussian()
        var values = [Double](repeating: 0, count: n)
        let open = TradingCalendar.tradingDays(from: start, count: n)
        var current = (exp(x) * 100_000).rounded() / 100_000
        for i in 0..<n {
            if open[i], i > 0 {
                x += reversion * (target - x) + dailyVol * rng.gaussian()
                current = (exp(x) * 100_000).rounded() / 100_000
            }
            values[i] = current
        }
        rates = values
        isTradingDay = open
    }

    func rate(on day: Day) -> Double {
        rates[min(max(start.distance(to: day), 0), rates.count - 1)]
    }

    /// The fixings (trading days only) as a model series.
    func series(base: CurrencyCode, quote: CurrencyCode) -> ExchangeRateSeries {
        var days = [Int32](), values = [Double]()
        days.reserveCapacity(rates.count * 5 / 7 + 2)
        values.reserveCapacity(rates.count * 5 / 7 + 2)
        for i in rates.indices where isTradingDay[i] {
            days.append(start.rawValue + Int32(i))
            values.append(rates[i])
        }
        return ExchangeRateSeries(base: base, quote: quote, days: days, rates: values)
    }
}
