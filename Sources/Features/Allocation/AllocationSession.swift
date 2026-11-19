import SwiftUI
import KontorUI

/// View state of the Allocation screen that has to be reachable from outside the screen's view
/// hierarchy: palette commands switch the tab, the inspector and the review sheet need the taxonomy
/// and the rebalancing inputs. One session per `PortfolioStore` (= per window), kept weakly.
@MainActor @Observable
final class AllocationSession {
    enum Tab: String, CaseIterable, Identifiable {
        case allocation, edit, rebalancing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .allocation: "Allocation"
            case .edit: "Edit"
            case .rebalancing: "Rebalancing"
            }
        }
    }

    enum Visual: String, CaseIterable, Identifiable {
        case donut, sunburst, treemap, bars
        var id: String { rawValue }
        var title: String {
            switch self {
            case .donut: "Donut"
            case .sunburst: "Sunburst"
            case .treemap: "Treemap"
            case .bars: "Target vs. Actual"
            }
        }
        var symbol: String {
            switch self {
            case .donut: "chart.pie"
            case .sunburst: "circle.circle"
            case .treemap: "rectangle.split.2x2"
            case .bars: "chart.bar.xaxis"
            }
        }
    }

    enum ProposalMode: String, CaseIterable, Identifiable {
        case classes, orders
        var id: String { rawValue }
        var title: String { self == .classes ? "By Classification" : "By Security" }
    }

    var tab = Tab.allocation
    var visual = Visual.donut
    /// The taxonomy the user picked; resolved against the file by `taxonomy(in:)`.
    var taxonomyID: UUID?
    var rebalancing = RebalancingInputs()
    var proposalMode = ProposalMode.classes
    /// Selected classification in the Edit tab (shared so "Edit Classification" can reveal it).
    var editSelection: UUID?

    /// The selected taxonomy, or the first one if the selection is gone.
    func taxonomy(in file: PortfolioFile) -> Taxonomy? {
        file.taxonomies.first { $0.id == taxonomyID } ?? file.taxonomies.first
    }

    // MARK: Per-store lookup

    private struct Entry {
        weak var store: PortfolioStore?
        let session: AllocationSession
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func session(for store: PortfolioStore) -> AllocationSession {
        let key = ObjectIdentifier(store)
        if let entry = entries[key], entry.store === store { return entry.session }
        entries = entries.filter { $0.value.store != nil }
        let session = AllocationSession()
        entries[key] = Entry(store: store, session: session)
        return session
    }
}

/// What the user typed into the Rebalancing tab. Hashable + Sendable: it is the cache key of the
/// proposal.
struct RebalancingInputs: Hashable, Sendable {
    enum Direction: String, Hashable, Sendable, CaseIterable, Identifiable {
        case invest, withdraw
        var id: String { rawValue }
        var title: String { self == .invest ? "Invest" : "Withdraw" }
    }

    /// Magnitude in minor units of the reporting currency.
    var amount: Int64 = 0
    var direction = Direction.invest
    var buyOnly = false
    var wholeShares = true
    var excludedClassifications: Set<UUID> = []
    var excludedVehicles: Set<AllocationVehicle> = []

    /// Signed cash for the engine: > 0 invests, < 0 withdraws.
    var cash: Int64 { direction == .invest ? amount : -amount }

    var options: RebalancingOptions {
        RebalancingOptions(cash: cash, mode: buyOnly ? .noSales : .buyAndSell, wholeShares: wholeShares)
    }

    var hasExclusions: Bool { !excludedClassifications.isEmpty || !excludedVehicles.isEmpty }

    // Text form for the review sheet's payload.
    var payload: [String: String] {
        [
            "amount": String(amount), "direction": direction.rawValue, "buyOnly": buyOnly ? "1" : "0",
            "wholeShares": wholeShares ? "1" : "0",
            "excludedClasses": excludedClassifications.map(\.uuidString).sorted().joined(separator: ","),
            "excludedVehicles": excludedVehicles.map(\.token).sorted().joined(separator: ","),
        ]
    }

    init() {}

    init(payload: [String: String]) {
        amount = payload["amount"].flatMap(Int64.init) ?? 0
        direction = payload["direction"].flatMap(Direction.init(rawValue:)) ?? .invest
        buyOnly = payload["buyOnly"] == "1"
        wholeShares = payload["wholeShares"] != "0"
        excludedClassifications = Set((payload["excludedClasses"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        excludedVehicles = Set((payload["excludedVehicles"] ?? "").split(separator: ",").compactMap { AllocationVehicle(token: String($0)) })
    }
}
