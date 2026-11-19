# KontorInterchange — API

Gets data into and out of Kontor: Portfolio Performance (PP) XML import/export, a CSV import engine
for a wizard UI, CSV export, and file-format detection. Pure Swift + Foundation, no dependencies
besides `KontorModel`; all public types are `Sendable` value types and all entry points are pure
functions (safe to call from any task).

```swift
.package(path: "../Interchange")
.product(name: "KontorInterchange", package: "Interchange")
```

Contents: [format detection](#1-which-importer-applies) · [PP import](#2-portfolio-performance-import) ·
[PP export](#3-portfolio-performance-export) · [CSV import](#4-csv-import-wizard-engine) ·
[CSV export](#5-csv-export) · [mapping reference](#6-portfolio-performance-mapping-reference)

---

## 1. Which importer applies?

```swift
switch FileFormat.detect(data: data, filename: url.lastPathComponent) {
case .kontor:
    document = try PortfolioFile(data: data)
case .portfolioPerformanceXML, .portfolioPerformanceZippedXML:
    let result = try PortfolioPerformanceImporter.read(data, name: url.deletingPathExtension().lastPathComponent)
case .csv:
    startWizard(CSVDocument(data: data))
case let other:                       // .portfolioPerformanceBinary, .portfolioPerformanceEncrypted, .unknown
    show(other.displayName, other.advice)   // advice tells the user to "Save As › XML" in PP
}
```

`FileFormat`: `kontor`, `portfolioPerformanceXML`, `portfolioPerformanceZippedXML`,
`portfolioPerformanceBinary`, `portfolioPerformanceEncrypted`, `csv`, `unknown`
— plus `isReadable`, `displayName`, `advice`. Detection is by content; the file name only breaks ties
(`.kontor`, `.csv`/`.tsv`/`.txt`).

---

## 2. Portfolio Performance import

```swift
do {
    let result = try PortfolioPerformanceImporter.read(data, name: "My Portfolio")
    result.file            // PortfolioFile, ready to save
    result.report.summary  // multi-line text for a "done" sheet
    result.report.counts   // securities, prices, accounts, depots, transactions, transactionsByKind, taxonomies, …
    result.report.warnings // [ImportWarning] — everything skipped or approximated
} catch let error as PortfolioPerformanceImportError {
    show(error.errorDescription!)      // user-presentable, says what to do
}
```

* Accepts the XStream `client` XML of any PP version (tested 25 … 70; older scales for shares/quotes
  are converted) with **both reference styles** (relative XPath and `id`/`reference`), plain or in
  PP's ZIP container (`data.xml`; unzip + inflate are built in).
* Rejects with a specific `PortfolioPerformanceImportError`:
  `.encrypted`, `.binaryFormat` (protobuf, plain `PPPBV1` or zipped), `.unsupportedArchive(reason:)`,
  `.notXML`, `.notPortfolioPerformance(rootElement:)`, `.malformedXML(line:message:)`, `.emptyFile`.
* `PortfolioPerformanceImporter.container(of: data)` → `.xml | .zippedXML | .binary | .encrypted | .unknown`
  (cheap pre-check).
* Deterministic: importing the same file twice yields an identical `PortfolioFile` (objects without a
  UUID in PP get a derived, stable one).
* Robust: malformed or hostile input (truncated files, dangling or absurd references, numbers beyond
  any plausible size) produces an error or a warning (`invalidValue`: capped at 10^16 currency units),
  never a crash — covered by mutation fuzz tests.
* Dates: `2019-01-07`, `2019-01-07T09:30` and the instant notation of pre-2015 files
  (`2013-12-31 23:00:00.0 UTC`, rounded to the nearest local midnight).
* `PortfolioPerformanceImport` (`file`, `report`) is `Hashable`.
* Fast: single pass over the bytes into a flat tree, no per-element allocations
  (≈ 0.25 s for an 80 MB file with one million quotes and 25,000 transactions; release build, Apple Silicon).

### ImportReport / ImportWarning

```swift
struct ImportReport { sourceFormat: String; sourceVersion: Int?; counts: Counts; warnings: [ImportWarning]
                      var isLossless: Bool; var summary: String }
struct ImportWarning { severity: .info | .warning; code: Code; message: String; count: Int; examples: [String]
                       var id: String }   // Identifiable: code + message, unique within a report
```

Repeated issues are aggregated (`count`, up to five `examples`). `.info` = left out on purpose
(dashboards, PP's table layouts, logos, ex-dates, PDF file names); `.warning` = approximated or dropped
(unknown quote feed, weekly plan interval, broken cross entry, dangling reference, …). `code` is a
stable enum for programmatic handling (`unknownQuoteFeed`, `approximatedQuoteFeed`, `skippedPlan`,
`unresolvedReference`, `incompleteCrossEntry`, `missingSecurity`, `skippedDashboards`, …).

---

## 3. Portfolio Performance export

```swift
let export = PortfolioPerformanceExporter.export(file)                         // XPath references (PP default)
let export = PortfolioPerformanceExporter.export(file, options: .init(referenceStyle: .id, timestamp: date))
try export.data.write(to: url)         // UTF-8 XML, extension .xml
export.warnings                         // [ImportWarning] with code .notExportable
```

Writes format version 56 (opens in every PP since 2022): securities with prices/events/attributes,
accounts, securities accounts, all transactions (purchases, sales and transfers as linked cross
entries with units for fees, taxes and foreign-currency gross value), taxonomies with assignments,
watchlists, savings plans, exchange rates (as PP exchange-rate entries).

Round trip: `read(export(file).data).file == file` — exactly, including names with surrounding
spaces, empty names and the order of the ledger (verified on randomly generated documents).
Kontor-only data (settings, dashboards, exact quote-feed configuration, ids of
watchlists/plans/events, plan end dates, target-weight flags, the ledger order as `kontor.order`, the
depot of dividends, fees and taxes as `kontor.depots`) is
stored in client/feed properties that PP preserves but ignores. If the file was edited in PP in
between, the ledger comes back sorted by date and time, with the recorded order breaking ties.
Fix `options.timestamp` for byte-identical output. `PortfolioPerformanceExportOptions` and
`ReferenceStyle` (`CaseIterable`) are `Hashable`.

Not representable, reported in `warnings`: fee/tax breakdown on kinds PP stores without units and
bookings without the account/depot/security PP requires. Normalised without a warning:
`minuteOfDay == 0` comes back as `nil` (PP's midnight means "no time"), an empty `source` as `nil`,
and control characters that XML 1.0 cannot carry are dropped from text.

---

## 4. CSV import (wizard engine)

Four steps, each a pure function, so the UI can re-run any of them as the user changes settings.

```swift
// 1. Sniff + parse. Everything detected can be overridden.
var document = CSVDocument(data: data)
document.dialect                    // encoding, delimiter, headerRecord, firstDataRecord, decimalSeparator, dateOrder
document.isDateOrderAmbiguous       // true → ask the user (e.g. all dates like 03/04/2024)
document.isDecimalSeparatorAmbiguous
document.header                     // [String]  ("Column 1"… if the file has no header)
document.rows                       // [[String]] padded to header.count;  document.lineNumbers for messages

var dialect = document.dialect
dialect.dateOrder = .monthDayYear
document = CSVDocument(data: data, dialect: dialect)          // re-parse with overrides

// 2. Map columns (auto-mapped via English/German synonyms incl. PP's own CSV headers).
var mapping = CSVColumnMapping.automatic(header: document.header, target: .transactions)
mapping.set(.amount, column: 6)                               // user override; mapping.columns: [CSVField?]

// 3. Propose.
var options = CSVImportOptions(target: .transactions, mapping: mapping,
                               defaultAccountID: account.id, defaultDepotID: depot.id)
options.typeAliases = ["Wertpapierabrechnung": .buy]          // teach unknown type values
let proposal = CSVImporter.propose(document, options: options, file: file)

for row in proposal.rows {            // ImportProposal.Row
    row.index; row.lineNumber
    row.status                        // .ok | .warning | .error | .duplicate(of: UUID?)
    row.messages                      // why
    row.transaction                   // the Transaction that would be added (also set for duplicates)
}
proposal.newSecurities; proposal.newAccounts; proposal.newDepots   // would be created
proposal.unrecognizedTypes            // offer these for typeAliases
proposal.missingFields                // required fields without a column (then every row is an error)
proposal.statusCounts                 // .ok / .warning / .error / .duplicate / .recommended in ONE pass — use this in views
proposal.okCount / warningCount / errorCount / duplicateCount   // convenience; each walks all rows

// 4. Apply (pure).
let updated = proposal.apply(to: file)                               // .recommended = ok + warning rows
let updated = proposal.apply(to: file, selection: .rows([0, 2, 5]))  // explicit (duplicates allowed, errors never)
// same as CSVImporter.apply(proposal, to: file, selection: …)
```

### Targets

| `CSVImportTarget` | fields | result of `apply` |
|---|---|---|
| `.transactions` | all `CSVField`s; `date` required | appends transactions + the new securities/accounts/depots that selected rows reference |
| `.quotes` | `date`, `quote` (required) | merges prices into `proposal.quoteSecurityID` (= `options.securityID`, may be set later) |
| `.securities` | `securityName`, `isin`, `wkn`, `ticker`, `currency`, `note` | appends securities that do not exist yet |

`CSVField`: `date, time, type, securityName, isin, wkn, ticker, shares, quote, amount, fees, taxes,
currency, grossAmount, grossCurrency, exchangeRate, account, counterAccount, depot, counterDepot, note`
(`displayName` for UI labels, `CSVField.match(header:)` for a single title).

### Semantics

* **Sniffing** — encoding: UTF-8 (± BOM), UTF-16 LE/BE (± BOM), else Windows-1252. Delimiter: `; , tab |`
  (decided on the first 200 records). Preamble lines before the header are skipped; a header may
  repeat titles (two "Währung" columns — the first one is mapped).
  Decimal separator: voted over the numeric cells of the **whole file** (dates and ticker suffixes
  like `0700.HK` do not vote). `isDecimalSeparatorAmbiguous` is set when only values like `1,234`
  exist (then the delimiter decides: `;` → decimal comma, `,` → decimal point) or when a sizeable
  minority of cells votes the other way.
  Date order (`.yearMonthDay`, `.dayMonthYear`, `.monthDayYear`) decided over the **whole** date column:
  impossible readings are excluded (one `25/03/2024` anywhere settles it), then the reading that keeps
  the column sorted wins, then regional hints (`.` or decimal comma → day first); the last two set
  `isDateOrderAmbiguous`.
* **Values** — `CSVValueParser.decimal("1.234,56 €", decimalSeparator: ",", digits: 2)`,
  `CSVValueParser.date("31.03.2024 09:30", order: .dayMonthYear)`, `CSVValueParser.time("2:05 PM")` are public.
  Numbers: grouping separators, currency symbols/codes, `-5`, `5-`, `(5)`, exponents. Dates: numeric,
  `yyyyMMdd`, ISO date-times, English/German month names, optional time.
* **Types** — `CSVTransactionType.match("Kauf")`; English + German, PP vocabulary and common broker
  terms; `displayName` gives the English label for pickers. An unknown value makes the row an error
  and is listed in `unrecognizedTypes`. Without a type column (or with an empty cell) the type is
  inferred: security + negative shares → sell; security + shares → sell if the value is positive
  *and the file uses signed values at all* (some value is negative), otherwise buy;
  security without shares → dividend (or fee if negative), otherwise deposit/withdrawal.
  `Interest` with a negative value becomes an interest charge. Transfers need an offset
  account/depot; without one they become deposit/withdrawal or delivery (with a warning).
  `Transfer (Inbound)` rows are read from the receiver's side.
* **Amounts** — signs are dropped (direction comes from the type). `Value` is the net amount as in PP
  (buy: incl. fees and taxes; sell/dividend: after them). A missing value is derived from
  shares × quote ± fees/taxes; missing shares from value and quote (warning). Fee/tax rows without a
  value take it from the fees/taxes column; dividends and interest from gross − fees − taxes.
  `Gross Amount` + `Currency Gross Amount` in another currency → `securityGross`
  (cash transfers: `counterAmount`, also in the same currency if the credited amount differs).
  Values beyond 10^15 currency units are row errors.
* **Currency** — currency column → the account's currency → `options.defaultCurrency` → base currency.
  A row whose currency differs from the currency of its (existing) cash account is converted when
  it says what it is worth there — `Gross Amount` with `Currency Gross Amount` = the account's
  currency, or an `Exchange Rate` (row currency → account currency); value, fees and taxes are
  converted, the original gross goes to `securityGross`, the row is a *warning* row. Without either
  it is an **error** row ("The row is in USD, but its cash account is kept in EUR. …") — never a
  booking in the wrong currency.
* **Formula guard** — a text cell starting with an apostrophe followed by `= + - @`, tab or CR (what
  `CSVExporter` writes, see below) is read without the apostrophe.
* **Securities** — matched to existing ones by ISIN → ticker → WKN → name (case-insensitive);
  otherwise one new security per distinct identity is proposed. An ISIN is authoritative: a row
  with an ISIN never matches a security that carries a different ISIN, whatever ticker or name say.
* **Accounts / depots** — by name (case-insensitive) → the caller's default → the only existing one
  → (empty document) a new "Cash Account"/"Depot" → error. Unknown names are created unless
  `options.createMissingAccounts == false`. A trade without account settles against the depot's
  reference account.
* **Duplicates** — same kind, date, security, shares and amount as an existing transaction in the
  same account (securities account for kinds that move shares, cash account otherwise)
  (quotes: same price on that day; securities: already present). Rows of one file are never
  duplicates of each other.
* Imported transactions get `source == options.sourceTag` (default `"csv-import"`).

---

## 5. CSV export

**Formula injection.** Text cells (`CSVValue.text`, column titles) that start with `=`, `+`, `-`, `@`,
a tab or a carriage return are written with a leading apostrophe, so a spreadsheet shows them as text
instead of evaluating them (`CSVExporter.neutralizingFormulas(_:)`). Typed numbers and dates
(`.decimal`, `.integer`, `.number`, `.day`, `.money`, …) are never altered — pass numbers as numbers.

Generic table API — use it for any report (holdings, statement of assets, performance tables):

```swift
var table = CSVTable(header: ["Name", "Shares", "Value", "Currency", "As of"])
table.rows.append(["ACME Corp", .shares(position.shares), .money(position.value), .text("EUR"), .day(today)])
let data = CSVExporter.data(table, format: .german)        // or .international, or a custom CSVExportFormat
let text = CSVExporter.string(table, format: .international)
```

`CSVValue`: `.text`, `.integer`, `.decimal(raw:digits:minFraction:)`, `.number(Double, fractionDigits:)`,
`.day`, `.empty`, helpers `.money(Money)`, `.minor(Int64)`, `.shares(Shares)`, `.price(Price)`; string
literals work directly. `CSVExportFormat(delimiter:decimalSeparator:dateStyle:language:lineEnding:includeByteOrderMark:)`;
presets `.international` (`,` `.` ISO, English) and `.german` (`;` `,` dd.MM.yyyy, German). Fields are
quoted when they contain the delimiter, quotes, line breaks or leading/trailing spaces.

Ready-made tables (headers and type names use PP's vocabulary, so the files re-import here and in PP):

```swift
CSVExporter.transactions(file, language: .german)              // whole ledger, chronological
CSVExporter.transactions(file, only: selection)                // a subset, in the given order
CSVExporter.quotes(of: security, in: from...to)                // Date, Quote
CSVExporter.securities(file)                                   // Security Name, ISIN, WKN, Ticker Symbol, Currency, Note
```

`transactions` → CSV → `CSVImporter` reproduces the ledger (ids and `source` aside; verified on
randomly generated documents in both presets). Pass the same language to the table and the format:
`CSVExporter.data(CSVExporter.transactions(file, language: format.language), format: format)`.

---

## 6. Portfolio Performance mapping reference

| Portfolio Performance | Kontor |
|---|---|
| `Security` (uuid, name, currencyCode, isin, wkn, tickerSymbol, note, isRetired, updatedAt) | `Security` (same; missing currency → base currency) |
| `prices` (+ `latest` if newer than the history) | `Security.prices` (rescaled to 8 decimals) |
| `feed` `YAHOO` / `YAHOO-ADJUSTEDCLOSE` | `QuoteFeed("yahoo", ticker)` (`options["adjusted"] = "true"`) |
| `feed` `COINGECKO` (+ `COINGECKOCOINID`) | `QuoteFeed("coingecko", coinId)` |
| `feed` `GENERIC-JSON` + `feedURL` + properties | `QuoteFeed("json-url", url, options: datePath, closePath, dateFormat, …)` |
| `feed` `GENERIC_HTML_TABLE` + `feedURL` | `QuoteFeed("html-table", url)` |
| `feed` `MANUAL` / none | `.manual` / `nil` |
| `feed` `PP` (PP's own server) | `QuoteFeed("yahoo", ticker, options: ["pp.feed": "PP"])` + warning (manual if no ticker) |
| any other feed | `QuoteFeed(provider: id.lowercased(), symbol: ticker or URL, options: ["pp.feed": id, …])` + warning |
| security `events` (STOCK_SPLIT, NOTE, DIVIDEND_PAYMENT) | `SecurityEvent` (.split "2:1", .note, .dividend "0.52 EUR") |
| security `attributes` + attribute types | `Security.attributes[typeName] = text` (percent/amount/quote converters applied; logos skipped) |
| security with `targetCurrencyCode` | `ExchangeRateSeries(base: currencyCode, quote: target)` |
| `Account`, `Portfolio` (+ `referenceAccount`) | `Account`, `Depot` (+ `referenceAccountID`) |
| `BuySellEntry` (account tx + portfolio tx) | one `.buy` / `.sell` (id = portfolio transaction's uuid) |
| `AccountTransferEntry` | one `.cashTransfer` (`counterAmount` if currencies/amounts differ) |
| `PortfolioTransferEntry` | one `.securityTransfer` |
| `DELIVERY_INBOUND` / `DELIVERY_OUTBOUND` | `.deliveryIn` / `.deliveryOut` |
| `DEPOSIT`, `REMOVAL`, `DIVIDENDS`, `INTEREST`, `INTEREST_CHARGE`, `FEES`, `FEES_REFUND`, `TAXES`, `TAX_REFUND` | `.deposit`, `.withdrawal`, `.dividend`, `.interest`, `.interestCharge`, `.fee`, `.feeRefund`, `.tax`, `.taxRefund` |
| units `FEE`, `TAX`, `GROSS_VALUE` (forex) | `fees`, `taxes`, `securityGross` |
| `date` (LocalDateTime) | `date` + `minuteOfDay` (midnight → nil) |
| `exDate` of a `DIVIDENDS` transaction | `Transaction.exDate` (both directions; on other bookings: info warning `skippedExDate`) |
| transactions listed in an investment plan | `source = "plan:<plan uuid>"`; all others `source = "pp-import"` |
| `Taxonomy` / root `Classification` children | `Taxonomy.root` (sorted by rank) |
| classification `weight` | `targetWeight` — only if the siblings' weights add up to 100 % (PP's default is 100 % each) |
| classification `color`, `description` | `color` (upper-cased), `note` |
| `Assignment` (security or account, weight, rank) | `Classification.Assignment` (basis points, sorted by rank) |
| `Watchlist` | `Watchlist` |
| `InvestmentPlan` (type or implied type, interval months) | `InvestmentPlan` (.purchase / .deposit / .withdrawal); weekly intervals → months + warning; INTEREST plans skipped + warning |
| `baseCurrency` | `Settings.baseCurrency` |
| `settings.bookmarks` | `Settings.preferences["pp.bookmarks"]` (JSON array of `{label, pattern}`) |
| dashboards, configuration sets, client properties | not imported (`.info` warnings) |
