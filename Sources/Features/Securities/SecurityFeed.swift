import SwiftUI
import KontorUI
import KontorMarketData

// MARK: - Generic feed form

/// Form rows that edit a `QuoteFeed`, generated from the provider registry's descriptors: a
/// provider picker, the provider's symbol field and one control per option. Embed in a `Form`.
struct FeedFormRows: View {
    @Binding var feed: QuoteFeed?
    let descriptors: [ProviderDescriptor]
    /// The security's ticker — what an empty symbol falls back to.
    var ticker = ""

    private var descriptor: ProviderDescriptor? { feed.flatMap { feed in descriptors.first { $0.id == feed.provider } } }

    var body: some View {
        Picker(selection: providerBinding) {
            Text("None").tag("")
            Divider()
            ForEach(descriptors) { Text($0.name).tag($0.id) }
            if let feed, descriptor == nil {
                Divider()
                Text("\(feed.provider) (unknown)").tag(feed.provider)
            }
        } label: {
            HelpLabel("Provider", topic: .quoteFeed)
        }
        if let descriptor {
            if !descriptor.summary.isEmpty {
                Text(descriptor.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let symbol = descriptor.symbol {
                optionRow(symbol, text: symbolBinding)
            }
            ForEach(descriptor.options) { option in
                optionRow(option, text: optionBinding(option))
            }
        } else if let feed {
            Text("Kontor has no provider called “\(feed.provider)”. Quotes of this security are not updated until you choose another one.")
                .font(.callout)
                .foregroundStyle(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Without a data source, quotes are only what you enter or import yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var providerBinding: Binding<String> {
        Binding(get: { feed?.provider ?? "" }, set: { id in
            guard id != (feed?.provider ?? "") else { return }
            if id.isEmpty {
                feed = nil
            } else {
                // Keep the symbol when switching between providers that use one.
                let keepsSymbol = descriptors.first { $0.id == id }?.symbol != nil
                feed = QuoteFeed(provider: id, symbol: keepsSymbol ? (feed?.symbol ?? "") : "")
            }
        })
    }

    private var symbolBinding: Binding<String> {
        Binding(get: { feed?.symbol ?? "" }, set: { feed?.symbol = $0 })
    }

    private func optionBinding(_ option: ProviderOption) -> Binding<String> {
        Binding(get: { feed?.options[option.key] ?? "" }, set: { value in
            if value.isEmpty { feed?.options[option.key] = nil } else { feed?.options[option.key] = value }
        })
    }

    @ViewBuilder private func optionRow(_ option: ProviderOption, text: Binding<String>) -> some View {
        let label = option.isRequired ? option.label : "\(option.label)"
        let placeholder = option.placeholder.isEmpty
            ? (option.key == "symbol" && !ticker.isEmpty ? ticker : option.defaultValue)
            : option.placeholder
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            switch option.kind {
            case .choice(let choices):
                Picker(label, selection: Binding(get: { text.wrappedValue.isEmpty ? option.defaultValue : text.wrappedValue },
                                                 set: { text.wrappedValue = $0 == option.defaultValue ? "" : $0 })) {
                    if option.defaultValue.isEmpty, !choices.contains(where: { $0.value.isEmpty }) { Text("Default").tag("") }
                    ForEach(choices) { Text($0.label).tag($0.value) }
                }
            case .secret:
                SecureField(label, text: text, prompt: Text(placeholder))
            case .jsonPath, .urlTemplate:
                LabeledContent(label) {
                    TextField(label, text: text, prompt: Text(placeholder), axis: .vertical)
                        .labelsHidden()
                        .font(.callout.monospaced())
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                }
            case .text:
                TextField(label, text: text, prompt: Text(placeholder))
                    .autocorrectionDisabled()
            }
            let hint = hint(option)
            if !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hint(_ option: ProviderOption) -> String {
        var parts = [String]()
        if !option.help.isEmpty { parts.append(option.help) }
        if option.kind == .urlTemplate, !option.help.contains("{") {
            parts.append("Placeholders: " + URLTemplate.placeholders.map { "{\($0)}" }.joined(separator: " "))
        }
        if option.isRequired { parts.append("Required.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Trying a feed

/// What a test download returned.
struct FeedSample: Equatable, Sendable {
    var points: [PricePoint]
    var total: Int
    var currency: CurrencyCode?
    var name: String?
    var exchange: String?
    var range: ClosedRange<Day>
}

enum FeedTestState: Equatable {
    case idle
    case running
    case success(FeedSample)
    case failure(String)
}

/// Network helpers of the feature. Every call is guarded by `MarketAccess.isOnline` and wrapped in
/// `store.whileBusy`.
@MainActor
enum FeedProbe {
    /// Downloads the last weeks of quotes for a feed, without storing anything.
    static func test(_ feed: QuoteFeed, security: Security, store: PortfolioStore) async -> FeedTestState {
        guard MarketAccess.isOnline(store) else { return .failure(MarketAccess.offlineHint) }
        let registry = MarketAccess.registry(store)
        let problems = registry.validate(feed)
        if let first = problems.first { return .failure(first) }
        let range = store.today.advanced(by: -45)...store.today
        let request = QuoteRequest(feed: feed, currency: security.currency, ticker: security.ticker, isin: security.isin,
                                   wkn: security.wkn, range: range)
        return await store.whileBusy {
            do {
                let history = try await registry.provider(for: feed).history(request)
                return .success(FeedSample(points: Array(history.points.suffix(6).reversed()), total: history.points.count,
                                           currency: history.currency, name: history.name, exchange: history.exchange, range: range))
            } catch {
                return .failure(describe(error))
            }
        }
    }

    /// Ranked feed candidates for a security (by ISIN, ticker, then name).
    static func suggestions(for security: Security, store: PortfolioStore) async -> Result<[FeedSuggestion], FeedError> {
        guard MarketAccess.isOnline(store), let yahoo = MarketAccess.registry(store).provider(id: YahooProvider.id) as? YahooProvider else {
            return .failure(FeedError(message: MarketAccess.offlineHint))
        }
        return await store.whileBusy {
            do {
                return .success(try await FeedSuggester(yahoo: yahoo).suggestions(for: security))
            } catch {
                return .failure(FeedError(message: describe(error)))
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? MarketDataError { return error.description }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct FeedError: Error, Equatable {
    var message: String
}

// MARK: - Data Source tab

struct SecurityFeedTab: View {
    @Environment(PortfolioStore.self) private var store
    let security: Security

    @State private var draft: QuoteFeed?
    @State private var didLoad = false
    @State private var test = FeedTestState.idle
    @State private var suggestions: [FeedSuggestion]?
    @State private var suggestionError: String?
    @State private var isSuggesting = false

    private var isDirty: Bool { draft != security.feed }
    private var isOnline: Bool { MarketAccess.isOnline(store) }

    var body: some View {
        let registry = MarketAccess.registry(store)
        let problems = draft.map { registry.validate($0) } ?? []
        Form {
            Section {
                statusRows(registry)
            } header: {
                Text("Status")
            }

            Section {
                FeedFormRows(feed: $draft, descriptors: registry.descriptors, ticker: security.ticker)
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.Colors.warning)
                        .font(.callout)
                }
                HStack(spacing: DS.Spacing.s) {
                    Button("Suggest from ISIN / Ticker", action: suggest)
                        .disabled(!isOnline || isSuggesting)
                        .help(isOnline ? "Searches Yahoo Finance by ISIN, ticker and name and ranks the listings" : MarketAccess.offlineHint)
                    if isSuggesting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Revert") { draft = security.feed }
                        .disabled(!isDirty)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                if let suggestionError {
                    Label(suggestionError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning).font(.callout)
                }
                if let suggestions { suggestionRows(suggestions) }
            } header: {
                Text("Data Source")
            } footer: {
                if !isOnline {
                    Text("Online features are switched off in this session, so searching, testing and downloading are unavailable.")
                }
            }

            Section {
                HStack(spacing: DS.Spacing.s) {
                    Button("Test", action: runTest)
                        .disabled(!isOnline || draft == nil || !registry.isAutomatic(draft) || test == .running)
                        .help("Downloads the last few weeks with the settings above — nothing is stored")
                    if test == .running { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Fetch Now") { store.updateQuotes(only: [security.id]) }
                        .disabled(!canFetch(registry))
                        .help("Downloads the quotes since the latest stored one")
                    Button("Reload Full History") { store.updateQuotes(only: [security.id], reloadHistory: true) }
                        .disabled(!canFetch(registry))
                        .help("Requests the whole history again and corrects stored prices that differ — use after a split")
                }
                testResult
            } header: {
                Text("Download")
            } footer: {
                if isDirty, isOnline {
                    Text("“Test” uses the unsaved settings above; “Fetch Now” uses the saved data source.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = security.feed
        }
        .onChange(of: security.feed) { old, new in
            // Follow undo/redo and quote updates unless the user is in the middle of an edit.
            if draft == old { draft = new }
        }
    }

    private func canFetch(_ registry: ProviderRegistry) -> Bool {
        isOnline && !isDirty && !security.isRetired && registry.isAutomatic(security.feed) && !store.isUpdatingQuotes
    }

    @ViewBuilder private func statusRows(_ registry: ProviderRegistry) -> some View {
        let latest = security.prices.latest
        KeyValueRow("Updates") {
            if security.isRetired {
                Text("Off — the security is retired").foregroundStyle(.secondary)
            } else if registry.isAutomatic(security.feed) {
                Label("Automatic", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.primary)
            } else if security.feed?.provider == "manual" || security.feed == nil {
                Text("Manual — quotes are entered or imported by hand").foregroundStyle(.secondary)
            } else {
                Label("Not possible — unknown provider", systemImage: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
            }
        }
        KeyValueRow("Latest Quote") {
            if let latest {
                let age = latest.day.distance(to: store.today)
                HStack(spacing: DS.Spacing.s) {
                    if !security.isRetired, age > SecurityListModel.staleAfterDays {
                        Label("\(Fmt.duration(days: age)) old", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(DS.Colors.warning)
                    }
                    Text("\(Fmt.price(latest.price, currency: security.currency)) · \(Fmt.day(latest.day, style: .medium))").numeric()
                }
            } else {
                Text("None").foregroundStyle(.secondary)
            }
        }
        KeyValueRow("Stored Quotes") {
            if let first = security.prices.firstDay {
                Text("\(Fmt.integer(security.prices.count)) since \(Fmt.day(first, style: .medium))").numeric()
            } else {
                Text("0").numeric()
            }
        }
        KeyValueRow("Last Download") {
            Text(security.updatedAt.map { Fmt.relativeDay(Day(date: $0), today: store.today) } ?? "Never").numeric()
        }
        if let failure = store.lastQuoteUpdate?.failures.first(where: { $0.securityID == security.id }) {
            Label(failure.message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(DS.Colors.warning)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func suggestionRows(_ suggestions: [FeedSuggestion]) -> some View {
        if suggestions.isEmpty {
            Text("No listing found for this ISIN, ticker or name.").foregroundStyle(.secondary).font(.callout)
        } else {
            ForEach(suggestions.prefix(6)) { suggestion in
                Button {
                    draft = suggestion.feed
                } label: {
                    HStack(spacing: DS.Spacing.s) {
                        Image(systemName: draft == suggestion.feed ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(draft == suggestion.feed ? Color.accentColor : .secondary)
                        Text(suggestion.match.symbol).fontWeight(.medium).numeric()
                        Text(suggestion.match.name).lineLimit(1).foregroundStyle(.secondary)
                        Spacer()
                        Text([suggestion.match.exchangeName.isEmpty ? suggestion.match.exchange : suggestion.match.exchangeName,
                              suggestion.currency ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        if suggestion.isVerified {
                            Image(systemName: "checkmark.seal").foregroundStyle(.secondary).help("Confirmed with a live quote")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var testResult: some View {
        switch test {
        case .idle, .running:
            EmptyView()
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        case .success(let sample):
            FeedSampleView(sample: sample, securityCurrency: security.currency)
        }
    }

    private func save() {
        let feed = draft
        store.updateSecurity(security.id, actionName: "Change Data Source") { $0.feed = feed }
    }

    private func runTest() {
        guard let feed = draft else { return }
        test = .running
        let security = security
        Task { test = await FeedProbe.test(feed, security: security, store: store) }
    }

    private func suggest() {
        isSuggesting = true
        suggestionError = nil
        let security = security
        Task {
            switch await FeedProbe.suggestions(for: security, store: store) {
            case .success(let list):
                suggestions = list
                if draft == nil || draft?.provider == "manual", let best = list.first { draft = best.feed }
            case .failure(let error):
                suggestionError = error.message
            }
            isSuggesting = false
        }
    }
}

/// The result of a test download: what the provider calls the instrument and the newest quotes.
struct FeedSampleView: View {
    let sample: FeedSample
    let securityCurrency: CurrencyCode

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Label {
                Text(summary)
            } icon: {
                Image(systemName: sample.total == 0 ? "questionmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(sample.total == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            }
            if let currency = sample.currency, currency != securityCurrency {
                Label("The feed quotes in \(currency), but the security is kept in \(securityCurrency). Change the security's currency or pick another listing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Colors.warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !sample.points.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.xl, verticalSpacing: DS.Spacing.xs) {
                    ForEach(sample.points, id: \.day) { point in
                        GridRow {
                            Text(Fmt.day(point.day, style: .medium)).foregroundStyle(.secondary)
                            Text(Fmt.price(point.price, currency: sample.currency ?? securityCurrency)).gridColumnAlignment(.trailing)
                        }
                    }
                }
                .numeric()
                .font(.callout)
            }
        }
    }

    private var summary: String {
        let name = [sample.name, sample.exchange].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if sample.total == 0 {
            return "The request worked, but there are no quotes between \(Fmt.day(sample.range.lowerBound, style: .medium)) and \(Fmt.day(sample.range.upperBound, style: .medium))."
        }
        return "\(Fmt.integer(sample.total)) quotes in the last \(sample.range.lowerBound.distance(to: sample.range.upperBound)) days" + (name.isEmpty ? "" : " — \(name)")
    }
}

// MARK: - Notes & attributes tab

struct SecurityNotesTab: View {
    @Environment(PortfolioStore.self) private var store
    let security: Security

    private struct AttributeDraft: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    @State private var note = ""
    @State private var attributes: [AttributeDraft] = []
    @State private var didLoad = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $note)
                    .font(.body)
                    .frame(minHeight: 84)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Notes")
            } header: {
                Text("Notes")
            }

            Section {
                ForEach($attributes) { $attribute in
                    HStack(spacing: DS.Spacing.s) {
                        TextField("Name", text: $attribute.key, prompt: Text("Name, e.g. TER"))
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        TextField("Value", text: $attribute.value, prompt: Text("Value"))
                            .labelsHidden()
                        Button {
                            attributes.removeAll { $0.id == attribute.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove attribute \(attribute.key)")
                    }
                }
                Button("Add Attribute", systemImage: "plus") { attributes.append(AttributeDraft(key: "", value: "")) }
                    .buttonStyle(.borderless)
            } header: {
                Text("Attributes")
            } footer: {
                Text("Free-form facts you want to keep with the security — costs, sector, distribution policy.")
            }

            Section("Classification") {
                classificationRows
            }

            Section("Watchlists & Status") {
                ForEach(store.file.watchlists) { list in
                    Toggle(list.name, isOn: Binding(get: { list.securityIDs.contains(security.id) }, set: { isOn in
                        if isOn { store.addSecurities([security.id], toWatchlist: list.id) } else { store.removeSecurities([security.id], fromWatchlist: list.id) }
                    }))
                }
                Toggle(isOn: Binding(get: { store.isBenchmark(security.id) }, set: { _ in store.toggleBenchmark(security.id) })) {
                    HelpLabel("Use as Benchmark", topic: .benchmark)
                }
                Toggle(isOn: Binding(get: { security.isRetired }, set: { store.setRetired([security.id], $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Retired")
                        Text("Hidden from pickers and skipped by quote updates; history stays intact.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onDisappear(perform: commit)
        .onChange(of: security.note) { _, new in if new != note { note = new } }
        .onChange(of: security.attributes) { _, new in if new != attributeDictionary { attributes = Self.drafts(new) } }
        // Edits are saved shortly after typing stops — one undo step per pause.
        .task(id: PendingEdit(note: note, attributes: attributeDictionary)) {
            guard didLoad else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private struct PendingEdit: Hashable {
        var note: String
        var attributes: [String: String]
    }

    private var attributeDictionary: [String: String] {
        var result = [String: String]()
        for attribute in attributes {
            let key = attribute.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = attribute.value }
        }
        return result
    }

    private static func drafts(_ attributes: [String: String]) -> [AttributeDraft] {
        attributes.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { AttributeDraft(key: $0.key, value: $0.value) }
    }

    private func load() {
        guard !didLoad else { return }
        note = security.note
        attributes = Self.drafts(security.attributes)
        didLoad = true
    }

    private func commit() {
        guard didLoad, let current = store.security(security.id) else { return }
        let note = note, attributes = attributeDictionary
        if current.note != note {
            store.updateSecurity(security.id, actionName: "Edit Note") { $0.note = note }
        }
        if current.attributes != attributes {
            store.updateSecurity(security.id, actionName: "Edit Attributes") { $0.attributes = attributes }
        }
    }

    @ViewBuilder private var classificationRows: some View {
        if store.file.taxonomies.isEmpty {
            Text("No taxonomies yet. Create one under Allocation to group your securities.").foregroundStyle(.secondary)
        }
        ForEach(store.file.taxonomies) { taxonomy in
            let assigned = Self.assignments(of: security.id, in: taxonomy)
            KeyValueRow(taxonomy.name) {
                if assigned.isEmpty {
                    Button("Not assigned") { store.navigate(to: .taxonomy(taxonomy.id)) }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(assigned, id: \.id) { item in
                            Button {
                                store.navigate(to: .classification(taxonomy: taxonomy.id, id: item.id))
                            } label: {
                                HStack(spacing: DS.Spacing.xs) {
                                    Circle().fill(ChartColors.classification(item.color)).frame(width: 8, height: 8)
                                    Text(item.path)
                                    if item.weight != 10_000 { Text(Fmt.percent(basisPoints: item.weight, decimals: 0)).foregroundStyle(.secondary).numeric() }
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private struct Assigned {
        var id: UUID
        var path: String
        var color: String
        var weight: Int
    }

    private static func assignments(of securityID: UUID, in taxonomy: Taxonomy) -> [Assigned] {
        var result = [Assigned]()
        func visit(_ nodes: [Classification], _ path: [String]) {
            for node in nodes {
                let here = path + [node.name]
                for assignment in node.assignments where assignment.securityID == securityID {
                    result.append(Assigned(id: node.id, path: here.joined(separator: " ▸ "), color: node.color, weight: assignment.weight))
                }
                visit(node.children, here)
            }
        }
        visit(taxonomy.root, [])
        return result
    }
}
