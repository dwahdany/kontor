import SwiftUI
import KontorModel

/// One row of a ``SearchablePicker``.
public struct PickerItem<ID: Hashable>: Identifiable {
    public let id: ID
    public var title: String
    /// Secondary text shown trailing (ISIN, currency, …); also searched.
    public var detail: String
    /// Extra search terms that are not displayed.
    public var keywords: [String]
    /// Dimmed rows (retired entities) sort last.
    public var isDimmed: Bool

    public init(id: ID, title: String, detail: String = "", keywords: [String] = [], isDimmed: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.isDimmed = isDimmed
    }
}

/// A pop-up button that opens a searchable, keyboard-navigable list — the basis of the security,
/// account, depot and currency pickers. Type to filter (fuzzy), ↑/↓ to move, ⏎ to choose, ⎋ to close.
public struct SearchablePicker<ID: Hashable>: View {
    private let title: String
    @Binding private var selection: ID?
    private let items: [PickerItem<ID>]
    private let placeholder: String
    private let allowsNone: Bool

    @State private var isOpen = false

    /// - Parameters:
    ///   - title: Accessibility label and search prompt ("Security").
    ///   - allowsNone: Adds a "None" row that clears the selection.
    public init(
        _ title: String, selection: Binding<ID?>, items: [PickerItem<ID>], placeholder: String = "Choose…",
        allowsNone: Bool = false
    ) {
        self.title = title
        _selection = selection
        self.items = items
        self.placeholder = placeholder
        self.allowsNone = allowsNone
    }

    private var selected: PickerItem<ID>? {
        selection.flatMap { id in items.first { $0.id == id } }
    }

    public var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Text(selected?.title ?? placeholder)
                    .foregroundStyle(selected == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Spacing.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(selected?.title ?? placeholder)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SearchablePickerList(
                title: title, items: items, selection: selection, allowsNone: allowsNone
            ) { choice in
                selection = choice
                isOpen = false
            }
        }
    }
}

private struct SearchablePickerList<ID: Hashable>: View {
    let title: String
    let items: [PickerItem<ID>]
    let selection: ID?
    let allowsNone: Bool
    let choose: (ID?) -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    /// nil id = the "None" row.
    private struct Row: Identifiable {
        let index: Int
        let item: PickerItem<ID>?
        var id: Int { index }
    }

    private var rows: [Row] {
        let ranked = FuzzyMatcher.rank(items, query: query) { [$0.title, $0.detail] + $0.keywords }.map(\.item)
        var result = [Row]()
        if allowsNone, query.isEmpty { result.append(Row(index: 0, item: nil)) }
        for item in ranked { result.append(Row(index: result.count, item: item)) }
        return result
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(title)", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if rows.indices.contains(highlighted) { choose(rows[highlighted].item?.id) }
                    }
            }
            .padding(DS.Spacing.m)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            rowView(row, isHighlighted: row.index == highlighted)
                                .id(row.index)
                                .onTapGesture { choose(row.item?.id) }
                                .onHover { if $0 { highlighted = row.index } }
                        }
                    }
                    .padding(DS.Spacing.xs)
                }
                .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
            }
            .frame(maxHeight: 280)
            if rows.isEmpty {
                Text("No matches").foregroundStyle(.secondary).padding(DS.Spacing.l)
            }
        }
        .frame(width: 340)
        .onAppear {
            searchFocused = true
            highlighted = rows.firstIndex { $0.item?.id == selection && selection != nil } ?? 0
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(rows.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
    }

    private func rowView(_ row: Row, isHighlighted: Bool) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "checkmark")
                .imageScale(.small)
                .fontWeight(.semibold)
                .opacity(row.item?.id == selection && (row.item != nil || selection == nil) ? 1 : 0)
            if let item = row.item {
                Text(item.title).lineLimit(1)
                Spacer(minLength: DS.Spacing.s)
                Text(item.detail)
                    .font(.callout)
                    .numeric()
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            } else {
                Text("None")
                Spacer()
            }
        }
        .opacity(row.item?.isDimmed == true && !isHighlighted ? 0.55 : 1)
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 5)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Entity pickers

/// Chooses a security of the open portfolio. Active securities are sorted by name; retired ones are
/// hidden unless `includesRetired` is set (then they sort last, dimmed) or currently selected.
public struct SecurityPicker: View {
    @Environment(PortfolioStore.self) private var store
    @Binding private var selection: UUID?
    private let includesRetired: Bool
    private let allowsNone: Bool

    public init(selection: Binding<UUID?>, includesRetired: Bool = false, allowsNone: Bool = false) {
        _selection = selection
        self.includesRetired = includesRetired
        self.allowsNone = allowsNone
    }

    public var body: some View {
        SearchablePicker("Security", selection: $selection, items: items, placeholder: "Choose Security…", allowsNone: allowsNone)
    }

    private var items: [PickerItem<UUID>] {
        store.file.securities
            .filter { !$0.isRetired || includesRetired || $0.id == selection }
            .sorted(by: Self.order)
            .map {
                PickerItem(
                    id: $0.id, title: $0.name, detail: $0.ticker.isEmpty ? $0.isin : $0.ticker,
                    keywords: [$0.isin, $0.wkn, $0.ticker], isDimmed: $0.isRetired
                )
            }
    }

    private static func order(_ a: Security, _ b: Security) -> Bool {
        if a.isRetired != b.isRetired { return !a.isRetired }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Chooses a cash account. Optionally restricted to one currency.
public struct AccountPicker: View {
    @Environment(PortfolioStore.self) private var store
    @Binding private var selection: UUID?
    private let currency: CurrencyCode?
    private let includesRetired: Bool
    private let allowsNone: Bool

    public init(selection: Binding<UUID?>, currency: CurrencyCode? = nil, includesRetired: Bool = false, allowsNone: Bool = false) {
        _selection = selection
        self.currency = currency
        self.includesRetired = includesRetired
        self.allowsNone = allowsNone
    }

    public var body: some View {
        SearchablePicker("Account", selection: $selection, items: items, placeholder: "Choose Account…", allowsNone: allowsNone)
    }

    private var items: [PickerItem<UUID>] {
        store.file.accounts
            .filter { (!$0.isRetired || includesRetired || $0.id == selection) && (currency == nil || $0.currency == currency || $0.id == selection) }
            .sorted {
                if $0.isRetired != $1.isRetired { return !$0.isRetired }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map { PickerItem(id: $0.id, title: $0.name, detail: $0.currency, isDimmed: $0.isRetired) }
    }
}

/// Chooses a depot (securities account).
public struct DepotPicker: View {
    @Environment(PortfolioStore.self) private var store
    @Binding private var selection: UUID?
    private let includesRetired: Bool
    private let allowsNone: Bool

    public init(selection: Binding<UUID?>, includesRetired: Bool = false, allowsNone: Bool = false) {
        _selection = selection
        self.includesRetired = includesRetired
        self.allowsNone = allowsNone
    }

    public var body: some View {
        SearchablePicker("Depot", selection: $selection, items: items, placeholder: "Choose Depot…", allowsNone: allowsNone)
    }

    private var items: [PickerItem<UUID>] {
        store.file.depots
            .filter { !$0.isRetired || includesRetired || $0.id == selection }
            .sorted {
                if $0.isRetired != $1.isRetired { return !$0.isRetired }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map { depot in
                PickerItem(
                    id: depot.id, title: depot.name,
                    detail: store.account(depot.referenceAccountID)?.name ?? "", isDimmed: depot.isRetired
                )
            }
    }
}

/// Chooses an ISO-4217 currency from a searchable list (code, name, symbol). Currencies in
/// `preferred` (e.g. those already used in the portfolio) are listed first.
///
/// ```swift
/// CurrencyPicker(selection: $account.currency, preferred: store.file.currencies)
/// ```
public struct CurrencyPicker: View {
    @Binding private var selection: CurrencyCode
    private let preferred: [CurrencyCode]

    public init(selection: Binding<CurrencyCode>, preferred: [CurrencyCode] = []) {
        _selection = selection
        self.preferred = preferred
    }

    public var body: some View {
        SearchablePicker(
            "Currency",
            selection: Binding(get: { selection }, set: { if let code = $0 { selection = code } }),
            items: items, placeholder: "Currency"
        )
    }

    private var items: [PickerItem<CurrencyCode>] {
        var seen = Set<CurrencyCode>()
        var result = [PickerItem<CurrencyCode>]()
        func add(_ code: CurrencyCode) {
            guard seen.insert(code).inserted else { return }
            result.append(PickerItem(id: code, title: code, detail: Currencies.name(code), keywords: [Fmt.currencySymbol(code)]))
        }
        preferred.forEach(add)
        add(selection)
        Currencies.common.forEach(add)
        Currencies.all.forEach(add)
        return result
    }
}

/// ISO currency metadata.
public enum Currencies {
    /// Frequently used currencies, listed before the alphabetical rest.
    public static let common: [CurrencyCode] = ["EUR", "USD", "GBP", "CHF", "JPY", "CAD", "AUD", "SEK", "NOK", "DKK", "PLN", "CNY", "HKD", "SGD"]

    /// All current ISO-4217 codes known to the system, alphabetically.
    public static let all: [CurrencyCode] = Locale.commonISOCurrencyCodes.sorted()

    private static let names = NameCache()

    private final class NameCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache = [String: String]()
        func name(_ code: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            if let n = cache[code] { return n }
            let n = Locale.current.localizedString(forCurrencyCode: code) ?? code
            cache[code] = n
            return n
        }
    }

    /// Localised display name ("Swiss Franc"); the code itself if unknown (e.g. crypto tickers).
    public static func name(_ code: CurrencyCode) -> String { names.name(code) }
}
