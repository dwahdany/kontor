# KontorSampleData

Deterministic sample portfolios for the first-run experience, SwiftUI previews, screenshots, tests and
benchmarks. Pure Swift + Foundation, depends only on `KontorModel`.

```swift
.package(path: "../SampleData")                                   // from another Core/* package
.product(name: "KontorSampleData", package: "SampleData")
```

## Entry points

```swift
import KontorModel
import KontorSampleData

public enum SampleData {
    static func demoPortfolio(today: Day = .today, seed: UInt64 = 42) -> PortfolioFile
    static func starterPortfolio(name: String, baseCurrency: CurrencyCode) -> PortfolioFile
    static func stressPortfolio(securities: Int, years: Int, transactions: Int, seed: UInt64 = 1) -> PortfolioFile
    static func stressPortfolio(securities: Int, years: Int, transactions: Int, seed: UInt64 = 1, endingOn: Day) -> PortfolioFile

    static let demoHistoryYears = 9
    static let stressEndDay = Day(year: 2025, month: 12, day: 31)
}
```

### `demoPortfolio` — the showcase file

```swift
let file = SampleData.demoPortfolio()                              // ends today
let fixed = SampleData.demoPortfolio(today: Day(year: 2026, month: 6, day: 30), seed: 42)   // previews, screenshots
```

* Same `today` + `seed` ⇒ byte-identical file (all UUIDs included). No clock, no system randomness.
* Entity ids (securities, accounts, depots, plans, watchlists, taxonomies, dashboard) depend on the
  **seed only**, so they stay stable as `today` advances. Prices and the ledger depend on both.
* ~1 ms in release builds (~20 ms debug) — cheap enough to call from a preview. ~1 MB as JSON.
* Works for any `today` from 2015 to 2040. Nothing in the file is dated after `today`.

Content (everything fictional, notes say "Demo data"):

| Part | What is in it |
|---|---|
| Securities (16, fixed order) | 0 global equity ETF (Acc) · 1 emerging markets ETF (Dist) · 2 small cap ETF · 3 Europe dividend ETF (Dist) · 4 EUR stock · 5 EUR stock, **retired**, sold at a loss, prices stop ~6 months after the exit · 6 USD stock (partial sale with a large gain) · 7 USD stock · 8 GBP stock · 9 government bond ETF (Dist) · 10 corporate bond ETF · 11 gold ETC · 12 real estate ETF (Dist) · 13 crypto asset (fractional, quoted 7 days a week) · 14, 15 benchmark indices (never held; `settings.benchmarkSecurityIDs`) |
| Prices | 9 years of daily closes from the first of the month nine years before `today`; trading days only (see "Trading calendar") except crypto, which is quoted every day. Two decimals. Correlated GBM with a correction, a crash + recovery and a slow bear market. |
| Exchange rates | `EUR→USD`, `EUR→GBP`, trading days, same span |
| Accounts | `[0]` Settlement Account (EUR) · `[1]` Savings Account (EUR, monthly interest) · `[2]` USD Broker Cash |
| Depots | `[0]` Main Depot (reference: settlement) · `[1]` Kids Depot (reference: savings) |
| Ledger | ~650 transactions: `buy, sell, deliveryIn, deposit, withdrawal, dividend, interest, fee, feeRefund, tax, taxRefund, cashTransfer, securityTransfer`. Stored in chronological order; every entry has a distinct `minuteOfDay` within its day, so `Transaction.chronological` reproduces the booking order. All bookings fall on trading days. |
| Plans | `[0]` monthly ETF purchase (500 EUR incl. 1.50 fee) · `[1]` monthly deposit (1,500 EUR). Executions carry `source == "plan:<plan.id.uuidString>"`. `plan.start` is the **nominal** day (the 5th / the 1st of a month, even when that is a weekend or holiday); each monthly execution is booked on the first trading day on or after the nominal day, one per month without gaps. |
| Taxonomies | `[0]` "Asset Classes" (with target weights; the portfolio is overweight equity and underweight bonds) · `[1]` "Regions" (weighted multi-assignments) · `[2]` "Investment Type". Every security and account is assigned in each; weights per vehicle sum to 10 000. |
| Other | 2 watchlists, 1 dashboard, security attributes (`TER`, `Distribution`, `Sector`, …), `QuoteFeed(provider: "manual")` on some, `.dividend` security events for every distribution, `settings.preferences["sampleData"] == "demo"` |

Dashboard widget kinds are placeholders for the app to map: `total-value`, `ttwror`, `irr`,
`max-drawdown`, `performance-chart` (config `period`, `benchmark` = security UUID), `allocation`
(config `taxonomy` = taxonomy UUID), `earnings`, `top-movers`.

Guaranteed for every seed and day (covered by tests): no cash balance or share position ever goes
negative; all references resolve; `amount.currency` is the account currency; buys/sells are valued at
that day's close (`securityGross` set when currencies differ); currency exchanges use that day's rate;
dividends are based on the shares held in the depot at the time, net of withholding tax.

### `starterPortfolio` — "New Portfolio"

```swift
let file = SampleData.starterPortfolio(name: "My Portfolio", baseCurrency: "EUR")
```

One "Cash Account", one "Depot" referencing it, "Asset Classes" and "Regions" taxonomies (no
assignments, no targets) and the default dashboard. Uses fresh random UUIDs — two new files never
share ids — so it is the one generator that is *not* deterministic.

### `stressPortfolio` — benchmarks

```swift
let big = SampleData.stressPortfolio(securities: 200, years: 25, transactions: 50_000)   // ~25 ms release
```

`securities` instruments (every fifth in USD, the rest EUR) with `years` of trading-day prices ending at
`SampleData.stressEndDay` (fixed, so benchmarks do not depend on the clock), two EUR accounts, two depots and **exactly** `transactions` consistent
ledger entries (buys, sells, dividends, deposits, withdrawals, fees, interest, transfers). Deterministic
per seed. Transaction ids are sequence-prefixed, so id order equals booking order; `minuteOfDay` is nil.

To benchmark screens whose reports are relative to the current date ("YTD", "1 year"), let the file
end today instead:

```swift
let live = SampleData.stressPortfolio(securities: 200, years: 25, transactions: 50_000, endingOn: .today)
```

ISINs are fictional (`XXTEST…`, valid check digits) for any number of securities.

## Trading calendar

All sample quotes, exchange-rate fixings and transactions follow one fictional exchange calendar:
Monday–Friday, closed on New Year's Day, Good Friday, Easter Monday, 25 and 26 December. Price and
rate series therefore have the same gaps real data has (weekends *and* holidays) — value a day
without a quote with `PriceSeries.price(on:)` / `ExchangeRateSeries.rate(on:)`, which fall back to the
previous close. The demo's crypto asset is the exception: it has a quote for every calendar day.
Buys, sells and deliveries are always dated on a day that has a quote for the security.

## Also public

```swift
public struct SampleRandom: RandomNumberGenerator, Sendable {      // xoshiro256** seeded via SplitMix64
    init(seed: UInt64)
    init(seed: UInt64, stream: UInt64)                             // independent sub-stream
    static func subSeed(_ seed: UInt64, stream: UInt64) -> UInt64
    mutating func next() -> UInt64
    mutating func unit() -> Double                                 // [0, 1)
    mutating func uniform(_ low: Double, _ high: Double) -> Double
    mutating func int(below bound: Int) -> Int
    mutating func int(in range: ClosedRange<Int>) -> Int
    mutating func gaussian() -> Double                             // standard normal
    mutating func uuid() -> UUID                                   // deterministic v4
    mutating func sequencedUUID(_ sequence: UInt64) -> UUID        // sorts by sequence
}
```

Handy for deterministic fixtures in other packages' tests:

```swift
var rng = SampleRandom(seed: 7)
let id = rng.uuid()            // always the same UUID for seed 7
```

## Notes

* Reproducibility is exact on one platform. Prices go through `exp`/`log`/`sin`/`cos`, so a different
  libm (Linux vs. Darwin) may differ in the last digit of individual quotes.
* Securities' `updatedAt` is nil (the generators never read the clock).
* The demo's price history is generated relative to `today` (market phases sit at fixed fractions of
  the nine years), so files for two different days are different histories, not one history extended
  by a day. Generate the demo once and save it; do not regenerate it daily and expect continuity.
* Taxes withheld on demo sales are computed against the average cost of the position, which can
  differ from what the engine derives under FIFO. They are recorded facts of the ledger, not a
  calculation to reproduce.
* Net worth of the demo is roughly 240–400 k EUR depending on the seed (about 310 k for the default
  seed on 2026-11-18): ~50 % global equity ETF, ~10 % bonds, ~10 % cash, the rest spread over 11 holdings.
