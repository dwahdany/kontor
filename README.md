# Kontor

Kontor is a native macOS portfolio tracker: securities, cash accounts and honest performance
measurement in one fast, calm, keyboard-friendly app. Documents are plain JSON (`.kontor`), so your
data stays portable, diff-able and yours.

Kontor is an original app. It can import files from other tools (Portfolio Performance XML, CSV) but
shares no code or design with them.

- **Target:** macOS 27, Swift 6 (strict concurrency), SwiftPM only — no Xcode project, no third-party
  dependencies.
- **Status:** all eleven screens, the editors, import/export and the app shell are implemented and
  integrated. `swift build` is warning-free, `swift test` is green with every feature compiled in,
  and `Scripts/selftest.sh` drives the app end to end without anyone clicking (see
  [Self-test](#self-test)). What is still open is listed under [Known limitations](#known-limitations).

## What Kontor does

| Screen | What you get |
|---|---|
| **Dashboard** (⌘1) | A widget grid you arrange yourself (⌘E): net worth, returns, performance and value charts, allocation, top movers, largest holdings, dividends, drawdown, volatility, cash, upcoming plans, recent transactions, watchlist, consistency check — 21 widget kinds, several dashboards per file. A widget can be pinned to its own period and scope; Monthly Returns always shows whole years, statement widgets (net worth, holdings, cash) show the last day of the period, and Recent Transactions and Upcoming Plans always cover the whole portfolio. |
| **Holdings** (⌘2) | The statement of assets for any day: sortable, groupable table (depot, currency, any taxonomy) with cost basis, unrealized gain, TTWROR, IRR, dividends and sparkline; treemap and concentration views; inspector with price chart and open tax lots; buy / sell / dividend straight from a row. |
| **Performance** (⌘3) | TTWROR, IRR, gain, drawdown, volatility and Sharpe ratio for the period; return vs. benchmarks, value vs. invested capital, drawdown; drag across the chart to measure any stretch; a reconciling statement from initial to final value with the transactions behind every line; monthly heatmap, calendar years, rolling returns, risk figures, performance per security. |
| **Allocation** (⌘4) | Taxonomies (asset classes, regions, sectors … or your own) with target weights; donut, sunburst, treemap and target-vs-actual; an editor with drag-and-drop assignment and weighted splits; rebalancing proposals that become reviewed, undoable transactions. |
| **Earnings** (⌘5) | Dividends, interest, fees and taxes per month, quarter and year; year × month matrix; per security and per account; payment list; a 12-month dividend calendar with an estimate for the year ahead. |
| **Trades** (⌘6) | Closed and open trades with holding period, gain, return and return per year; win rate, profit factor, distributions; realized results per calendar year for your tax records. |
| **Securities** (⌘7) | Master data, watchlists, price chart with moving averages, purchase price and comparison; transactions, price history, events (stock splits), data source (Yahoo Finance, CoinGecko, manual) and notes per security. |
| **Transactions** (⌘8) | The complete ledger with filters, running balance per account and consistency issues; one editor for all 15 transaction kinds that calculates the missing figure, converts currencies and previews the resulting position. |
| **Accounts** (⌘9) | Cash accounts and depots: balances, net worth by account, statements, positions per depot. |
| **Plans** (⌘0) | Savings, deposit and withdrawal plans: due executions are proposed for review, never booked silently; per-plan performance; a what-if projection. |
| **Import** | Portfolio Performance files (become the content of a new portfolio, merge into an existing one, or open as a portfolio of their own), CSV wizard for broker statements, quotes and security lists with a live preview and remembered layouts; export as CSV, Portfolio Performance XML or Kontor JSON. Drop a file anywhere on a screen to import it. |

Everywhere: one reporting period and one scope (whole portfolio, a depot, an account, a
classification) per window; ⌘K command palette; inspector (⌥⌘I); every change is one undo step;
ⓘ popovers explain the finance terms; light and dark; numbers in your region's format.

**Words Kontor uses.** A **depot** is a securities account (where shares and funds are held); a
**cash account** holds money in one currency; a depot settles against its **reference account**.
Ledger entries are always called **transactions**. **TTWROR** is the time-weighted return, **IRR**
the money-weighted return. Both are shown **per year** only when there is more than a year to
measure — a portfolio that is four weeks old shows the return of those four weeks, whatever period
is selected, and the Sharpe ratio and volatility wait until there is enough history.

**How numbers differ from Portfolio Performance.** Imported ledgers reproduce PP's balances, share
counts and trades. Two conventions differ on purpose: the cost basis includes purchase fees but
**not** purchase taxes (PP includes both), and exchange rates are not part of PP files — Kontor
downloads them right after an import, and until then amounts in foreign currencies count as zero
(the import sheet says so).

Developers: read [The feature-module contract](#the-feature-module-contract) and
[`Sources/KontorUI/API.md`](Sources/KontorUI/API.md), then `Core/Engine/API.md` for the calculations.

## Build, test, bundle

```sh
swift build                     # everything: all eleven features (what CI and releases build)
swift test                      # KontorUI tests + every feature's tests
(cd Core/Engine && swift test)  # each Core package has its own suite: Model Engine MarketData Interchange SampleData
Scripts/selftest.sh             # end-to-end self-test of the built app, invisible (see "Self-test")

Scripts/bundle.sh               # → dist/Kontor.app (debug): hardened runtime, NOT sandboxed
Scripts/bundle.sh release       # → dist/Kontor.app (release): hardened runtime + App Sandbox
Scripts/bundle.sh debug --sandbox | release --no-sandbox | … --quiet | … --verify

Scripts/run.sh [file]           # for humans: bundle + open the app (brings a window to the front)
```

**Builds are throttled on purpose.** `bundle.sh` (and therefore `shot.sh` and `run.sh`) compiles at
low priority (`nice 15`) on a third of the cores, and `shot.sh` renders at low priority too, so the Mac
stays usable while they run. Override with `KONTOR_BUILD_JOBS=<n>` and `KONTOR_BUILD_NICE=<0…20>`;
when calling SwiftPM yourself, do the same: `nice -n 15 swift build -j 4`.

`bundle.sh` builds, assembles the bundle (Info.plist with document types, generated icon) and signs it
ad hoc. It does not launch anything unless you pass `--verify` (which launches the bundle hidden, in
the background, and checks that it stays alive). Always run the app from a bundle: document types,
the `.kontor` UTI and the icon come from `Resources/Info.plist`.

Why debug is not sandboxed: the screenshot mode writes to arbitrary paths, which the App Sandbox
forbids. The release bundle is sandboxed (user-selected files read/write + outgoing network); there,
use `--out -` / `--open -` (stdout/stdin).

### Build isolation: `KONTOR_FEATURES`

`Package.swift` reads the environment variable `KONTOR_FEATURES`:

| value | effect |
|---|---|
| unset, or `all` | all eleven features are targets of the package (default) |
| `Holdings` | only `FeatureHoldings` (+ `FeatureHoldingsTests`) exists; the other ten are **not even declared**, so their sources are never compiled |
| `Holdings,Transactions` | several (case-insensitive, comma-separated) |
| `none` | the bare shell |

The shell's `FeatureCatalog` registers features with `#if canImport(FeatureX)`; a feature that is not
linked shows `FeaturePlaceholder` for its screen and the placeholder sheet for its editors. So the app
always builds and runs with only *your* feature compiled, no matter what state the other ten are in.

**Always pair a selection with its own scratch path** so parallel builds never share a build
directory. The scripts do this for you:

| selection | build directory | bundle |
|---|---|---|
| unset / `all` | `.build/` | `dist/Kontor.app` |
| `Holdings` | `.build-holdings/` | `dist-holdings/Kontor.app` |
| `Holdings,Plans` | `.build-holdings-plans/` | `dist-holdings-plans/Kontor.app` |

```sh
export KONTOR_FEATURES=Holdings
swift build --scratch-path .build-holdings                                   # compile
swift test  --scratch-path .build-holdings --filter FeatureHoldingsTests     # your tests
Scripts/shot.sh Holdings holdings /tmp/holdings.png                          # build + bundle + screenshot
```

(All `.build-*/` and `dist-*/` directories are git-ignored.)

## Headless screenshots

Every screen, sheet and popover can be rendered to a PNG without anything appearing on screen — this
is how UI changes are reviewed.

```sh
Scripts/shot.sh <Feature|all> <screen-id> <out.png|out-dir/> [extra app arguments…]

Scripts/shot.sh Holdings holdings /tmp/holdings.png
Scripts/shot.sh Holdings holdings /tmp/holdings/ --appearance both --today 2026-06-30
Scripts/shot.sh Allocation allocation /tmp/rebalance.png --state tab=rebalancing
Scripts/shot.sh Transactions holdings /tmp/editor.png --sheet new-transaction:buy
Scripts/shot.sh Transactions transactions /tmp/edit.png --sheet edit-transaction:first
Scripts/shot.sh Performance performance /tmp/perf.png --stress      # 50,000 transactions, prints timing
Scripts/shot.sh all all /tmp/everything/ --appearance both           # full app, every target, light + dark
```

`shot.sh` sets `KONTOR_FEATURES` (first argument; `all` = unset), builds into the matching scratch
path, assembles the matching bundle and runs its screenshot mode with `--demo` unless you pass
`--open`, `--stress` or `--demo` yourself. Any number of `shot.sh` runs for different features can
run at the same time. Calling the binary directly works too:

```sh
APP=dist/Kontor.app/Contents/MacOS/Kontor       # or dist-<feature>/…

$APP --screenshot holdings --demo --today 2026-06-30 --out /tmp/holdings.png
$APP --screenshot all --demo --appearance both --out /tmp/shots/
$APP --screenshot securities --demo --route security:<uuid> --inspector --out /tmp/s.png
$APP --screenshot consistency --open my.kontor --out /tmp/check.png
$APP --screenshot quote-report --demo --out /tmp/quotes.png          # the quote-update results popover
$APP --screenshot palette --demo --query "div" --out /tmp/palette.png
$APP --screenshot dashboard --demo --out - > dashboard.png           # stdout (works sandboxed)
$APP --list-ids --demo --today 2026-06-30                            # entity ids for --route/--scope/--sheet
$APP --write-demo /tmp/demo.kontor --pretty                          # the demo portfolio as a file
$APP --help                                                          # the full reference below
```

```
Kontor --screenshot <target> --out <file.png | directory | -> [options]

targets   dashboard holdings performance allocation earnings trades securities transactions
          accounts plans import                                        (feature screens)
          welcome palette settings portfolio-settings consistency quote-report   (shell surfaces)
          all                      (everything; --out is a directory, files <target>[-light|-dark].png)

data
--demo                    the demo portfolio (KontorSampleData; deterministic for a given --today)
--stress                  stress portfolio: 200 securities × 25 years × 50,000 transactions ending
                          on "today"; prints the time until the screen settled
--open <file.kontor>      a portfolio file ("-" = stdin)
--today <YYYY-MM-DD>      fix "today" — ALWAYS pass it for reproducible renders and stable demo data

view state
--route <route>           security:<uuid> | account:<uuid> | depot:<uuid> | transaction:<uuid> |
                          plan:<uuid> | taxonomy:<uuid> | classification:<taxonomy>/<classification> |
                          <screen>/<focus>   (e.g. performance/security:<uuid>)
--period <p>              1M 3M 6M YTD MTD QTD 1Y 3Y 5Y 10Y ALL, 30D, a year (2024),
                          or a range 2024-01-01..2024-06-30
--scope <scope>           portfolio | depot:<uuid> | account:<uuid> | classification:<taxonomy>/<classification>
--state <key>=<value>     feature-defined view state, repeatable → store.launchState (see below)
--sheet <request>         present a sheet above the target screen and capture it:
                          new-transaction[:<kind>]   edit-transaction:<uuid>|first
                          new-security               edit-security:<uuid>|first
                          new-account                edit-account:<uuid>|first
                          new-depot                  edit-depot:<uuid>|first
                          new-plan                   edit-plan:<uuid>|first
                          import[:<path>]            export[:transactions|securities|quotes:<uuid>|first]
                          portfolio-settings         consistency
                          custom:<id>[?key=value&key=value]
--inspector               show the inspector
--query <text>            pre-fill the command palette (target "palette")
--toast <text>            show a toast        --activity "Updating quotes 3/14"   show progress

rendering
--window-size <W>x<H>     window size in points (default 1440x900; alias --size)
--appearance light|dark|both
--locale <id>             number/date formats, e.g. de_DE
--red-gains               red-is-up color convention (process-local; safe to run concurrently)
--scale 1|2               pixels per point (default 1)
--delay <seconds>         extra settle time (default 0.6)
--timing                  print time-to-settled and analysis-cache statistics (always on with --stress)

exit status: 0 ok · 64 bad arguments · 1 rendering/writing failed
```

How it works: the real `MainWindowView` is hosted in a real `NSWindow` that sits **below the desktop
picture** — composited by the window server, never visible, never key, and the process is never
activated (it runs as an accessory app: no Dock icon, no focus change). Sheets and popovers attach to
that window and stay invisible too. The runner waits until `store.isBusy` has been false for a moment
(plus `--delay`), then captures the window from the window server — toolbars, Liquid Glass, `Table`s
and charts included. A logged-in GUI session is required. The screenshot mode never touches the
network (no quote updater is installed).

A hidden debug target, `chart-gallery`, renders every component of the shared chart kit with the
portfolio's data (`--state page=time|bars|parts|grids|states`, `--state patterns=on`); it is not part
of `all`:

```sh
Scripts/shot.sh none chart-gallery /tmp/charts/ --appearance both --today 2026-06-30 --period ALL --state page=bars
```

`--onscreen` exists for debugging the capture itself (visible, frontmost window). **Do not use it in
automated or agent runs** — it takes the focus of whoever is using the Mac.

**For your screen to be captured correctly:** derive data through the store's analysis layer
(`analysisTask`, `store.analyze`, `store.compute` — they mark the store busy) or wrap other
asynchronous work in `await store.whileBusy { … }`; make the screen reflect `store.route.focus`,
`store.period`, `store.scope`, `store.today` and `store.launchState`.

## Self-test

Nobody can click through the app in an automated session (UI scripting would take the focus of
whoever is using the Mac). `Scripts/selftest.sh` is the next best thing: it drives the **real app
objects** end to end, invisibly, and exits with 0 or 1.

```sh
Scripts/selftest.sh                      # debug bundle: everything, about 7 minutes
Scripts/selftest.sh --quick              # without the stress portfolio and the deep tours, about 2 minutes
Scripts/selftest.sh release              # the sandboxed release bundle
Scripts/selftest.sh --verbose            # timing per step, other stderr output at the end
Scripts/selftest.sh --only tours         # one phase: scenario | documents | import | tours
Scripts/selftest.sh --no-document | --document-only
```

It runs two programs:

**1. `Kontor --selftest`** (in-process, windows below the desktop picture like the screenshot mode).
One line per step, `ok` or `FAIL` with the reason:

- **Scenario** — a starter document; accounts, a depot and securities through the editors' own save
  code; all 15 transaction kinds typed into the real `TransactionDraft` (including a foreign-currency
  purchase and a cross-currency transfer), validated and saved like the sheet does; cash balances and
  positions per depot checked against the engine; a savings plan and its due transactions; a quote
  update against a stub HTTP server through the real providers and parsers; a rebalancing proposal
  turned into transactions; then **every step undone and redone with the file compared at each step**.
- **Documents** — the document's write and read paths (saved, reopened, compared, byte-identical),
  the snapshot taken on a background thread while the main thread waits, JSON that is not a
  portfolio, unusable exchange rates, undo depth.
- **Import and export** — Portfolio Performance XML into an empty portfolio and merged into one with
  data (twice), CSV through the wizard with its automatic mapping (twice: the second import must
  find only duplicates), the CSV round trip, and — in debug — every Portfolio Performance fixture
  of the repository.
- **Hosted UI** — the real `MainWindowView` for the starter, demo, scenario and stress portfolios:
  every screen in every documented sub-view (`--state` variants), six periods and four scopes per
  screen, deep links with the inspector open, back and forward, every sheet request (all transaction
  kinds, all editors, import, export, the feature-private sheets), the palette, quote report, toast
  and confirmation layers, and an edit plus undo while each screen is mounted. A view that reads a
  missing environment object, throws during layout or never settles fails its step.
- **Runtime warnings** — everything the process wrote to standard error and to the unified log is
  searched for "Modifying state during view update", "Publishing changes from within view updates",
  AttributeGraph cycles, `NSTableView` re-entrancy, constraint conflicts, "tried to update multiple
  times per frame", layout recursion and logged exceptions; each hit is attributed to the step that
  was running. Two messages are expected and ignored: SwiftUI's note that scene storage is inert in
  a window that is not part of an `App` scene, and AppKit's one-time layout-recursion note when
  SwiftUI resizes the transaction editor's sheet (no frame of the app is on that stack).

Options of the binary: `--verbose`, `--quick`, `--today <day>`, `--fixtures <dir>` (import every
`.xml` in it), `--only <phase>`, and for the tours `--portfolio starter,demo,scenario,stress` and
`--parts screens,periods,links,sheets,layers,edits`.

**2. `Kontor --document-selftest <dir|auto>`** (a normal launch, started hidden and in the
background with `open -n -g -j`). Only a running document app has AppKit's `NSDocument` machinery,
so this part opens a file through the document controller and then: edit → document is edited →
**Save** → compare the file → **autosave** → undo/redo through the document's undo manager → a
change that bypasses undo → **Revert** after the file changed on disk → the window is wired to the
new store (undo manager, change tracking, services) → edit → Save → compare. A watchdog on a
background thread reports a blocked main thread as a failure instead of hanging.

To make a feature testable this way, expose what its sheet does as a function instead of a private
method of the view (`TransactionEditor.commit`, `AccountEditor.commit`, …) and add a small
`public enum <Feature>SelfTest` with hooks the shell calls (`Sources/Features/*/*SelfTest.swift`).

What the self-test cannot see: anything that needs a pointer or a key press (drag and drop, focus
order, context menus, shortcuts), open and save panels, and how things look — that is what the
screenshots are for.

## Repository layout

```
Package.swift                 root package "Kontor" (app); depends on Core/* by path; KONTOR_FEATURES
Core/Model                    KontorModel       — the shared data model (frozen contract)
Core/Engine                   KontorEngine      — every calculation (API.md)
Core/MarketData               KontorMarketData  — quote / FX providers, QuoteUpdater (API.md)
Core/Interchange              KontorInterchange — Portfolio Performance XML + CSV import/export (API.md)
Core/SampleData               KontorSampleData  — demo / starter / stress portfolios (API.md)
Sources/KontorUI              shared UI kit: store + analysis cache, routing, sheets, design system,
  API.md                      Fmt, controls, charts, help topics, registry  ← read it before writing a screen
  Charts/                     the shared chart kit (time series, bars, donut, sunburst, treemap, heatmap, …)
Sources/Features/<Name>       one library target per screen: Feature<Name>
Sources/Kontor                executable: app scenes, menus, sidebar, toolbar, palette, welcome,
                              settings, document type, consistency sheet, quote updates, screenshot
                              mode, self-test
Tests/KontorUITests           Swift Testing suite for KontorUI (store, analysis cache, formatting, …)
Tests/Feature<Name>Tests      one test target per feature (owned by that feature)
Resources/                    Info.plist, entitlements (sandboxed + development)
Scripts/                      bundle.sh, shot.sh, selftest.sh, run.sh, make-icon.swift
```

Dependency rules (declared in `Package.swift`):

| target | depends on |
|---|---|
| `KontorUI` | KontorModel, KontorEngine, KontorMarketData, KontorSampleData. **Re-exports KontorModel and KontorEngine** (`@_exported import`), so `import KontorUI` is enough for model and engine types. |
| every `Feature<Name>` | KontorUI, KontorModel, KontorEngine |
| `FeatureImport` | + KontorInterchange |
| `FeatureSecurities` | + KontorMarketData |
| `Feature<Name>Tests` | the feature, its dependencies, KontorSampleData |
| `Kontor` (executable) | everything, and the features selected by `KONTOR_FEATURES` |

Features never depend on each other or on the executable.

## The feature-module contract

Each screen lives in `Sources/Features/<Name>/` (+ `Tests/Feature<Name>Tests/`) and owns those
directories exclusively. Two source files exist from the start:

- `<Name>Screen.swift` — `public struct <Name>Screen: View { public init() }`. **Replace its body.**
- `<Name>Feature.swift` — `public enum <Name>Feature { static var module: FeatureModule }`, already
  registered by `Sources/Kontor/FeatureCatalog.swift`. Declare everything your feature contributes
  here. Keep the `typealias Transaction = KontorModel.Transaction` line (SwiftUI also has a
  `Transaction`).

While several people work on features in parallel, stay inside your two directories and report wishes
for shared code; KontorUI, the shell and `Core/*` are changed in integration passes.

### The workflow

```sh
export KONTOR_FEATURES=Earnings                                         # your feature, for this shell
swift build --scratch-path .build-earnings                              # must print no warnings
swift test  --scratch-path .build-earnings --filter FeatureEarningsTests

# render and LOOK at it — light and dark, fixed date
Scripts/shot.sh Earnings earnings /tmp/earnings/ --appearance both --today 2026-06-30
Scripts/shot.sh Earnings earnings /tmp/earnings-securities.png --today 2026-06-30 --state tab=securities
Scripts/shot.sh Earnings earnings /tmp/earnings-depot.png --today 2026-06-30 --scope depot:<uuid> --period 3Y
Scripts/shot.sh Earnings earnings /tmp/earnings-stress.png --stress     # must settle fast with 50,000 transactions
dist-earnings/Kontor.app/Contents/MacOS/Kontor --list-ids --demo --today 2026-06-30    # ids for --route/--scope
```

Never run `Scripts/run.sh`, `open`, `--onscreen` or `bundle.sh --verify` from an automated session:
someone is working on this Mac. `shot.sh` is invisible and is all you need.

### 1. Derive your model through the analysis layer

Screens do not compute on the main actor and do not build their own `Ledger`/`Analysis`. The store
owns a shared, memoizing analysis layer: one engine `Ledger` per document revision, one `Analysis`
per (scope, interval), results cached per key, concurrent requests de-duplicated, stale work
cancelled. `analysisTask` gives you "last good value + isLoading", so content never flashes.

```swift
import SwiftUI
import KontorUI          // re-exports KontorModel and KontorEngine

/// Plain, Sendable values — everything the view shows, computed off the main actor.
struct EarningsModel: Sendable {
    var total: Money
    var months: [(label: String, dividends: Int64)]
    var isEmpty: Bool { months.allSatisfy { $0.dividends == 0 } }

    init(_ analysis: Analysis) {
        let report = analysis.earnings                       // computed here, on a background thread
        total = Money(minor: report.total.net, currency: analysis.currency)
        months = report.months.map { (Fmt.month(year: $0.year, month: $0.month), $0.amounts.dividends) }
    }
}

public struct EarningsScreen: View {
    @Environment(PortfolioStore.self) private var store
    @State private var model = Loadable<EarningsModel>()
    @State private var tab = Tab.overview

    enum Tab: String { case overview, securities }

    public init() {}

    public var body: some View {
        Group {
            if let model = model.value, model.isEmpty {
                EmptyState("No Earnings Yet", symbol: "banknote", message: "Dividends and interest will appear here.") {
                    Button("New Transaction") { store.present(.newTransaction(TransactionPrefill(kind: .dividend))) }
                }
            } else if let model = model.value {
                HStack(spacing: DS.Spacing.xs) {
                    Text(Fmt.money(model.total)).font(.kontorHero).numeric()
                    HelpButton(.grossVersusNet)
                }
                .opacity(self.model.isRefreshing ? 0.6 : 1)   // last good value stays while recomputing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingOverlay(model.isInitialLoad)
        // Recomputes when the document, the window's scope or the reporting period change.
        .analysisTask($model, id: "earnings.model") { analysis in EarningsModel(analysis) }
        .toolbar { ToolbarItem { ScopePicker() } }
        .onAppear { tab = store.launchValue("tab", as: Tab.self) ?? tab }   // --state tab=securities
    }
}
```

(This exact code compiles.) The variants:

```swift
// View modifiers — keep a Loadable up to date (preferred)
.analysisTask($model, id: "allocation.model", variant: taxonomyID) { analysis in … }   // + extra inputs
.analysisTask($model, id: "dashboard.ytd", scope: .portfolio, interval: store.interval(for: .ytd)) { … }
.ledgerTask($rows, id: "securities.rows") { ledger in … }     // depends on the document only (lists)

// Async calls — for commands, sheets, exports
let summary = try await store.analyze("performance.summary") { analysis in Summary(analysis) }
let rows    = try await store.compute("securities.rows") { ledger in makeRows(ledger) }
let issues  = try await store.consistencyIssues()

store.ledger            // synchronous, built once per revision — cheap lookups only, no heavy work in body
```

Rules: the closure is `@Sendable`, pure, and runs on a background thread — touch every `analysis`
property you need **inside** it (they compute lazily) and return `Sendable` values. Namespace ids
with your feature (`"earnings.…"`); everything else the result depends on goes into `variant:`.
`CancellationError` means "superseded" — `try?` it.

### 2. Change data through the store

```swift
store.addTransaction(tx)                              // one undo step, "Undo Add Transaction"
store.updateSecurity(id) { $0.note = "…" }
store.confirmDeleteSecurities(selection)              // asks first only if anything refers to them
store.mutate("Apply Rebalancing") { file in … }       // arbitrary edits = ONE undo step; no-ops are free
```

Undo/redo, the document's edited state, autosave, Versions and cache invalidation follow
automatically (`store.revision` increases on every change).

### 3. Navigate, deep-link and open editors without knowing other features

```swift
store.navigate(to: .security(id))                        // Securities, focused on that security
store.navigate(to: .account(id))                         // Accounts          (.depot(id) too)
store.navigate(to: .transaction(id))                     // Transactions, reveals that entry
store.navigate(to: .plan(id))                            // Plans
store.navigate(to: .classification(taxonomy: t, id: c))  // Allocation        (.taxonomy(t) too)
store.navigate(to: Route(.performance, focus: .security(id)))   // any screen + any focus
store.setFocus(.transaction(id))                         // "this is selected here" (inspector follows; no history entry)

store.present(.newTransaction(TransactionPrefill(kind: .buy, date: store.today, securityID: id, depotID: depot,
                                                 shares: Shares(10), amount: Money(minor: 123_456, currency: "EUR"))))
store.present(.editTransaction(id))                      // whichever feature owns the editor provides it
store.present(.importFile(url));  store.present(.export(ExportRequest(.transactions(only: ids))))
store.toast("Copied 12 rows", style: .success)
```

**Routing contract — every screen:** when `store.route.focus` names an entity you show, select and
reveal it (`store.route.securityID`, `.accountID`, `.depotID`, `.transactionID`, `.planID`,
`.taxonomyID`, `.classificationID`); when the user changes the selection, call `store.setFocus(…)`.

| route | screen that must honour it |
|---|---|
| `.security(id)` | Securities (select + show details) |
| `.account(id)`, `.depot(id)` | Accounts |
| `.transaction(id)` | Transactions (clear filters if needed, select, scroll to it) |
| `Route(.transactions, focus: .security(id) / .account(id) / .depot(id))` | Transactions (lists exactly that entity's entries — "Show Transactions") |
| `Route(.performance, focus: .security(id))`, `Route(.trades, focus: .security(id) / .transaction(id))` | Performance (Securities section), Trades (selects the trade) |
| `.plan(id)` | Plans |
| `.taxonomy(id)`, `.classification(taxonomy:id:)` | Allocation |

**Sheet ownership** — any feature may *request* (`store.present`), the owner *provides* the view via
`FeatureModule.sheet`; unclaimed requests show the shell's placeholder sheet:

| request | owner |
|---|---|
| `.newTransaction(TransactionPrefill)`, `.editTransaction(id)` | FeatureTransactions |
| `.newSecurity(SecurityPrefill)`, `.editSecurity(id)` | FeatureSecurities |
| `.newAccount(AccountPrefill)`, `.editAccount(id)`, `.newDepot(DepotPrefill)`, `.editDepot(id)` | FeatureAccounts |
| `.newPlan(PlanPrefill)`, `.editPlan(id)` | FeaturePlans |
| `.importFile(URL?)`, `.export(ExportRequest)`, `.custom("import.export")`, `.custom("import.file")` (payload `path`, `target`) | FeatureImport (a build without it falls back to the shell's JSON export) |
| `.portfolioSettings`, `.consistencyReport` | the shell |
| `.custom(id:payload:)` | whoever claims the id — in use: `dashboard.gallery`, `dashboard.widget`, `allocation.split`, `allocation.rebalance-review`, `securities.split`, `transactions.change-date`, `plans.generate`, `import.export`, `import.file` |

### 4. Contribute to the shell (in `<Name>Feature.swift`)

```swift
public enum EarningsFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.earnings) { EarningsScreen() }
            .commands { store in
                [PaletteCommand(id: "earnings.copy", title: "Copy Earnings as TSV", symbol: "doc.on.doc") {
                    Pasteboard.copy(EarningsExport.tsv(store.file))
                }]
            }
            .inspector { EarningsInspector() }
            .sheet { request in                      // `if case` chain WITHOUT a final else
                if case .custom(id: "earnings.forecast", _) = request { ForecastSheet() }
            }
    }
}
```

### 5. Launch state (`--state key=value`) — make every sub-view reachable for screenshots

Reviewers only see your UI through screenshots, so every tab, mode and sub-view needs a key.
`--state` arguments arrive in `store.launchState: [String: String]` (empty in normal use). Read it
**once, in `onAppear`**, to set your initial `@State`:

```swift
.onAppear {
    tab = store.launchValue("tab", as: Tab.self) ?? tab             // --state tab=rebalancing
    if let id = store.launchValue("taxonomy").flatMap(UUID.init(uuidString:)) { taxonomyID = id }
    showsChart = store.launchValue("chart") != "off"                // --state chart=off
}
```

Conventions: keys are lowercase; `tab`, `mode`, `sort`, `filter`, `group`, `selection` are the usual
names. Only the active screen reads them, so no prefix is needed. **List your keys and values in a
doc comment on your `<Name>Screen`** and in your final report. Entity focus comes from `--route`,
scope from `--scope`, period from `--period` — do not duplicate those as state keys.

### 6. Look and feel

Use the kit — the shared **chart kit** for every chart (`TimeSeriesChart`, `BarSeriesChart`, `DonutChart`,
`SunburstChart`, `TreemapChart`, `HeatmapGrid`, `WaterfallChart`, `DistributionChart`, `TargetActualBar`,
`Sparkline`; never your own Canvas/Swift Charts code — see "Charts" in the API reference),
`Fmt` for every number and date (never ad-hoc formatters), `GainText`/`DeltaLabel` for
signed values, `Card`/`StatTile`/`SectionHeader`/`EmptyState`, `DS.Spacing`/`DS.Radius`,
`CategoryPalette` for chart categories, `\.gainStyle` for gain/loss colors, the input controls for
forms, the table guideline for lists, `HelpButton(.ttwror)` next to every finance term,
`PeriodPicker`/`ScopePicker` for period and scope. All documented with examples in
[`Sources/KontorUI/API.md`](Sources/KontorUI/API.md).

The shell's toolbar already has back/forward, the period picker, Update Quotes, "+", search and the
inspector toggle. Your `.toolbar { }` items appear next to them — add `ScopePicker(store: store)`
there if your screen is scope-aware. Toolbar items, table cells and selection context menus are
hosted outside your view tree: hand them the store instead of reading it from the environment.

### Do / Don't

| Do | Don't |
|---|---|
| Build with `KONTOR_FEATURES=<You>` and `--scratch-path .build-<you>` (or `Scripts/shot.sh`) | Build into `.build/` while others work, or edit `Package.swift` |
| Stay inside `Sources/Features/<You>/` and `Tests/Feature<You>Tests/` | Touch KontorUI, the shell, Core packages or another feature (they are frozen — report wishes instead) |
| `analysisTask` / `store.analyze` / `store.compute`, keyed by a namespaced id | `Ledger(store.file)` / `Analysis(…)` in a view, engine calls in `body`, `Task.detached` with your own caching |
| Return small `Sendable` row/model structs from the work closure | Hand engine objects to views and read lazy properties on the main actor |
| Show `model.value` while `isRefreshing`; spinner only for `isInitialLoad` | Clear content while recomputing |
| `store.mutate("Name") { }` — one undo step per user action | Confirmation dialogs for undoable actions; multiple undo steps for one action |
| `store.present(.editSecurity(id))`, `store.navigate(to: .security(id))` | `import FeatureSecurities`, or building another feature's editor |
| Honour `store.route.focus`, `store.scope`, `store.periodInterval`, `store.today`, `store.launchState` | `Day.today` / `Date()` for valuations (breaks `--today`), private period/scope state without reason |
| `Fmt.…`, `.numeric()`, `\.gainStyle`, `HelpButton` | `NumberFormatter`, `String(format:)`, hard-coded green/red |
| The chart kit (`TimeSeriesChart`, `BarSeriesChart`, `DonutChart`, …) fed with `Sendable` values from `analysisTask` | `import Charts`, hand-drawn charts, chart data computed in `body` |
| `Scripts/shot.sh … --today 2026-06-30`, then look at the PNG (light + dark, `--stress`) | `Scripts/run.sh`, `open`, `--onscreen`, `bundle.sh --verify`, `screencapture`, UI scripting |
| Network only via `store.updateQuotes` (shell-installed updater; absent in screenshot mode and tests) | Own `URLSession` calls from a screen |
| `@State` as the source of truth, mirrored into `@SceneStorage("<feature>.key")` for state that should survive relaunch (scene storage is inert in the screenshot window) | Unprefixed scene-storage / `@AppStorage` keys; seeding `@SceneStorage` from `launchState` |
| Create a `Table` only once its rows exist; pass the store into cells, toolbar items and selection context menus; give a `Table` a new `.id` when a result adds many rows at once (a cleared filter) | `@Environment(PortfolioStore.self)` inside table cells, toolbar items or selection context menus; mounting an empty `Table` and filling it later, or letting a live `Table` take hundreds of new rows (AppKit re-entrancy warning) |
| `Table` or a `LazyVStack` in a `ScrollView` for collections that can exceed about 100 rows | `List` for long collections (on macOS 27 it logs an `NSTableView` re-entrancy warning when first filled) |
| Expose what a sheet's Save does as a function and add a `<Feature>SelfTest` hook, so `Scripts/selftest.sh` can drive it | Logic that exists only inside a private method of a view |

## App shell reference

- **Documents:** `DocumentGroup` + `ReferenceFileDocument` (`KontorDocument`) → Open, Save, Autosave,
  Revert, Versions, Duplicate, Recents, window tabs and undo come from the system. UTI
  `app.kontor.portfolio` (conforms to `public.json`), bundle id `app.kontor.Kontor`.
  `.xml`/`.portfolio`/`.csv` files opened with Kontor are routed to the importer
  (`store.present(.importFile(url))`) instead of being opened as documents.
  - *Saving never waits for the main thread.* AppKit takes the snapshot on a background thread while
    the main thread is blocked; the store mirrors every change into a lock-protected `FileSnapshot`
    that `KontorDocument.snapshot` reads.
  - *The window follows the document instance.* Revert, restoring a version and an external change
    hand the window a new document and store; the content is keyed by the document, so undo
    manager, change tracking, services and state restoration are wired again.
  - *Reading is strict, writing is forgiving* (`DocumentIO` in KontorUI): JSON without a format
    version or any portfolio collection, a `null` or misspelt collection and a format version below
    1 are refused with a message instead of opening as an empty portfolio. Exchange rates that are
    zero, negative or not a number are dropped on open (a toast says so) and can never make a
    document unsaveable. Unknown top-level keys are not preserved across a save.
  - *Undo depth is bounded:* 100 steps, fewer for very large files (each step keeps a copy of the
    collections it changed — about 12 MB per transaction edit with 50,000 transactions; such a file
    keeps 15 steps).
- **Welcome window** at launch when no document is restored: New Portfolio (name + base currency →
  `SampleData.starterPortfolio`), Open…, Open Demo Portfolio (`SampleData.demoPortfolio`), Import
  from Portfolio Performance…, recents. An import into the untouched starter document makes the file
  its content ("Import into This Portfolio"); "Open as New Portfolio" closes the untouched host
  window.
- **Main window:** sidebar (Overview · Analysis · Data · Tools), feature screen, optional inspector,
  toolbar (back/forward, period, update quotes, "+", search, inspector + the screen's own items),
  ⌘K command palette, toasts. Route, period, scope and inspector state are restored per window.
  While a sheet is open, the menu commands that navigate, open the palette or open further sheets
  are disabled.
- **Quote updates:** toolbar button / ⌘R / Portfolio ▸ Update Quotes, and automatically when a
  portfolio opens (Settings ▸ Market Data; optional 30-minute refresh). Progress shows in the toolbar
  button ("Updating quotes 3/14", click to cancel); failures are listed per security in a popover
  with "Show" links and "Retry Failed". An update **you** start is **one undoable step** ("Undo
  Update Quotes"); an automatic one marks the document as edited but never becomes an undo step and
  never clears the redo stack. An update that finds nothing new leaves the document untouched.
  Securities without a feed, with a manual feed and retired ones are never requested; a portfolio
  with more than one currency fetches exchange rates even without any quote feed (also right after
  an import). Closing a window cancels its download. One `QuoteUpdater` (KontorMarketData) is shared
  by all windows.
- **Check Consistency** (⇧⌘K): the engine's `ConsistencyChecker` findings grouped by severity; "Show"
  navigates to the transaction, security, account or depot concerned.
- **Shortcuts:** ⌘1…⌘9/⌘0 screens · ⌘K palette · ⌘[ ⌘] history · ⌥⌘I inspector · ⌥⌘1…5 period ·
  ⇧⌘N transaction · ⌥⌘N security · ⌃⌘N account · ⌘R update quotes · ⇧⌘K check consistency ·
  ⌥⌘, portfolio settings · ⇧⌘I import · ⇧⌘E export · ⌘, app settings.
  Screen-level conventions: ⌃1…⌃6 switch a screen's sections (Performance, Earnings, Trades,
  Securities) · ⌘F quick filter · ⌘E edit (dashboard layout, selected security) · Return opens/edits ·
  Delete deletes (undoable) · ⌘C copies rows as TSV · ⌘D duplicate (Transactions) ·
  ⌃⌘B / ⇧⌃⌘S / ⌃⌘D / ⌃⌘T buy, sell, dividend, show transactions for the selected holding (⌃⌘S alone
  is the system's sidebar toggle) · ⌃⌘D/⌃⌘I/⌃⌘E record dividend, interest, export (Earnings) ·
  ⌘T statement for today (Holdings) · ⇧⌘G generate due plan transactions · ⌘↑ back to the accounts
  overview · ⌃⌘↑↓←→ move/indent classifications · ⌘↩ save, ⇧⌘↩ save & new, ⌃⌥K opens the kind
  list and ⌃⌥-letter picks a kind (transaction editor; plain ⌃-letter belongs to text editing).
  Two of these collide with system shortcuts when those are enabled: ⌃⌘D (Look Up) and ⌃1…⌃6
  (Mission Control "Switch to Desktop n").
- **Appearance** (Settings ▸ General) is applied by the app delegate for the whole process, with or
  without the welcome window.
- **File drop:** a `.kontor` file dropped on a screen opens as a document; `.xml`, `.portfolio` and
  `.csv` files go to the importer.
- **Settings:** app-level preferences (`AppPreferences.Key`, `@AppStorage`) in the Settings window;
  document-level settings (base currency, cost method, risk-free rate, benchmarks) in
  Portfolio ▸ Portfolio Settings…, stored in the file.
- **Where things are wired** (all in `Sources/Kontor`): `FeatureCatalog.makeRegistry()` — feature
  modules by `#if canImport`; `ShellContext.installServices(on:network:)` — import panel and the
  shared `QuoteUpdater`; `KontorApp.swift` (`DocumentWindow` / `DocumentContent`) — store ↔ window
  wiring; `SheetHost` — feature sheets, shell sheets, placeholder; `ScreenshotRunner` — the headless
  screenshot mode; `SelfTest` / `DocumentSelfTest` — the self-test.

## Known limitations

Verified by the self-test, the test suites and screenshots; **never driven by hand** — nothing that
needs a pointer, a key press or a system panel has been exercised.

- **Not exercised:** drag and drop, keyboard shortcuts and focus order, context menus, open/save
  panels (sandboxed or not), Finder double-click, Versions browser, VoiceOver and Full Keyboard
  Access. Heatmap, treemap, waterfall, donut and sunburst selection is pointer-only.
- **Documents:** unknown top-level keys of a file are dropped on the next save. Undo steps are whole
  snapshots (bounded in number, not in bytes). Undo and Redo stay enabled while an editor sheet is
  open. Reverting in the very instant a file is replaced on disk has been seen to fail with "not in
  the correct format"; a moment later it works.
- **Numbers:** the cost basis excludes purchase taxes (Portfolio Performance includes them). A
  security's annualized TTWROR is annualized over the whole period even if it was held for part of
  it. Very short trades show an astronomically large annualized return. A classification scope and
  the same group in a taxonomy can differ by cents (two apportioning rules). Same-day entries
  without a time of day are ordered by id, except where that would produce a short position.
- **Import:** no PDF import. Quote CSV files hold one security. Exchange rates are not read from
  Portfolio Performance files (they are downloaded afterwards). Portfolio Performance attributes of
  accounts, depots and plans, `latestFeed` settings, a plan's "generate automatically" switch and
  client properties are dropped without a note. The CSV transactions export has no column for a
  security's currency or a dividend's ex-date. The import report cannot be reopened after importing.
- **Plans:** pausing a plan overwrites its end date (the model has no pause state). The stress
  sample has no plans.
- **Screens:** names in dense tables are truncated in the middle (full name in the tooltip); at
  900 pt width the Securities detail header and the Transactions table are cut off rather than
  reflowed; a total row scrolls with its table. A flat chart series gets a wide default axis. The
  Dashboard does not flag outdated quotes beyond the sidebar footer. There is no place to enter an
  exchange rate by hand.
- **Wording:** a pass over vocabulary (one gain figure has several names across screens, portfolio
  share is called Weight, Share and Actual) and a shared section-tab, filter-field and inspector
  layout is still to do. Strings are not localisable yet (English only; numbers and dates follow
  the region).
