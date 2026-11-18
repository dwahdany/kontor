# KontorMarketData

Downloads quotes and exchange rates for a `PortfolioFile`. Pure Swift (Foundation only, plus
`FoundationNetworking` on Linux), Swift 6 strict-concurrency clean, no third-party dependencies.

```swift
.package(path: "../MarketData")   // product "KontorMarketData"
import KontorMarketData
```

Privacy: requests carry nothing but the instrument identifier — no cookies, no credentials, no
cache on disk (`URLSessionConfiguration.ephemeral`).

## The 90 % use case: update a file

```swift
let updater = QuoteUpdater()                          // built-in providers + ECB, real network

// 1. Download (off the main actor; never throws; only reads `file`)
let result = await updater.update(file) { progress in // @Sendable, serialized, arbitrary thread
    // progress.target: .security(UUID) | .exchangeRates
    // progress.status: .pending | .running | .success(newPoints:) | .failed(message:) | .cancelled
    // progress.completed / progress.total / progress.fraction / progress.name
}

// 2. Apply (pure + synchronous → main actor, inside an undo group)
let summary = apply(result, to: &document.file)       // or result.apply(to: &file)
summary.prices; summary.rates; summary.derivedRates; summary.events; summary.changedSecurities; summary.hasChanges
```

* `update(_:today:only:progress:)` — `only:` restricts to a set of security ids (e.g. "update selected").
* Cancel by cancelling the surrounding `Task`: the call returns promptly with `wasCancelled == true`
  and everything that had finished; unfinished targets are `.cancelled`. `wasCancelled` means "the
  result is partial" — a cancellation that arrives after the last target finished leaves it `false`.
* One failing security never fails the batch: see `result.statuses[target]` / `result.failures`.
* Stream variant: `for await event in updater.updates(for: file) { … }` yields `.progress(UpdateProgress)`
  and finally `.finished(UpdateResult)`; dropping the stream cancels the run.
* `updater.plan(for: file)` → `UpdatePlan` shows what would be requested without any network access
  (`securities[i].request?.range`, `rates`, `hasWork`), e.g. for a confirmation sheet.
* "Reload history" for selected securities (after a split, or when a security only has a few
  hand-entered prices): `UpdateOptions(reloadsFullHistory: true)` + `only: ids`. Everything from
  `historyStart` is requested again; stored prices that differ are corrected, stored days the
  provider does not know are kept.
* For lists: `UpdateProgress` is `Identifiable` by its target (one row per target moving through the
  states); `target.securityID`, `status.isFinal`, `status.failureMessage`.
* All result types (`UpdateResult`, `SecurityUpdate`, `UpdateProgress`, `UpdatePlan`, `ApplySummary`,
  `FeedSuggestion`) have public initializers, so previews and tests can build them by hand.

### What gets requested

| item | range |
|---|---|
| non-retired security with an automatic feed | day after its last price … today. If the last price was stored while that day was still in progress (`updatedAt` < end of that day UTC + 2 h) the day is fetched again so the intraday price gets replaced by the close. No prices yet → `options.historyStart`. Already up to date → no request, status `.success(newPoints: 0)`. |
| retired / no feed / `manual` | skipped (not part of the run) |
| unknown provider id | part of the run, fails with "Unknown quote provider …" |
| exchange rates | only for files with > 1 currency: every currency except EUR, from the day after its last stored `EUR → X` rate (or `options.rateHistoryStart`) |

`UpdateOptions(maxConcurrentDownloads: 8, historyStart: .earliest, rateHistoryStart: .earliest,
updatesExchangeRates: true, collectsEvents: true, refreshesProvisionalDay: true, checksCurrency: true,
reloadsFullHistory: false)`

`HistoryStart`: `.earliest` (securities 1970-01-01, ECB 1999-01-04) · `.day(Day)` ·
`.beforeFirstTransaction(days:)`.

`checksCurrency`: a feed that reports another currency than `Security.currency` fails with
"The feed quotes in USD, but the security is kept in EUR." instead of importing wrong numbers.

### `UpdateResult` (Sendable value)

`securities: [SecurityUpdate]` (`id`, `points` = only new/changed prices, `events`, `fetchedAt`) ·
`exchangeRates: [ExchangeRateSeries]` (new `EUR → X` points) · `statuses: [UpdateTarget: UpdateStatus]` ·
`failures: [UpdateTarget: String]` · `unsupportedCurrencies` (no ECB rate, e.g. "BTC") ·
`newPriceCount`, `newRateCount`, `hasNewData`, `wasCancelled`, `startedAt`, `finishedAt`.

### `apply(_:to:)`

Merges prices (same result as `PriceSeries.merge`: incoming points win), appends dividends/splits
that are not yet in `Security.events` (same day + kind = already known), sets
`Security.updatedAt = fetchedAt` for every downloaded security, merges exchange rates. Idempotent;
never removes data; ignores securities deleted in the meantime.

Cost: appending new closes is O(new points), independent of the stored history (200 securities with
45 years of prices each + one new close: about 1 ms in a release build), so it is fine on the main
actor. Only a back-fill of more than 16 days *between* stored days rebuilds a series.

**Exchange-rate storage convention.** `file.exchangeRates` holds the ECB series `EUR → X` for every
foreign currency. If `settings.baseCurrency` is not EUR, `apply` additionally maintains the derived
cross rates `base → X` (and `base → EUR`), so a direct series from the base currency always exists.
Derived rates are merged day by day into an existing `base → X` series (rates from other sources on
other days survive) and are brought in line on every `apply` of a run that covered exchange rates —
also when nothing new was downloaded, e.g. right after the base currency was changed.
`summary.derivedRates` counts them. KontorEngine's `CurrencyConverter` triangulates through EUR by
itself, so the derived series are a convenience, not a requirement.
`ExchangeRates.rate(from:to:on:in:)` resolves any pair (direct, inverse, or via EUR);
`ExchangeRates.triangulate(...)` and `ExchangeRates.refreshCrossRates(in:)` (returns the number of
derived rates added or changed) are the pure building blocks.

## Providers

```swift
let registry = ProviderRegistry.standard()            // or .standard(http: myClient)
registry.descriptors                                    // [ProviderDescriptor] in display order
try registry.provider(for: feed).history(request)      // QuoteHistory
registry.validate(feed)                                 // [String] problems, no network
registry.isAutomatic(feed)                              // false for nil / manual / unknown
```

| `QuoteFeed.provider` | name | `symbol` | `options` |
|---|---|---|---|
| `yahoo` | Yahoo Finance | Yahoo ticker (`EUNL.DE`, `^GSPC`, `BTC-USD`); empty → `Security.ticker` | — |
| `coingecko` | CoinGecko | coin id (`bitcoin`) | `currency` (default: security currency), `apiKey`, `plan` (`demo`/`pro`) |
| `json-url` | JSON (URL) | URL template | `datePath`\*, `closePath`\* (JSONPath), `dateFormat`, `factor` |
| `csv-url` | CSV (URL) | URL template | `dateColumn`, `closeColumn` (title or 1-based number), `delimiter`, `decimalSeparator`, `dateFormat`, `factor` |
| `manual` | Manual | — | — (never downloads) |

**Generic form rendering:** `ProviderDescriptor` has `id`, `name`, `summary`, `symbol: ProviderOption?`
(nil = no symbol field), `options: [ProviderOption]`, `supportsSearch`, `isAutomatic`. A `ProviderOption`
has `key`, `label`, `help`, `kind` (`.text`, `.urlTemplate`, `.jsonPath`, `.secret`,
`.choice([Choice(value, label)])`), `isRequired`, `placeholder`, `defaultValue`.

### Protocol

```swift
public protocol QuoteProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func history(_ request: QuoteRequest) async throws -> QuoteHistory
    func latest(_ request: QuoteRequest) async throws -> LatestQuote   // default: tail of history
}
QuoteRequest(security: security, range: from...to)      // nil if the security has no feed
QuoteRequest(feed:currency:ticker:isin:wkn:range:)
```

`QuoteHistory`: `points: [PricePoint]` (ascending, one per day, inside the range), `currency`, `name`,
`exchange`, `events: [QuoteEvent]` (`day`, `kind: .dividend/.split`, `detail` = `"0.205"` / `"4:1"`),
`latest: LatestQuote?` (`point`, `time`, `currency`, `name`).

Errors are `MarketDataError` (`LocalizedError`, user-presentable `description`): `.invalidURL`,
`.network`, `.timeout`, `.http(status:host:)`, `.rateLimited(host:)`, `.symbolNotFound`,
`.malformedResponse`, `.invalidConfiguration`, `.unknownProvider`, `.currencyMismatch`, `.unsupported`.

Register your own provider with `registry.register(MyProvider())` and pass the registry to
`QuoteUpdater(registry:rateProvider:options:)`.

### Yahoo Finance (`YahooProvider`)

* Daily close, not adjusted for dividends. Yahoo itself re-bases the whole history after a split, so
  prices stored before a split are on the old basis until the history is reloaded
  (`reloadsFullHistory`). Days are computed in the exchange's time zone (DST-aware).
* Null closes are skipped; float artefacts are removed (`185.63999938964844` → `185.64`). Values that
  cannot be real (non-positive, non-finite, beyond what `Price` can hold, absurd timestamps) are
  skipped as well — all built-in parsers do this instead of trapping.
* A window without any quotes (weekend, holiday, or Yahoo's HTTP 400 "Data doesn't exist for
  startDate …") is an empty history, not an error.
* Pence & co. (`GBp`, `ZAc`, `ILA`) are converted to the major unit — unless the security's own
  currency is the minor unit (`GBX`), then quotes stay as delivered.
* `query1` is tried first, `query2` when it is rate-limited or failing.
* Search: `try await yahoo.search("apple")` / `yahoo.lookup(isin: "IE00B4L5Y983")` → `[SymbolMatch]`
  (`symbol`, `name`, `exchange` code, `exchangeName`, `type`, `provider`, `.feed`).

### CoinGecko (`CoinGeckoProvider`)

Daily close = price at 24:00 UTC; the running day carries the latest price. The keyless API only
serves the past 365 days (older days are silently not requested). `coingecko.search("bitcoin")`
returns coin ids as `SymbolMatch.symbol`.

### Generic URL feeds

URL placeholders (`URLTemplate`): `{TICKER}` `{ISIN}` `{WKN}` `{CURRENCY}` `{FROM}` `{TO}` — dates as
`yyyy-MM-dd`, or formatted: `{FROM:unix}`, `{TO:unix-ms}`, `{FROM:yyyyMMdd}`, `{TO:dd.MM.yyyy}`.

```swift
QuoteFeed(provider: "json-url", symbol: "https://example.com/api/{ISIN}?from={FROM}",
          options: ["datePath": "$.data[*].date", "closePath": "$.data[*].close"])
QuoteFeed(provider: "csv-url", symbol: "https://example.com/{TICKER}.csv")   // everything detected
```

`JSONPath`: `$`, `.name`, `['name']`, `[0]`, `[-1]`, `[*]`, `.*`, `..name`, trailing `~` (member names):
`$.prices[*][0]`, `$['Time Series (Daily)'].*~` + `$['Time Series (Daily)'].*['4. close']`.
Both paths must select the same number of values; dates may be strings or numbers.

`dateFormat`: empty/`auto` (ISO, `dd.MM.yyyy`, `MM/dd/yyyy` vs `dd/MM/yyyy` decided across the
column, month names EN/DE, `yyyyMMdd`, Unix s/ms), `unix`, `unix-ms`, or a pattern of
`yyyy yy MM M MMM dd d` (`dd.MM.yyyy`, `d-MMM-yy`). Only the date counts: a time part in the pattern
(`yyyy-MM-dd'T'HH:mm:ss`) or in the data is ignored. Unix timestamps are read as UTC days.

CSV detection (`CSVQuoteParser.parse(_:options:)`, `.sniff(_:)` → `CSVDialect` for previews):
delimiter (`, ; tab |`), preamble + header row, date column, close column (titles like Close /
Schlusskurs / Last / Price / Kurs / NAV, else the first numeric column, or the 4th of ≥ 4 = OHLC),
decimal separator, UTF-8/BOM/Latin-1.

Stand-alone helpers: `JSONValue(data:)`, `JSONPath(_:).evaluate(_:)`, `DayParser.parse(_:)`,
`DatePattern`, `NumberParser.parse(_:decimal:)`, `URLTemplate.expand(_:_:)`, `ISIN.isPlausible(_:)`,
`Price(checkedQuote:)` (nil instead of a trap for values a `Price` cannot hold — use it in custom
providers).

## Exchange rates (`ECBProvider: ExchangeRateProvider`)

```swift
let batch = try await ECBProvider(http: http).rates(for: [
    RateRequest(currency: "USD", from: lastDay.advanced(by: 1), hasHistory: true)])
batch.series        // [ExchangeRateSeries] base "EUR", only days ≥ from
batch.unsupported   // currencies ECB does not publish
```

Loads the 2 kB daily file first (latest publication day + published currencies), then only if needed
the smallest history file covering the gap: `ECBFeed.smallest(covering:latestPublication:)` →
`.daily` / `.last90Days` / `.full` (8 MB, parsed in a few ms by a byte scanner — no XML library).
Discontinued currencies (`ECBProvider.discontinued`, e.g. HRK, BGN) are loaded once from the full file.

## Suggesting a feed

```swift
let suggester = FeedSuggester(yahoo: YahooProvider(http: http))
let ranked = try await suggester.suggestions(for: security)   // [FeedSuggestion], best first
security.feed = ranked.first?.feed                             // or: suggester.suggestFeed(for:)
```

Searches by ISIN, then ticker, then name; discovers sibling listings of an ISIN hit; ranks by
exchange currency vs. `security.currency`, venue and instrument type; confirms the currency of the
top candidates with a live quote (`isVerified`, `currency`).

## HTTP layer

```swift
public protocol HTTPClient: Sendable { func send(_ request: HTTPRequest) async throws -> HTTPResponse }
```

* `URLSessionHTTPClient()` — real transport (cookie-less, ephemeral).
* `ResilientHTTPClient(base, retry: RetryPolicy(), throttle: .standard, clock: SystemClock())` —
  per-host spacing + retry with exponential back-off (and `Retry-After`) on 429 / 5xx / transport
  errors. `ResilientHTTPClient.standard()` is the production stack and the default everywhere.
  Share **one** instance across providers so throttling is global. Requests cancelled while they
  wait for their slot give it back, so a cancelled update does not delay the next one.
* `StubHTTPClient()` — in-memory, for tests and SwiftUI previews:

```swift
let http = StubHTTPClient()
http.on("finance/chart/AAPL", body: jsonData)                    // substring match on the URL
http.on("eurofxref-daily.xml", responses: [.init(status: 503), .init(status: 200, body: xml)])
http.on("slow.example") { _ in try await Task.sleep(for: .seconds(1)); return .init(status: 200) }
let updater = QuoteUpdater(http: http)
http.requestedURLs
```

## Tests

`swift test` runs offline against recorded real responses in `Tests/KontorMarketDataTests/Fixtures`,
including parser fuzzing (truncated and garbled fixtures) and coarse benchmarks (timings are printed;
run `swift test -c release --filter BenchmarkTests` for representative numbers).
`KONTOR_LIVE_TESTS=1 swift test --filter LiveTests` hits the real endpoints.
