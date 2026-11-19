import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Dashboard feature with the app shell. The executable lists `DashboardFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Dashboard` needs to change.
public enum DashboardFeature {
    /// `store.present(.custom(id: gallerySheetID))` — the widget gallery. Payload: `category`.
    static let gallerySheetID = "dashboard.gallery"
    /// `store.present(.custom(id: widgetSheetID, payload: ["widget": <uuid | index | "first">]))` — widget settings.
    static let widgetSheetID = "dashboard.widget"

    @MainActor public static var module: FeatureModule {
        FeatureModule(.dashboard) { DashboardScreen() }
            .commands { store in commands(store) }
            .inspector { DashboardInspector() }
            .sheet { request in
                if case .custom(id: gallerySheetID, let payload) = request {
                    WidgetGallerySheet(payload: payload)
                } else if case .custom(id: widgetSheetID, let payload) = request {
                    WidgetEditorSheet(payload: payload)
                }
            }
    }

    @MainActor private static func commands(_ store: PortfolioStore) -> [PaletteCommand] {
        let session = store.dashboardSession
        let current = store.currentDashboard
        var commands = [
            PaletteCommand(id: "dashboard.edit", title: session.isEditing ? "Finish Editing Dashboard" : "Edit Dashboard",
                           subtitle: "Add, remove, move and resize widgets", symbol: "square.and.pencil",
                           keywords: ["customize", "layout", "widgets", "arrange"], shortcut: "⌘E") {
                store.navigate(to: .dashboard)
                store.toggleDashboardEditing()
            },
            PaletteCommand(id: "dashboard.add-widget", title: "Add Widget…", subtitle: "Dashboard “\(current.name)”",
                           symbol: "rectangle.badge.plus", keywords: ["gallery", "dashboard", "tile", "chart"]) {
                store.navigate(to: .dashboard)
                store.present(.custom(id: gallerySheetID))
            },
            PaletteCommand(id: "dashboard.new", title: "New Dashboard", symbol: "rectangle.3.group",
                           keywords: ["add", "tab", "overview"]) {
                store.navigate(to: .dashboard)
                store.newDashboard()
            },
            PaletteCommand(id: "dashboard.duplicate", title: "Duplicate Dashboard “\(current.name)”", symbol: "plus.square.on.square",
                           keywords: ["copy"]) {
                store.navigate(to: .dashboard)
                store.duplicateDashboard()
            },
            PaletteCommand(id: "dashboard.reset", title: "Reset Dashboard to Default", subtitle: "Replaces the widgets of “\(current.name)” (undoable)",
                           symbol: "arrow.counterclockwise", keywords: ["restore", "layout", "default"]) {
                store.navigate(to: .dashboard)
                store.resetDashboardToDefault()
            },
        ]
        if store.file.dashboards.contains(where: { $0.id == current.id }) {
            commands.append(PaletteCommand(id: "dashboard.delete", title: "Delete Dashboard “\(current.name)”", subtitle: "Undoable",
                                           symbol: "trash", keywords: ["remove"]) {
                store.deleteCurrentDashboard()
            })
        }
        for (offset, title) in [(-1, "Move Dashboard “\(current.name)” Left"), (1, "Move Dashboard “\(current.name)” Right")]
        where store.canMoveCurrentDashboard(by: offset) {
            commands.append(PaletteCommand(id: "dashboard.move.\(offset)", title: title, subtitle: "Order of the dashboard switcher",
                                           symbol: offset < 0 ? "arrow.left" : "arrow.right", keywords: ["reorder", "order", "tab"]) {
                store.navigate(to: .dashboard)
                store.moveCurrentDashboard(by: offset)
            })
        }
        for dashboard in store.file.dashboards where dashboard.id != current.id {
            commands.append(PaletteCommand(id: "dashboard.show.\(dashboard.id.uuidString)", title: "Show Dashboard “\(dashboard.name)”",
                                           symbol: "rectangle.3.group", category: .navigation, keywords: ["switch", "open"]) {
                store.selectDashboard(dashboard.id)
                store.navigate(to: .dashboard)
            })
        }
        return commands
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
