import SwiftUI
import KontorModel
import KontorUI

/// Builds the palette's command list: screens, shell actions, the portfolio's securities and
/// accounts, plus whatever features contribute through the registry.
@MainActor
enum PaletteCommands {
    static func all(store: PortfolioStore, registry: FeatureRegistry) -> [PaletteCommand] {
        var commands = [PaletteCommand]()

        for screen in AppScreen.allCases {
            commands.append(PaletteCommand(
                id: "go.\(screen.id)", title: screen.title, subtitle: screen.summary, symbol: screen.symbol,
                category: .navigation, shortcut: screen.shortcutHint
            ) { store.navigate(to: screen) })
        }

        func action(_ id: String, _ title: String, _ symbol: String, shortcut: String? = nil, keywords: [String] = [], _ run: @escaping @MainActor () -> Void) {
            commands.append(PaletteCommand(id: "shell.\(id)", title: title, symbol: symbol, category: .action, keywords: keywords, shortcut: shortcut, action: run))
        }
        action("new-transaction", "New Transaction", "plus.circle", shortcut: "⇧⌘N", keywords: ["buy", "sell", "dividend", "deposit", "add"]) { store.present(.newTransaction) }
        action("new-security", "New Security", "building.columns", shortcut: "⌥⌘N", keywords: ["stock", "etf", "fund", "add"]) { store.present(.newSecurity) }
        action("new-account", "New Account", "creditcard", shortcut: "⌃⌘N", keywords: ["cash", "add"]) { store.present(.newAccount) }
        action("new-depot", "New Depot", "briefcase", keywords: ["broker", "custody", "add"]) { store.present(.newDepot) }
        action("new-plan", "New Plan", "calendar.badge.clock", keywords: ["savings plan", "recurring"]) { store.present(.newPlan) }
        action("update-quotes", "Update Quotes", "arrow.trianglehead.2.clockwise", shortcut: "⌘R", keywords: ["prices", "refresh", "sync"]) { ShellContext.shared.updateQuotes(store) }
        action("check", "Check Consistency", "checkmark.seal", shortcut: "⇧⌘K", keywords: ["validate", "errors", "problems"]) { store.present(.consistencyReport) }
        action("settings", "Portfolio Settings", "slider.horizontal.3", shortcut: "⌥⌘,", keywords: ["base currency", "benchmark", "cost method"]) { store.present(.portfolioSettings) }
        action("import", "Import…", "square.and.arrow.down", shortcut: "⇧⌘I", keywords: ["csv", "portfolio performance", "xml"]) { store.services.chooseImportFile?(store) }
        action("export", "Export…", "square.and.arrow.up", shortcut: "⇧⌘E", keywords: ["json", "save copy"]) { store.services.export?(store) }
        action("inspector", store.isInspectorPresented ? "Hide Inspector" : "Show Inspector", "sidebar.trailing", shortcut: "⌥⌘I") { store.isInspectorPresented.toggle() }
        for period in ReportingPeriod.presets {
            action("period.\(period.shortTitle)", "Period: \(period.title)", "calendar", keywords: [period.shortTitle, "reporting period", "range"]) { store.period = period }
        }

        commands.append(contentsOf: registry.commands(for: store))

        for security in store.file.securities {
            commands.append(PaletteCommand(
                id: "security.\(security.id.uuidString)", title: security.name,
                subtitle: [security.ticker, security.isin].filter { !$0.isEmpty }.joined(separator: " · "),
                symbol: "building.columns", category: .security, keywords: [security.ticker, security.isin, security.wkn]
            ) { store.navigate(to: .security(security.id)) })
        }
        for account in store.file.accounts {
            commands.append(PaletteCommand(
                id: "account.\(account.id.uuidString)", title: account.name, subtitle: "Account · \(account.currency)",
                symbol: "creditcard", category: .account
            ) { store.navigate(to: .account(account.id)) })
        }
        for depot in store.file.depots {
            commands.append(PaletteCommand(
                id: "depot.\(depot.id.uuidString)", title: depot.name, subtitle: "Depot",
                symbol: "briefcase", category: .account
            ) { store.navigate(to: .depot(depot.id)) })
        }
        return commands
    }
}

/// Hosts the palette above the window content with a dimmed backdrop.
struct CommandPaletteLayer: View {
    @Environment(PortfolioStore.self) private var store
    let registry: FeatureRegistry

    var body: some View {
        if store.isCommandPalettePresented {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { store.isCommandPalettePresented = false }
                        .accessibilityHidden(true)
                    CommandPalette(
                        commands: PaletteCommands.all(store: store, registry: registry),
                        query: Bindable(store).commandPaletteQuery
                    ) {
                        store.isCommandPalettePresented = false
                    }
                    .padding(.top, max(48, proxy.size.height * 0.14))
                }
            }
            .transition(.opacity)
        }
    }
}

/// The ⌘K palette: a search field over a ranked, keyboard-navigable command list.
struct CommandPalette: View {
    let commands: [PaletteCommand]
    @Binding var query: String
    let close: () -> Void

    @State private var highlighted = 0
    @FocusState private var isSearchFocused: Bool

    private struct Row: Identifiable {
        let index: Int
        let command: PaletteCommand
        let positions: [Int]
        /// Section header shown above this row (browse mode only).
        let header: String?
        var id: String { command.id }
    }

    private var rows: [Row] {
        if FuzzyMatcher.Query(query).isEmpty {
            // Browse mode: screens and actions, grouped.
            let browse = commands.filter { $0.category == .navigation || $0.category == .action }.prefix(22)
            var last: PaletteCommand.Category?
            return browse.enumerated().map { index, command in
                defer { last = command.category }
                return Row(index: index, command: command, positions: [], header: command.category != last ? command.category.title : nil)
            }
        }
        let ranked = FuzzyMatcher.rank(commands, query: query, limit: 40) { [$0.title] + $0.keywords + [$0.subtitle ?? ""] }
        return ranked.enumerated().map { Row(index: $0.offset, command: $0.element.item, positions: $0.element.match.positions, header: nil) }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search screens, securities, accounts and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit { run(rows) }
                    .accessibilityLabel("Command palette search")
                Text("esc")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.quaternary))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Spacing.l + 2)
            .padding(.vertical, DS.Spacing.m + 2)

            Divider()

            if rows.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    Text("No Results").font(.headline)
                    Text("Nothing matches “\(query)”.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.xxl)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(rows) { row in
                                if let header = row.header {
                                    Text(header)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, DS.Spacing.m)
                                        .padding(.top, row.index == 0 ? DS.Spacing.xs : DS.Spacing.m)
                                        .padding(.bottom, DS.Spacing.xxs)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                PaletteRow(command: row.command, positions: row.positions, isHighlighted: row.index == highlighted)
                                    .id(row.index)
                                    .onTapGesture {
                                        highlighted = row.index
                                        run(rows)
                                    }
                                    .onHover { if $0 { highlighted = row.index } }
                            }
                        }
                        .padding(DS.Spacing.s)
                    }
                    .frame(maxHeight: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
                }
            }

            Divider()
            HStack(spacing: DS.Spacing.l) {
                hint("↑↓", "Navigate")
                hint("⏎", "Open")
                Spacer()
                Text("\(rows.count) result\(rows.count == 1 ? "" : "s")").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
        }
        .frame(width: 620)
        .glassPanel()
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(rows.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onExitCommand(perform: close)
        .accessibilityAddTraits(.isModal)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(key).fontWeight(.medium)
            Text(label)
        }
    }

    private func run(_ rows: [Row]) {
        guard rows.indices.contains(highlighted) else { return }
        let command = rows[highlighted].command
        close()
        command.action()
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let positions: [Int]
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: command.symbol)
                .frame(width: 22)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 0) {
                Text(highlightedTitle).lineLimit(1)
                if let subtitle = command.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Spacing.s)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, 6)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(
            isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// The title with matched characters emphasised.
    private var highlightedTitle: AttributedString {
        var result = AttributedString()
        let matched = Set(positions)
        for (offset, character) in command.title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.font = .body.weight(.bold)
                piece.underlineStyle = isHighlighted ? .single : nil
            }
            result.append(piece)
        }
        return result
    }
}
