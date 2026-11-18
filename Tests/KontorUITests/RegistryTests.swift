import SwiftUI
import Testing
import KontorModel
@testable import KontorUI

@MainActor
@Suite struct Registry {
    @Test func modulesContributeCommandsInspectorsAndSheets() {
        let store = PortfolioStore()
        var ran = 0
        let holdings = FeatureModule(.holdings) { Text("Holdings") }
            .commands { _ in [PaletteCommand(id: "holdings.copy", title: "Copy Holdings", symbol: "doc.on.doc") { ran += 1 }] }
            .inspector { Text("Inspector") }
        let transactions = FeatureModule(.transactions) { Text("Transactions") }
            .sheet { request in
                if case .editTransaction = request {
                    Text("Editor")
                } else if case .newTransaction(let prefill) = request {
                    Label(prefill.note ?? "New", systemImage: "plus")
                } else if case .custom(id: "transactions.split", _) = request {
                    EmptyView()
                }
            }
        let registry = FeatureRegistry([holdings, transactions])

        #expect(registry.module(for: .holdings) != nil)
        #expect(registry.module(for: .dashboard) == nil)
        #expect(registry.inspector(for: .holdings) != nil)
        #expect(registry.inspector(for: .transactions) == nil)

        // Sheets are claimed by whichever feature returns a view for the request.
        #expect(registry.sheet(for: .editTransaction(UUID())) != nil)
        #expect(registry.sheet(for: .newTransaction) != nil)
        #expect(registry.sheet(for: .custom(id: "transactions.split")) != nil)
        #expect(registry.sheet(for: .custom(id: "other")) == nil)
        #expect(registry.sheet(for: .newSecurity) == nil)

        let commands = registry.commands(for: store)
        #expect(commands.map(\.id) == ["holdings.copy"])
        commands[0].action()
        #expect(ran == 1)

        // Registering again replaces the module for that screen.
        registry.register(FeatureModule(.holdings) { Text("New") })
        #expect(registry.commands(for: store).isEmpty)
    }

    @Test func paletteStateResetsOnClose() {
        let store = PortfolioStore()
        store.openCommandPalette(query: "hold")
        #expect(store.isCommandPalettePresented)
        #expect(store.commandPaletteQuery == "hold")
        store.isCommandPalettePresented = false
        #expect(store.commandPaletteQuery.isEmpty)
    }

    @Test func sheetRequestsAreDistinct() {
        let id = UUID()
        #expect(SheetRequest.newTransaction == .newTransaction(TransactionPrefill()))
        #expect(SheetRequest.editSecurity(id) != .editAccount(id))
        #expect(SheetRequest.custom(id: "a") != .custom(id: "b"))
        #expect(SheetRequest.importFile(nil).title == "Import")
    }

    @Test func gainStyles() {
        #expect(GainStyle.greenUp.gain == DS.Colors.green)
        #expect(GainStyle.redUp.gain == DS.Colors.red)
        #expect(GainStyle.redUp.loss == DS.Colors.green)
        #expect(GainStyle.greenUp.color(for: 0) == DS.Colors.neutral)
        #expect(Trend(-1.5) == .down)
        #expect(Trend(minor: 0) == .flat)
        #expect(Trend.up.arrow == "▲")
        #expect(CategoryPalette.colors.count == 8)
        #expect(CategoryPalette.hex(0) == "#2A78D6")
        #expect(CategoryPalette.hex(99) == "#9A9AA0")
    }
}
