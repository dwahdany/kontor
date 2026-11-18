# Kontor

Kontor is a native macOS portfolio tracker: securities, cash accounts and honest performance
measurement in one fast, calm, keyboard-friendly app. Documents are plain JSON (`.kontor`), so your
data stays portable, diff-able and yours.

Kontor is an original app. It can import files from other tools (Portfolio Performance XML, CSV) but
shares no code or design with them.

- **Target:** macOS 27, Swift 6 (strict concurrency), SwiftPM only — no Xcode project.
- **Status:** the app shell and UI kit are complete; the eleven feature screens are placeholders
  that feature teams replace one by one.

## Build, run, bundle

```sh
swift build                     # compile everything (root package)
swift test                      # KontorUI unit tests (store, formatting, fuzzy matching, registry)

Scripts/run.sh                  # build the debug bundle and launch it
Scripts/run.sh file.kontor      # … and open a document (or hand a .csv/.xml to the importer)

Scripts/bundle.sh               # → dist/Kontor.app (debug): hardened runtime, NOT sandboxed
Scripts/bundle.sh release       # → dist/Kontor.app (release): hardened runtime + App Sandbox
Scripts/bundle.sh debug --sandbox | release --no-sandbox | … --no-verify
```

`bundle.sh` builds, assembles the bundle (Info.plist with document types, generated icon), signs it
ad hoc and verifies that it launches and stays alive. Always run the app from the bundle: document
types, the `.kontor` UTI and the icon come from `Resources/Info.plist`, which a bare
`swift run Kontor` does not have.

Why debug is not sandboxed: the screenshot mode below writes to arbitrary paths, which the App
Sandbox forbids. The release bundle is sandboxed (user-selected files read/write + outgoing
network); there, use `--out -` / `--open -` (stdout/stdin).

## Headless screenshots

Every screen can be rendered to a PNG without touching the UI — this is how changes are reviewed.

```sh
APP=dist/Kontor.app/Contents/MacOS/Kontor

$APP --screenshot holdings --demo --out /tmp/holdings.png
$APP --screenshot holdings --demo --appearance dark --size 1440x900 --out /tmp/holdings-dark.png
$APP --screenshot all --demo --appearance both --out /tmp/shots/        # every target, light + dark
$APP --screenshot securities --open my.kontor --route security:<uuid> --inspector --out /tmp/s.png
$APP --screenshot palette --demo --query "div" --out /tmp/palette.png
$APP --screenshot dashboard --demo --out - > dashboard.png               # stdout (works sandboxed)
$APP --write-demo /tmp/demo.kontor --pretty                              # the demo portfolio as a file
$APP --help
```

```
Kontor --screenshot <target> --out <file.png | directory | -> [options]

targets   dashboard holdings performance allocation earnings trades securities transactions
          accounts plans import          (feature screens)
          welcome palette settings portfolio-settings consistency      (shell surfaces)
          all                            (everything; --out is a directory, files <target>[-light|-dark].png)

--demo                    built-in demo portfolio (deterministic, stable entity ids)
--open <file.kontor>      a portfolio file ("-" = stdin)
--size <W>x<H>            window size in points (default 1440x900)
--appearance light|dark|both
--route <route>           security:<uuid> | account:<uuid> | depot:<uuid> | transaction:<uuid> |
                          plan:<uuid> | taxonomy:<uuid> | <screen>/<kind>:<uuid>
--period <p>              1M 3M 6M YTD MTD QTD 1Y 3Y 5Y 10Y ALL or a year (2024)
--today <YYYY-MM-DD>      fix "today" (reproducible renders)
--locale <id>             number/date formats, e.g. de_DE
--inspector               show the inspector
--query <text>            pre-fill the command palette (target "palette")
--red-gains               red-is-up color convention
--toast <text>            show a toast        --activity "Updating quotes 3/14"   show progress
--scale 1|2               pixels per point (default 1)
--delay <seconds>         extra settle time (default 0.6)

exit status: 0 ok · 64 bad arguments · 1 rendering/writing failed
```

How it works: the real `MainWindowView` is hosted in a real `NSWindow`, the runner waits until
`store.isBusy` has been false for a moment (plus `--delay`), then captures the window as composited
by the window server — toolbars, Liquid Glass, `Table`s and charts included. The window appears
briefly on screen and the app takes focus while capturing; a logged-in GUI session is required.

**For your screen to be captured correctly:** do asynchronous work inside
`await store.whileBusy { … }` (or `beginBusy()/endBusy()`), and make the screen reflect
`store.route.focus`, `store.period` and `store.today`.

Demo entity ids for `--route` (stable across runs): run `--write-demo f.kontor --pretty` and look
them up, e.g. Global Equity Index ETF = `security:9CEC8EFD-D49F-4BA6-A4FD-236DD1D7AAFA`.

## Repository layout

```
Package.swift                 root package "Kontor" (app); depends on Core/* by path
Core/Model                    KontorModel       — the shared data model (frozen contract)
Core/Engine                   KontorEngine      — calculations
Core/MarketData               KontorMarketData  — quote / FX providers
Core/Interchange              KontorInterchange — import / export
Core/SampleData               KontorSampleData  — demo portfolio generator
Sources/KontorUI              shared UI kit: store, routing, design system, Fmt, controls, registry
  API.md                      ← the UI kit reference; read it before writing a screen
Sources/Features/<Name>       one library target per screen: Feature<Name>
Sources/Kontor                executable: app scenes, menus, sidebar, toolbar, palette, welcome,
                              settings, document type, screenshot mode
Tests/KontorUITests           Swift Testing suite for KontorUI
Resources/                    Info.plist, entitlements (sandboxed + development)
Scripts/                      bundle.sh, run.sh, make-icon.swift
```

Dependency rules: `Feature*` → `KontorUI` + `KontorModel` (later also the Core packages they
need). Features never depend on each other or on the executable. `KontorUI` depends on
`KontorModel` only.

## The feature-module contract

Each screen lives in `Sources/Features/<Name>/` and owns that directory exclusively. Two files exist
from the start:

- `<Name>Screen.swift` — `public struct <Name>Screen: View { public init() }`. **Replace its body.**
- `<Name>Feature.swift` — `public enum <Name>Feature { static var module: FeatureModule }`, already
  listed in `Sources/Kontor/FeatureCatalog.swift`. Declare everything your feature contributes here.

You never need to edit files outside your directory.

### 1. Read the store, key work on `revision`

```swift
import SwiftUI
import KontorModel
import KontorUI

public struct EarningsScreen: View {
    @Environment(PortfolioStore.self) private var store
    @State private var model: EarningsModel?

    public init() {}

    private struct Inputs: Equatable { var revision: Int; var period: ReportingPeriod; var today: Day }

    public var body: some View {
        Group {
            if let model, model.isEmpty {
                EmptyState("No Earnings Yet", symbol: "banknote", message: "Dividends and interest will appear here.") {
                    Button("New Transaction") { store.present(.newTransaction(TransactionPrefill(kind: .dividend))) }
                }
            } else if let model {
                EarningsContent(model: model)
            }
        }
        .loadingOverlay(model == nil)
        .task(id: Inputs(revision: store.revision, period: store.period, today: store.today)) {
            let file = store.file, interval = store.periodInterval      // cheap value snapshots
            model = await store.whileBusy {
                await Task.detached(priority: .userInitiated) { EarningsModel(file: file, interval: interval) }.value
            }
        }
    }
}
```

- `store.file` is read-only; `store.revision` changes on every edit, undo, redo and reload.
- Heavy work goes off the main actor (`PortfolioFile` is `Sendable`); wrap it in `whileBusy`.
- Look entities up with `store.security(id)`, `store.account(id)`, … (O(1)).

### 2. Change data through the store

```swift
store.addTransaction(tx)                              // one undo step, "Undo Add Transaction"
store.updateSecurity(id) { $0.note = "…" }
store.confirmDeleteSecurities(selection)              // asks first if anything refers to them
store.mutate("Apply Rebalancing") { file in … }       // arbitrary edits; no-ops are free
```

Undo/redo, the document's edited state, autosave and Versions follow automatically.

### 3. Navigate and open editors without knowing other features

```swift
store.navigate(to: .security(id))                     // go to Securities, focused on that security
store.setFocus(.transaction(id))                      // tell the inspector what is selected here
store.present(.editTransaction(id))                   // whichever feature owns the editor provides it
store.toast("Copied 12 rows", style: .success)
```

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
            .sheet { request in
                if case .custom(id: "earnings.forecast", _) = request { ForecastSheet() }
            }
    }
}
```

Sheet ownership: Transactions → `.newTransaction` / `.editTransaction`; Securities → `.newSecurity` /
`.editSecurity`; Accounts → `.newAccount` / `.editAccount` / `.newDepot` / `.editDepot`; Plans →
`.newPlan` / `.editPlan`; Import → `.importFile`. The shell provides `.portfolioSettings` and
`.consistencyReport` and shows a placeholder for unclaimed requests.

### 5. Look and feel

Use the kit — `Fmt` for every number and date, `GainText`/`DeltaLabel` for signed values,
`Card`/`StatTile`/`SectionHeader`/`EmptyState`, `DS.Spacing`/`DS.Radius`, `CategoryPalette` for
chart categories, `\.gainStyle` for gain/loss colors, the input controls for forms and the table
guideline for lists. All of it is documented with examples in
[`Sources/KontorUI/API.md`](Sources/KontorUI/API.md).

House rules: tabular digits for numbers (`.numeric()`); color only for meaning; never hard-code
green/red; everything reachable by keyboard; respect Reduce Motion, Increase Contrast and
Differentiate Without Color; toolbar items go in `.toolbar { }` on your screen (they appear next to
the shell's period picker, quotes, "+" and search); screen-local view state that should survive
relaunch uses `@SceneStorage` with a `"<feature>."` key prefix.

`Transaction` note: SwiftUI also has a type named `Transaction`. Each feature target contains
`typealias Transaction = KontorModel.Transaction` (in `<Name>Feature.swift`) so the bare name means
the ledger entry — keep that line.

### 6. Verify

```sh
swift build && swift test
Scripts/bundle.sh debug --no-verify
dist/Kontor.app/Contents/MacOS/Kontor --screenshot earnings --demo --appearance both --out /tmp/earnings/
```

Look at the PNGs in light and dark.

## App shell reference

- **Documents:** `DocumentGroup` + `ReferenceFileDocument` (`KontorDocument`) → Open, Save, Autosave,
  Revert, Versions, Duplicate, Recents, window tabs and undo come from the system. UTI
  `app.kontor.portfolio` (conforms to `public.json`), bundle id `app.kontor.Kontor`.
  `.xml`/`.portfolio`/`.csv` files opened with Kontor are routed to the importer
  (`store.present(.importFile(url))`) instead of being opened as documents.
- **Welcome window** at launch when no document is restored: New Portfolio (name + base currency),
  Open…, Open Demo Portfolio, Import from Portfolio Performance…, recents.
- **Main window:** sidebar (Overview · Analysis · Data · Tools), feature screen, optional inspector,
  toolbar (back/forward, period, update quotes, "+", search, inspector), ⌘K command palette, toasts.
- **Shortcuts:** ⌘1…⌘9/⌘0 screens · ⌘K palette · ⌘[ ⌘] history · ⌥⌘I inspector · ⌥⌘1…5 period ·
  ⇧⌘N transaction · ⌥⌘N security · ⌃⌘N account · ⌘R update quotes · ⇧⌘K check consistency ·
  ⌥⌘, portfolio settings · ⇧⌘I import · ⇧⌘E export · ⌘, app settings.
- **Settings:** app-level preferences (`AppPreferences.Key`, `@AppStorage`) in the Settings window;
  document-level settings (base currency, cost method, risk-free rate, benchmarks) in
  Portfolio ▸ Portfolio Settings…, stored in the file.
- **Integration seams** (all in `Sources/Kontor`): `ShellContext.installServices(on:)` — install
  `store.services.updateQuotes` (KontorMarketData) and replace the JSON export (KontorInterchange);
  `DemoPortfolio.make(today:)` — swap for KontorSampleData; `FeatureCatalog.makeRegistry()` — the
  list of feature modules.
