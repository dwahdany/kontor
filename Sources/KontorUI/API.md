# KontorUI — UI kit reference

Everything a feature screen needs: the store, navigation, formatting, design system, input
controls and the registration seam. `import KontorUI` (plus `KontorModel` and `SwiftUI`).

Contents: [Store](#portfoliostore) · [Navigation](#navigation) · [Sheets, confirmations, toasts, activity](#sheets-confirmations-toasts-activity) ·
[Feature registry](#feature-registry) · [Formatting](#formatting-fmt) · [Design system](#design-system) ·
[Components](#components) · [Input controls](#input-controls) · [Tables](#tables) · [Utilities](#utilities)

> **`Transaction` is ambiguous** in files that import both SwiftUI and KontorModel (SwiftUI has its
> own `Transaction`). Every feature target already contains
> `typealias Transaction = KontorModel.Transaction` (in `<Name>Feature.swift`), so the bare name
> works inside your module. `Txn` is a public alias exported by KontorUI.

---

## PortfolioStore

`@MainActor @Observable final class PortfolioStore` — one per open document, injected into the
environment by the shell.

```swift
@Environment(PortfolioStore.self) private var store
```

### Reading

| Member | Meaning |
|---|---|
| `file: PortfolioFile` | The document (read-only; mutate via `mutate`). |
| `revision: Int` | +1 on every change of `file` (edits, undo/redo, reload). **Key recomputation on it.** |
| `today: Day` | Valuation date (fixed in screenshot mode). |
| `period: ReportingPeriod` | Global reporting period (toolbar picker). Settable. |
| `periodInterval: ClosedRange<Day>` | `period` resolved against `today` and `inception`. |
| `inception: Day?` | Date of the first transaction. |
| `baseCurrency: CurrencyCode` | `file.settings.baseCurrency`. |
| `security(_:)`, `account(_:)`, `depot(_:)`, `transaction(_:)`, `plan(_:)` | O(1) id → entity lookups (accept `UUID?`). Caches rebuild lazily per revision. |
| `transactions(forSecurity:)`, `transactions(forAccount:)`, `transactions(forDepot:)` | Indexed, in file order. Account/depot variants include transfer counterparts. |

### The recomputation pattern

Compute off the main actor, keyed on everything the result depends on. `whileBusy` drives loading
indicators and tells the headless screenshot mode when the screen has settled.

```swift
struct HoldingsScreen: View {
    @Environment(PortfolioStore.self) private var store
    @State private var model: HoldingsModel?

    private struct Inputs: Equatable { var revision: Int; var period: ReportingPeriod; var today: Day }

    var body: some View {
        content
            .loadingOverlay(model == nil)
            .task(id: Inputs(revision: store.revision, period: store.period, today: store.today)) {
                let file = store.file, interval = store.periodInterval   // value snapshots
                model = await store.whileBusy {
                    await Task.detached(priority: .userInitiated) { HoldingsModel(file, interval) }.value
                }
            }
    }
}
```

### Mutating

```swift
// One undo step named "Add Transaction"; bumps revision; marks the document edited.
store.addTransaction(tx)

// Arbitrary edits: body receives a copy; if the result equals the current file nothing happens
// (no revision bump, no undo step). Returns true if the file changed.
store.mutate("Rebalance") { file in
    file.transactions.append(contentsOf: orders)
    file.taxonomies[0].root[1].targetWeight = 2_500
}

// Bulk background changes (quote updates): dirty the document, skip the undo stack.
store.mutate("Update Quotes", undoable: false) { file in … }
store.updateSecurity(id, actionName: "Update Quotes", undoable: false) { $0.prices.merge(points) }
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
reference account; `deleteDepots` removes their transactions and plans. Because that is
destructive, ask first — `confirmDelete…` does it for you (shows a dialog only if something
refers to the entities, deletes immediately otherwise):

```swift
store.confirmDeleteSecurities(selection)
// or by hand:
let usage = store.usage(ofSecurities: ids)        // EntityUsage(transactions:plans:classifications:watchlists:depots:)
store.confirm(ConfirmationRequest(title: "Delete?", message: usage.summary) { store.deleteSecurities(ids) })
```

### ReportingPeriod

`typealias ReportingPeriod = UIReportingPeriod` — the seam to the engine's future period type; always
write `ReportingPeriod`.

```swift
enum UIReportingPeriod: Hashable, Codable, Sendable {
    case trailingMonths(Int), monthToDate, quarterToDate, yearToDate, calendarYear(Int), allTime, custom(from: Day, to: Day)
    static let presets: [Self]                                    // 1M 3M 6M YTD 1Y 3Y 5Y All
    var shortTitle: String                                        // "1Y", "YTD", "2023", "All"
    var title: String                                             // "1 Year", "Year to Date"
    func interval(today: Day, inception: Day?) -> ClosedRange<Day>
}
```

`interval.lowerBound` is the *reference day* whose closing value opens the period (Dec 31 for YTD),
`upperBound` the last day included.

---

## Navigation

```swift
enum AppScreen: String, CaseIterable   // dashboard, holdings, performance, allocation, earnings, trades,
                                       // securities, transactions, accounts, plans, import
    var title, summary, symbol: String; var section: Section; var shortcutKey: KeyEquivalent?   // ⌘1…⌘9, ⌘0

struct Route: Hashable, Codable { var screen: AppScreen; var focus: Focus? }
enum Route.Focus { security(UUID), account(UUID), depot(UUID), transaction(UUID), plan(UUID),
                   taxonomy(UUID), classification(taxonomy: UUID, id: UUID) }
```

```swift
store.navigate(to: .security(id))                       // Securities screen, that security focused
store.navigate(to: .holdings)                           // AppScreen overload
store.navigate(to: Route(.performance, focus: .security(id)))
store.setFocus(.transaction(id))                        // selection changed inside your screen (no history entry)
store.route                                             // observe: react to route.focus (select/scroll to it)
store.goBack(); store.goForward(); store.canGoBack; store.canGoForward
```

Conveniences: `Route.security(_:)`, `.account(_:)`, `.depot(_:)` → Accounts, `.transaction(_:)`,
`.plan(_:)`, `.taxonomy(_:)` → Allocation. Text form (`Route(string:)` / `stringValue`):
`holdings`, `security:<uuid>`, `performance/security:<uuid>`.

**Contract for screens:** when `store.route.focus` names an entity you show, select and reveal it;
when the user changes the selection, call `store.setFocus(…)` so the inspector follows. A focus
whose entity disappears (delete, undo) is cleared automatically.

---

## Sheets, confirmations, toasts, activity

```swift
store.present(.newTransaction(TransactionPrefill(kind: .buy, securityID: id)))
store.present(.editSecurity(id))
store.present(.importFile(url))            // nil → importer asks for a file
store.present(.custom(id: "allocation.rebalance", payload: ["taxonomy": id.uuidString]))
store.dismissSheet()                       // call from your sheet when done (next queued request follows)
```

`SheetRequest`: `.newTransaction(TransactionPrefill)`, `.editTransaction(UUID)`, `.newSecurity`,
`.editSecurity(UUID)`, `.newAccount`, `.editAccount(UUID)`, `.newDepot`, `.editDepot(UUID)`, `.newPlan`,
`.editPlan(UUID)`, `.importFile(URL?)`, `.portfolioSettings`, `.consistencyReport`,
`.custom(id:payload:)`. Any feature may *request*; the owning feature *provides* the view through its
`FeatureModule.sheet` (see below). Unclaimed requests show a placeholder.

```swift
store.toast("Imported 208 transactions", style: .success)          // .info .success .warning .error
store.show(Toast("Export failed", message: error.localizedDescription, style: .error, duration: 6))

store.beginActivity("Updating quotes", total: 14)                   // toolbar + sidebar progress
store.updateActivity(completed: 3)                                  // "Updating quotes 3/14"
store.endActivity()

store.isBusy                                // activity running or inside whileBusy
await store.whileBusy { … }                 // or beginBusy()/endBusy()
store.openCommandPalette(query: "div")      // ⌘K palette, pre-filled
store.isInspectorPresented = true
store.services.updateQuotes / .export / .chooseImportFile   // installed by the shell
```

---

## Feature registry

Each feature target exposes one `FeatureModule`; the executable lists them in
`Sources/Kontor/FeatureCatalog.swift` (already done for all eleven).

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
Fmt.shares(Shares(12.5))                                     // "12.5" (≤ 8 decimals, zeros trimmed)
Fmt.price(Price(101.5), currency: "EUR")                     // "€101.50" (2–4 decimals; up to 8 below 1)
Fmt.number(1234.567, decimals: 1)                            // "1,234.6"
Fmt.integer(1_234_567)                                       // "1,234,567"
Fmt.rate(1.08345)                                            // "1.0835"
Fmt.currencySymbol("EUR")                                    // "€"
Fmt.day(day)                                                 // "03/31/2024"     de: "31.03.2024"
Fmt.day(day, style: .medium)                                 // "Mar 31, 2024"   (.long .monthYear .shortMonthYear .dayMonth .iso)
Fmt.relativeDay(day, today: store.today)                     // "Today", "Yesterday", "3 days ago", else medium
Fmt.missing                                                  // "–" (also returned for NaN/∞)
```

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

**Chart categories** — `CategoryPalette.color(i)` / `.colors` (8 hues, light+dark steps,
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
PeriodPicker()                                            // global period; PeriodPicker(selection:) for a local one
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
primary (double-click) action; ⌘C copies TSV; quick filter in the toolbar; footer with counts.
Rows are plain value structs computed off the main actor.

```swift
struct LedgerRow: Identifiable {
    let id: UUID
    var date: Day, kind: String, security: String, amount: Money
}

struct LedgerTable: View {
    @Environment(PortfolioStore.self) private var store
    @SceneStorage("ledger.columns") private var columns: TableColumnCustomization<LedgerRow>
    @SceneStorage("ledger.filter") private var filter = ""
    @State private var selection = Set<LedgerRow.ID>()
    @State private var sortOrder = [KeyPathComparator(\LedgerRow.date, order: .reverse)]
    @State private var rows: [LedgerRow] = []

    var body: some View {
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
        .onDeleteCommand { store.deleteTransactions(selection) }
        .onChange(of: selection) { _, ids in store.setFocus(ids.count == 1 ? .transaction(ids.first!) : nil) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TableFooter(count: rows.count, noun: "transaction", selected: selection.count,
                        filteredFrom: store.file.transactions.count)
        }
        .toolbar { ToolbarItem { QuickFilterField(text: $filter, prompt: "Filter transactions") } }
        .task(id: Inputs(revision: store.revision, filter: filter, sortOrder: sortOrder)) {
            let file = store.file, filter = QuickFilter(filter), order = sortOrder
            rows = await store.whileBusy {
                await Task.detached { Self.makeRows(file, filter: filter).sorted(using: order) }.value
            }
        }
    }

    private struct Inputs: Equatable {
        var revision: Int, filter: String, sortOrder: [KeyPathComparator<LedgerRow>]
    }

    private nonisolated static func makeRows(_ file: PortfolioFile, filter: QuickFilter) -> [LedgerRow] {
        let names = Dictionary(uniqueKeysWithValues: file.securities.map { ($0.id, $0.name) })
        return file.transactions.compactMap { t in
            let security = t.securityID.flatMap { names[$0] } ?? ""
            guard filter.matches(security, t.kind.rawValue, t.note) else { return nil }
            return LedgerRow(id: t.id, date: t.date, kind: t.kind.rawValue.capitalized, security: security, amount: t.amount)
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

(This exact code compiles and renders in the shell.) Helpers: `TSV.string(header:rows:)`,
`TSV.number(_: Decimal)` (ungrouped, locale decimal separator — what spreadsheets expect on paste),
`Pasteboard.copy(_:)`, `QuickFilterField(text:prompt:focusShortcut:)` (⌘F focuses it),
`QuickFilter(text).matches(fields…)` (all terms, case/diacritic-insensitive),
`TableFooter(count:noun:selected:filteredFrom:) { trailing }`.

---

## Utilities

```swift
FuzzyMatcher.match("hld", in: "Holdings")                 // Match(score:positions:isTight:)?
FuzzyMatcher.rank(items, query: text, limit: 40) { [$0.name, $0.ticker] }   // [(item, match)], best first

ConsistencyChecker.check(file)                            // [Issue(severity:message:route:)]

AppPreferences.Key.gainStyle / .defaultCurrency / .appearance / .autoUpdateQuotes / …   // @AppStorage keys
AppPreferences.defaultCurrency, AppPreferences.gainStyle

hexComponents("#FF8000")                                  // (r, g, b, a)?
```
