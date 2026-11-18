import SwiftUI
import KontorModel
import KontorUI

/// Menu bar commands. They act on the focused portfolio window's store and are disabled when no
/// portfolio window is focused.
///
/// Shortcut map (kept conflict-free with the standard document menus):
/// ⌘1…⌘9, ⌘0 screens · ⌘K palette · ⌘[ ⌘] history · ⌥⌘I inspector · ⌥⌘1…⌥⌘5 period
/// ⇧⌘N transaction · ⌥⌘N security · ⌃⌘N account · ⌘R quotes · ⇧⌘K check · ⌥⌘, portfolio settings
/// ⇧⌘I import · ⇧⌘E export
struct AppCommands: Commands {
    @FocusedValue(\.portfolioStore) private var store

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import…") { store.map { $0.services.chooseImportFile?($0) } }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(store == nil)
            Button("Export…") { store.map { $0.services.export?($0) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store == nil)
        }

        SidebarCommands()

        CommandGroup(before: .sidebar) {
            ForEach(AppScreen.Section.allCases) { section in
                ForEach(section.screens) { screen in
                    screenButton(screen)
                }
                Divider()
            }
            Menu("Reporting Period") {
                ForEach(Array(Self.periodShortcuts.enumerated()), id: \.offset) { index, period in
                    Button(period.title) { store?.period = period }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
                Divider()
                ForEach(ReportingPeriod.presets.filter { !Self.periodShortcuts.contains($0) }, id: \.self) { period in
                    Button(period.title) { store?.period = period }
                }
            }
            .disabled(store == nil)
            Divider()
            Button("Back") { store?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(store?.canGoBack != true)
            Button("Forward") { store?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(store?.canGoForward != true)
            Divider()
            Button("Command Palette…") { store?.isCommandPalettePresented.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(store == nil)
            Button(store?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") { store?.isInspectorPresented.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(store == nil)
        }

        CommandMenu("Portfolio") {
            Group {
                Button("New Transaction…") { store?.present(.newTransaction) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Security…") { store?.present(.newSecurity) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Account…") { store?.present(.newAccount) }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                Button("New Depot…") { store?.present(.newDepot) }
                Button("New Plan…") { store?.present(.newPlan) }
                Divider()
                Button("Update Quotes") { store.map { ShellContext.shared.updateQuotes($0) } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store?.activity != nil)
                Button("Check Consistency") { store?.present(.consistencyReport) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Portfolio Settings…") { store?.present(.portfolioSettings) }
                    .keyboardShortcut(",", modifiers: [.command, .option])
            }
            .disabled(store == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Search Commands…") { store?.isCommandPalettePresented = true }
                .keyboardShortcut("?", modifiers: .command)
                .disabled(store == nil)
        }
    }

    /// ⌥⌘1 … ⌥⌘5
    private static let periodShortcuts: [ReportingPeriod] = [
        .yearToDate, .trailingMonths(12), .trailingMonths(36), .trailingMonths(60), .allTime,
    ]

    @ViewBuilder
    private func screenButton(_ screen: AppScreen) -> some View {
        let button = Button(screen.title) { store?.navigate(to: screen) }.disabled(store == nil)
        if let key = screen.shortcutKey {
            button.keyboardShortcut(key, modifiers: .command)
        } else {
            button
        }
    }
}
