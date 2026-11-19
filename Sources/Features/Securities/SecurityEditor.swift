import SwiftUI
import KontorUI
import KontorMarketData

/// The sheet behind `.newSecurity(prefill)` and `.editSecurity(id)`.
///
/// Adding: search online (Yahoo Finance for stocks, ETFs, funds and indices; CoinGecko for crypto
/// assets), pick a hit — name, ticker, currency and data source are filled in and the price
/// history is downloaded after saving — or enter the master data by hand.
///
/// Launch state: `editor=search|manual`, `query=<text>`.
struct SecurityEditor: View {
    enum Mode: Equatable {
        case new(SecurityPrefill)
        case edit(UUID)
    }

    enum Source: String, CaseIterable, Identifiable {
        case search, manual
        var id: String { rawValue }
        var title: String { self == .search ? "Search Online" : "Enter Manually" }
    }

    enum Catalog: String, CaseIterable, Identifiable {
        case yahoo, coingecko
        var id: String { rawValue }
        var title: String { self == .yahoo ? "Stocks, ETFs, Funds" : "Crypto" }
        var prompt: String { self == .yahoo ? "Name, ticker or ISIN" : "Coin name or symbol" }
    }

    enum SearchState: Equatable {
        case idle, searching
        case results([SymbolMatch])
        case failure(String)
    }

    @Environment(PortfolioStore.self) private var store
    let mode: Mode

    @State private var draft = Security(name: "", currency: "EUR")
    @State private var original: Security?
    @State private var isBenchmark = false
    @State private var source = Source.search
    @State private var catalog = Catalog.yahoo
    @State private var query = ""
    @State private var search = SearchState.idle
    @State private var picked: SymbolMatch?
    @State private var verification: String?
    @State private var showsFeed = false
    @State private var didLoad = false
    @FocusState private var focus: Field?

    private enum Field { case search, name }

    private var isNew: Bool { if case .new = mode { true } else { false } }
    private var isOnline: Bool { MarketAccess.isOnline(store) }
    private var showsForm: Bool { !isNew || source == .manual || picked != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                if isNew, source == .search { searchSection }
                if showsForm {
                    masterDataSection
                    feedSection
                    if !isNew { statusSection }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(width: 580)
        .frame(minHeight: isNew && source == .search && picked == nil ? 460 : 0)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .task(id: SearchKey(query: query, catalog: catalog, source: source)) { await runSearch() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: DS.Spacing.m) {
            Text(isNew ? "Add Security" : "Edit Security").font(.headline)
            if isNew {
                Picker("How to add", selection: $source) {
                    ForEach(Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.top, DS.Spacing.l)
        .padding(.bottom, DS.Spacing.m)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var searchSection: some View {
        Section {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query, prompt: Text(catalog.prompt))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .search)
                    .autocorrectionDisabled()
                if search == .searching { ProgressView().controlSize(.small) }
                Picker("Catalog", selection: $catalog) {
                    ForEach(Catalog.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            searchResults
        } footer: {
            Text(catalog == .yahoo
                 ? "Results come from Yahoo Finance. Only your search text is sent."
                 : "Results come from CoinGecko. Only your search text is sent; the free service covers the past year of prices.")
        }
    }

    @ViewBuilder private var searchResults: some View {
        if !isOnline {
            notice("Online search is not available in this session.", symbol: "wifi.slash",
                   detail: "Enter the security by hand — you can attach a data source later.") {
                Button("Enter Manually") { source = .manual }
            }
        } else {
            switch search {
            case .idle:
                notice("Type at least two characters.", symbol: "text.cursor", detail: "For example “MSCI World”, “AAPL” or an ISIN.") { EmptyView() }
            case .searching:
                notice("Searching…", symbol: "magnifyingglass", detail: nil) { EmptyView() }
            case .failure(let message):
                notice("The search did not work.", symbol: "exclamationmark.triangle", detail: message) {
                    Button("Enter Manually") { source = .manual }
                }
            case .results(let matches) where matches.isEmpty:
                notice("Nothing found for “\(query)”.", symbol: "questionmark.circle", detail: "Check the spelling, or try the ISIN or ticker.") {
                    Button("Enter Manually") { source = .manual }
                }
            case .results(let matches):
                ForEach(matches.prefix(8)) { match in
                    Button {
                        pick(match)
                    } label: {
                        HStack(spacing: DS.Spacing.s) {
                            Image(systemName: picked == match ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(picked == match ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(match.name.isEmpty ? match.symbol : match.name).lineLimit(1)
                                Text([match.symbol, match.exchangeName.isEmpty ? match.exchange : match.exchangeName]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            StatusBadge(title: Self.typeTitle(match.type))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func notice<Actions: View>(_ title: String, symbol: String, detail: String?, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                actions().controlSize(.small).padding(.top, DS.Spacing.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    @ViewBuilder private var masterDataSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("e.g. Vanguard FTSE All-World"))
                .focused($focus, equals: .name)
            LabeledContent("Currency") {
                CurrencyPicker(selection: $draft.currency, preferred: store.file.currencies).frame(width: 220)
            }
            if let original, original.currency != draft.currency, !original.prices.isEmpty || !store.transactions(forSecurity: original.id).isEmpty {
                Label("Stored quotes and transactions are not converted — they will be read as \(draft.currency).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let verification {
                Label(verification, systemImage: "checkmark.seal").font(.callout).foregroundStyle(.secondary)
            }
            TextField("ISIN", text: $draft.isin, prompt: Text("Optional"))
                .autocorrectionDisabled()
            if let duplicate {
                HStack {
                    Label("“\(duplicate.name)” already has this ISIN.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.Colors.warning)
                    Spacer()
                    Button("Show") {
                        store.dismissSheet()
                        store.navigate(to: .security(duplicate.id))
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
            } else if !draft.isin.isEmpty, !ISIN.isPlausible(draft.isin.trimmingCharacters(in: .whitespaces).uppercased()) {
                Label("This does not look like a valid ISIN (12 characters with a check digit).", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextField("WKN", text: $draft.wkn, prompt: Text("Optional"))
                .autocorrectionDisabled()
            TextField("Ticker", text: $draft.ticker, prompt: Text("Optional"))
                .autocorrectionDisabled()
        } header: {
            Text(isNew && picked != nil ? "Security — check and adjust" : "Security")
        }
    }

    @ViewBuilder private var feedSection: some View {
        let registry = MarketAccess.registry(store)
        Section {
            DisclosureGroup(isExpanded: $showsFeed) {
                FeedFormRows(feed: $draft.feed, descriptors: registry.descriptors, ticker: draft.ticker)
                ForEach(draft.feed.map { registry.validate($0) } ?? [], id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning).font(.callout)
                }
            } label: {
                HStack {
                    HelpLabel("Data Source", topic: .quoteFeed)
                    Spacer()
                    Text(feedSummary(registry)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } footer: {
            if isNew, registry.isAutomatic(draft.feed) {
                Text(isOnline ? "The price history is downloaded right after adding." : "The price history is downloaded with the next quote update.")
            }
        }
    }

    private func feedSummary(_ registry: ProviderRegistry) -> String {
        guard let feed = draft.feed else { return "None" }
        let name = registry.descriptor(id: feed.provider)?.name ?? feed.provider
        let symbol = feed.symbol.hasPrefix("http") ? "" : feed.symbol
        return symbol.isEmpty ? name : "\(name) · \(symbol)"
    }

    private var statusSection: some View {
        Section {
            TextField("Note", text: $draft.note, prompt: Text("Optional"), axis: .vertical)
                .lineLimit(1...4)
            Toggle(isOn: $isBenchmark) { HelpLabel("Use as Benchmark", topic: .benchmark) }
            Toggle("Retired", isOn: $draft.isRetired)
        } footer: {
            Text("Retired securities are hidden from pickers and skipped by quote updates.")
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.s) {
            if !isNew, let original {
                Button("Delete…", role: .destructive) {
                    store.dismissSheet()
                    store.confirmDeleteSecurities([original.id])
                }
            }
            Spacer()
            Button("Cancel") { store.dismissSheet() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Add Security" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(DS.Spacing.l)
    }

    // MARK: Logic

    private var canSave: Bool {
        showsForm && !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.currency.isEmpty
    }

    private var duplicate: Security? {
        let isin = draft.isin.trimmingCharacters(in: .whitespaces).uppercased()
        guard !isin.isEmpty else { return nil }
        return store.file.securities.first { $0.id != draft.id && $0.isin.uppercased() == isin }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        switch mode {
        case .new(let prefill):
            draft = Security(
                name: prefill.name ?? "", currency: prefill.currency ?? store.baseCurrency, isin: prefill.isin ?? "",
                wkn: prefill.wkn ?? "", ticker: prefill.ticker ?? "", feed: prefill.feed)
            let hasPrefill = prefill != SecurityPrefill()
            source = store.launchValue("editor", as: Source.self) ?? (hasPrefill || !isOnline ? .manual : .search)
            query = store.launchValue("query") ?? ""
            showsFeed = prefill.feed != nil
            focus = source == .search ? .search : .name
        case .edit(let id):
            guard let security = store.security(id) else {
                store.dismissSheet()
                return
            }
            draft = security
            original = security
            isBenchmark = store.isBenchmark(id)
            focus = .name
        }
    }

    private struct SearchKey: Hashable {
        var query: String
        var catalog: Catalog
        var source: Source
    }

    /// Debounced search; the task is cancelled and restarted whenever the text or catalog changes.
    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNew, source == .search, isOnline, text.count >= 2 else {
            search = .idle
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let registry = MarketAccess.registry(store)
        guard let provider = registry.provider(id: catalog == .yahoo ? YahooProvider.id : CoinGeckoProvider.id) as? any SymbolSearching else {
            search = .failure("This catalog is not available.")
            return
        }
        search = .searching
        let result: SearchState = await store.whileBusy {
            do {
                return .results(try await provider.search(text))
            } catch is CancellationError {
                return .idle
            } catch {
                return .failure(FeedProbe.describe(error))
            }
        }
        guard !Task.isCancelled else { return }
        search = result
    }

    private func pick(_ match: SymbolMatch) {
        picked = match
        verification = nil
        draft.name = match.name.isEmpty ? match.symbol : match.name
        draft.feed = match.feed
        if match.provider == CoinGeckoProvider.id {
            draft.ticker = ""
        } else {
            draft.ticker = match.symbol
            if let currency = ExchangeDirectory.currency(of: match) { draft.currency = currency }
        }
        if ISIN.isPlausible(query.trimmingCharacters(in: .whitespaces).uppercased()) {
            draft.isin = query.trimmingCharacters(in: .whitespaces).uppercased()
        }
        guard isOnline, let feed = draft.feed else { return }
        // Confirm the listing's currency with a live quote, so the first download cannot fail on a mismatch.
        let security = draft
        Task {
            let state = await FeedProbe.test(feed, security: security, store: store)
            guard picked == match, case .success(let sample) = state else { return }
            if let currency = sample.currency, match.provider != CoinGeckoProvider.id { draft.currency = currency }
            if let latest = sample.points.first {
                verification = "Latest quote \(Fmt.price(latest.price, currency: sample.currency ?? draft.currency)) on \(Fmt.day(latest.day, style: .medium))"
            }
        }
    }

    private func save() {
        guard canSave else { return }
        Self.commit(draft, isNew: isNew, isBenchmark: isBenchmark, isOnline: isOnline, in: store)
    }

    /// What "Save" does with the draft (also driven by the app's self-test).
    static func commit(_ draft: Security, isNew: Bool, isBenchmark: Bool, isOnline: Bool, in store: PortfolioStore) {
        var security = draft
        security.name = security.name.trimmingCharacters(in: .whitespacesAndNewlines)
        security.isin = security.isin.trimmingCharacters(in: .whitespaces).uppercased()
        security.wkn = security.wkn.trimmingCharacters(in: .whitespaces).uppercased()
        security.ticker = security.ticker.trimmingCharacters(in: .whitespaces)
        if isNew {
            store.addSecurity(security)
            store.dismissSheet()
            if store.route.screen == .securities {
                store.navigate(to: .security(security.id))
            } else {
                store.toast("Added “\(security.name)”", style: .success)
            }
            if isOnline, MarketAccess.registry(store).isAutomatic(security.feed) {
                store.updateQuotes(only: [security.id], interactive: false)
            }
        } else {
            let id = security.id
            let benchmark = isBenchmark
            // Master data only: quotes and events may have changed while the sheet was open.
            store.mutate("Edit Security") { file in
                guard let index = file.securities.firstIndex(where: { $0.id == id }) else { return }
                file.securities[index].name = security.name
                file.securities[index].currency = security.currency
                file.securities[index].isin = security.isin
                file.securities[index].wkn = security.wkn
                file.securities[index].ticker = security.ticker
                file.securities[index].note = security.note
                file.securities[index].isRetired = security.isRetired
                file.securities[index].feed = security.feed
                let wasBenchmark = file.settings.benchmarkSecurityIDs.contains(id)
                if benchmark, !wasBenchmark { file.settings.benchmarkSecurityIDs.append(id) }
                if !benchmark, wasBenchmark { file.settings.benchmarkSecurityIDs.removeAll { $0 == id } }
            }
            store.dismissSheet()
        }
    }

    static func typeTitle(_ type: SymbolMatch.InstrumentType) -> String {
        switch type {
        case .equity: "Stock"
        case .etf: "ETF"
        case .fund: "Fund"
        case .index: "Index"
        case .currency: "Currency"
        case .crypto: "Crypto"
        case .future: "Future"
        case .option: "Option"
        case .other: "Other"
        }
    }
}

// MARK: - Stock split

/// `.custom(id: "securities.split", payload: ["security": <uuid>, "ratio": "2:1", "day": "YYYY-MM-DD",
/// "adjust": "quotes" | "shares" | "both" | "none"])` —
/// records a stock split through the engine's `StockSplit`, with a preview of what changes.
struct SplitSheet: View {
    static let requestID = "securities.split"

    @Environment(PortfolioStore.self) private var store
    let payload: [String: String]

    @State private var securityID: UUID?
    @State private var day = Day(rawValue: 0)
    @State private var newShares = 2
    @State private var oldShares = 1
    /// Which half of the history is rewritten (see `SplitAdjustments`).
    @State private var adjusting = SplitAdjustments()
    @State private var hasAutomaticFeed = false
    @State private var preview = Loadable<SplitPreview>()
    @State private var didLoad = false

    private var isRatioValid: Bool { newShares >= 1 && oldShares >= 1 }

    var body: some View {
        let security = store.security(securityID)
        let query = SplitQuery(securityID: securityID ?? UUID(), day: day, newShares: newShares, oldShares: oldShares, adjusting: adjusting)
        VStack(spacing: 0) {
            VStack(spacing: DS.Spacing.xs) {
                Text("Record Stock Split").font(.headline)
                Text(security?.displayName ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.top, DS.Spacing.l)
            .padding(.bottom, DS.Spacing.m)
            .padding(.horizontal, DS.Spacing.l)
            Divider()
            Form {
                Section {
                    LabeledContent("First Day After the Split") {
                        DayField("First Day After the Split", day: $day).labelsHidden()
                    }
                    LabeledContent("Ratio") {
                        HStack(spacing: DS.Spacing.xs) {
                            TextField("New shares", value: $newShares, format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Stepper("New shares", value: $newShares, in: 1...10_000).labelsHidden()
                            Text(":").foregroundStyle(.secondary).padding(.horizontal, DS.Spacing.xs)
                            TextField("Old shares", value: $oldShares, format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Stepper("Old shares", value: $oldShares, in: 1...10_000).labelsHidden()
                        }
                        .numeric()
                    }
                    if isRatioValid {
                        Text("\(Fmt.integer(newShares)) new share\(newShares == 1 ? "" : "s") for every \(Fmt.integer(oldShares)) old share\(oldShares == 1 ? "" : "s")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .numeric()
                    }
                } footer: {
                    Text("A 2-for-1 split doubles the number of shares and halves the price.")
                }
                Section {
                    Toggle("Adjust earlier quotes", isOn: $adjusting.quotes)
                    Toggle("Adjust earlier share counts", isOn: $adjusting.shares)
                } header: {
                    Text("Adjust")
                } footer: {
                    Text(hasAutomaticFeed
                         ? "Downloaded quotes are normally split-adjusted already, so only the share counts of your earlier transactions need the new basis. Switch quotes on if the history still shows the old prices."
                         : "Switch off whatever is already on the new basis — for example quotes you entered after the split.")
                }
                Section("What Will Change") {
                    previewRows
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text("One step — undo with ⌘Z").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.dismissSheet() }.keyboardShortcut(.cancelAction)
                Button(adjusting.quotes || adjusting.shares ? "Apply Split" : "Record Event", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isRatioValid || preview.value?.isValid != true || newShares == oldShares)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .ledgerTask($preview, id: "securities.split", variant: query) { ledger in SplitPreview(ledger, query: query) }
        .onAppear(perform: load)
    }

    @ViewBuilder private var previewRows: some View {
        if !isRatioValid {
            // The engine rejects such a ratio; say so instead of waiting for a preview that never comes.
            Label("Enter whole numbers of 1 or more on both sides of the ratio.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Colors.warning)
        } else if let preview = preview.value, preview.isValid, newShares != oldShares {
            if preview.isRecorded {
                Label("A \(preview.ratio) split on this day is already recorded. Applying it again would adjust the data twice.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            KeyValueRow("Quotes before \(Fmt.day(day, style: .medium))") {
                Text(!adjusting.quotes ? "unchanged" : preview.adjustedPrices == 0 ? "none" : "\(Fmt.integer(preview.adjustedPrices)) adjusted").numeric()
            }
            if let before = preview.priceBefore, let after = preview.priceAfter {
                KeyValueRow("Last quote before the split") {
                    Text("\(Fmt.price(before, currency: preview.currency)) → \(Fmt.price(after, currency: preview.currency, maxDecimals: 4))").numeric()
                }
            }
            KeyValueRow("Transactions before that day") {
                Text(!adjusting.shares ? "unchanged" : preview.adjustedTransactions == 0 ? "none" : "\(Fmt.integer(preview.adjustedTransactions)) adjusted").numeric()
            }
            ForEach(preview.samples) { sample in
                HStack {
                    Text(Fmt.day(sample.date, style: .medium)).foregroundStyle(.secondary)
                    Text(sample.kind.title)
                    Spacer()
                    Text("\(Fmt.shares(sample.before)) → \(Fmt.shares(sample.after)) shares")
                }
                .font(.callout)
                .numeric()
            }
            if preview.adjustedTransactions > preview.samples.count {
                Text("… and \(Fmt.integer(preview.adjustedTransactions - preview.samples.count)) more").font(.callout).foregroundStyle(.secondary)
            }
            KeyValueRow("Event") { Text("“Split \(preview.ratio)” on \(Fmt.day(day, style: .medium))").numeric() }
        } else if newShares == oldShares {
            Text("Enter a ratio other than 1 : 1.").foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        securityID = payload["security"].flatMap(UUID.init(uuidString:)) ?? store.route.securityID
        guard store.security(securityID) != nil else {
            store.dismissSheet()
            return
        }
        day = payload["day"].flatMap { Day(iso: $0) } ?? store.today
        // Quotes from an automatic feed are split-adjusted by the provider; rescaling them again
        // would halve a history that is already right. `adjust=quotes|shares|both|none` overrides.
        hasAutomaticFeed = store.security(securityID)?.feed.map { MarketAccess.automaticProviders(store).contains($0.provider) } ?? false
        adjusting.quotes = !hasAutomaticFeed
        switch payload["adjust"] {
        case "quotes"?: adjusting = SplitAdjustments(quotes: true, shares: false)
        case "shares"?: adjusting = SplitAdjustments(quotes: false, shares: true)
        case "both"?: adjusting = SplitAdjustments(quotes: true, shares: true)
        case "none"?: adjusting = SplitAdjustments(quotes: false, shares: false)
        default: break
        }
        if let parts = payload["ratio"]?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 {
            newShares = parts[0]
            oldShares = parts[1]
        }
    }

    private func apply() {
        guard let securityID, let split = StockSplit(securityID: securityID, day: day, newShares: newShares, oldShares: oldShares) else { return }
        let adjusting = adjusting
        store.mutate("Apply Stock Split \(split.ratio)") { file in
            if let changed = file.applying(split, adjusting: adjusting) { file = changed }
        }
        store.dismissSheet()
        let message = switch (adjusting.quotes, adjusting.shares) {
        case (true, true): "Earlier quotes and share counts were adjusted."
        case (true, false): "Earlier quotes were adjusted; share counts are unchanged."
        case (false, true): "Earlier share counts were adjusted; quotes are unchanged."
        case (false, false): "The event was recorded; quotes and share counts are unchanged."
        }
        store.toast("Split \(split.ratio) \(adjusting.quotes || adjusting.shares ? "applied" : "recorded")", message: message, style: .success)
    }
}
