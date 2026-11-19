# KontorUI — UI kit reference

Everything a feature screen needs: the store and its analysis layer, scope and period, navigation,
sheets, quote updates, formatting, help topics, design system, input controls and the registration
seam.

```swift
import SwiftUI
import KontorUI      // re-exports KontorModel and KontorEngine (@_exported) — no further imports needed
```

`import KontorModel` / `import KontorEngine` remain valid (every feature target depends on both).
Not re-exported: KontorMarketData (FeatureSecurities imports it), KontorInterchange (FeatureImport),
KontorSampleData (tests and previews).

Contents: [Store](#portfoliostore) · [Analysis layer](#analysis-layer) · [Period and scope](#period-and-scope) ·
[Navigation](#navigation) · [Sheets](#sheets) · [Confirmations, toasts, activity](#confirmations-toasts-activity) ·
[Quote updates](#quote-updates) · [Launch state](#launch-state) · [Feature registry](#feature-registry) ·
[Formatting](#formatting-fmt) · [Help topics](#help-topics) · [Design system](#design-system) ·
[Components](#components) · [Charts](#charts) · [Input controls](#input-controls) · [Tables](#tables) · [Utilities](#utilities)

> **`Transaction` is ambiguous** in files that import both SwiftUI and KontorModel (SwiftUI has its
> own `Transaction`). Every feature target already contains
> `typealias Transaction = KontorModel.Transaction` (in `<Name>Feature.swift`), so the bare name
> works inside your module. `Txn` is a public alias exported by KontorUI.

---

## PortfolioStore

`@MainActor @Observable final class PortfolioStore` — one per open document window, injected into
the environment by the shell.

```swift
@Environment(PortfolioStore.self) private var store
```

### Reading

| Member | Meaning |
|---|---|
| `file: PortfolioFile` | The document (read-only; mutate via `mutate`). |
| `revision: Int` | +1 on every change of `file` (edits, undo/redo, reload). The identity of everything derived from the file. |
| `today: Day` | Valuation date (fixed by `--today` in screenshot mode). **Never use `Day.today` in a screen.** |
| `period: ReportingPeriod` | The window's reporting period (toolbar `PeriodPicker`). Settable. Engine type. |
| `periodInterval: DayInterval` | `period` resolved against `today` and `inception`. Engine type. |
| `interval(for: ReportingPeriod) -> DayInterval` | Any other period resolved the same way. |
| `scopeSelection: ScopeSelection` | The window's scope (toolbar `ScopePicker`). Settable. |
| `scope: Scope` | Engine scope of the selection (`.portfolio` if the selected entity vanished). |
| `scopeTitle: String`, `isWholePortfolioScope: Bool` | "Main Depot" / "Asset Classes ▸ Equity"; whether the window is narrowed. |
| `inception: Day?` | Date of the first transaction. |
| `baseCurrency: CurrencyCode` | `file.settings.baseCurrency`. |
| `ledger: Ledger` | Engine ledger of the current revision, built lazily once (synchronous — cheap lookups only). |
| `security(_:)`, `account(_:)`, `depot(_:)`, `transaction(_:)`, `plan(_:)` | O(1) id → entity lookups (accept `UUID?`). Caches rebuild lazily per revision. |
| `transactions(forSecurity:)`, `transactions(forAccount:)`, `transactions(forDepot:)` | Indexed, in file order. Account/depot variants include transfer counterparts. |
| `launchState: [String: String]`, `launchValue(_:)`, `launchValue(_:as:)` | `--state key=value` of the screenshot mode — see [Launch state](#launch-state). |

### Mutating

```swift
// One undo step named "Add Transaction"; bumps revision; marks the document edited.
store.addTransaction(tx)

// Arbitrary edits: body receives a copy; if the result equals the current file nothing happens
// (no revision bump, no undo step). Returns true if the file changed. ONE undo step per call.
store.mutate("Rebalance") { file in
    file.transactions.append(contentsOf: orders)
    file.taxonomies[0].root[1].targetWeight = 2_500
}

// Changes that should dirty the document but not appear in the undo stack (rare):
store.mutate("Refresh Derived Data", undoable: false) { file in … }
store.updateSecurity(id, actionName: "Edit Security") { $0.note = "…" }      // in-place edit of one security
```

CRUD conveniences (each one undo step):

| Entity | Methods |
|---|---|
| Transactions | `addTransaction(_:)`, `addTransactions(_:actionName:)`, `updateTransaction(_:)`, `deleteTransaction(_:)`, `deleteTransactions(_: Set<UUID>)` |
| Securities | `addSecurity`, `updateSecurity(_:)`, `updateSecurity(_:actionName:undoable:_:)` (in place), `usage(ofSecurities:)`, `deleteSecurities(_:)`, `confirmDeleteSecurities(_:)` |
| Accounts | `addAccount`, `updateAccount`, `usage(ofAccounts:)`, `deleteAccounts(_:)`, `confirmDeleteAccounts(_:)` |
| Depots | `addDepot`, `updateDepot`, `usage(ofDepots:)`, `deleteDepots(_:)`, `confirmDeleteDepots(_:)` |
| Plans | `addPlan`, `updatePlan`, `deletePlans(_:)` |
| Watchlists / taxonomies / dashboards | `upsertWatchlist`, `deleteWatchlist`, `upsertTaxonomy(_:actionName:)`, `deleteTaxonomy`, `upsertDashboard(_:actionName:)`, `deleteDashboard` |
| Document | `updateSettings(_:_:)`, `rename(_:)`, `replaceFile(_:)` (no undo; load/revert/tests) |

**Referential cleanup.** `deleteSecurities` also removes the securities' transactions, plans,
taxonomy assignments, watchlist entries and benchmark settings; `deleteAccounts` removes
transactions on the accounts (incl. transfers), plans and assignments and clears depots'
reference account; `deleteDepots` removes their transactions and plans. Because that loses a lot of
data, ask first — `confirmDelete…` does it for you (shows a dialog only if something refers to the
entities, deletes immediately otherwise). Everything else is simply undoable: no confirmations.

```swift
store.confirmDeleteSecurities(selection)
// or by hand:
let usage = store.usage(ofSecurities: ids)        // EntityUsage(transactions:plans:classifications:watchlists:depots:)
store.confirm(ConfirmationRequest(title: "Delete?", message: usage.summary) { store.deleteSecurities(ids) })
```

---

## Analysis layer

The store owns a shared, memoizing analysis layer (`store.analysisCache: AnalysisCache`) so that
screens never recompute the same things and never compute on the main actor:

* one engine **`Ledger` per revision** — built once, off the main actor (or by `store.ledger`,
  whoever comes first);
* one engine **`Analysis` per (scope, interval)** — screens showing the same scope and period share
  the daily valuation pass and the lot replay;
* **results memoized** per (revision, key); up to 96 values, least recently used dropped first;
* **in-flight de-duplication** — equal requests share one computation;
* **cancellation** — a new revision drops everything and cancels running work; work whose every
  requester went away before it started is skipped;
* **`store.isBusy` is true while any request is pending**, so loading indicators and the screenshot
  mode's settle detection just work.

### `Loadable` + view modifiers (preferred)

```swift
public struct Loadable<Value> {
    public var value: Value?           // the most recent successfully computed value ("last good value")
    public var isLoading: Bool         // a computation for newer inputs is running
    public var revision: Int?          // the document revision `value` was computed from
    public init(_ value: Value? = nil)
    public var isInitialLoad: Bool     // loading && value == nil → show a spinner
    public var isRefreshing: Bool      // loading && value != nil → keep (maybe dim) the content
    public func map<T>(_ transform: (Value) -> T) -> Loadable<T>
}
```

```swift
@State private var model = Loadable<HoldingsModel>()

var body: some View {
    HoldingsContent(model: model.value)                      // nil only before the first result
        .loadingOverlay(model.isInitialLoad)                 // spinner only when there is nothing to show
        .opacity(model.isRefreshing ? 0.6 : 1)               // optional: dim stale content
        .analysisTask($model, id: "holdings.model") { analysis in HoldingsModel(analysis) }
}
```

```swift
extension View {
    /// Recomputes when store.revision, the scope, the interval or `variant` change.
    /// scope nil → store.scope (follows ScopePicker); interval nil → store.periodInterval (follows PeriodPicker).
    func analysisTask<Value: Sendable>(
        _ target: Binding<Loadable<Value>>, id: String, scope: Scope? = nil, interval: DayInterval? = nil,
        _ work: @escaping @Sendable (Analysis) throws -> Value) -> some View
    func analysisTask<Value: Sendable, Variant: Hashable & Sendable>(
        _ target: Binding<Loadable<Value>>, id: String, scope: Scope? = nil, interval: DayInterval? = nil,
        variant: Variant, _ work: @escaping @Sendable (Analysis) throws -> Value) -> some View

    /// For models that depend on the document only (lists of securities, accounts, transactions).
    func ledgerTask<Value: Sendable>(
        _ target: Binding<Loadable<Value>>, id: String, _ work: @escaping @Sendable (Ledger) throws -> Value) -> some View
    func ledgerTask<Value: Sendable, Variant: Hashable & Sendable>(
        _ target: Binding<Loadable<Value>>, id: String, variant: Variant,
        _ work: @escaping @Sendable (Ledger) throws -> Value) -> some View
}
```

Examples:

```swift
.analysisTask($model, id: "allocation.model", variant: taxonomy.id) { analysis in … }      // extra input
.analysisTask($ytd, id: "dashboard.ytd", scope: .portfolio, interval: store.interval(for: .ytd)) { $0.ttwror }
.ledgerTask($rows, id: "securities.rows") { ledger in
    ledger.securities.map { SecurityRow(id: $0.id, name: $0.name, count: ledger.transactions(forSecurity: $0.id).count) }
}
```

### Async accessors (commands, sheets, exports, tests)

```swift
// Derive from the shared Analysis of (scope, interval) — memoized by (revision, id, scope, interval, variant)
let summary = try await store.analyze("performance.summary") { analysis in
    Summary(ttwror: analysis.ttwror, irr: analysis.irr, value: analysis.snapshot.totalValue)
}
let ytd = try await store.analyze("dashboard.ytd", scope: .portfolio, interval: store.interval(for: .ytd)) { $0.ttwror }
let allocation = try await store.analyze("allocation.model", variant: taxonomy.id) { analysis in … }

// Derive from the Ledger — memoized by (revision, key); key: any Hashable & Sendable
let rows = try await store.compute("securities.rows") { ledger in makeRows(ledger) }

let analysis = await store.analysis()                    // the shared facade itself (scope:/interval:/period: optional)
let ledger   = await store.ledgerOffMain()               // the revision's ledger, built off the main actor
let issues   = try await store.consistencyIssues()       // engine consistency check, most severe first
store.ledger                                             // synchronous; fine for lookups, not for heavy work in `body`
```

```swift
func compute<Value: Sendable>(_ key: some Hashable & Sendable,
                              _ work: @escaping @Sendable (Ledger) throws -> Value) async throws -> Value
func analyze<Value: Sendable>(_ id: String, scope: Scope? = nil, interval: DayInterval? = nil,
                              _ work: @escaping @Sendable (Analysis) throws -> Value) async throws -> Value
func analyze<Value: Sendable, Variant: Hashable & Sendable>(
    _ id: String, scope: Scope? = nil, interval: DayInterval? = nil, variant: Variant,
    _ work: @escaping @Sendable (Analysis) throws -> Value) async throws -> Value
func analysis(scope: Scope? = nil, interval: DayInterval? = nil) async -> Analysis
func analysis(scope: Scope? = nil, period: ReportingPeriod) async -> Analysis
```

### Rules

* The work closure is **pure and `@Sendable`**, runs on a background thread, and must not touch the
  store. Capture value snapshots (`let taxonomy = …`) and list them in `variant:` (or the key) —
  **everything the result depends on besides the document, scope and interval belongs in the key.**
* `Analysis` properties **compute lazily on first access** (see `Core/Engine/API.md`, "Analysis
  facade", for costs). Read them inside the closure and return plain `Sendable` structs; never hand
  an `Analysis` to a view and read it in `body`.
* Namespace ids by feature: `"holdings.rows"`, `"performance.chart"`. Equal id + equal inputs + equal
  result type = same cache entry.
* Both accessors throw `CancellationError` when the calling task is cancelled or the document changed
  while computing — the task for the new inputs takes over, so `try?` is right. Other errors thrown
  by your closure propagate (and are not cached).
* `today` is not part of the key: pass `store.today` through `variant:` if your result depends on it
  beyond the interval (the interval already ends on `today` for relative periods).
* `store.analysisCache.statistics` (`hits`, `misses`, `joins`, `computed`, `cancelled`,
  `invalidations`, `ledgersBuilt`) is there for tests and `--timing`.

Anything asynchronous that does **not** go through the analysis layer must be wrapped in
`await store.whileBusy { … }` (or `beginBusy()`/`endBusy()`), otherwise screenshots are taken too early.

---

## Period and scope

`ReportingPeriod` and `DayInterval` are the **engine's** types (`Core/Engine/API.md`, "Reporting periods").

```swift
enum ReportingPeriod: Hashable, Sendable, Codable {
    case ytd, monthToDate, quarterToDate, lastDays(Int), lastMonths(Int), lastYears(Int), year(Int), allTime
    case custom(from: Day, to: Day)
    static let presets: [ReportingPeriod]       // YTD 1M 3M 6M 1Y 3Y 5Y All
    var title: String                           // "Year to date", "Last 3 months", "2023"
    var shortTitle: String                      // "YTD", "3M", "1Y", "Max"
    func interval(today: Day, firstTransactionDay: Day?) -> DayInterval
    // KontorUI:
    init?(code: String); var code: String       // "1M 3M 6M YTD MTD QTD 1Y 3Y 5Y 10Y ALL", "30D", "2024", "2024-01-01..2024-06-30"
}

struct DayInterval: Hashable, Sendable, Codable {
    var start: Day      // BASELINE day: the value at the end of `start` opens the period (Dec 31 for YTD)
    var end: Day        // last day included
    var firstDay: Day   // start + 1 — the first day whose transactions belong to the period
    var dayCount: Int; var years: Double; func contains(_ day: Day) -> Bool   // start < day <= end
}
```

```swift
store.period = .lastYears(3)
store.periodInterval                 // DayInterval for the window's period
store.interval(for: .ytd)            // any other period
Fmt.interval(store.periodInterval)   // "Jan 1, 2024 – Jun 30, 2024" (firstDay … end)
PeriodPicker()                       // edits store.period;  PeriodPicker(selection: $local) for a screen-local period
```

**Scope** — which part of the portfolio a window looks at. Stored per window, restored with the window.

```swift
enum ScopeSelection: Hashable, Codable, Sendable {
    case portfolio
    case depot(UUID)                                   // the securities held in one depot
    case account(UUID)                                 // one cash account
    case classification(taxonomy: UUID, id: UUID)      // a classification incl. sub-classifications, weighted
    func resolve(in file: PortfolioFile) -> Scope?     // nil if the entity no longer exists
    func title(in file: PortfolioFile) -> String       // "Whole Portfolio", "Main Depot", "Asset Classes ▸ Equity"
    var symbol: String
    init?(string: String); var stringValue: String     // portfolio | depot:<uuid> | account:<uuid> | classification:<t>/<c>
}

store.scopeSelection = .depot(depotID)
store.scope                    // engine Scope — what analysisTask/analyze use by default
store.scopeTitle               // for headers: "Holdings — Main Depot"
store.isWholePortfolioScope

ScopePicker()                                              // toolbar menu bound to store.scopeSelection
ScopePicker(accounts: false, classifications: true)        // leave out single cash accounts (securities-only screens)
ScopePicker(selection: $localScope)                        // screen-local scope
taxonomy.flattened                                         // [(classification, depth)] depth-first — for menus/outlines
```

Put `ToolbarItem { ScopePicker() }` in your screen's `.toolbar` if the screen is scope-aware
(Dashboard, Holdings, Performance, Earnings, Trades, Allocation typically are). Screens that list
master data (Securities, Transactions, Accounts, Plans, Import) normally ignore the scope.

---

## Navigation

```swift
enum AppScreen: String, CaseIterable   // dashboard, holdings, performance, allocation, earnings, trades,
                                       // securities, transactions, accounts, plans, import
    var title, summary, symbol: String; var section: Section; var shortcutKey: KeyEquivalent?   // ⌘1…⌘9, ⌘0

struct Route: Hashable, Codable, Sendable { var screen: AppScreen; var focus: Focus? }
enum Route.Focus { security(UUID), account(UUID), depot(UUID), transaction(UUID), plan(UUID),
                   taxonomy(UUID), classification(taxonomy: UUID, id: UUID) }
```

```swift
store.navigate(to: .security(id))                        // Securities, that security focused
store.navigate(to: .account(id))                         // Accounts            store.navigate(to: .depot(id))
store.navigate(to: .transaction(id))                     // Transactions — reveals the entry
store.navigate(to: .plan(id))                            // Plans
store.navigate(to: .taxonomy(id))                        // Allocation
store.navigate(to: .classification(taxonomy: t, id: c))  // Allocation, that classification
store.navigate(to: .holdings)                            // AppScreen overload
store.navigate(to: Route(.performance, focus: .security(id)))   // any screen with any focus
store.setFocus(.transaction(id))                         // selection changed inside your screen (no history entry)
store.route                                              // observe it
store.route.securityID / .accountID / .depotID / .transactionID / .planID / .taxonomyID / .classificationID
store.goBack(); store.goForward(); store.canGoBack; store.canGoForward
```

Text form (`Route(string:)` / `stringValue`, used by `--route` and window restoration): `holdings`,
`security:<uuid>`, `account:<uuid>`, `depot:<uuid>`, `transaction:<uuid>`, `plan:<uuid>`,
`taxonomy:<uuid>`, `classification:<taxonomy uuid>/<classification uuid>`,
`performance/security:<uuid>` (`<screen>/<focus>`).

**Contract for screens:** when `store.route.focus` names an entity you show, select and reveal it;
when the user changes the selection, call `store.setFocus(…)` so the inspector follows. A focus whose
entity disappears (delete, undo) is cleared automatically.

```swift
.onChange(of: store.route.securityID, initial: true) { _, id in
    if let id { selection = [id] }                                   // reveal what a deep link asked for
}
.onChange(of: selection) { _, ids in
    store.setFocus(ids.count == 1 ? .security(ids.first!) : nil)     // inspector follows
}
```

| route | honoured by |
|---|---|
| `.security(id)` | Securities |
| `.account(id)`, `.depot(id)` | Accounts |
| `.transaction(id)` | Transactions (clears filters that hide it, selects, scrolls) |
| `.plan(id)` | Plans |
| `.taxonomy(id)`, `.classification(taxonomy:id:)` | Allocation |

---

## Sheets

Any feature may *request* a sheet; the feature that owns the editor *provides* it through
`FeatureModule.sheet` — nobody imports anybody. Requests queue if a sheet is already up; unclaimed
requests show the shell's placeholder sheet.

```swift
store.present(.newTransaction(TransactionPrefill(
    kind: .buy, date: store.today, securityID: id, accountID: nil, depotID: depotID,
    shares: Shares(10), amount: Money(minor: 123_456, currency: "EUR"))))
store.present(.newTransaction(TransactionPrefill(copying: transaction, date: store.today)))   // "Duplicate"
store.present(.newTransaction)                                   // no prefill; same for .newSecurity/.newAccount/.newDepot/.newPlan
store.present(.editTransaction(id))
store.present(.newSecurity(SecurityPrefill(name: "ACME", currency: "USD", isin: "US0000000000")))
store.present(.editSecurity(id))
store.present(.newAccount(AccountPrefill(currency: "USD")));     store.present(.editAccount(id))
store.present(.newDepot(DepotPrefill(referenceAccountID: id)));  store.present(.editDepot(id))
store.present(.newPlan(PlanPrefill(kind: .purchase, securityID: id)));  store.present(.editPlan(id))
store.present(.importFile(url))                                  // .importFile (nil) → the importer asks for a file
store.present(.export)                                           // whole portfolio; or:
store.present(.export(ExportRequest(.transactions(only: ids))))  // .transactions(), .securities, .quotes(securityID:)
store.present(.portfolioSettings);  store.present(.consistencyReport)        // shell-owned
store.present(.custom(id: "allocation.rebalance", payload: ["taxonomy": id.uuidString]))
store.dismissSheet()                       // call from your sheet when done (the next queued request follows)
store.services.chooseImportFile?(store)    // open panel → .importFile(url)
```

| request | payload | owner |
|---|---|---|
| `.newTransaction(TransactionPrefill)`, `.editTransaction(UUID)` | `kind, date, securityID, accountID, depotID, counterAccountID, counterDepotID, shares, amount, fees, taxes, note, source` — all optional; `init(copying:date:)` | FeatureTransactions |
| `.newSecurity(SecurityPrefill)`, `.editSecurity(UUID)` | `name, currency, isin, wkn, ticker, feed` | FeatureSecurities |
| `.newAccount(AccountPrefill)`, `.editAccount(UUID)` | `name, currency` | FeatureAccounts |
| `.newDepot(DepotPrefill)`, `.editDepot(UUID)` | `name, referenceAccountID` | FeatureAccounts |
| `.newPlan(PlanPrefill)`, `.editPlan(UUID)` | `kind, securityID, depotID, accountID, amount, start` | FeaturePlans |
| `.importFile(URL?)` | file to import, nil = ask | FeatureImport |
| `.export(ExportRequest)` | `.portfolio`, `.transactions(only: Set<UUID>?)`, `.securities`, `.quotes(securityID:)` | FeatureImport (the shell offers a JSON export until then) |
| `.portfolioSettings`, `.consistencyReport` | — | shell |
| `.custom(id:payload:)` | `[String: String]` | whoever claims the id (namespace: `"<feature>.<name>"`) |

An editor owner must treat every prefill field as optional, fill sensible defaults (e.g. the depot's
reference account), and handle an id that no longer exists by dismissing. The view finds the store
and `\.gainStyle` in the environment.

Text form for the screenshot mode (`SheetRequest.parse(_:in:)`, `--sheet`): `new-transaction`,
`new-transaction:<kind>` (kind = `Transaction.Kind` raw value, e.g. `buy`), `edit-transaction:<uuid>|first`,
`new-security`, `edit-security:<uuid>|first`, `new-account`, `edit-account:<uuid>|first`, `new-depot`,
`edit-depot:<uuid>|first`, `new-plan`, `edit-plan:<uuid>|first`, `import`, `import:<path>`, `export`,
`export:transactions|securities|quotes:<uuid>|first`, `portfolio-settings`, `consistency`,
`custom:<id>?key=value&key=value`.

---

## Confirmations, toasts, activity

```swift
store.confirm(ConfirmationRequest(title: "Delete 3 Accounts?", message: "…", confirmTitle: "Delete") { … })

store.toast("Imported 208 transactions", style: .success)          // .info .success .warning .error
store.show(Toast("Export failed", message: error.localizedDescription, style: .error, duration: 6))

store.beginActivity("Importing", total: 14)                         // toolbar/sidebar progress; counts as busy
store.updateActivity(completed: 3)                                  // "Importing 3/14"
store.endActivity()

store.isBusy                                // activity running, analysis request pending, or inside whileBusy
await store.whileBusy { … }                 // or beginBusy()/endBusy()
await store.waitUntilSettled()              // tests: suspends until isBusy has been false for a moment
store.openCommandPalette(query: "div")      // ⌘K palette, pre-filled
store.isInspectorPresented = true
```

---

## Quote updates

The shell installs KontorMarketData's `QuoteUpdater` on the store (`store.quoteUpdater`; nil in tests
and in screenshot mode, so nothing can reach the network there). The toolbar button, ⌘R and the
automatic update on open call the same API a feature can use:

```swift
store.updateQuotes()                                   // all securities with an automatic feed
store.updateQuotes(only: [id])                         // "Update Selected"
store.updateQuotes(only: [id], reloadHistory: true)    // full history again (after a split / to correct prices)
store.updateQuotes(interactive: false)                 // quiet: toast only (automatic runs)
store.cancelQuoteUpdate()                              // what was downloaded so far is still applied

store.isUpdatingQuotes                                 // progress is store.activity ("Updating quotes 3/14")
store.hasAutomaticQuoteFeeds
store.lastQuoteUpdate                                  // QuoteUpdateReport?
store.isQuoteReportPresented = true                    // the shell's results popover (failures per security)
let report = await store.updateQuotes()?.value         // Task<QuoteUpdateReport?, Never>? — nil if nothing started
```

```swift
struct QuoteUpdateReport: Equatable, Sendable {
    var finishedAt: Date, targetCount: Int, newPrices: Int, newRates: Int, changedSecurities: Int
    var failures: [Failure]            // Failure(securityID: UUID?, name: String, message: String) — nil id = exchange rates
    var unsupportedCurrencies: [CurrencyCode], wasCancelled: Bool
    var hasFailures: Bool, hasNewData: Bool, summary: String      // "124 new prices, 6 new exchange rates"
}
```

Guarantees: results are applied through `store.mutate("Update Quotes")` as **one undoable step**;
securities without a feed, with a `manual` feed and retired ones are never requested; a second call
while an update runs does nothing. Do not make network calls of your own from a screen — to try a
feed in an editor (FeatureSecurities), use KontorMarketData's providers directly inside
`store.whileBusy`, and never when `store.quoteUpdater == nil`.

---

## Launch state

The screenshot mode's `--state key=value` (repeatable) lands in `store.launchState`. It is how a
reviewer opens a specific tab, mode or sub-view of your screen; in normal use it is empty.

```swift
enum Tab: String { case overview, rebalancing }
@State private var tab = Tab.overview

.onAppear {
    tab = store.launchValue("tab", as: Tab.self) ?? tab                         // --state tab=rebalancing
    if let id = store.launchValue("taxonomy").flatMap(UUID.init(uuidString:)) { taxonomyID = id }
    showsChart = store.launchValue("chart") != "off"                            // --state chart=off
}
```

Contract: read it once (`onAppear`) to seed `@State`; keys lowercase (`tab`, `mode`, `sort`, `filter`,
`group`, `selection`, …); unknown keys/values are ignored; document your keys in a doc comment on
your screen type. Use `--route` for entity focus, `--scope` and `--period` for scope and period,
`--sheet` for sheets — not state keys.

```sh
Scripts/shot.sh Allocation allocation /tmp/rebalancing.png --today 2026-06-30 --state tab=rebalancing --state chart=off
```

---

## Feature registry

Each feature target exposes one `FeatureModule`; the executable collects them in
`Sources/Kontor/FeatureCatalog.swift` with `#if canImport(Feature<Name>)` (already done for all
eleven — a feature that is not part of the build falls back to `FeaturePlaceholder`).

```swift
public enum TransactionsFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.transactions) { TransactionsScreen() }
            // (a) command palette entries — called each time the palette opens
            .commands { store in
                [PaletteCommand(id: "transactions.copy-all", title: "Copy All Transactions as TSV",
                                symbol: "doc.on.doc", keywords: ["export", "clipboard"]) {
                    Pasteboard.copy(makeTSV(store.file))
                }]
            }
            // (b) trailing inspector while this screen is active (read store.route.focus)
            .inspector { TransactionInspector() }
            // (c) sheets this feature owns — `if case` chains WITHOUT a final `else`, so that
            //     requests owned by other features fall through (a `switch` with a default view
            //     would claim every request)
            .sheet { request in
                if case .newTransaction(let prefill) = request {
                    TransactionEditor(prefill: prefill)
                } else if case .editTransaction(let id) = request {
                    TransactionEditor(editing: id)
                }
            }
    }
}
```

`PaletteCommand(id:title:subtitle:symbol:category:keywords:shortcut:action:)` — `category` is
`.navigation`, `.action` (default), `.security`, `.account`, `.other`. Screens, securities, accounts
and the shell's own actions are already in the palette. Views provided through the registry get the
store and `\.gainStyle` from the environment.

`FeatureRegistry` (shell-side): `content(for:)`, `inspector(for:)`, `sheet(for:)`, `commands(for:)`.
`FeaturePlaceholder(screen)` is the stand-in view.

---

## Formatting (`Fmt`)

Static, thread-safe, integer-based (no `NumberFormatter` per call) — cheap enough for every table
cell. Locale conventions come from the user's region.

```swift
Fmt.money(Money(minor: 123_456, currency: "USD"))           // "$1,234.56"      de: "1.234,56 $"
Fmt.money(m, signed: true)                                   // "+$1,234.56"
Fmt.money(m, symbol: false)                                  // "1,234.56"
Fmt.money(minor: 123_456, currency: "EUR")                   // "€1,234.56"
Fmt.moneyRounded(m)                                          // "$1,235"
Fmt.compactMoney(Money(minor: 123_456_789, currency: "USD")) // "$1.2M"          de: "1,2 Mio. $"
Fmt.percent(0.0734)                                          // "7.34%"          de: "7,34 %"
Fmt.percent(0.0734, decimals: 1, signed: true)               // "+7.3%"
Fmt.percent(basisPoints: 2_500)                              // "25.00%"
Fmt.moneyRounded(m, signed: true)                            // "+$1,235"
Fmt.shares(Shares(12.5))                                     // "12.5" (≤ 8 decimals, zeros trimmed)
Fmt.shares(shares, maxDecimals: 4)                           // "3.8524" — table cells; exact value in a tooltip
Fmt.price(Price(101.5), currency: "EUR")                     // "€101.50" (2–4 decimals; up to 8 below 1)
Fmt.price(price, currency: "EUR", maxDecimals: 4)            // engine-derived prices (dividend per share, averages)
Fmt.time(minuteOfDay: 495)                                   // "08:15"
Fmt.bytes(74_100_000)                                        // "74.1 MB"
Fmt.number(1234.567, decimals: 1)                            // "1,234.6"
Fmt.integer(1_234_567)                                       // "1,234,567"
Fmt.rate(1.08345)                                            // "1.0835"
Fmt.currencySymbol("EUR")                                    // "€"
Fmt.day(day)                                                 // "03/31/2024"     de: "31.03.2024"
Fmt.day(day, style: .medium)                                 // "Mar 31, 2024"   (.long .monthYear .shortMonthYear .dayMonth .iso)
Fmt.relativeDay(day, today: store.today)                     // "Today", "Yesterday", "3 days ago", else medium
Fmt.missing                                                  // "–" (also returned for NaN/∞)
```

### Engine values

Engine results are fractions, optionals and day counts; these overloads render them (nil → "–"):

```swift
Fmt.percent(analysis.irr)                    // Double? → "7.34%" or "–"   (also decimals:, signed:)
Fmt.percentagePoints(0.0125)                 // "+1.25 pp"   (difference of two percentages)
Fmt.basisPoints(25)                          // "25 bp"      Fmt.basisPoints(25, signed: true) → "+25 bp"
Fmt.basisPoints(fraction: 0.0025)            // "25 bp"
Fmt.percent(basisPoints: 2_500)              // "25.00%"     (model weights are basis points)
Fmt.ratio(risk.sharpeRatio)                  // "1.23" — unitless (Sharpe, profit factor); nil → "–"
Fmt.multiple(1.5)                            // "1.5×"
Fmt.number(optionalDouble)                   // Double? → "–"       Fmt.money(optionalMoney) → "–"
Fmt.compactMoney(minor: 123_456_789, currency: "USD")     // "$1.2M"
Fmt.duration(days: 400)                      // "13 months"  (< 2 months: days, < 2 years: months, else "2.4 years")
Fmt.duration(days: 400, style: .compact)     // "13mo"       ("12d", "5mo", "2.4y" — table cells)
Fmt.duration(years: interval.years)          // "2.4 years"
Fmt.interval(store.periodInterval)           // "Jan 1, 2024 – Jun 30, 2024"
Fmt.month(year: 2024, month: 3)              // "Mar 2024"   (long: true → "March 2024")
```

Display names (never show raw values): `Transaction.Kind.title` ("Delivery (Inbound)"), `.symbol`,
`Transaction.Kind.menuOrder`; `InvestmentPlan.Kind.title`; `CostMethod.title` / `.shortTitle`;
`ReportingPeriod.title` / `.shortTitle` / `.code`; `ConsistencyIssue.title`, `.route`,
`ConsistencyIssue.Severity.title` / `.pluralTitle` / `.symbol` / `.color`.

Parsing (tolerant of either decimal separator, grouping, currency symbols, `%`, `−`, `(…)`):

```swift
Fmt.parseMinor("1.234,56 €")      // 123456        Fmt.parseMoney("3.50", currency: "USD")
Fmt.parseShares("0,5")            // Shares(0.5)   Fmt.parsePrice("101.1235")
Fmt.parsePercent("12,5 %")        // 0.125         Fmt.parseDouble("2.5")
Fmt.parseDay("31.3.24")           // Day?          (ISO, locale order, 2-digit years, day+month only)
```

A lone separator is read as the decimal separator unless it is the locale's grouping separator
followed by exactly three digits (`1,234` → 1234 in en_US, 1.234 in de_DE).

For a specific locale (tests, exports): `KontorFormatter(locale:)` has the same methods as instance
methods. `Fmt.setLocale(_:)` switches the app-wide formatter.

---

## Help topics

Plain-language explanations of finance terms, shown in a popover from a small ⓘ. Put one next to
every term a newcomer might not know.

```swift
HelpButton(.ttwror)                                           // the ⓘ
HelpLabel("Sharpe Ratio", topic: .sharpeRatio)                // label + ⓘ (form rows, column headers, tiles)
HStack(spacing: DS.Spacing.xs) { Text("TTWROR"); HelpButton(.ttwror) }
HelpTopicView(topic: .ttwrorVersusIRR)                        // the text inline (empty states, settings)
HelpTopic.irr.title; HelpTopic.irr.text; HelpTopic.irr.related
```

`enum HelpTopic: String, CaseIterable` —
`ttwror, irr, ttwrorVersusIRR, annualizedReturn, absolutePerformance` ·
`costBasis, costMethod, purchasePrice` (`costMethod` explains FIFO vs. average) ·
`realizedGains, unrealizedGains, currencyGains` ·
`maxDrawdown, volatility, semiVolatility, sharpeRatio, riskFreeRate` ·
`dividendYield, yieldOnCost, grossVersusNet` ·
`benchmark, reportingPeriod, scope, investedCapital, externalFlows` ·
`allocation, targetWeight, rebalancing` ·
`trade, holdingPeriod, profitFactor` ·
`savingsPlan, exDate, delivery, securityTransfer` ·
`quoteFeed, exchangeRates, baseCurrency` · `consistencyCheck` ·
`netWorth, dayChange, weight, stalePrice, watchlist` ·
`depot, cashAccount, referenceAccount, retired` ·
`stockSplit, movingAverage, rollingReturn, trailingTwelveMonths` ·
`winRate, taxYear, drift, projection, planExecution`.

If a term is missing, add a case with title and text in `Help/HelpTopic.swift`.

---

## Design system

```swift
DS.Spacing.xxs/xs/s/m/l/xl/xxl      // 2 4 8 12 16 24 32
DS.Radius.small/control/card/panel  // 4 8 14 20
DS.Size.tableRow, .sparkline, .readableWidth, .cardMinWidth
DS.Motion.quick, .regular, .standard(reduceMotion)   // nil when Reduce Motion is on

DS.Colors.green / .red              // polarity colors (prefer GainStyle below)
DS.Colors.neutral, .warning, .cardFill, .hairline, .benchmark

Color(hex: "#2A78D6")               // #RGB, #RRGGBB, #RRGGBBAA; invalid → gray
Color(light: "#1A8F3C", dark: "#30D158")
color.hexString                     // "#RRGGBB" (store in Classification.color)

Font.kontorHero / .kontorValue / .kontorNumber / .kontorCaption
view.numeric()                      // tabular digits — use on every number
```

**Gain/loss colors** respect the user's "red = up" preference — never hard-code green/red:

```swift
@Environment(\.gainStyle) private var gainStyle
gainStyle.gain; gainStyle.loss; gainStyle.color(for: change); gainStyle.color(forMinor: delta.minor)
```

**Chart categories** (charts themselves: see [Charts](#charts)) — `CategoryPalette.color(i)` / `.colors` (8 hues, light+dark steps,
colorblind-validated *in this order*; assign by entity in fixed order, never cycle — past eight use
`CategoryPalette.other`). `CategoryPalette.hex(i)` gives a default for `Classification.color`.
Text keeps label colors; a colored mark next to it carries identity (`CategoryTag`).

**Surfaces** — content sits on solid cards (`Card`, `.cardBackground()`); Liquid Glass is reserved for
transient chrome floating above content (`.glassPanel()`: palette, toasts, overlays). `.screenPadding()`
is the standard margin around a screen's scroll content.

**Accessibility rules** — numbers use tabular digits; color never carries meaning alone
(`DeltaLabel` always shows ▲▼, `GainText` adds them under Differentiate Without Color); honour
`accessibilityReduceMotion` via `DS.Motion.standard`; every control keyboard-reachable with an
accessibility label.

---

## Components

```swift
Card("Allocation", symbol: "chart.pie") { chart } accessory: { Button("Details") { … }.buttonStyle(.link) }
Card { content }                                          // untitled

SectionHeader("Positions", subtitle: "12") { Button("Add", systemImage: "plus") { … } }

StatTile("Net Worth", value: Fmt.money(total),
         delta: DeltaLabel(fraction: 0.0124, amount: change), footnote: "today", symbol: "sum")

DeltaLabel(fraction: 0.0124)                              // ▲ 1.24%
DeltaLabel(fraction: -0.02, amount: Money(minor: -31_240, currency: "EUR"))   // ▼ 2.00% −€312.40

GainText(money: gain)                                     // +$1,204.10 in gain/loss color
GainText(percent: 0.0734)                                 // +7.34%
GainText("+12 bp", trend: .up)                            // custom text; Trend(value) / Trend(minor:)

Sparkline(values)                                         // [Double], colored by net change
Sparkline(raw: security.prices.values.suffix(260), tint: .secondary).frame(width: 72, height: 20)

CategoryTag("Equity", color: CategoryPalette.color(0))

KeyValueRow("ISIN", security.isin)                        // "–" when empty
KeyValueRow("Gain") { GainText(money: gain) }

EmptyState("No Transactions", symbol: "list.bullet.rectangle", message: "Record a purchase or import your history.") {
    Button("New Transaction") { store.present(.newTransaction) }
}

view.loadingOverlay(isLoading, label: "Calculating…")     // appears only after ~180 ms
PeriodPicker()                                            // window period; PeriodPicker(selection:) for a local one
ScopePicker()                                             // window scope; see "Period and scope"
HelpButton(.irr)                                          // ⓘ popover; see "Help topics"
```

---

## Charts

One shared chart kit (`Sources/KontorUI/Charts`) — **do not build your own charts or import Swift
Charts in a feature.** Every chart is a single `Canvas` pass (no view per mark, smooth with 25 years
of daily data), supports light/dark, Increase Contrast, Differentiate Without Color (textures, dash
patterns, ▲▼), Reduce Motion, VoiceOver (label + summary + audio graph) and has built-in hover
values, empty and loading states.

The rules that keep charts consistent:

* **Data in, off the main actor.** Chart inputs (`TimeSeries`, `BarSeries`, `ChartSlice`, `ChartNode`,
  `HeatmapRow`, `WaterfallStep`, `Histogram`, `ChartMarker`) are plain `Sendable` values: build them
  inside `analysisTask` and store them in your model. Never read `Analysis` in `body`.
* **Values are `Double`s in the unit of the `ChartValueFormat`**: `.money(currency)` = **minor
  units** (`Double(int64)`), `.percent()` = fractions (0.0734), `.price(currency)` = major units
  (engine `priceLevels`), `.number(decimals:)`, `.count`. All text goes through `Fmt`.
* **One value axis per chart** — never two scales. Different units → two charts (or the built-in
  underwater panel).
* **Color means something**: series/categories take `ChartColors.series(i)` (= `CategoryPalette`, in
  order, never cycled — fold with `ChartSlice.folded`), comparisons `ChartColors.comparison`,
  polarity the user's gain/loss colors (automatic with `.gainLoss` / `DivergingScale`),
  classifications `ChartColors.classification(node.color, fallbackIndex: i)`.
* **Sizing**: time, bar, donut, sunburst, treemap and distribution charts fill the frame you give
  them (`.frame(height: 260)`); `HeatmapGrid`, `WaterfallChart` and `TargetActualBar` have an
  intrinsic height. Put charts in a `Card`; on another background set `.environment(\.chartSurface, color)`.
* **States**: every chart has `.loading(loadable.isRefreshing)` (dims; spinner when there is no data
  yet) and `.emptyMessage("…")`. Screens still own their real `EmptyState` with a call to action.
* **Screenshots / linking**: every chart has `.pinnedHover(…)` to show its hover state without a
  pointer — use it with a launch-state key so reviewers can see the tooltip.

```swift
// Shared by all charts
ChartValueFormat.money("EUR") / .percent(decimals: 2, signed: true) / .percent(compounding: false) / .price("EUR") / .number(decimals: 1) / .count
ChartColors.series(2); ChartColors.comparison; ChartColors.neutral; ChartColors.other
ChartColors.classification(classification.color, fallbackIndex: index)     // stored hex, adjusted for legibility in light + dark
DivergingScale(limit: 0.08, gainStyle: gainStyle).color(for: 0.031, scheme: colorScheme)   // + .ink(for:scheme:) — black/white ≥ 4.5:1
ChartLegend(items, hidden: $hidden)                                        // standalone legend (toggles / hover-linked / vertical)
ChartLabels.shortMonths                                                    // "Jan" … "Dec" in the Fmt locale
.environment(\.chartPatternsForced, true)                                  // textures regardless of the system setting
```

### TimeSeriesChart

Lines / areas / stepped lines over days; month/year ticks; zero rule; hover crosshair with a floating
legend of exact values for all series; legend toggles (≥ 2 series); optional drag-to-select range,
markers and an "underwater" panel. ←/→ move the crosshair, Esc clears.

```swift
struct PerformanceChartModel: Sendable {
    var currency: CurrencyCode, start: Day
    var value: [ChartPoint<Int64>], invested: [Int64], returns: [ChartPoint<Double>], drawdown: [Double]
    init(_ a: Analysis) {
        currency = a.currency; start = a.interval.start
        value = a.valuation.chartPoints(maxPoints: 900)          // engine-reduced (any length works: the chart reduces per pixel)
        invested = a.investedCapital                             // dense daily [Int64], index i = start + i
        returns = a.returns.chartPoints(maxPoints: 900)
        drawdown = a.drawdowns.map { -$0 }                       // underwater curves are ≤ 0
    }
}

TimeSeriesChart([
    TimeSeries("Portfolio", points: m.value, style: .area),                                    // first series = on top, leads the tooltip
    TimeSeries("Invested", start: m.start, values: m.invested, style: .step, color: ChartColors.comparison),
], format: .money(m.currency), title: "Portfolio value")
.timeDomain(store.periodInterval)              // optional: pin the x-axis to the period
.rangeSelection { selection in … }             // drag → ChartRangeSelection(interval: DayInterval, changes: [seriesID, from, to]); nil when cleared
.loading(model.isRefreshing)
.frame(height: 280)

TimeSeriesChart([
    TimeSeries("Portfolio", points: m.returns),
    TimeSeries("MSCI World", points: benchmarkPoints, color: ChartColors.comparison, dashed: true),
], format: .percent(signed: true), title: "Cumulative return")
.underwater(TimeSeries("Drawdown", start: m.start, values: m.drawdown))        // secondary panel, loss-colored fill

TimeSeriesChart([TimeSeries(security.name, start: interval.start, values: levels)],               // ledger.priceLevels(…) → major units
                format: .price(currency), baseline: .data, title: "Price")                       // .data: axis hugs the data
    .markers(ChartMarker.markers(for: transactions))          // ▲ buy, ▼ sell (on the line), ◆ dividend, ● event (on the axis)
    .onHover { day in hoveredDay = day }                      // link charts: feed another chart's .pinnedHover(day)
```

`TimeSeries` inits: `points: [ChartPoint<Double>]`, `points: [ChartPoint<Int64>]`, `start:values:` with
`[Double]`, `[Int64]` or `[Double?]` (dense daily engine arrays), `days:values:`. Styles `.line .area
.step .stepArea`, `dashed:`, `color:`. Other modifiers: `.legendHidden()`, `.emptyMessage(_:)`,
`.pinnedHover(day)`, `.pinnedRange(DayInterval)`.

### BarSeriesChart

Categorical or time-bucketed bars, grouped or stacked, colored by series or by gain/loss; hover
values, selection, optional overlay line (same axis). ←/→ + Return with keyboard focus.

```swift
let months = BarCategory.months(report.months.map { ($0.year, $0.month) })     // or BarCategory.month(year:month:), .year(2024), BarCategory(id:label:detail:)
BarSeriesChart(categories: months, series: [
    BarSeries("Dividends", values: report.months.map(\.amounts.dividends)),    // [Int64] or [Double], one per category
    BarSeries("Interest", values: report.months.map(\.amounts.interest)),
], format: .money(currency), layout: .stacked, title: "Earnings per month")
.overlayLine(BarOverlayLine("12-month average", values: trailingAverage))      // [Double?]
.selection(selectedMonth) { selectedMonth = $0 }                               // category id, nil = deselected
.frame(height: 240)

BarSeriesChart(categories: years, values: yearlyReturns, name: "Return", format: .percent(signed: true))   // single series, .gainLoss
    .valueLabels()
```

Labels that do not fit are thinned automatically. `.legendHidden()`, `.pinnedHover(categoryID)`.

### DonutChart · SunburstChart · TreemapChart

```swift
DonutChart(ChartSlice.slices(from: allocation), format: .money(currency), centerTitle: "Net Worth", title: "Asset classes")
    .selection(selectedID) { selectedID = $0 }            // also selectable from the legend
    .frame(height: 220)                                   // legend (name · value · share) beside it, or wrapped below when narrow
DonutChart(ChartSlice.folded(slices), format: …)          // own slices: ChartSlice("Equity", value: v, color: …); fold to ≤ 8

SunburstChart(ChartNode.nodes(from: allocation, includesItems: true), format: .money(currency), centerTitle: taxonomy.name)
    .levels(3)                                            // 1…3 rings; children are tints of their parent
    .selection(selectedID) { id in … }                    // ids = classification UUID strings ("<classification>/<vehicle>" for items)

TreemapChart(ChartNode.nodes(from: allocation, includesItems: true), format: .money(currency), title: "Holdings")
TreemapChart(ChartNode.nodes(from: allocation, includesItems: true, changes: ttwrorBySecurityID), format: .money(currency),
             coloring: .performance(limit: 0.10))         // ChartNode.change on the diverging gain/loss scale; nil limit = from data
```

`ChartNode(name, id:, value:, color:, change:, children:)` — `value` includes the children. Hover
shows name/value/share (center label or tooltip); `.pinnedHover(id)`, `.legendHidden()`.

### HeatmapGrid · WaterfallChart · DistributionChart · TargetActualBar · Sparkline

```swift
HeatmapGrid(model.heatmap)                                 // engine ReturnHeatmap → year × month + "Year" column, newest first
HeatmapGrid(rows: [HeatmapRow(label: "2024", cells: values, total: sum)], columns: ChartLabels.shortMonths,
            format: .percent(decimals: 1), totalTitle: "Year", limit: 0.08)
    .selection { rowID, column in … }                      // .rowHeight(22), .scaleHidden(), .pinnedHover(row:column:)

WaterfallChart(WaterfallStep.steps(from: analysis.breakdown), format: .money(currency), title: "Performance breakdown")
WaterfallChart([.total("Start", value: a), .change("Gains", value: g), .change("Fees", value: -f), .total("End", value: b)], format: …)
    .selection { stepID in … }                             // ids from steps(from:) are PerformanceBreakdown.Line raw values; Line.title for names

DistributionChart(Histogram(monthlyReturns, targetBins: 24), format: .percent(decimals: 1, signed: true), title: "Monthly returns")
    .markers(mean: true, median: true)                     // Histogram(…) is Sendable — bin inside analysisTask
    .frame(height: 200)                                    // coloring: .gainLoss (default) | .neutral

TargetActualBar(actual: node.share, target: node.targetShare, maximum: 0.6, color: color, tolerance: 0.03)   // ▲ +2.1 pp label; table cells

Sparkline(values)                                          // unchanged — see Components
```

### Building blocks (for the rare custom composition)

`LinearScale.nice(min:max:targetTicks:includeZero:padding:tight:)`, `DayAxis.ticks(from:to:maxTicks:)`,
`Treemap.layout(weights:in:)`, `Histogram`, `ChartRGB` (luminance, contrast, `.ink`), `ChartPattern`.

### Chart gallery (debug)

`ChartGallery` renders every component with the open portfolio; it exists only in the screenshot
mode and is the reference for feeding the charts (`ChartGallery.Model`):

```sh
Scripts/shot.sh none chart-gallery /tmp/charts/ --appearance both --today 2026-06-30 --period ALL --state page=time
# page = time | bars | parts | grids | states      --state patterns=on  (Differentiate-Without-Color textures)      --red-gains
```

---

## Input controls

All numeric fields accept either decimal separator, mark invalid input and update the binding live.

```swift
MoneyField("Amount", minor: $amountMinor, currency: account.currency)   // or MoneyField("Amount", money: $money)
SharesField("Shares", shares: $shares)
PriceField("Price", price: $price, currency: security.currency)
PercentField("Risk-Free Rate", fraction: $rate)                          // 0.02 ⇄ "2.00 %"
DayField("Date", day: $date)                                             // Day ⇄ date picker
DayField("End", day: $plan.end, placeholder: "No end")                   // optional Day

CurrencyPicker(selection: $currency, preferred: store.file.currencies)   // searchable ISO list
SecurityPicker(selection: $securityID)                                   // Binding<UUID?>; retired hidden…
SecurityPicker(selection: $securityID, includesRetired: true, allowsNone: true)   // …or listed last, dimmed
AccountPicker(selection: $accountID, currency: "EUR")
DepotPicker(selection: $depotID)

SearchablePicker("Broker", selection: $id, items: [PickerItem(id:title:detail:keywords:isDimmed:)])
```

Pickers open a popover with a search field (fuzzy), ↑/↓, ⏎, ⎋. `Currencies.all / .common / .name(_:)`.

---

## Tables

Guideline for every list screen: SwiftUI `Table` with typed, sortable columns; column customization
and filter text persisted per window with `@SceneStorage`; multi-selection; context menu with a
primary (double-click) action; ⌘C copies TSV; Delete deletes (undoable, no confirmation); quick
filter in the toolbar; footer with counts. Rows are plain `Sendable` value structs built, filtered
and sorted off the main actor through `ledgerTask` / `analysisTask`.

```swift
struct LedgerRow: Identifiable, Sendable {
    let id: UUID
    var date: Day, kind: String, security: String, amount: Money
}

struct LedgerTable: View {
    @Environment(PortfolioStore.self) private var store
    @SceneStorage("ledger.columns") private var columns: TableColumnCustomization<LedgerRow>
    @SceneStorage("ledger.filter") private var filter = ""
    @State private var selection = Set<LedgerRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\LedgerRow.date, order: .reverse)]
    @State private var loaded = Loadable<[LedgerRow]>()

    /// Everything the rows depend on besides the document.
    private struct Query: Hashable, Sendable {
        var filter: String
        var sortOrder: [KeyPathComparator<LedgerRow>]
    }

    private var rows: [LedgerRow] { loaded.value ?? [] }

    var body: some View {
        let query = Query(filter: filter, sortOrder: sortOrder)
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Date", value: \.date) { Text(Fmt.day($0.date)).numeric() }
                .width(min: 80, ideal: 96)
                .customizationID("date")
            TableColumn("Type", value: \.kind).customizationID("type")
            TableColumn("Security", value: \.security).customizationID("security")
            TableColumn("Amount", value: \.amount.minor) { Text(Fmt.money($0.amount)).numeric() }
                .alignment(.trailing)
                .customizationID("amount")
        }
        .contextMenu(forSelectionType: LedgerRow.ID.self) { ids in
            Button("Edit…") { ids.first.map { store.present(.editTransaction($0)) } }.disabled(ids.count != 1)
            Button("Copy") { Pasteboard.copy(tsv(ids)) }
            Divider()
            Button("Delete", role: .destructive) { store.deleteTransactions(ids) }
        } primaryAction: { ids in
            ids.first.map { store.present(.editTransaction($0)) }
        }
        .onCopyCommand { [NSItemProvider(object: tsv(selection) as NSString)] }
        .onDeleteCommand { store.deleteTransactions(selection) }                 // undoable — no confirmation
        .onChange(of: selection) { _, ids in store.setFocus(ids.count == 1 ? .transaction(ids.first!) : nil) }
        .onChange(of: store.route.transactionID, initial: true) { _, id in       // deep link: reveal it
            if let id, selection != [id] { selection = [id] }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "transaction", selected: selection.count,
                        filteredFrom: store.file.transactions.count)
        }
        .toolbar { ToolbarItem { QuickFilterField(text: $filter, prompt: "Filter transactions") } }
        // Rows are built, filtered and sorted off the main actor; memoized per (revision, query).
        .ledgerTask($loaded, id: "ledger.rows", variant: query) { ledger in
            Self.makeRows(ledger, filter: QuickFilter(query.filter)).sorted(using: query.sortOrder)
        }
    }

    private nonisolated static func makeRows(_ ledger: Ledger, filter: QuickFilter) -> [LedgerRow] {
        ledger.transactions.compactMap { t in
            let security = t.securityID.flatMap { ledger.security($0)?.name } ?? ""
            guard filter.matches(security, t.kind.title, t.note) else { return nil }
            return LedgerRow(id: t.id, date: t.date, kind: t.kind.title, security: security, amount: t.amount)
        }
    }

    private func tsv(_ ids: Set<LedgerRow.ID>) -> String {
        TSV.string(header: ["Date", "Type", "Security", "Amount", "Currency"],
                   rows: rows.filter { ids.contains($0.id) }.map {
                       [$0.date.iso, $0.kind, $0.security, TSV.number($0.amount.decimalValue), $0.amount.currency]
                   })
    }
}
```

(This exact code compiles.) Helpers: `TSV.string(header:rows:)`,
`TSV.number(_: Decimal)` (ungrouped, locale decimal separator — what spreadsheets expect on paste),
`Pasteboard.copy(_:)`, `QuickFilterField(text:prompt:focusShortcut:)` (⌘F focuses it),
`QuickFilter(text).matches(fields…)` (all terms, case/diacritic-insensitive; `Sendable`),
`TableFooter(count:noun:selected:filteredFrom:) { trailing }`.

`TableFooter(count:noun:plural:selected:filteredFrom:leading:)` pluralizes regular nouns itself
("security" → "securities"); pass `plural:` for irregular ones and `leading:` for text such as the period.

**Table traps on this SDK** (all hit during feature work):

* Do not read `@Environment(PortfolioStore.self)` inside table cells or in
  `contextMenu(forSelectionType:)` content — pass the store in.
* `TableRowBuilder` has no `if`/`else` (use a `ForEach` over a possibly empty array);
  `TableColumnBuilder` accepts `if`, but at most ~10 columns per builder block — split wide tables into
  `@TableColumnBuilder` computed properties. Column `min` widths are hard limits: when their sum
  (plus ~17 pt of chrome per column) exceeds the width, the table scrolls horizontally.
* Create the `Table` only once its rows exist (or give it an `.id` that changes with its structure):
  inserting hundreds of rows into a table that is already on screen logs AppKit's "reentrant
  operation in its NSTableView delegate" warning. Nested `DisclosureTableRow`s that start expanded
  trigger it as well — use a flat table with your own indentation.
* `@SceneStorage` is inert in the screenshot window (there is no scene). Keep `@State` as the source
  of truth, seed it from scene storage and `launchState` in `onAppear`, and mirror changes back.
* `ScrollViewReader.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.5))` reveals a table row without
  scrolling sideways.

`Loadable`, `analysisTask`, `store.analyze` and `store.compute` work with Optional result types
(`Loadable<Model?>`), including a nil result.

With 50,000 rows: keep row structs small, pre-format nothing you can format in the cell, and never
filter or sort in `body`.

---

## Utilities

```swift
FuzzyMatcher.match("hld", in: "Holdings")                 // Match(score:positions:isTight:)?
FuzzyMatcher.rank(items, query: text, limit: 40) { [$0.name, $0.ticker] }   // [(item, match)], best first

try await store.consistencyIssues()                       // [ConsistencyIssue] (engine), off the main actor, memoized
issue.severity / .kind / .message / .title / .route       // route: Route? → store.navigate(to:)
store.present(.consistencyReport)                         // the shell's Check Consistency sheet (⇧⌘K)

AppPreferences.Key.gainStyle / .defaultCurrency / .appearance / .autoUpdateQuotes / .periodicUpdate / …   // @AppStorage keys
AppPreferences.defaultCurrency, AppPreferences.gainStyle

hexComponents("#FF8000")                                  // (r, g, b, a)?
```

### Testing a feature

`Tests/Feature<Name>Tests` depends on your feature, KontorUI, the engine and KontorSampleData:

```swift
import Testing
import KontorUI
import KontorSampleData
@testable import FeatureHoldings

@Suite @MainActor struct HoldingsModelTests {
    @Test func buildsRowsForTheDemoPortfolio() async throws {
        let today = Day(year: 2026, month: 6, day: 30)
        let store = PortfolioStore(file: SampleData.demoPortfolio(today: today), today: today)
        let model = try await store.analyze("holdings.model") { analysis in HoldingsModel(analysis) }
        #expect(!model.rows.isEmpty)
    }
}
```

```sh
KONTOR_FEATURES=Holdings swift test --scratch-path .build-holdings --filter FeatureHoldingsTests
```
