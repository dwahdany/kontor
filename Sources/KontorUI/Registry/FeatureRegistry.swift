import SwiftUI
import KontorModel

/// An entry of the ⌘K command palette.
public struct PaletteCommand: Identifiable {
    /// What kind of thing the command is — used for grouping and ranking.
    public enum Category: Int, Sendable, Comparable {
        case navigation, action, security, account, other
        public static func < (a: Category, b: Category) -> Bool { a.rawValue < b.rawValue }
        public var title: String {
            switch self {
            case .navigation: "Go to"
            case .action: "Actions"
            case .security: "Securities"
            case .account: "Accounts"
            case .other: "More"
            }
        }
    }

    /// Stable, unique id ("holdings.export-csv").
    public let id: String
    public var title: String
    public var subtitle: String?
    public var symbol: String
    public var category: Category
    /// Extra search terms (ISIN, ticker, synonyms).
    public var keywords: [String]
    /// Display-only shortcut hint ("⌘R").
    public var shortcut: String?
    public var action: @MainActor () -> Void

    public init(
        id: String, title: String, subtitle: String? = nil, symbol: String, category: Category = .action,
        keywords: [String] = [], shortcut: String? = nil, action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.category = category
        self.keywords = keywords
        self.shortcut = shortcut
        self.action = action
    }
}

/// Everything one feature target contributes to the app. Each feature exposes exactly one module
/// (`public enum HoldingsFeature { public static var module: FeatureModule }`); the executable
/// collects them in a `FeatureRegistry`. Features never import each other.
///
/// ```swift
/// public enum HoldingsFeature {
///     @MainActor public static var module: FeatureModule {
///         FeatureModule(.holdings) { HoldingsScreen() }
///             .commands { store in
///                 [PaletteCommand(id: "holdings.copy", title: "Copy Holdings as TSV", symbol: "doc.on.doc") { … }]
///             }
///             .inspector { HoldingInspector() }
///             .sheet { request in
///                 if case .custom(id: "holdings.columns", _) = request { ColumnChooser() }
///             }
///     }
/// }
/// ```
@MainActor
public struct FeatureModule {
    public let screen: AppScreen
    let makeContent: @MainActor () -> AnyView
    var makeCommands: (@MainActor (PortfolioStore) -> [PaletteCommand])?
    var makeInspector: (@MainActor () -> AnyView)?
    var makeSheet: (@MainActor (SheetRequest) -> AnyView?)?

    /// - Parameters:
    ///   - screen: The screen this feature implements.
    ///   - content: The screen's root view. It finds the store in the environment
    ///     (`@Environment(PortfolioStore.self)`).
    public init<Content: View>(_ screen: AppScreen, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.screen = screen
        self.makeContent = { AnyView(content()) }
    }

    /// Contributes commands to the ⌘K palette. Called each time the palette opens, so the list may
    /// depend on the current file (but keep it fast — securities and accounts are already listed
    /// by the shell).
    public func commands(_ make: @escaping @MainActor (PortfolioStore) -> [PaletteCommand]) -> FeatureModule {
        var copy = self
        copy.makeCommands = make
        return copy
    }

    /// Provides the trailing inspector shown while this feature's screen is active. Read
    /// `store.route.focus` to follow the selection; without an inspector the shell shows a generic
    /// summary of the focused entity.
    public func inspector<Content: View>(@ViewBuilder _ content: @escaping @MainActor () -> Content) -> FeatureModule {
        var copy = self
        copy.makeInspector = { AnyView(content()) }
        return copy
    }

    /// Provides sheets for the requests this feature owns. Write `if case … { } else if case … { }`
    /// **without a final `else`**: producing no view lets requests owned by other features fall
    /// through (a `switch` with a default view would claim every request).
    ///
    /// ```swift
    /// .sheet { request in
    ///     if case .newTransaction(let prefill) = request {
    ///         TransactionEditor(prefill: prefill)
    ///     } else if case .editTransaction(let id) = request {
    ///         TransactionEditor(editing: id)
    ///     }
    /// }
    /// ```
    ///
    /// The view should call `store.dismissSheet()` when done.
    public func sheet<Content: View>(@ViewBuilder _ content: @escaping @MainActor (SheetRequest) -> Content?) -> FeatureModule {
        var copy = self
        copy.makeSheet = { request in content(request).map { AnyView($0) } }
        return copy
    }
}

/// Maps screens to feature modules and aggregates their contributions. Built once by the
/// executable and injected into the environment.
@MainActor
public final class FeatureRegistry {
    private var modules: [AppScreen: FeatureModule] = [:]

    public init(_ modules: [FeatureModule] = []) {
        for module in modules { register(module) }
    }

    /// Registers (or replaces) the module for its screen.
    public func register(_ module: FeatureModule) {
        modules[module.screen] = module
    }

    public func module(for screen: AppScreen) -> FeatureModule? { modules[screen] }

    /// The root view of a screen; a placeholder if no feature registered for it.
    public func content(for screen: AppScreen) -> AnyView {
        modules[screen]?.makeContent() ?? AnyView(FeaturePlaceholder(screen))
    }

    /// The feature-provided inspector for a screen, if any.
    public func inspector(for screen: AppScreen) -> AnyView? {
        modules[screen]?.makeInspector?()
    }

    /// The first feature-provided sheet for a request, if any feature claims it.
    public func sheet(for request: SheetRequest) -> AnyView? {
        for screen in AppScreen.allCases {
            if let view = modules[screen]?.makeSheet?(request) { return view }
        }
        return nil
    }

    /// Palette commands of all features, in screen order.
    public func commands(for store: PortfolioStore) -> [PaletteCommand] {
        AppScreen.allCases.flatMap { modules[$0]?.makeCommands?(store) ?? [] }
    }
}

extension EnvironmentValues {
    /// The app's feature registry (shell use; features rarely need it).
    @Entry public var featureRegistry: FeatureRegistry? = nil
}

/// The stand-in a feature target ships until its real screen exists: the screen's icon, title and
/// purpose plus a few live facts from the store, so the app is navigable from day one.
public struct FeaturePlaceholder: View {
    @Environment(PortfolioStore.self) private var store
    @State private var value = Loadable<Money>()
    private let screen: AppScreen

    public init(_ screen: AppScreen) {
        self.screen = screen
    }

    public var body: some View {
        VStack(spacing: DS.Spacing.xl) {
            Spacer(minLength: 0)
            VStack(spacing: DS.Spacing.m) {
                Image(systemName: screen.symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 56)
                Text(screen.title)
                    .font(.title2.weight(.semibold))
                Text(screen.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Spacing.xl) {
                fact(Fmt.integer(store.file.securities.count), "Securities")
                Divider().frame(height: 28)
                fact(Fmt.integer(store.file.transactions.count), "Transactions")
                Divider().frame(height: 28)
                fact(Fmt.integer(store.file.accounts.count + store.file.depots.count), "Accounts")
                Divider().frame(height: 28)
                fact(store.period.shortTitle, "Period")
                Divider().frame(height: 28)
                // Live from the shared analysis layer (scope-aware, computed off the main actor).
                fact(value.value.map { Fmt.compactMoney($0) } ?? Fmt.missing, store.isWholePortfolioScope ? "Value" : "Value in Scope")
                    .opacity(value.isRefreshing ? 0.5 : 1)
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.vertical, DS.Spacing.m)
            .cardBackground()
            Text("This screen is under construction.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.xl)
        .accessibilityElement(children: .combine)
        .analysisTask($value, id: "kontorui.placeholder.value") { analysis in analysis.snapshot.totalValue }
        .toolbar {
            ToolbarItem { ScopePicker(store: store) }
        }
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(spacing: DS.Spacing.xxs) {
            Text(value).font(.kontorValue)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 72)
    }
}
